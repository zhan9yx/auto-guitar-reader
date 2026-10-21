import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

/// Records what the session asks the audio side to do.
@MainActor
final class FakePlaybackOutput: PlaybackOutput {
    struct Install { var events: [NoteEvent]; var seek: Double; var playing: Bool }
    var sampleRate = 44100.0
    var installs: [Install] = []
    var playingFlag = false
    var seeks: [Double] = []
    var position = 0.0
    var volume: Float = -1
    var brightness: Float = -1

    @MainActor
    func install(events: [NoteEvent], seekSeconds: Double, playing: Bool) {
        installs.append(Install(events: events, seek: seekSeconds, playing: playing))
        position = seekSeconds
        playingFlag = playing
    }
    @MainActor
    func setPlaying(_ playing: Bool) { playingFlag = playing }
    @MainActor
    func seek(toSeconds: Double) { seeks.append(toSeconds); position = toSeconds }
    var positionSeconds: Double { position }
    @MainActor
    func setVolume(_ volume: Float) { self.volume = volume }
    @MainActor
    func setBrightness(_ brightness: Float) { self.brightness = brightness }
}

final class LogicPlaybackTests: XCTestCase {
    /// Verse (2 lines x 4 chords) + chorus (1 line x 4 chords), 120 BPM 4/4: 4 beats per chord (2 s), 12 chords.
    @MainActor
    private func makeScore() throws -> Score {
        let cho = """
        {title: t}
        {tempo: 120}
        {start_of_verse}
        [C]夜色轻轻[G]落在窗台[Am]你的笑声[F]还在耳边
        [C]路灯慢慢[G]点亮回忆[Am]我却不敢[F]回头看
        {end_of_verse}
        {start_of_chorus}
        [F]风吹过[G]你的发梢[Em]我还记得[Am]那个微笑
        {end_of_chorus}
        """
        return try ChordProParser.parse(cho)
    }

    // MARK: Plan

    func testPlanMapsEngineTimeToBeatsAndEvents() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            var p = PlaybackParameters()
            p.countInBeats = 4
            let plan = PlaybackPlan.make(score: score, params: p)
            XCTAssertEqual(plan.secondsPerBeat, 0.5, accuracy: 1e-9)
            XCTAssertEqual(plan.countInSeconds, 2, accuracy: 1e-9)
            XCTAssertEqual(plan.events.filter { $0.isClick }.count, 4)
            XCTAssertTrue(plan.events.filter { !$0.isClick }.allSatisfy { $0.time >= 2 - 1e-9 }, "notes start after the count-in")
            XCTAssertEqual(plan.finishSeconds, 2 + 12 * 4 * 0.5 + PlaybackPlan.tailSeconds, accuracy: 1e-9)

            // During the count-in: first event, flagged.
            let ci = try XCTUnwrap(plan.reading(atEngineSeconds: 1))
            XCTAssertTrue(ci.isCountIn)
            XCTAssertEqual(ci.eventIndex, 0)
            XCTAssertEqual(ci.beat, -2, accuracy: 1e-9)
            // 1 s into the 2nd chord (beat 4 + 2 = 6 -> engine 2 + 3 s).
            let r = try XCTUnwrap(plan.reading(atEngineSeconds: 5))
            XCTAssertFalse(r.isCountIn)
            XCTAssertEqual(r.eventIndex, 1)
            XCTAssertEqual(r.progressInEvent, 0.5, accuracy: 1e-9)
            XCTAssertEqual(plan.engineSeconds(forBeat: 6), 5, accuracy: 1e-9)
            // Past the end: stays on the last event.
            XCTAssertEqual(plan.reading(atEngineSeconds: 1000)?.eventIndex, plan.timeline.events.count - 1)
        }
    }

    func testTempoScaleAndTransposeChangeThePlan() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            var slow = PlaybackParameters(); slow.tempoScale = 0.5
            let a = PlaybackPlan.make(score: score, params: PlaybackParameters())
            let b = PlaybackPlan.make(score: score, params: slow)
            XCTAssertEqual(b.secondsPerBeat, a.secondsPerBeat * 2, accuracy: 1e-9)
            XCTAssertEqual(b.bpm, 60, accuracy: 1e-9)
            XCTAssertEqual(a.events.count, b.events.count)

            var up = PlaybackParameters(); up.transpose = 2
            let c = PlaybackPlan.make(score: score, params: up)
            let lowA = a.events.filter { !$0.isClick }.map(\.midi).min() ?? 0
            let lowC = c.events.filter { !$0.isClick }.map(\.midi).min() ?? 0
            XCTAssertNotEqual(lowA, lowC)
            // Tempo outside the slider range is clamped.
            var crazy = PlaybackParameters(); crazy.tempoScale = 9
            XCTAssertEqual(PlaybackPlan.make(score: score, params: crazy).params.tempoScale, 1.5)
        }
    }

    func testStrumPatternNilFollowsTheScore() throws {
        try MainActor.assumeIsolated {
            var score = try makeScore()
            score.strumPatterns = [StrumPattern(id: "custom", name: "自定义", subdivision: 1, strokes: "D")]
            score.sections[1].strumPatternID = "custom"
            var follow = PlaybackParameters(); follow.strumPattern = nil
            var forced = PlaybackParameters(); forced.strumPattern = .arpeggio
            let a = PlaybackPlan.make(score: score, params: follow)
            let b = PlaybackPlan.make(score: score, params: forced)
            XCTAssertNotEqual(a.events, b.events)
            // Chorus events (8...11) in the "follow" plan use the 1-stroke pattern: 4 beats = 4 downstrokes per chord.
            let chorusStrokeTimes = Set(a.events.filter { $0.eventIndex == 8 }.map { ($0.time * 10).rounded() })
            XCTAssertLessThanOrEqual(chorusStrokeTimes.count, 4 * 2)
        }
    }

    func testMetronomeAndCountInClicks() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            var p = PlaybackParameters(); p.metronome = true; p.countInBeats = 2
            let plan = PlaybackPlan.make(score: score, params: p)
            XCTAssertEqual(plan.events.filter { $0.isClick }.count, 2 + 12 * 4)
        }
    }

    func testSectionLoopIsUnrolledAndMapsPositionBackIntoTheSection() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            var p = PlaybackParameters(); p.loopPass = 1; p.countInBeats = 4
            let plan = PlaybackPlan.make(score: score, params: p)
            let loop = try XCTUnwrap(plan.loopBeats)
            XCTAssertEqual(loop.lowerBound, 32, accuracy: 1e-9)          // chorus starts after 8 verse chords x 4 beats
            XCTAssertEqual(loop.upperBound, 48, accuracy: 1e-9)
            let length = 16 * 0.5
            XCTAssertEqual(plan.finishSeconds, 2 + Double(plan.loopRepeats) * length, accuracy: 1e-6)
            XCTAssertGreaterThan(plan.loopRepeats, 100)

            // Only chorus events (and count-in clicks) are in the note list; every repeat is identical.
            let music = plan.events.filter { !$0.isClick }
            XCTAssertTrue(music.allSatisfy { (8...11).contains($0.eventIndex) })
            let perRepeat = music.filter { $0.time < 2 + length }.count
            XCTAssertGreaterThan(perRepeat, 8)
            XCTAssertEqual(music.count, perRepeat * plan.loopRepeats)
            XCTAssertTrue(music.allSatisfy { $0.time + $0.duration <= 2 + Double(plan.loopRepeats) * length + 1e-6 })
            // Notes never ring across the loop point.
            for n in music {
                let local = (n.time - 2).truncatingRemainder(dividingBy: length)
                XCTAssertLessThanOrEqual(local + n.duration, length + 1e-6)
            }

            // Engine time -> beat: second repeat, 1 s in.
            XCTAssertEqual(plan.beat(atEngineSeconds: 2 + length + 1), 32 + 2, accuracy: 1e-9)
            let r = try XCTUnwrap(plan.reading(atEngineSeconds: 2 + 3 * length + 0.25))
            XCTAssertEqual(r.eventIndex, 8)
            // A beat outside the loop maps to the loop start.
            XCTAssertEqual(plan.engineSeconds(forBeat: 5), 2, accuracy: 1e-9)
            XCTAssertEqual(plan.engineSeconds(forBeat: 34), 2 + 1, accuracy: 1e-9)
            // Invalid loop index: plays normally.
            var bad = PlaybackParameters(); bad.loopPass = 99
            XCTAssertNil(PlaybackPlan.make(score: score, params: bad).loopBeats)
        }
    }

    func testLoopOptionsNameTheSectionPasses() throws {
        try MainActor.assumeIsolated {
            var score = try makeScore()
            score.arrangement = [score.sections[0].id, score.sections[1].id, score.sections[1].id]
            let tl = Timeline.build(from: score)
            let options = LoopOption.options(for: score, timeline: tl)
            XCTAssertEqual(options.count, 3)
            XCTAssertEqual(options[0].title, score.sections[0].name.isEmpty ? "段落 1" : score.sections[0].name)
            XCTAssertTrue(options[1].title.hasSuffix("第1遍"))
            XCTAssertTrue(options[2].title.hasSuffix("第2遍"))
        }
    }

    // MARK: Session / re-plan

    func testReplanResumesAtTheEquivalentBeat() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let out = FakePlaybackOutput()
            var params = PlaybackParameters(); params.countInBeats = 4
            let session = PlaybackSession(score: score, output: out, params: params)
            session.play()
            XCTAssertEqual(out.installs.count, 1)
            XCTAssertEqual(out.installs[0].seek, 0)
            XCTAssertTrue(out.installs[0].playing)
            XCTAssertEqual(session.state, .playing)

            // Beat 10 at 120 BPM: engine 2 + 5 s.
            out.position = 7
            // Half speed: beat 10 is at 4 s count-in + 10 beats x 1 s.
            var slow = params; slow.tempoScale = 0.5
            session.updateParameters(slow)
            XCTAssertEqual(out.installs.count, 2)
            XCTAssertEqual(out.installs[1].seek, 4 + 10 * 1.0, accuracy: 1e-9)
            XCTAssertTrue(out.installs[1].playing)

            // Count-in off: same beat, no count-in offset.
            var noCount = slow; noCount.countInBeats = 0
            session.updateParameters(noCount)
            XCTAssertEqual(out.installs[2].seek, 10 * 1.0, accuracy: 1e-9)

            // Transposition keeps the beat as well.
            var up = noCount; up.transpose = 3
            session.updateParameters(up)
            XCTAssertEqual(out.installs[3].seek, 10, accuracy: 1e-9)

            // No change: nothing is re-installed.
            session.updateParameters(up)
            XCTAssertEqual(out.installs.count, 4)

            // Looping the chorus while playing in the verse: restarts at the loop start.
            var loop = up; loop.loopPass = 1
            session.updateParameters(loop)
            XCTAssertEqual(out.installs[4].seek, 0, accuracy: 1e-9)       // no count-in, loop starts at engine 0
            XCTAssertEqual(session.plan.beat(atEngineSeconds: 0), 32, accuracy: 1e-9)
        }
    }

    func testReplanKeepsAPausedSessionPausedAndHandlesTheCountIn() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let out = FakePlaybackOutput()
            var params = PlaybackParameters(); params.countInBeats = 4
            let session = PlaybackSession(score: score, output: out, params: params)
            session.play()
            // In the middle of the count-in (beat -2).
            out.position = 1
            session.pause()
            XCTAssertEqual(session.state, .paused)
            XCTAssertFalse(out.playingFlag)
            var fast = params; fast.tempoScale = 1.5
            session.updateParameters(fast)
            XCTAssertFalse(try XCTUnwrap(out.installs.last).playing, "stays paused")
            // beat -2 at 180 BPM (1/3 s/beat) with a 4/3 s count-in -> 2/3 s.
            XCTAssertEqual(try XCTUnwrap(out.installs.last).seek, 2.0 / 3.0, accuracy: 1e-9)
            session.play()
            XCTAssertEqual(session.state, .playing)
            XCTAssertTrue(out.playingFlag)
            XCTAssertEqual(out.installs.count, 2, "resuming does not re-install")
        }
    }

    func testParametersChangedBeforePlayOnlyReplanLazily() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let out = FakePlaybackOutput()
            let session = PlaybackSession(score: score, output: out)
            var p = PlaybackParameters(); p.tempoScale = 0.75
            session.updateParameters(p)
            XCTAssertTrue(out.installs.isEmpty)
            session.play()
            XCTAssertEqual(out.installs.count, 1)
            XCTAssertEqual(session.plan.params.tempoScale, 0.75)
        }
    }

    func testTickReportsPositionAndFinishes() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let out = FakePlaybackOutput()
            let session = PlaybackSession(score: score, output: out)
            var finished = 0
            session.onFinish = { finished += 1 }
            XCTAssertNil(session.tick())
            session.play()
            out.position = 3                         // 1 s into the 2nd chord (no count-in, 2 s chords)... 3 s = beat 6
            let r = try XCTUnwrap(session.tick())
            XCTAssertEqual(r.eventIndex, 1)
            XCTAssertEqual(r.progressInEvent, 0.5, accuracy: 1e-9)
            XCTAssertEqual(session.reading, r)

            out.position = session.plan.finishSeconds + 0.1
            XCTAssertNil(session.tick())
            XCTAssertEqual(finished, 1)
            XCTAssertEqual(session.state, .idle)
            XCTAssertFalse(out.playingFlag)
            XCTAssertEqual(out.seeks.last, 0)
            XCTAssertNil(session.tick())
            XCTAssertEqual(finished, 1)
            // Playing again starts over.
            session.play()
            XCTAssertEqual(session.state, .playing)
            XCTAssertEqual(try XCTUnwrap(out.installs.last).seek, 0)
        }
    }

    func testSeekToEventAndRestart() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let out = FakePlaybackOutput()
            var params = PlaybackParameters(); params.countInBeats = 4
            let session = PlaybackSession(score: score, output: out, params: params)
            session.play()
            session.seek(toEvent: 5)
            XCTAssertEqual(out.seeks.last ?? -1, 2 + 5 * 2.0, accuracy: 1e-9)
            session.pause()
            session.restart()
            XCTAssertEqual(out.seeks.last, 0)
            XCTAssertEqual(session.state, .playing)
            session.stop()
            XCTAssertEqual(session.state, .idle)
            XCTAssertFalse(out.playingFlag)
            session.setVolume(2)
            XCTAssertEqual(out.volume, 1)
            session.setBrightness(-1)
            XCTAssertEqual(out.brightness, 0)
        }
    }

    // MARK: SequencerBox

    func testSequencerBoxRendersAndSwapsEngines() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let plan = PlaybackPlan.make(score: score, params: PlaybackParameters())
            let sr = 22050.0
            let a = SequencerEngine(sampleRate: sr, events: plan.events)
            a.isPlaying = true
            let box = SequencerBox()
            var out = [Float](repeating: 0, count: 512)

            // Nothing submitted yet: silence.
            out.withUnsafeMutableBufferPointer { box.render(into: $0.baseAddress!, frameCount: 512) }
            XCTAssertTrue(out.allSatisfy { $0 == 0 })

            box.submit(a)
            var energy: Float = 0
            for _ in 0..<40 {
                out.withUnsafeMutableBufferPointer { box.render(into: $0.baseAddress!, frameCount: 512) }
                energy += out.reduce(0) { $0 + $1 * $1 }
            }
            XCTAssertGreaterThan(energy, 0.01)
            XCTAssertGreaterThan(a.positionSeconds, 0.5)

            // Swap to an engine without notes: after the swap the output decays to silence.
            let b = SequencerEngine(sampleRate: sr, events: [])
            b.isPlaying = true
            box.submit(b)
            for _ in 0..<4 {
                out.withUnsafeMutableBufferPointer { box.render(into: $0.baseAddress!, frameCount: 512) }
            }
            XCTAssertTrue(out.allSatisfy { $0 == 0 })
            box.releaseAll()
            out.withUnsafeMutableBufferPointer { box.render(into: $0.baseAddress!, frameCount: 512) }
            XCTAssertTrue(out.allSatisfy { $0 == 0 })
        }
    }

    func testSequencerBoxHandOverWhileRenderingOnAnotherThread() throws {
        try MainActor.assumeIsolated {
            let score = try makeScore()
            let plan = PlaybackPlan.make(score: score, params: PlaybackParameters())
            let box = SequencerBox()
            let stop = ManagedFlag()
            let rendered = ManagedCounter()
            let renderQueue = DispatchQueue(label: "test.render")
            let done = DispatchSemaphore(value: 0)
            renderQueue.async {
                var buffer = [Float](repeating: 0, count: 256)
                while !stop.isSet {
                    buffer.withUnsafeMutableBufferPointer { box.render(into: $0.baseAddress!, frameCount: 256) }
                    rendered.increment()
                    precondition(buffer.allSatisfy { $0.isFinite })
                }
                done.signal()
            }
            for i in 0..<60 {
                let e = SequencerEngine(sampleRate: 22050, events: plan.events)
                e.seek(toSeconds: Double(i) * 0.3)
                e.isPlaying = true
                box.submit(e)
                usleep(2_000)
            }
            stop.set()
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
            XCTAssertGreaterThan(rendered.value, 10)
            box.releaseAll()
        }
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
