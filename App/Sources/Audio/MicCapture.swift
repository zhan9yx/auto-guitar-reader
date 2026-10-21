import Foundation
import AVFoundation

/// State shared with the capture (tap) thread. Handlers are swapped under a lock; the tap block only talks to this
/// object, never to main-actor state.
final class MicSink: @unchecked Sendable {
    let meter = MicLevelMeter()
    private let lock = NSLock()
    private var onSamples: (([Float]) -> Void)?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func configure(onSamples: (([Float]) -> Void)?, onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.onSamples = onSamples
        self.onBuffer = onBuffer
        lock.unlock()
    }

    /// Runs on the engine's tap thread (not the real-time render thread, but still latency sensitive): copy out of the
    /// buffer, downmix, hand over. The HMM never runs here.
    func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }
        var pointers: [UnsafePointer<Float>] = []
        pointers.reserveCapacity(channelCount)
        for c in 0..<channelCount { pointers.append(UnsafePointer(channelData[c])) }
        let mono = AudioMath.downmixToMono(channels: pointers, frames: frames)
        meter.update(rms: AudioMath.rms(mono))

        lock.lock()
        let samplesHandler = onSamples
        let bufferHandler = onBuffer
        lock.unlock()
        samplesHandler?(mono)
        bufferHandler?(buffer)
    }
}

/// Microphone capture through `AVAudioEngine.inputNode` (the audio session must already be `.playAndRecord` /
/// `.measurement`). Delivers mono Float samples at the hardware sample rate plus the raw buffers (for speech).
@MainActor
final class MicCapture {
    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "找不到可用的麦克风输入" }
    }

    private let engine = AVAudioEngine()
    private let sink = MicSink()
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0

    /// Input level in dBFS (thread-safe, poll from the UI).
    var levelDB: Float { sink.meter.dB }

    /// The hardware changed under us (sample rate, route): the owner should stop / restart following.
    var onConfigurationChange: (() -> Void)?

    init() {}

    /// Reads the input format. Throws when there is no usable input (no permission, no device).
    func prepare() throws -> Double {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        sampleRate = format.sampleRate
        return format.sampleRate
    }

    /// `onSamples` / `onBuffer` are called on the tap thread.
    func start(onSamples: @escaping ([Float]) -> Void, onBuffer: ((AVAudioPCMBuffer) -> Void)?) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        sampleRate = format.sampleRate
        sink.meter.reset()
        sink.configure(onSamples: onSamples, onBuffer: onBuffer)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: MicCapture.makeTapBlock(sink: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.configure(onSamples: nil, onBuffer: nil)
            throw error
        }
        isRunning = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onConfigurationChange?() }
        }
    }

    func stop() {
        if let token = configObserver {
            NotificationCenter.default.removeObserver(token)
            configObserver = nil
        }
        guard isRunning else {
            sink.configure(onSamples: nil, onBuffer: nil)
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.configure(onSamples: nil, onBuffer: nil)
        sink.meter.reset()
        isRunning = false
    }

    /// Nonisolated on purpose: the tap block runs on a framework thread.
    nonisolated private static func makeTapBlock(sink: MicSink) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            sink.handle(buffer)
        }
    }
}
