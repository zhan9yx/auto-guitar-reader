import XCTest
@testable import AGRCore

/// End-to-end tests on synthesized audio (short: ~13-18 s of audio each, modest thresholds; the full acceptance
/// numbers come from `agr-tool follow-eval --suite`).
final class FollowEvalTests: XCTestCase {
    private func shortSong() -> Score {
        let cho = """
        {title: t}
        {tempo: 150}
        {start_of_verse}
        [C]夜色轻轻[G]落在窗台[Am]你的笑声[F]还在耳边
        [C]路灯慢慢[G]点亮回忆[Am]我却不敢[F]回头看
        {end_of_verse}
        """
        return try! ChordProParser.parse(cho)
    }

    func testSynthesizedTakeHasTruthAndAudio() {
        let take = FollowEvaluator.synthesizeTake(score: shortSong(), mode: .strumSing, seed: 4, tempoDrift: 0.1, snrDB: 20, withVoice: true)
        XCTAssertEqual(take.sampleRate, 44100)
        XCTAssertGreaterThan(take.audio.count, 44100 * 10)
        XCTAssertEqual(take.truth.count, 8)
        XCTAssertEqual(take.truth.map(\.eventIndex), Array(0..<8))
        XCTAssertEqual(take.truth.map(\.time), take.truth.map(\.time).sorted())
        XCTAssertTrue(take.audio.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    func testTakesAreDeterministicPerSeedAndDifferAcrossSeeds() {
        let s = shortSong()
        let a = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, seed: 1, tempoDrift: 0.1, snrDB: 20, withVoice: false)
        let b = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, seed: 1, tempoDrift: 0.1, snrDB: 20, withVoice: false)
        let c = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, seed: 2, tempoDrift: 0.1, snrDB: 20, withVoice: false)
        XCTAssertEqual(a.audio, b.audio)
        XCTAssertNotEqual(a.truth.map(\.time), c.truth.map(\.time))
    }

    func testStopMidInsertsASilentPauseAndLevelScalesTheTake() {
        let s = shortSong()
        var o = TakeOptions()
        o.seed = 3; o.snrDB = 40; o.stopMid = 5
        let take = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: o)
        XCTAssertEqual(take.stops.count, 1)
        let st = take.stops[0]
        XCTAssertEqual(st.event, 4)                       // middle of the 8-event verse
        XCTAssertEqual(take.truth[4].time, st.restart, accuracy: 1e-9)
        XCTAssertGreaterThan(take.truth[4].time - take.truth[3].time, 5)
        XCTAssertGreaterThan(st.restart - st.soundEnd, 4)
        // The pause is (nearly) silent: RMS of the middle of the stop is far below the playing level.
        func rms(_ a: Double, _ b: Double) -> Double {
            let x = take.audio[Int(a * take.sampleRate)..<Int(b * take.sampleRate)]
            return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
        }
        XCTAssertLessThan(rms(st.soundEnd + 0.5, st.restart - 0.5), 0.05 * rms(1, 4))
        var q = o
        q.stopMid = 0; q.outputGainDB = -12
        var n = o
        n.stopMid = 0
        let quiet = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: q)
        let normal = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: n)
        XCTAssertTrue(quiet.stops.isEmpty)
        let peakQ = quiet.audio.map { abs($0) }.max()!, peakN = normal.audio.map { abs($0) }.max()!
        XCTAssertEqual(Double(peakQ / peakN), pow(10, -12.0 / 20), accuracy: 0.01)
    }

    func testStopAndRestartMetricsOnASynthesizedTake() {
        let s = shortSong()
        var o = TakeOptions()
        o.seed = 5; o.snrDB = 20; o.stopMid = 5
        let take = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: o)
        var eo = FollowEvalOptions()
        eo.stops = take.stops
        eo.scoreEndTime = take.scoreEndTime
        let r = FollowEvaluator.evaluate(timeline: take.timeline, mode: .strumSing, audio: take.audio, sampleRate: take.sampleRate,
                                         groundTruth: take.truth, options: eo)
        XCTAssertEqual(r.stopCount, 1)
        XCTAssertLessThan(r.stopSilentLatency, 0.6)
        XCTAssertGreaterThan(r.stopPausedLatency, 2.4)   // 3 s of silence; the gate may close a little before the nominal end of the sound
        XCTAssertLessThan(r.stopPausedLatency, 4)
        XCTAssertGreaterThan(r.stopPausedFraction, 0.9)
        XCTAssertLessThan(r.restartGateFrames, 4)
        XCTAssertLessThan(r.restartRecoveryFrames, 25)
        XCTAssertGreaterThan(r.withinOneAccuracyAll, 0.9)
    }

    func testSplitMix64IsDeterministic() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42), c = SplitMix64(seed: 43)
        let xs = (0..<5).map { _ in a.next() }
        XCTAssertEqual(xs, (0..<5).map { _ in b.next() })
        XCTAssertNotEqual(xs[0], c.next())
        var d = SplitMix64(seed: 1)
        for _ in 0..<1000 { let u = d.uniform(); XCTAssertTrue(u >= 0 && u <= 1) }
    }

    func testDriftChangesTheTimingWithinBounds() {
        let s = shortSong()
        let tl = Timeline.build(from: s)
        var o = TakeOptions(); o.seed = 3; o.tempoDrift = 0.15; o.snrDB = 60; o.timingJitter = 0
        let take = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: o)
        let nominal = tl.seconds(forBeat: tl.events[7].startBeat)
        let actual = take.truth[7].time
        XCTAssertNotEqual(actual, nominal)
        XCTAssertEqual(actual / nominal, 1, accuracy: 0.2)
        // Section pauses add 1-2 s.
        var cho = "{title: t}\n{tempo: 150}\n{start_of_verse}\n[C]a [G]b\n{end_of_verse}\n{start_of_chorus}\n[Am]c [F]d\n{end_of_chorus}"
        cho += "\n"
        let two = try! ChordProParser.parse(cho)
        var p = TakeOptions(); p.seed = 9; p.tempoDrift = 0; p.timingJitter = 0; p.sectionPauses = true; p.humanize = 0
        var found = false
        for seed in 1...6 {
            p.seed = UInt64(seed)
            let t = FollowEvaluator.synthesizeTake(score: two, mode: .strumSing, options: p)
            let gap = t.truth[2].time - t.truth[1].time
            if gap > 2 * 4 * 60 / 150 * 0.5 + 0.9 { found = true; break }
        }
        XCTAssertTrue(found, "some seeds must insert a pause between sections")
    }

    func testStrumSingWithVoiceFollowsAndScrollsSmoothly() {
        let take = FollowEvaluator.synthesizeTake(score: shortSong(), mode: .strumSing, seed: 3, tempoDrift: 0.12, snrDB: 15, withVoice: true)
        let r = FollowEvaluator.evaluate(score: shortSong(), mode: .strumSing, audio: take.audio, sampleRate: take.sampleRate,
                                         groundTruth: take.truth)
        XCTAssertGreaterThan(r.frames, 300)
        XCTAssertGreaterThanOrEqual(r.withinOneAccuracy, 0.8, "\(r)")
        XCTAssertLessThan(r.medianLatency, 1.0)
        XCTAssertLessThanOrEqual(r.scrollMaxSpeed, 0.6 + 1e-6)
        XCTAssertLessThanOrEqual(r.scrollMaxAcceleration, 1.5 * 1.02)
    }

    func testStrumSingWithLyricsSimulationRuns() {
        let s = shortSong()
        var o = TakeOptions(); o.seed = 5; o.tempoDrift = 0.1; o.snrDB = 15; o.withVoice = true
        let take = FollowEvaluator.synthesizeTake(score: s, mode: .strumSing, options: o)
        var eo = FollowEvalOptions()
        eo.lyrics = LyricsSimulation()
        eo.lyricChars = take.lyricChars
        eo.scoreEndTime = take.scoreEndTime
        eo.driveScroll = false
        let r = FollowEvaluator.evaluate(timeline: take.timeline, mode: .strumSing, audio: take.audio, sampleRate: take.sampleRate,
                                         groundTruth: take.truth, options: eo)
        XCTAssertGreaterThan(r.lyricsEvidenceCount, 3)
        XCTAssertGreaterThanOrEqual(r.withinOneAccuracy, 0.8, "\(r)")
        XCTAssertFalse(take.lyricChars.isEmpty)
    }

    func testFingerstyleFollowsArpeggio() {
        var score = FollowEvalSongs.fingerstylePieceA()
        // First 5 measures only (~17 s).
        score.sections[0].lines = [Line(id: "x", kind: .tab, tab: TabBlock(measures: Array(score.sections[0].lines[0].tab!.measures) + Array(score.sections[0].lines[1].tab!.measures.prefix(1))))]
        let take = FollowEvaluator.synthesizeTake(score: score, mode: .fingerstyle, seed: 2, tempoDrift: 0.1, snrDB: 25, withVoice: false)
        XCTAssertGreaterThanOrEqual(take.truth.count, 40)
        let r = FollowEvaluator.evaluate(score: score, mode: .fingerstyle, audio: take.audio, sampleRate: take.sampleRate, groundTruth: take.truth)
        XCTAssertGreaterThanOrEqual(r.withinOneAccuracy, 0.7, "\(r)")
    }

    func testReportIsCodableAndStable() throws {
        var r = FollowEvalReport(exactAccuracy: 0.5, withinOneAccuracy: 0.9, medianLatency: 0.3, frames: 100)
        r.scrollBackwardMoves = 2
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(FollowEvalReport.self, from: data)
        XCTAssertEqual(back.withinOneAccuracy, 0.9)
        XCTAssertEqual(back.scrollBackwardMoves, 2)
    }

    // MARK: WAV / CSV

    func testWAVReaderRoundTripAndFormats() throws {
        let samples: [Float] = (0..<1000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let data = OfflineRenderer.wavData(samples, sampleRate: 22050)
        let back = try WAVReader.read(data)
        XCTAssertEqual(back.sampleRate, 22050)
        XCTAssertEqual(back.samples.count, 1000)
        XCTAssertEqual(back.samples[100], samples[100], accuracy: 1e-3)

        // 32-bit float stereo -> mono mix.
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let frames = 50
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 8)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(2); u32(48000); u32(48000 * 8); u16(8); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 8))
        for _ in 0..<frames { u32((0.25 as Float).bitPattern); u32((0.75 as Float).bitPattern) }
        let f = try WAVReader.read(d)
        XCTAssertEqual(f.sampleRate, 48000)
        XCTAssertEqual(f.samples.count, frames)
        XCTAssertEqual(f.samples[0], 0.5, accuracy: 1e-6)

        XCTAssertThrowsError(try WAVReader.read(Data([1, 2, 3, 4])))
    }

    func testTruthCSVRoundTrip() {
        let truth: [(time: Double, eventIndex: Int)] = [(0.5, 0), (2.25, 1), (4.0, 2)]
        let text = TruthCSV.format(truth)
        let back = TruthCSV.parse(text)
        XCTAssertEqual(back.map(\.eventIndex), [0, 1, 2])
        XCTAssertEqual(back.map(\.time), [0.5, 2.25, 4.0])
        XCTAssertEqual(TruthCSV.parse("# comment\ntime,eventIndex\n1.0 3\n0.5\t2\n").map(\.eventIndex), [2, 3])
    }

    func testBuiltInSongsMeetTheSpec() {
        for s in FollowEvalSongs.strumSongs {
            let tl = Timeline.build(from: s.score)
            XCTAssertGreaterThanOrEqual(tl.events.filter { $0.kind == .chord }.count, 40, s.name)
            XCTAssertTrue(tl.sectionPasses.count >= 8)
            // The same progression appears in verse and chorus passes: some chord n-gram repeats.
            let names = tl.events.compactMap { $0.chord?.description }
            var seen = Set<String>(), repeated = false
            for i in 0..<(names.count - 3) { let g = names[i..<(i + 4)].joined(separator: " "); if !seen.insert(g).inserted { repeated = true } }
            XCTAssertTrue(repeated, s.name)
        }
        for s in FollowEvalSongs.fingerstylePieces {
            let tl = Timeline.build(from: s.score)
            XCTAssertGreaterThanOrEqual(tl.events.filter { $0.kind == .notes }.count, 60, s.name)
        }
    }
}
