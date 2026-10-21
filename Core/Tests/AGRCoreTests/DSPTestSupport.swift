import XCTest
@testable import AGRCore

/// Shared helpers for audio tests (pitch estimation, simple chord rendering).
enum AudioTest {
    /// Pitch of the strongest spectral peak within ±6% of `expected` (Hz) using a Hann window,
    /// zero-padding and parabolic interpolation of the log-magnitude.
    static func estimatePitch(_ x: [Float], sampleRate: Double, expected: Double, from: Double, to: Double) -> Double {
        let a = Int(from * sampleRate), b = min(Int(to * sampleRate), x.count)
        let seg = Array(x[a..<b])
        let n = seg.count
        var padded = [Float](repeating: 0, count: 1 << 18)
        for i in 0..<n { padded[i] = seg[i] * Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        let mags = FFT.magnitudes(of: padded)
        let df = sampleRate / Double(padded.count)
        let lo = Int(expected * 0.94 / df), hi = Int(expected * 1.06 / df)
        var best = lo
        for k in lo...hi where mags[k] > mags[best] { best = k }
        let l = log(Double(mags[best - 1]) + 1e-20), c = log(Double(mags[best]) + 1e-20), r = log(Double(mags[best + 1]) + 1e-20)
        let delta = 0.5 * (l - r) / (l - 2 * c + r)
        return (Double(best) + delta) * df
    }

    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }
    static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    static func energy(_ x: [Float], sampleRate: Double, from: Double, to: Double) -> Double {
        let a = Int(from * sampleRate), b = min(Int(to * sampleRate), x.count)
        var s = 0.0
        for i in a..<b { s += Double(x[i]) * Double(x[i]) }
        return s / Double(max(b - a, 1))
    }

    /// Strummed chord events (low → high, 12 ms apart) for a voicing string like "x32010".
    static func strum(_ shape: String, at time: Double, velocity: Float = 0.8, duration: Double = 3, up: Bool = false) -> [NoteEvent] {
        let notes = Voicing(shape)!.stringNotes(tuning: ScoreMeta.standardTuning, capo: 0)
        let ordered = up ? Array(notes.reversed()) : notes
        return ordered.enumerated().map { i, n in
            NoteEvent(time: time + Double(i) * 0.012, midi: n.midi, velocity: velocity, duration: duration,
                      stringIndex: n.string, eventIndex: 0)
        }
    }

    static func noise(_ n: Int, rms: Float, seed: UInt64 = 7) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { _ in Float(rng.signed()) * rms * 1.732 }
    }
}
