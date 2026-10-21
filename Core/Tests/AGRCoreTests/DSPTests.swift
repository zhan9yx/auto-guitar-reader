import XCTest
@testable import AGRCore

final class DSPTests: XCTestCase {
    // MARK: FFT

    func naiveDFT(_ x: [Float]) -> (re: [Double], im: [Double]) {
        let n = x.count
        var re = [Double](repeating: 0, count: n / 2 + 1), im = re
        for k in 0...(n / 2) {
            for t in 0..<n {
                let a = -2 * Double.pi * Double(k * t % n) / Double(n)
                re[k] += Double(x[t]) * cos(a); im[k] += Double(x[t]) * sin(a)
            }
        }
        return (re, im)
    }

    func testFFTMatchesNaiveDFT() {
        var rng = SplitMix64(seed: 3)
        for n in [4, 8, 16, 64, 256, 1024] {
            let x = (0..<n).map { _ in Float(rng.signed()) }
            let fft = FFT(size: n, allowAccelerate: false)
            var re = [Float](repeating: 0, count: n / 2 + 1), im = re
            x.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: &re, im: &im) }
            let ref = naiveDFT(x)
            var maxErr = 0.0
            for k in 0...(n / 2) {
                maxErr = max(maxErr, abs(Double(re[k]) - ref.re[k]), abs(Double(im[k]) - ref.im[k]))
            }
            XCTAssertLessThan(maxErr, 2e-4 * Double(n).squareRoot() , "n=\(n)")
            XCTAssertEqual(im[0], 0, accuracy: 1e-6); XCTAssertEqual(im[n / 2], 0, accuracy: 1e-4)
        }
    }

    func testFFTSineAndParseval() {
        let n = 4096
        let x = (0..<n).map { Float(sin(2 * Double.pi * 100 * Double($0) / Double(n))) }
        let mags = FFT.magnitudes(of: x)
        XCTAssertEqual(mags.count, n / 2 + 1)
        XCTAssertEqual(Double(mags[100]), Double(n) / 2, accuracy: 0.5)
        XCTAssertLessThan(Double(mags[50]), 0.01)
        let timeEnergy = x.reduce(0) { $0 + Double($1) * Double($1) }
        var spec = 0.0
        for k in 0...(n / 2) { spec += Double(mags[k]) * Double(mags[k]) * (k == 0 || k == n / 2 ? 1 : 2) }
        XCTAssertEqual(spec / Double(n), timeEnergy, accuracy: timeEnergy * 1e-3)
        XCTAssertTrue(FFT.isPowerOfTwo(4096)); XCTAssertFalse(FFT.isPowerOfTwo(100))
    }

    // MARK: Resampler

    func tone(_ f: Double, sr: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * Double.pi * f * Double($0) / sr)) }
    }

    func testResamplerPreservesToneFrequencyAndAmplitude() {
        for sr in [44100.0, 48000.0, 16000.0, 22050.0] {
            let r = StreamResampler(inputRate: sr, outputRate: 22050)
            var out: [Float] = []
            let x = tone(440, sr: sr, seconds: 2)
            x.withUnsafeBufferPointer { r.process($0, into: &out) }
            XCTAssertEqual(Double(out.count), 2 * 22050, accuracy: 40, "sr \(sr)")
            let f = AudioTest.estimatePitch(out, sampleRate: 22050, expected: 440, from: 0.5, to: 1.5)
            XCTAssertEqual(f, 440, accuracy: 0.2, "sr \(sr)")
            var s = 0.0
            for v in out[11025..<33075] { s += Double(v) * Double(v) }
            XCTAssertEqual((s / 22050).squareRoot(), 0.5 / 2.0.squareRoot(), accuracy: 0.005, "sr \(sr)")
        }
    }

    func testResamplerRejectsAliasingFrequencies() {
        // 15 kHz at 44.1 kHz is above the 11.025 kHz output Nyquist: must be strongly attenuated, not folded.
        let r = StreamResampler(inputRate: 44100, outputRate: 22050)
        var out: [Float] = []
        tone(15000, sr: 44100, seconds: 1, amp: 0.5).withUnsafeBufferPointer { r.process($0, into: &out) }
        let rms = (out[2000...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(out.count - 2000)).squareRoot()
        XCTAssertLessThan(20 * log10(rms / (0.5 / 2.0.squareRoot())), -60)
    }

    func testResamplerStreamingEqualsOneShot() {
        let x = tone(330, sr: 48000, seconds: 1.5) + tone(1500, sr: 48000, seconds: 0.5, amp: 0.2)
        let one = StreamResampler(inputRate: 48000, outputRate: 22050)
        var a: [Float] = []
        x.withUnsafeBufferPointer { one.process($0, into: &a) }
        let ch = StreamResampler(inputRate: 48000, outputRate: 22050)
        var b: [Float] = []
        var i = 0, size = 1
        while i < x.count {
            let n = min(size, x.count - i)
            x[i..<(i + n)].withUnsafeBufferPointer { ch.process($0, into: &b) }
            i += n; size = size * 3 % 4999 + 1
        }
        XCTAssertEqual(a.count, b.count)
        for k in 0..<min(a.count, b.count) { XCTAssertEqual(a[k], b[k], accuracy: 1e-6) }
    }

    // MARK: Feature extraction

    func renderEvents(_ events: [NoteEvent], sr: Double = 44100, tail: Double = 0.5) -> [Float] {
        OfflineRenderer.render(events, sampleRate: sr, tail: tail)
    }

    func meanChroma(_ frames: [FeatureFrame], from: Double, to: Double, bass: Bool = false) -> [Float] {
        var acc = [Float](repeating: 0, count: 12)
        for f in frames where f.time >= from && f.time <= to && !f.isSilent {
            for i in 0..<12 { acc[i] += bass ? f.bassChroma[i] : f.chroma[i] }
        }
        return acc
    }

    func topPitchClasses(_ v: [Float], _ k: Int) -> Set<Int> {
        Set(v.enumerated().sorted { $0.element > $1.element }.prefix(k).map(\.offset))
    }

    func testFrameRateAndTimes() {
        for sr in [22050.0, 44100.0, 48000.0] {
            let fe = FeatureExtractor(inputSampleRate: sr)
            let frames = fe.process(AudioTest.noise(Int(sr * 3), rms: 0.1))
            XCTAssertEqual(frames.first!.time, 0, accuracy: 1e-12)
            for (a, b) in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(b.time - a.time, 512.0 / 22050.0, accuracy: 1e-9)
            }
            // 3 s → about 3 * 22050/512 frames (minus the look-ahead of window/2).
            XCTAssertEqual(Double(frames.count), 3 * 22050.0 / 512.0, accuracy: 6, "sr \(sr)")
            XCTAssertEqual(FeatureConfig().frameRate, 22050.0 / 512.0, accuracy: 1e-12)
            XCTAssertEqual(frames[10].semitone.count, 49)
            XCTAssertEqual(frames[10].chroma.count, 12)
        }
    }

    func testSemitoneSpectrumPeaksAtToneNote() {
        for midi in [40, 45, 57, 69, 81] {
            let f = AudioTest.hz(midi)
            let x = tone(f, sr: 22050, seconds: 1.5, amp: 0.3)
            let frames = FeatureExtractor(inputSampleRate: 22050).process(x)
            let mid = frames[frames.count / 2]
            let best = mid.semitone.enumerated().max { $0.element < $1.element }!.offset
            XCTAssertEqual(best + 40, midi, "tone at midi \(midi)")
            XCTAssertEqual(mid.chroma[midi % 12], mid.chroma.max()!)
        }
    }

    /// Triad template (root 1.0, third 0.8, fifth 0.8) classification among all 24 major/minor chords.
    func classify(_ chroma: [Float]) -> (root: Int, minor: Bool) {
        var best = (root: 0, minor: false), bestScore = -Float.infinity
        for root in 0..<12 {
            for minor in [false, true] {
                var t = [Float](repeating: 0, count: 12)
                t[root] = 1; t[(root + (minor ? 3 : 4)) % 12] = 0.8; t[(root + 7) % 12] = 0.8
                let tn = t.reduce(0) { $0 + $1 * $1 }.squareRoot()
                let cn = chroma.reduce(0) { $0 + $1 * $1 }.squareRoot()
                var dot: Float = 0
                for i in 0..<12 { dot += t[i] * chroma[i] }
                let sc = dot / (tn * cn)
                if sc > bestScore { bestScore = sc; best = (root, minor) }
            }
        }
        return best
    }

    func testChromaOfRenderedCMajorPeaksAtChordTones() {
        let x = renderEvents(AudioTest.strum("x32010", at: 0.2, duration: 2.5), tail: 0.5)
        let frames = FeatureExtractor(inputSampleRate: 44100).process(x)
        let c = meanChroma(frames, from: 0.6, to: 2.2)
        XCTAssertEqual(topPitchClasses(c, 3), [0, 4, 7], "\(c)")
    }

    func testRenderedChordsAreClassifiedByTriadTemplates() {
        let cases: [(String, Int, Bool)] = [("x32010", 0, false), ("320003", 7, false), ("x02210", 9, true),
                                            ("133211", 5, false), ("022000", 4, true), ("xx0232", 2, false),
                                            ("xx0231", 2, true), ("022100", 4, false), ("x24432", 11, true)]
        for (shape, root, minor) in cases {
            let x = renderEvents(AudioTest.strum(shape, at: 0.2, duration: 2.5), tail: 0.5)
            let frames = FeatureExtractor(inputSampleRate: 44100).process(x)
            let c = meanChroma(frames, from: 0.6, to: 2.2)
            let r = classify(c)
            XCTAssertEqual(r.root, root, "\(shape): \(c)")
            XCTAssertEqual(r.minor, minor, "\(shape): \(c)")
        }
    }

    func testChromaWorksAtOtherInputRates() {
        let x = renderEvents(AudioTest.strum("x32010", at: 0.2, duration: 2.5), sr: 48000)
        let frames = FeatureExtractor(inputSampleRate: 48000).process(x)
        XCTAssertEqual(topPitchClasses(meanChroma(frames, from: 0.6, to: 2.2), 3), [0, 4, 7])
    }

    func testBassChromaFollowsLowestNote() {
        func bassTop(_ shape: String) -> Int {
            let x = renderEvents(AudioTest.strum(shape, at: 0.2, duration: 2.5))
            let frames = FeatureExtractor(inputSampleRate: 44100).process(x)
            let c = meanChroma(frames, from: 0.5, to: 2.2, bass: true)
            return c.enumerated().max { $0.element < $1.element }!.offset
        }
        XCTAssertEqual(bassTop("332010"), 7)   // C/G
        XCTAssertEqual(bassTop("x32010"), 0)   // C
        XCTAssertEqual(bassTop("x20003"), 11)  // G/B
        XCTAssertEqual(bassTop("022000"), 4)   // Em
    }

    func testChromaNormalization() {
        let x = renderEvents(AudioTest.strum("x32010", at: 0.2, duration: 2))
        let frames = FeatureExtractor(inputSampleRate: 44100).process(x)
        let active = frames.filter { !$0.isSilent }
        XCTAssertFalse(active.isEmpty)
        for f in active.prefix(40) {
            XCTAssertEqual(f.chroma.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
            XCTAssertTrue(f.chroma.allSatisfy { $0 >= 0 })
            XCTAssertTrue(f.onset >= 0 && f.rms >= 0)
        }
        for f in frames where f.isSilent { XCTAssertTrue(f.chroma.allSatisfy { $0 == 0 }); XCTAssertTrue(f.bassChroma.allSatisfy { $0 == 0 }) }
    }

    func testOnsetPeaksAtStrumTimes() {
        let times = [0.5, 1.5, 2.5, 3.5]
        var events: [NoteEvent] = []
        for (i, t) in times.enumerated() { events += AudioTest.strum(i % 2 == 0 ? "x32010" : "320003", at: t, duration: 0.9, up: i % 2 == 1) }
        let x = renderEvents(events, tail: 1.0)
        let frames = FeatureExtractor(inputSampleRate: 44100).process(x)
        let hop = 512.0 / 22050.0
        for t in times {
            let window = frames.filter { $0.time > t - 0.3 && $0.time < t + 0.3 }
            let peak = window.max { $0.onset < $1.onset }!
            // Strum spreads over ~60 ms; the flux peak lands within 2 hops of the strum's centre.
            XCTAssertLessThanOrEqual(abs(peak.time - (t + 0.03)), 2 * hop, "strum at \(t): peak at \(peak.time)")
            // Between strums the flux is much smaller than at the strum.
            let quiet = frames.filter { $0.time > t + 0.5 && $0.time < t + 0.9 }.map(\.onset).max() ?? 0
            XCTAssertGreaterThan(peak.onset, 4 * quiet)
        }
        XCTAssertEqual(frames.first!.onset, 0)
    }

    func testNoiseGate() {
        // Low-level noise stays silent (after the start-up frames).
        let quiet = FeatureExtractor(inputSampleRate: 44100).process(AudioTest.noise(44100 * 6, rms: 0.0008))
        XCTAssertTrue(quiet.allSatisfy { $0.isSilent })
        // Stationary noise a bit above the absolute floor is still treated as noise floor.
        let hiss = FeatureExtractor(inputSampleRate: 44100).process(AudioTest.noise(44100 * 8, rms: 0.01))
        XCTAssertTrue(hiss.dropFirst(20).allSatisfy { $0.isSilent })
        // A chord is not silent while it rings; silence before / after is.
        var x = [Float](repeating: 0, count: 44100) + renderEvents(AudioTest.strum("x32010", at: 0, duration: 2.0), tail: 0)
        x += [Float](repeating: 0, count: 44100 * 2)
        let noisy = zip(x, AudioTest.noise(x.count, rms: 0.0005)).map { $0 + $1 }
        let frames = FeatureExtractor(inputSampleRate: 44100).process(noisy)
        let during = frames.filter { $0.time > 1.2 && $0.time < 2.8 }
        XCTAssertGreaterThan(Double(during.filter { !$0.isSilent }.count) / Double(during.count), 0.95)
        XCTAssertTrue(frames.filter { $0.time < 0.8 }.allSatisfy { $0.isSilent })
        XCTAssertTrue(frames.filter { $0.time > 3.6 }.allSatisfy { $0.isSilent })
    }

    func testGateHysteresisAvoidsChatter() {
        // Amplitude-modulated tone hovering around the threshold must not flip every frame.
        let n = 22050 * 6
        let x = (0..<n).map { i -> Float in
            let env = 0.012 + 0.003 * Float(sin(2 * Double.pi * 3 * Double(i) / 22050))
            return env * Float(sin(2 * Double.pi * 220 * Double(i) / 22050))
        }
        let frames = FeatureExtractor(inputSampleRate: 22050).process(x)
        var flips = 0
        for (a, b) in zip(frames, frames.dropFirst()) where a.isSilent != b.isSilent { flips += 1 }
        XCTAssertLessThan(flips, 6)
    }

    func testStreamingChunkingDoesNotChangeFrames() {
        let x = renderEvents(AudioTest.strum("x32010", at: 0.1, duration: 1.5), tail: 0)
        let whole = FeatureExtractor(inputSampleRate: 44100).process(x)
        let fe = FeatureExtractor(inputSampleRate: 44100)
        var chunked: [FeatureFrame] = []
        var i = 0, size = 77
        while i < x.count {
            let n = min(size, x.count - i)
            chunked += fe.process(Array(x[i..<(i + n)]))
            i += n; size = (size * 7 + 13) % 3000 + 1
        }
        XCTAssertEqual(whole.count, chunked.count)
        for (a, b) in zip(whole, chunked) {
            XCTAssertEqual(a.time, b.time, accuracy: 1e-12)
            XCTAssertEqual(a.isSilent, b.isSilent)
            for k in 0..<12 { XCTAssertEqual(a.chroma[k], b.chroma[k], accuracy: 2e-3) }
        }
        // reset() restarts the stream deterministically.
        fe.reset()
        let again = fe.process(x)
        XCTAssertEqual(again.count, whole.count)
        XCTAssertEqual(again[20].chroma, whole[20].chroma)
    }

    func testExtractorSpeed() {
        let x = AudioTest.noise(44100 * 20, rms: 0.1)
        let fe = FeatureExtractor(inputSampleRate: 44100)
        let t0 = Date()
        let frames = fe.process(x)
        let dt = Date().timeIntervalSince(t0)
        let fps = Double(frames.count) / dt
        print("FeatureExtractor: \(frames.count) frames in \(String(format: "%.3f", dt)) s = \(Int(fps)) frames/s (realtime needs 43)")
        XCTAssertGreaterThan(fps, 100)
    }
}
