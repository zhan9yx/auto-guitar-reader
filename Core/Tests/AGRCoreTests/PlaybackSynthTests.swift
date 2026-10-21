import XCTest
@testable import AGRCore

final class PlaybackSynthTests: XCTestCase {
    func render(_ synth: GuitarSynth, frames: Int, block: Int = 4096) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { bp in
            var done = 0
            while done < frames {
                let n = min(block, frames - done)
                synth.render(into: bp.baseAddress! + done, frameCount: n)
                done += n
            }
        }
        return out
    }

    func testPitchAccuracyWithinThreeCents() {
        for sr in [44100.0, 48000.0] {
            for midi in [40, 45, 55, 64, 76] {
                let synth = GuitarSynth(sampleRate: sr)
                synth.pluck(midi: midi, velocity: 0.8, stringIndex: 0)
                let x = render(synth, frames: Int(0.5 * sr))
                let f = AudioTest.estimatePitch(x, sampleRate: sr, expected: AudioTest.hz(midi), from: 0.1, to: 0.5)
                XCTAssertLessThan(abs(AudioTest.cents(f, AudioTest.hz(midi))), 3, "midi \(midi) @\(sr): \(f) Hz")
            }
        }
    }

    func testPitchAccurateAcrossBrightnessSettings() {
        for b: Float in [0, 0.5, 1] {
            let synth = GuitarSynth(sampleRate: 44100)
            synth.brightness = b
            synth.bodyResonance = 0
            synth.pluck(midi: 52, velocity: 0.6, stringIndex: 2)
            let x = render(synth, frames: 22050)
            let f = AudioTest.estimatePitch(x, sampleRate: 44100, expected: AudioTest.hz(52), from: 0.1, to: 0.5)
            XCTAssertLessThan(abs(AudioTest.cents(f, AudioTest.hz(52))), 3, "brightness \(b)")
        }
    }

    func testDecayRealistic() {
        let sr = 44100.0
        for (midi, minRatioDB) in [(40, 8.0), (64, 15.0)] {
            let synth = GuitarSynth(sampleRate: sr)
            synth.pluck(midi: midi, velocity: 0.8, stringIndex: 0)
            let x = render(synth, frames: Int(7 * sr))
            let e1 = AudioTest.energy(x, sampleRate: sr, from: 0.1, to: 0.2)
            let e2 = AudioTest.energy(x, sampleRate: sr, from: 2.0, to: 2.1)
            XCTAssertLessThan(e2, e1, "midi \(midi)")
            XCTAssertGreaterThan(10 * log10(e1 / e2), minRatioDB, "midi \(midi) decay too slow")
            XCTAssertGreaterThan(e2, 0, "string should still ring at 2 s")
        }
        // Low strings ring longer than high ones.
        func energyAt3s(_ midi: Int) -> Double {
            let s = GuitarSynth(sampleRate: sr)
            s.pluck(midi: midi, velocity: 0.8, stringIndex: 0)
            let x = render(s, frames: Int(3.2 * sr))
            return AudioTest.energy(x, sampleRate: sr, from: 3.0, to: 3.1) / AudioTest.energy(x, sampleRate: sr, from: 0.1, to: 0.2)
        }
        XCTAssertGreaterThan(energyAt3s(40), energyAt3s(64))
    }

    func testNoNaNNoDenormalsAndBoundedPeak() {
        let sr = 44100.0
        let synth = GuitarSynth(sampleRate: sr)
        synth.brightness = 1
        synth.volume = 1
        var rng = SplitMix64(seed: 5)
        var all: [Float] = []
        for step in 0..<40 {
            for s in 0..<6 where rng.next() % 2 == 0 {
                synth.pluck(midi: 40 + Int(rng.next() % 40), velocity: Float(rng.next() % 101) / 100, stringIndex: s)
            }
            if step % 7 == 3 { synth.mute(stringIndex: Int(rng.next() % 6)) }
            all += render(synth, frames: 4410)
        }
        // Let everything die and verify silence + no denormals.
        all += render(synth, frames: Int(30 * sr))
        XCTAssertTrue(all.allSatisfy { $0.isFinite })
        XCTAssertLessThanOrEqual(all.map { abs($0) }.max()!, 1.0)
        XCTAssertTrue(all.allSatisfy { $0 == 0 || abs($0) > 1e-30 }, "denormal in output")
        XCTAssertFalse(synth.isSounding)
        // Loudest possible strum stays within ±1.
        let loud = GuitarSynth(sampleRate: sr)
        loud.brightness = 1; loud.volume = 1; loud.bodyResonance = 1
        for (i, m) in [40, 47, 52, 56, 59, 64].enumerated() { loud.pluck(midi: m, velocity: 1, stringIndex: i) }
        XCTAssertLessThanOrEqual(render(loud, frames: 20000).map { abs($0) }.max()!, 1.0)
    }

    func testBlockSizeIndependence() {
        func run(block: Int) -> [Float] {
            let s = GuitarSynth(sampleRate: 44100)
            for (i, m) in [40, 47, 52, 55, 59, 64].enumerated() { s.pluck(midi: m, velocity: 0.7, stringIndex: i) }
            return render(s, frames: 8000, block: block)
        }
        let one = run(block: 1)
        let big = run(block: 4096)
        XCTAssertEqual(one, big)
        XCTAssertEqual(one.reduce(0, +), big.reduce(0, +))
        XCTAssertEqual(run(block: 333), big)
        XCTAssertGreaterThan(big.map { abs($0) }.max()!, 0.05)
    }

    func testRenderLargerThanScratchChunk() {
        let s = GuitarSynth(sampleRate: 44100)
        s.pluck(midi: 45, velocity: 0.7, stringIndex: 1)
        let a = render(s, frames: 10000, block: 10000)
        let s2 = GuitarSynth(sampleRate: 44100)
        s2.pluck(midi: 45, velocity: 0.7, stringIndex: 1)
        XCTAssertEqual(a, render(s2, frames: 10000, block: 512))
    }

    func testMuteDampsQuickly() {
        let sr = 44100.0
        let s = GuitarSynth(sampleRate: sr)
        s.pluck(midi: 45, velocity: 0.8, stringIndex: 1)
        _ = render(s, frames: 4410)
        let before = AudioTest.energy(render(s, frames: 4410), sampleRate: sr, from: 0, to: 0.1)
        s.mute(stringIndex: 1)
        let x = render(s, frames: 22050)
        let after = AudioTest.energy(x, sampleRate: sr, from: 0.15, to: 0.3)
        XCTAssertLessThan(after, before * 1e-3)
        // Muting another string leaves this one ringing.
        let s2 = GuitarSynth(sampleRate: sr)
        s2.pluck(midi: 45, velocity: 0.8, stringIndex: 1)
        s2.mute(stringIndex: 3)
        let y = render(s2, frames: 8820)
        XCTAssertGreaterThan(AudioTest.energy(y, sampleRate: sr, from: 0.1, to: 0.2), 1e-5)
    }

    func testVelocityAndBrightnessShapeTheSound() {
        let sr = 44100.0
        func centroid(_ x: [Float]) -> Double {
            let m = FFT.magnitudes(of: Array(x[0..<8192]))
            var num = 0.0, den = 0.0
            for (k, v) in m.enumerated() { num += Double(k) * Double(v); den += Double(v) }
            return num / den * sr / 16384
        }
        func take(vel: Float, bright: Float) -> [Float] {
            let s = GuitarSynth(sampleRate: sr)
            s.brightness = bright
            s.pluck(midi: 52, velocity: vel, stringIndex: 2)
            return render(s, frames: 22050)
        }
        XCTAssertGreaterThan(centroid(take(vel: 0.8, bright: 1)), centroid(take(vel: 0.8, bright: 0)))
        let soft = take(vel: 0.2, bright: 0.5), hard = take(vel: 1.0, bright: 0.5)
        XCTAssertGreaterThan(AudioTest.energy(hard, sampleRate: sr, from: 0, to: 0.3),
                             AudioTest.energy(soft, sampleRate: sr, from: 0, to: 0.3) * 4)
        XCTAssertGreaterThan(centroid(hard), centroid(soft))   // softer = darker
    }

    func testRetriggerIsDeterministic() {
        func run() -> [Float] {
            let s = GuitarSynth(sampleRate: 48000)
            s.pluck(midi: 50, velocity: 0.5, stringIndex: 2)
            var a = render(s, frames: 3000)
            s.pluck(midi: 52, velocity: 0.9, stringIndex: 2)
            a += render(s, frames: 3000)
            return a
        }
        XCTAssertEqual(run(), run())
    }

    // MARK: Sequencer

    func ev(_ t: Double, _ midi: Int = 45, dur: Double = 1, s: Int = 1, v: Float = 0.8, click: Bool = false) -> NoteEvent {
        NoteEvent(time: t, midi: midi, velocity: v, duration: dur, stringIndex: click ? -1 : s, eventIndex: click ? -1 : 0, isClick: click)
    }

    func testSequencerFiresEventAtExactSample() {
        let sr = 44100.0
        let engine = SequencerEngine(sampleRate: sr, events: [ev(1000.0 / sr)])
        engine.isPlaying = true
        var out = [Float](repeating: 0, count: 3000)
        out.withUnsafeMutableBufferPointer { bp in
            var done = 0
            for block in [333, 667, 1, 999, 1000] {   // odd block sizes crossing the event boundary
                engine.render(into: bp.baseAddress! + done, frameCount: block)
                done += block
            }
        }
        XCTAssertEqual(out[999], 0)
        XCTAssertNotEqual(out[1000], 0)
        XCTAssertTrue(out[0..<1000].allSatisfy { $0 == 0 })
        XCTAssertEqual(engine.positionSeconds, 3000 / sr, accuracy: 1e-9)
    }

    func testSequencerOutputIndependentOfBlockSize() {
        let events = (0..<12).map { ev(Double($0) * 0.1 + 0.0003, 40 + $0 * 2, dur: 0.15, s: $0 % 6) }
        let a = OfflineRenderer.render(events, sampleRate: 44100, tail: 0.5)
        let engine = SequencerEngine(sampleRate: 44100, events: events)
        engine.isPlaying = true
        var b = [Float](repeating: 0, count: a.count)
        b.withUnsafeMutableBufferPointer { bp in
            var done = 0
            while done < a.count {
                let n = min(97, a.count - done)
                engine.render(into: bp.baseAddress! + done, frameCount: n)
                done += n
            }
        }
        let firstDiff = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertNil(firstDiff)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.map { abs($0) }.max()!, 0.05)
    }

    func testSequencerSeek() {
        let sr = 44100.0
        let engine = SequencerEngine(sampleRate: sr, events: [ev(0.5), ev(3.0, 52, s: 2)])
        engine.isPlaying = true
        engine.seek(toSeconds: 2.0)
        XCTAssertEqual(engine.positionSeconds, 2.0)           // pending seek is visible immediately
        var out = [Float](repeating: 0, count: Int(1.5 * sr))
        out.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: $0.count) }
        let onset = Int(1.0 * sr)
        XCTAssertTrue(out[0..<onset].allSatisfy { $0 == 0 }, "first event must be skipped")
        XCTAssertNotEqual(out[onset], 0)
        XCTAssertEqual(engine.positionSeconds, 3.5, accuracy: 1e-6)
        // Seek backwards replays the first event, and cuts ringing notes.
        engine.seek(toSeconds: 0.25)
        var out2 = [Float](repeating: 0, count: Int(0.5 * sr))
        out2.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: $0.count) }
        XCTAssertTrue(out2[Int(0.15 * sr)..<Int(0.25 * sr) - 1].allSatisfy { abs($0) < 1e-4 })   // old ring faded within ~50 ms
        XCTAssertNotEqual(out2[Int(0.25 * sr) + 5], 0)
    }

    func testSequencerPauseAndPosition() {
        let sr = 44100.0
        let engine = SequencerEngine(sampleRate: sr, events: [ev(0.0)])
        XCTAssertFalse(engine.isPlaying)
        var buf = [Float](repeating: 1, count: 1024)
        buf.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: 1024) }
        XCTAssertTrue(buf.allSatisfy { $0 == 0 })              // not playing: silence (buffer is overwritten)
        XCTAssertEqual(engine.positionSeconds, 0)
        engine.isPlaying = true
        XCTAssertTrue(engine.isPlaying)
        buf.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: 1024) }
        XCTAssertGreaterThan(buf.map { abs($0) }.max()!, 0.01)
        XCTAssertEqual(engine.positionSeconds, 1024 / sr, accuracy: 1e-9)
        engine.isPlaying = false
        for _ in 0..<40 { buf.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: 1024) } }
        XCTAssertEqual(engine.positionSeconds, 1024 / sr, accuracy: 1e-9)   // clock frozen
        XCTAssertTrue(buf.allSatisfy { abs($0) < 1e-3 })                    // muted quickly
        XCTAssertFalse(engine.isPlaying)
    }

    func testSequencerNoteOffAndClicks() {
        let sr = 44100.0
        let engine = SequencerEngine(sampleRate: sr, events: [ev(0, 45, dur: 0.3), ev(1.0, click: true)])
        engine.isPlaying = true
        var out = [Float](repeating: 0, count: Int(1.5 * sr))
        out.withUnsafeMutableBufferPointer { engine.render(into: $0.baseAddress!, frameCount: $0.count) }
        XCTAssertGreaterThan(AudioTest.energy(out, sampleRate: sr, from: 0.1, to: 0.3), 1e-4)
        XCTAssertLessThan(AudioTest.energy(out, sampleRate: sr, from: 0.5, to: 0.9), 1e-9)   // note-off damped it
        XCTAssertLessThan(abs(out[Int(sr) - 1]), 1e-9)
        XCTAssertNotEqual(out[Int(sr) + 3], 0)                                               // click burst
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 1.0)
    }

    func testOfflineRendererLengthAndWav() {
        let sr = 22050.0
        let events = [ev(0.5, 45, dur: 1.0)]
        let x = OfflineRenderer.render(events, sampleRate: sr, tail: 1.0)
        XCTAssertEqual(x.count, Int((2.5 * sr).rounded(.up)))
        let wav = OfflineRenderer.wavData(x, sampleRate: sr)
        XCTAssertEqual(wav.count, 44 + x.count * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(wav[o + $1]) << (8 * UInt32($1)) } }
        func u16(_ o: Int) -> UInt16 { UInt16(wav[o]) | UInt16(wav[o + 1]) << 8 }
        XCTAssertEqual(u32(4), UInt32(36 + x.count * 2))
        XCTAssertEqual(u16(20), 1); XCTAssertEqual(u16(22), 1)
        XCTAssertEqual(u32(24), 22050); XCTAssertEqual(u32(28), 44100); XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(u32(40), UInt32(x.count * 2))
        // Sample round trip.
        let k = Int(0.6 * sr)
        let s16 = Int16(bitPattern: u16(44 + 2 * k))
        XCTAssertEqual(Float(s16) / 32767, x[k], accuracy: 1.0 / 32767)
        // Clipping.
        let clipped = OfflineRenderer.wavData([2, -2], sampleRate: 8000)
        XCTAssertEqual(Int16(bitPattern: UInt16(clipped[44]) | UInt16(clipped[45]) << 8), 32767)
        XCTAssertEqual(Int16(bitPattern: UInt16(clipped[46]) | UInt16(clipped[47]) << 8), -32767)
        XCTAssertTrue(OfflineRenderer.render([], sampleRate: 8000, tail: 0).isEmpty)
    }

    func testEndToEndDemoRender() {
        let score = DemoScore.make()
        let t = Timeline.build(from: score)
        let notes = PerformancePlanner.plan(t, score: score, options: PlaybackOptions(countInBeats: 4))
        let x = OfflineRenderer.render(notes, sampleRate: 22050)
        XCTAssertGreaterThan(x.count, Int(15 * 22050))
        XCTAssertTrue(x.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(x.map { abs($0) }.max()!, 0.1)
    }
}
