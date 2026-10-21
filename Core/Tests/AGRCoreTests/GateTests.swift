import XCTest
@testable import AGRCore

/// Noise gate of `FeatureExtractor`: time hysteresis, adaptive floor, no gating of music (decays, soft plucks,
/// long sustained chords), fast stop / restart detection.
final class GateTests: XCTestCase {
    static let sr = 22050.0
    static let hop = 512.0 / sr
    static let halfWindow = 2048.0 / sr   // a frame's `time` is its window centre

    /// A chord of four partials with the given RMS (constant amplitude), `seconds` long.
    func chord(_ seconds: Double, rms: Float, from start: Int = 0) -> [Float] {
        let n = Int(seconds * Self.sr)
        let freqs = [110.0, 164.8, 220.0, 329.6]
        let a = rms / Float(2).squareRoot()      // four sines of amplitude a (distinct frequencies): rms = a * sqrt(2)
        return (0..<n).map { i in
            let t = Double(start + i) / Self.sr
            var v: Float = 0
            for f in freqs { v += a * Float(sin(2 * Double.pi * f * t)) }
            return v
        }
    }

    func noise(_ seconds: Double, rms: Float, seed: UInt64 = 7) -> [Float] {
        AudioTest.noise(Int(seconds * Self.sr), rms: rms, seed: seed)
    }

    func mix(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    func run(_ x: [Float], config: FeatureConfig = .init()) -> [FeatureFrame] {
        FeatureExtractor(config: config, inputSampleRate: Self.sr).process(x)
    }

    func frames(_ fs: [FeatureFrame], from: Double, to: Double) -> [FeatureFrame] {
        fs.filter { $0.time >= from && $0.time < to }
    }

    func silentFraction(_ fs: [FeatureFrame]) -> Double {
        fs.isEmpty ? 0 : Double(fs.filter(\.isSilent).count) / Double(fs.count)
    }

    // MARK: stop / restart

    func testSilenceIsReportedQuicklyAfterStopAndReopensAtRestart() {
        // 4 s of room noise (the floor is learned), 3 s of chord, a 5 s full stop, the chord again.
        let tStop = 7.0, tRestart = 12.0
        var sound = [Float](repeating: 0, count: Int(tRestart * Self.sr))
        let c1 = chord(3, rms: 0.05)
        for i in 0..<c1.count { sound[Int(4 * Self.sr) + i] = c1[i] }
        sound += chord(3, rms: 0.05, from: Int(tRestart * Self.sr))
        let x = mix(sound, noise(Double(sound.count) / Self.sr, rms: 0.004))
        let fs = run(x)

        // Silent before the music, open during it.
        XCTAssertGreaterThan(silentFraction(frames(fs, from: 1, to: 3.8)), 0.99)
        XCTAssertEqual(silentFraction(frames(fs, from: 4.2, to: tStop - 0.2)), 0)

        // Stop: silent within 0.5 s (live time: frame time + half a window) and stays silent for the whole pause.
        let firstSilent = fs.first { $0.time > tStop - 0.2 && $0.isSilent }!
        XCTAssertLessThan(firstSilent.time + Self.halfWindow - tStop, 0.5)
        XCTAssertEqual(silentFraction(frames(fs, from: firstSilent.time, to: tRestart - Self.halfWindow - 0.01)), 1)

        // Restart: not silent one hop after the sound reaches the analysis window (plus frame alignment).
        let reopen = fs.first { $0.time > tRestart - 1 && !$0.isSilent && $0.time > tRestart - Self.halfWindow - 0.05 }!
        XCTAssertLessThanOrEqual(reopen.time + Self.halfWindow - tRestart, Self.hop * 1.3,
                                 "gate reopened \(reopen.time + Self.halfWindow - tRestart) s after the restart")
        XCTAssertEqual(silentFraction(frames(fs, from: reopen.time, to: tRestart + 2.8)), 0)
    }

    func testClosingFramesAreFlaggedQuietButNotSilent() {
        let x = mix(chord(2, rms: 0.05) + [Float](repeating: 0, count: Int(3 * Self.sr)), noise(5, rms: 0.004))
        let fs = run(x)
        let quiet = fs.filter { $0.isQuiet }
        XCTAssertGreaterThan(quiet.count, 5)
        XCTAssertTrue(quiet.allSatisfy { !$0.isSilent })
        // A quiet run lasts about the hold time (0.25 s = 11 frames) and is followed by silence.
        let firstQuiet = fs.firstIndex { $0.isQuiet }!
        let firstSilent = fs.firstIndex { $0.isSilent && $0.time > 1.5 }!
        XCTAssertEqual(Double(firstSilent - firstQuiet), 0.25 / Self.hop, accuracy: 3)
        XCTAssertTrue(fs.filter { $0.isSilent }.allSatisfy { !$0.isQuiet })
    }

    // MARK: noise floor

    func testRisingRoomNoiseIsTrackedAndStaysSilent() {
        // Room noise rises 4x (12 dB) over 60 s; then a chord must still open the gate.
        let n = Int(60 * Self.sr)
        let base = noise(60, rms: 1)
        let x: [Float] = (0..<n).map { i in base[i] * Float(0.003 * pow(4.0, Double(i) / Double(n))) }
        let fs = run(x + mix(chord(1.5, rms: 0.05), noise(1.5, rms: 0.012)))
        XCTAssertGreaterThan(silentFraction(frames(fs, from: 2, to: 60)), 0.99, "rising noise must not open the gate")
        let extractor = FeatureExtractor(inputSampleRate: Self.sr)
        _ = extractor.process(x)
        XCTAssertGreaterThan(extractor.noiseFloorEstimate, 0.007, "the floor follows the noise up")
        XCTAssertLessThan(extractor.noiseFloorEstimate, 0.012)
        XCTAssertEqual(silentFraction(frames(fs, from: 60.2, to: 61.2)), 0)
    }

    func testFloorDoesNotClimbToTheMusicLevelDuringLongPlaying() {
        // 3 s of noise, then 100 s of a chord with ±20 % tremolo: floor stays near the noise, gate stays open.
        let n = Int(100 * Self.sr)
        let c = chord(100, rms: 0.03)
        let x: [Float] = (0..<n).map { i in c[i] * Float(1 + 0.2 * sin(2 * Double.pi * 0.5 * Double(i) / Self.sr)) }
        let all = mix(noise(3, rms: 0.004) + x, noise(103, rms: 0.004, seed: 11))
        let extractor = FeatureExtractor(inputSampleRate: Self.sr)
        let fs = extractor.process(all)
        XCTAssertEqual(silentFraction(frames(fs, from: 3.3, to: 103)), 0, "a long sustained chord must not be gated")
        XCTAssertLessThan(extractor.noiseFloorEstimate, 0.006, "floor \(extractor.noiseFloorEstimate) must stay at the noise")
    }

    // MARK: music is not gated

    func decayingNotes(_ seconds: Double, every: Double, peakRMS: Float, tau: Double, from start: Double = 0) -> [Float] {
        let n = Int(seconds * Self.sr)
        var out = [Float](repeating: 0, count: n)
        var t0 = start
        let freqs = [196.0, 246.9, 293.7, 392.0]
        var k = 0
        while t0 < seconds {
            let f = freqs[k % freqs.count]; k += 1
            let i0 = Int(t0 * Self.sr)
            for i in i0..<min(n, i0 + Int(tau * 8 * Self.sr)) {
                let t = Double(i - i0) / Self.sr
                out[i] += peakRMS * Float(2).squareRoot() * Float(exp(-t / tau) * sin(2 * Double.pi * f * t))
            }
            t0 += every
        }
        return out
    }

    func testSoftPluckGapsAreNotGated() {
        // Soft arpeggio: a pluck every 0.35 s (peak RMS 0.02, i.e. 14 dB above the noise, decaying in 0.2 s: the
        // windowed level of a pluck is only about 8 dB above the noise and falls to it between plucks).
        let x = mix(decayingNotes(30, every: 0.35, peakRMS: 0.02, tau: 0.2, from: 3), noise(30, rms: 0.004))
        let fs = run(x)
        XCTAssertGreaterThan(silentFraction(frames(fs, from: 1, to: 2.8)), 0.99)
        XCTAssertLessThan(silentFraction(frames(fs, from: 4, to: 30)), 0.02, "silent between soft plucks")
    }

    func testDecayBetweenStrumsIsNotGated() {
        // Loud strums every 1.6 s decaying slowly (tau 0.5 s): the valleys fall to the noise level, yet the gate stays
        // open (hold time) until the music has really stopped.
        let x = mix(decayingNotes(40, every: 1.6, peakRMS: 0.06, tau: 0.5, from: 3), noise(40, rms: 0.004))
        let fs = run(x)
        XCTAssertLessThan(silentFraction(frames(fs, from: 4, to: 38)), 0.10)
        // The same take with a 3 s gap is reported silent in the gap.
        let y = mix(decayingNotes(10, every: 1.6, peakRMS: 0.06, tau: 0.5, from: 3) + [Float](repeating: 0, count: Int(6 * Self.sr)), noise(16, rms: 0.004))
        let gs = run(y)
        XCTAssertGreaterThan(silentFraction(frames(gs, from: 12.5, to: 15.5)), 0.95)
    }

    func testQuietPlayerStillDetected() {
        // -12 dB player (rms 0.012) over a quiet room (0.0015).
        let x = mix(noise(2, rms: 0.0015) + chord(4, rms: 0.012) + noise(3, rms: 0.0015), noise(9, rms: 0.0015, seed: 3))
        let fs = run(x)
        XCTAssertEqual(silentFraction(frames(fs, from: 2.3, to: 5.9)), 0)
        XCTAssertGreaterThan(silentFraction(frames(fs, from: 7, to: 9)), 0.99)
    }

    func testBassChromaCoversE2ToE3() {
        // A low E (82 Hz = MIDI 40) is in the bass chroma; a sung A3 (220 Hz = MIDI 57) is not.
        func bassOf(_ f: Double) -> [Float] {
            let n = Int(2 * Self.sr)
            let x = (0..<n).map { Float(0.1 * sin(2 * Double.pi * f * Double($0) / Self.sr)) }
            let fs = run(x)
            return fs[fs.count / 2].bassChroma
        }
        let low = bassOf(82.41)
        XCTAssertEqual(low.firstIndex(of: low.max()!), 4)
        XCTAssertGreaterThan(low.max()!, 0.9)
        let cfg = FeatureConfig()
        XCTAssertEqual(cfg.bassMaxMidi, 52)
        // MIDI 53 (F3, 174.6 Hz) is above the range: its pitch class (5) gets little weight in the bass chroma.
        let high = bassOf(174.61)
        XCTAssertLessThan(high[5], 0.5)
    }
}
