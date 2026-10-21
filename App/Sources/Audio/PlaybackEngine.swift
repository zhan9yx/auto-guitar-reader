import Foundation
import AVFoundation
import AGRCore

/// AVAudioEngine + `AVAudioSourceNode` that renders `SequencerEngine` (mono Float32 at the hardware sample rate).
///
/// Threading:
/// * main actor: `start`, `install`, `setPlaying`, `seek`, `positionSeconds`, volume / brightness.
/// * audio render thread: the source node's block, which only calls `SequencerBox.render`.
/// New `SequencerEngine`s are built on the main thread and handed over through `SequencerBox` (try-lock swap, the
/// old engine is freed on the main thread). `setPlaying` / `seek` / `positionSeconds` go straight to the *active*
/// engine, whose own lock protocol (see `SequencerEngine`) makes them safe against the render thread.
@MainActor
final class PlaybackEngine: PlaybackOutput {
    enum EngineError: LocalizedError {
        case noOutputFormat
        var errorDescription: String? { "无法创建音频输出格式" }
    }

    /// Created on first use (see `MicCapture.engine`).
    private lazy var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let box = SequencerBox()
    /// The engine the audio thread is (or is about to be) rendering. Main thread only.
    private var active: SequencerEngine?
    private var lastEvents: [NoteEvent] = []
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false

    private(set) var sampleRate: Double = 44100
    private var volume: Float = 0.8
    private var brightness: Float = 0.5

    /// Called after the engine had to be rebuilt (route / sample-rate change).
    var onRebuilt: (() -> Void)?

    init() {}

    // MARK: Lifecycle

    /// Builds the graph and starts the engine. The audio session must already be active (`.playback`).
    func start() throws {
        guard !isRunning else { return }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 44100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw EngineError.noOutputFormat
        }
        let node = AVAudioSourceNode(format: format, renderBlock: PlaybackEngine.makeRenderBlock(box: box))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        engine.prepare()
        try engine.start()
        isRunning = true

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleConfigurationChange() }
            }
        }
    }

    /// Stops the engine and releases the sequencers.
    func stop() {
        if let token = configObserver {
            NotificationCenter.default.removeObserver(token)
            configObserver = nil
        }
        teardownGraph()
        box.releaseAll()
        active = nil
        lastEvents = []
    }

    private func teardownGraph() {
        // Never started: do not instantiate the (lazy) AVAudioEngine just to stop it.
        guard isRunning || sourceNode != nil else { return }
        engine.stop()
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        sourceNode = nil
        isRunning = false
    }

    /// The hardware configuration changed (headphones, Bluetooth, sample rate): rebuild at the new rate and resume.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        let position = active?.positionSeconds ?? 0
        let wasPlaying = active?.isPlaying ?? false
        let events = lastEvents
        teardownGraph()
        do {
            try start()
            if !events.isEmpty {
                install(events: events, seekSeconds: position, playing: wasPlaying)
            }
            onRebuilt?()
        } catch {
            isRunning = false
        }
    }

    // MARK: PlaybackOutput

    func install(events: [NoteEvent], seekSeconds: Double, playing: Bool) {
        let sequencer = SequencerEngine(sampleRate: sampleRate, events: events)
        // Plain Float stores before the engine is published: no race yet.
        sequencer.synth.volume = volume
        sequencer.synth.brightness = brightness
        sequencer.seek(toSeconds: seekSeconds)
        sequencer.isPlaying = playing
        lastEvents = events
        active = sequencer
        box.submit(sequencer)
    }

    func setPlaying(_ playing: Bool) {
        active?.isPlaying = playing
    }

    func seek(toSeconds seconds: Double) {
        active?.seek(toSeconds: seconds)
    }

    var positionSeconds: Double { active?.positionSeconds ?? 0 }

    /// Synth knobs are plain `Float` properties read by the render thread; a torn read of an aligned 32-bit float
    /// does not exist on the supported CPUs, and a one-block-late update is inaudible.
    func setVolume(_ volume: Float) {
        self.volume = volume
        active?.synth.volume = volume
    }

    func setBrightness(_ brightness: Float) {
        self.brightness = brightness
        active?.synth.brightness = brightness
    }

    // MARK: Render block (audio thread)

    /// Created in a nonisolated context on purpose: the closure must not inherit main-actor isolation.
    nonisolated private static func makeRenderBlock(box: SequencerBox) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let raw = first.mData else { return noErr }
            let out = raw.assumingMemoryBound(to: Float.self)
            let frames = Int(frameCount)
            box.render(into: out, frameCount: frames)
            // Mono source: should the system ask for more buffers, duplicate the signal.
            if buffers.count > 1 {
                for k in 1..<buffers.count {
                    if let other = buffers[k].mData?.assumingMemoryBound(to: Float.self) {
                        other.update(from: out, count: frames)
                    }
                }
            }
            return noErr
        }
    }
}
