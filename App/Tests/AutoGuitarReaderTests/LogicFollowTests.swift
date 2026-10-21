import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

/// Tests of the framework-free follow pipeline. They also run on Linux (type-check harness) against the real AGRCore.
final class LogicFollowTests: XCTestCase {
    private let shortCho = """
    {title: t}
    {tempo: 150}
    {start_of_verse}
    [C]夜色轻轻[G]落在窗台[Am]你的笑声[F]还在耳边
    [C]路灯慢慢[G]点亮回忆[Am]我却不敢[F]回头看
    {end_of_verse}
    """

    /// Two sections, 16 chord events (~26 s at 150 BPM).
    private let longCho = """
    {title: t}
    {tempo: 150}
    {start_of_verse}
    [C]夜色轻轻[G]落在窗台[Am]你的笑声[F]还在耳边
    [C]路灯慢慢[G]点亮回忆[Am]我却不敢[F]回头看
    {end_of_verse}
    {start_of_chorus}
    [F]风吹过[G]你的发梢[Em]我还记得[Am]那个微笑
    [F]时光慢慢[G]把我们淡忘[C]只剩下[C]歌声飘荡
    {end_of_chorus}
    """

    private func makeConfig(sampleRate: Double, mode: FollowMode = .strumSing, transpose: Int = 0) -> FollowSessionConfig {
        var cfg = FollowSessionConfig(mode: mode, transpose: transpose, inputSampleRate: sampleRate)
        cfg.maxPendingChunks = 1_000_000          // tests feed faster than real time
        return cfg
    }

    private func feed(_ session: FollowSession, audio: [Float], from start: Int = 0, chunk: Int = 1024) {
        var i = start
        while i < audio.count {
            session.ingest(samples: Array(audio[i..<min(i + chunk, audio.count)]))
            i += chunk
        }
        session.drain()
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FollowSnapshot] = []
        func add(_ s: FollowSnapshot) { lock.lock(); items.append(s); lock.unlock() }
        var all: [FollowSnapshot] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func truthEvent(at t: Double, truth: [(time: Double, eventIndex: Int)]) -> Int? {
        guard let first = truth.first, t >= first.time else { return nil }
        var k = 0
        while k + 1 < truth.count && truth[k + 1].time <= t { k += 1 }
        return truth[k].eventIndex
    }

    /// Fraction of snapshots (after `skip` seconds) within one event of the truth.
    private func accuracy(_ snaps: [FollowSnapshot], truth: [(time: Double, eventIndex: Int)], after: Double, until: Double) -> (fraction: Double, count: Int) {
        var ok = 0, n = 0
        for s in snaps where s.state.time >= after && s.state.time <= until {
            guard let t = truthEvent(at: s.state.time, truth: truth) else { continue }
            n += 1
            if abs(t - s.eventIndex) <= 1 { ok += 1 }
        }
        return (n == 0 ? 0 : Double(ok) / Double(n), n)
    }

    // MARK: Following synthesized audio

    func testFollowsSynthesizedTakeAndThrottlesPublishing() throws {
        let score = try ChordProParser.parse(shortCho)
        let take = FollowEvaluator.synthesizeTake(score: score, mode: .strumSing, seed: 3, tempoDrift: 0.12, snrDB: 15, withVoice: true)
        let session = FollowSession(score: score, config: makeConfig(sampleRate: take.sampleRate))
        let collector = Collector()
        session.onPublish = { collector.add($0) }
        feed(session, audio: take.audio)

        let snaps = collector.all
        let duration = Double(take.audio.count) / take.sampleRate
        XCTAssertGreaterThan(snaps.count, Int(duration * 12), "publishes at display-ish rate")
        XCTAssertLessThanOrEqual(snaps.count, Int(duration * 31) + take.truth.count + 2, "throttled to ~30 Hz")
        let last = try XCTUnwrap(take.truth.last)
        let acc = accuracy(snaps, truth: take.truth, after: (take.truth.first?.time ?? 0) + 0.3, until: duration)
        XCTAssertGreaterThan(acc.count, 100)
        XCTAssertGreaterThanOrEqual(acc.fraction, 0.8, "within-one accuracy \(acc)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.latestSnapshot).eventIndex, last.eventIndex - 1)
        XCTAssertEqual(session.droppedChunkCount, 0)
        // Snapshots carry the line / segment of the event for the highlight.
        XCTAssertEqual(session.latestSnapshot?.line, session.structure.events[session.latestSnapshot!.eventIndex].line)
    }

    func testTransposedScoreNeedsTheTransposedTimeline() throws {
        let score = try ChordProParser.parse(shortCho)
        var take = TakeOptions(); take.seed = 3; take.tempoDrift = 0.1; take.snrDB = 20; take.withVoice = false
        let rec = FollowEvaluator.synthesizeTake(score: score, mode: .strumSing, options: take,
                                                 timelineOptions: TimelineOptions(transpose: 2))
        let duration = Double(rec.audio.count) / rec.sampleRate

        // The reader is transposed by +2 after the follow session was created with 0.
        let session = FollowSession(score: score, config: makeConfig(sampleRate: rec.sampleRate))
        let collector = Collector()
        session.onPublish = { collector.add($0) }
        session.updateTranspose(2)
        feed(session, audio: rec.audio)
        let right = accuracy(collector.all, truth: rec.truth, after: (rec.truth.first?.time ?? 0) + 0.3, until: duration)
        XCTAssertGreaterThanOrEqual(right.fraction, 0.8, "\(right)")

        // Created with the transposition: same result.
        let session2 = FollowSession(score: score, config: makeConfig(sampleRate: rec.sampleRate, transpose: 2))
        let collector2 = Collector()
        session2.onPublish = { collector2.add($0) }
        feed(session2, audio: rec.audio)
        let right2 = accuracy(collector2.all, truth: rec.truth, after: (rec.truth.first?.time ?? 0) + 0.3, until: duration)
        XCTAssertGreaterThanOrEqual(right2.fraction, 0.8, "\(right2)")
    }

    func testRelocateToLineMidSongThenFollows() throws {
        let score = try ChordProParser.parse(longCho)
        let take = FollowEvaluator.synthesizeTake(score: score, mode: .strumSing, seed: 5, tempoDrift: 0.1, snrDB: 18, withVoice: false)
        let session = FollowSession(score: score, config: makeConfig(sampleRate: take.sampleRate))
        let collector = Collector()
        session.onPublish = { collector.add($0) }

        // The player starts in the chorus; the user double-taps its first line.
        let chorusFirst = 8
        let line = session.structure.events[chorusFirst].line
        XCTAssertEqual(line, LineRef(sectionIndex: 1, lineIndex: 0))
        let target = try XCTUnwrap(session.relocate(toLine: line))
        XCTAssertEqual(target, chorusFirst)
        XCTAssertEqual(session.currentEpoch, 1)
        // Optimistic snapshot is available immediately and carries the new epoch.
        XCTAssertEqual(session.latestSnapshot?.eventIndex, chorusFirst)
        XCTAssertEqual(session.latestSnapshot?.epoch, 1)
        XCTAssertGreaterThanOrEqual(session.latestSnapshot?.state.confidence ?? 0, 0.6)

        let startTime = take.truth[chorusFirst].time - 0.4
        feed(session, audio: take.audio, from: Int(startTime * take.sampleRate))
        let duration = Double(take.audio.count) / take.sampleRate
        let snaps = collector.all
        XCTAssertTrue(snaps.allSatisfy { $0.epoch == 1 }, "all later snapshots belong to the new epoch")
        // Snapshot times restart at 0 for this stream: compare against truth shifted by the stream start.
        let shifted = take.truth.map { (time: $0.time - startTime, eventIndex: $0.eventIndex) }
        let acc = accuracy(snaps, truth: shifted, after: 1.0, until: duration - startTime)
        XCTAssertGreaterThan(acc.count, 100)
        XCTAssertGreaterThanOrEqual(acc.fraction, 0.75, "\(acc)")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.latestSnapshot).eventIndex, take.truth.count - 2)
    }

    func testBackPressureDropsChunksInsteadOfQueueingForever() throws {
        let score = try ChordProParser.parse(shortCho)
        var cfg = makeConfig(sampleRate: 44100)
        cfg.maxPendingChunks = 2
        let queue = DispatchQueue(label: "test.blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }                       // the analysis queue is busy
        let session = FollowSession(score: score, config: cfg, queue: queue)
        for _ in 0..<10 { session.ingest(samples: [Float](repeating: 0, count: 1024)) }
        XCTAssertEqual(session.droppedChunkCount, 8)
        gate.signal()
        session.drain()
        XCTAssertEqual(session.droppedChunkCount, 8)
    }

    func testStoppedSessionIgnoresInputAndPublishesNothing() throws {
        let score = try ChordProParser.parse(shortCho)
        let session = FollowSession(score: score, config: makeConfig(sampleRate: 44100))
        let collector = Collector()
        session.onPublish = { collector.add($0) }
        session.stop()
        feed(session, audio: [Float](repeating: 0.01, count: 44100))
        XCTAssertTrue(collector.all.isEmpty)
        XCTAssertNil(session.latestSnapshot)
    }

    // MARK: Lyrics

    func testTranscriptReachesTheFollowerAndIsCounted() throws {
        let score = try ChordProParser.parse(shortCho)
        let session = FollowSession(score: score, config: makeConfig(sampleRate: 44100))
        XCTAssertTrue(session.usesLyrics)
        session.applyTranscript("夜色轻轻落在窗台你的笑声")
        session.ingest(samples: [Float](repeating: 0, count: 22050))   // a bit of silence to produce a snapshot
        session.drain()
        let snap = try XCTUnwrap(session.latestSnapshot)
        XCTAssertGreaterThanOrEqual(snap.lyricsEvidenceCount, 1)

        var off = makeConfig(sampleRate: 44100)
        off.lyricsEnabled = false
        XCTAssertFalse(FollowSession(score: score, config: off).usesLyrics)
    }

    func testScoreWithoutLyricsHasNoAligner() throws {
        var score = FollowEvalSongs.fingerstylePieceA()
        score.sections = Array(score.sections.prefix(1))
        let session = FollowSession(score: score, config: makeConfig(sampleRate: 44100, mode: .fingerstyle))
        XCTAssertFalse(session.usesLyrics)
    }

    // MARK: Relocation mapping

    func testRelocationPrefersTheNearestPassOfARepeatedSection() throws {
        var score = try ChordProParser.parse(longCho)
        // verse, chorus, verse, chorus
        score.arrangement = [score.sections[0].id, score.sections[1].id, score.sections[0].id, score.sections[1].id]
        let tl = Timeline.build(from: score)
        XCTAssertEqual(tl.sectionPasses.count, 4)
        let verseLine = LineRef(sectionIndex: 0, lineIndex: 1)
        let passes = tl.events.filter { $0.line == verseLine }.reduce(into: [Int: Int]()) { acc, e in
            if acc[e.passIndex] == nil { acc[e.passIndex] = e.index }
        }
        XCTAssertEqual(passes.count, 2)
        let first = passes[0]!, second = passes[1]!
        XCTAssertLessThan(first, second)

        XCTAssertEqual(FollowRelocation.eventIndex(forLine: verseLine, in: tl, near: 0), first)
        XCTAssertEqual(FollowRelocation.eventIndex(forLine: verseLine, in: tl, near: first + 3), first)
        XCTAssertEqual(FollowRelocation.eventIndex(forLine: verseLine, in: tl, near: second - 1), second)
        XCTAssertEqual(FollowRelocation.eventIndex(forLine: verseLine, in: tl, near: tl.events.count - 1), second)
        // Equidistant: go forward.
        let mid = (first + second) / 2
        if (mid - first) == (second - mid) {
            XCTAssertEqual(FollowRelocation.eventIndex(forLine: verseLine, in: tl, near: mid), second)
        }
    }

    func testRelocationOfALineWithoutEventsUsesTheNextLine() throws {
        var score = try ChordProParser.parse(shortCho)
        score.sections[0].lines.insert(Line(kind: .comment, text: "间奏"), at: 1)   // lines: lyrics, comment, lyrics
        let tl = Timeline.build(from: score)
        let comment = LineRef(sectionIndex: 0, lineIndex: 1)
        XCTAssertTrue(tl.events.allSatisfy { $0.line != comment })
        let nextFirst = try XCTUnwrap(tl.events.first { $0.line == LineRef(sectionIndex: 0, lineIndex: 2) }).index
        XCTAssertEqual(FollowRelocation.eventIndex(forLine: comment, in: tl, near: 0), nextFirst)
        // Last line is a comment: falls back to the last event before it.
        score.sections[0].lines.append(Line(kind: .comment, text: "尾声"))
        let tl2 = Timeline.build(from: score)
        let tail = LineRef(sectionIndex: 0, lineIndex: score.sections[0].lines.count - 1)
        XCTAssertEqual(FollowRelocation.eventIndex(forLine: tail, in: tl2, near: 0), tl2.events.count - 1)
        // Unknown section: nil.
        XCTAssertNil(FollowRelocation.eventIndex(forLine: LineRef(sectionIndex: 9, lineIndex: 0), in: tl, near: 0))
    }

    // MARK: Sensitivity

    func testSensitivityPresetsScaleTheDefaults() {
        let base = FollowerConfig()
        let steady = FollowSensitivity.steady.config(base: base)
        let standard = FollowSensitivity.standard.config(base: base)
        let responsive = FollowSensitivity.responsive.config(base: base)
        XCTAssertEqual(standard.kappa, base.kappa, accuracy: 1e-12)
        XCTAssertEqual(standard.pJump, base.pJump, accuracy: 1e-12)
        XCTAssertLessThan(steady.kappa, standard.kappa)
        XCTAssertGreaterThan(responsive.kappa, standard.kappa)
        XCTAssertLessThan(steady.pJump, standard.pJump)
        XCTAssertGreaterThan(responsive.pJump, standard.pJump)
        // Nothing else is touched.
        XCTAssertEqual(steady.pNext, base.pNext)
        XCTAssertEqual(responsive.holdFraction, base.holdFraction)
    }

    // MARK: Speech restart policy

    func testRestartPolicyBackoffAndBudget() {
        var p = SpeechRestartPolicy()
        p.maxRestartsPerMinute = 1000
        XCTAssertEqual(p.requestRestart(now: 0, isFailure: true) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.requestRestart(now: 1, isFailure: true) ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(p.requestRestart(now: 2, isFailure: true) ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(p.requestRestart(now: 3, isFailure: true) ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(p.requestRestart(now: 4, isFailure: true) ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(p.requestRestart(now: 5, isFailure: true) ?? -1, 8, accuracy: 1e-9)
        p.noteSuccess()
        XCTAssertEqual(p.requestRestart(now: 6, isFailure: true) ?? -1, 0.5, accuracy: 1e-9)
        // A rollover is not a failure.
        XCTAssertEqual(p.requestRestart(now: 7, isFailure: false) ?? -1, 0.1, accuracy: 1e-9)

        var q = SpeechRestartPolicy()
        q.maxRestartsPerMinute = 1000
        for i in 0..<q.maxConsecutiveFailures { XCTAssertNotNil(q.requestRestart(now: Double(i), isFailure: true)) }
        XCTAssertNil(q.requestRestart(now: 100, isFailure: true), "gives up after repeated hard failures")

        var r = SpeechRestartPolicy()           // 6 restarts per minute
        var delays: [Double] = []
        for _ in 0..<7 { delays.append(r.requestRestart(now: 0, isFailure: false) ?? -1) }
        XCTAssertTrue(delays[0..<6].allSatisfy { abs($0 - 0.1) < 1e-9 })
        XCTAssertGreaterThan(delays[6], 55, "the 7th restart within a minute waits for a free slot")
        XCTAssertLessThanOrEqual(delays[6], 60.2)
    }

    func testRecognitionStatusLabels() {
        XCTAssertEqual(LyricsRecognitionStatus.listening.label, "歌词识别：识别中")
        XCTAssertTrue(LyricsRecognitionStatus.restarting.isActive)
        XCTAssertFalse(LyricsRecognitionStatus.denied.isActive)
        XCTAssertTrue(LyricsRecognitionStatus.unavailable("x").label.contains("x"))
    }

    // MARK: Audio math

    func testAudioMath() {
        var a: [Float] = [1, 1, 1, 1], b: [Float] = [-1, 1, 3, 0]
        let mono = a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                AudioMath.downmixToMono(channels: [UnsafePointer(pa.baseAddress!), UnsafePointer(pb.baseAddress!)], frames: 4)
            }
        }
        XCTAssertEqual(mono, [0, 1, 2, 0.5])
        let single = a.withUnsafeMutableBufferPointer { AudioMath.downmixToMono(channels: [UnsafePointer($0.baseAddress!)], frames: 4) }
        XCTAssertEqual(single, [1, 1, 1, 1])
        XCTAssertEqual(AudioMath.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.dBFS(rms: 1), 0, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.dBFS(rms: 0.1), -20, accuracy: 1e-3)
        XCTAssertEqual(AudioMath.dBFS(rms: 0), -120)
        XCTAssertEqual(AudioMath.meterPosition(dB: -60), 0)
        XCTAssertEqual(AudioMath.meterPosition(dB: 0), 1)
        XCTAssertEqual(AudioMath.meterPosition(dB: -30), 0.5, accuracy: 1e-6)

        let meter = MicLevelMeter(releasePerUpdate: 2)
        meter.update(rms: 0.1)
        XCTAssertEqual(meter.dB, -20, accuracy: 1e-3)
        meter.update(rms: 0.001)                       // quieter: falls by at most 2 dB
        XCTAssertEqual(meter.dB, -22, accuracy: 1e-3)
        meter.update(rms: 0.5)                         // louder: immediate
        XCTAssertEqual(meter.dB, AudioMath.dBFS(rms: 0.5), accuracy: 1e-3)
    }
}
