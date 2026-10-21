import Foundation

/// Small DSP helpers shared by the microphone adapter (no framework types, unit-testable).
enum AudioMath {
    /// Average of all channels. `channels[i]` points at `frames` samples.
    static func downmixToMono(channels: [UnsafePointer<Float>], frames: Int) -> [Float] {
        guard frames > 0, let first = channels.first else { return [] }
        if channels.count == 1 {
            return Array(UnsafeBufferPointer(start: first, count: frames))
        }
        var out = [Float](repeating: 0, count: frames)
        for ch in channels {
            for i in 0..<frames { out[i] += ch[i] }
        }
        let scale = 1 / Float(channels.count)
        for i in 0..<frames { out[i] *= scale }
        return out
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Level in dBFS (-120 for silence).
    static func dBFS(rms: Float) -> Float {
        rms > 1e-6 ? 20 * log10f(rms) : -120
    }

    /// Meter position 0...1 for a dBFS value (-60 dB ... 0 dB).
    static func meterPosition(dB: Float) -> Float {
        min(max((dB + 60) / 60, 0), 1)
    }
}

/// Thread-safe input level (written from the capture thread, read by the UI): fast attack, slow release.
final class MicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = -120
    private let releasePerUpdate: Float

    /// `releasePerUpdate`: dB the level falls per `update` call when the input is quieter (about 23 ms per call).
    init(releasePerUpdate: Float = 1.5) {
        self.releasePerUpdate = releasePerUpdate
    }

    func update(rms: Float) {
        let db = AudioMath.dBFS(rms: rms)
        lock.lock()
        level = db > level ? db : max(db, level - releasePerUpdate)
        lock.unlock()
    }

    var dB: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    func reset() {
        lock.lock(); level = -120; lock.unlock()
    }
}
