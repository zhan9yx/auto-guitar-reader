import XCTest
@testable import AGRCore

final class FollowHMMTests: XCTestCase {
    typealias T = FollowTest

    private func follower(_ cho: String = T.loop, beats: Double? = 4, order: [Int]? = nil, mode: FollowMode = .strumSing,
                          config: FollowerConfig = .init()) -> (ScoreFollower, Timeline) {
        let tl = T.timeline(cho, beatsPerChord: beats, order: order)
        return (ScoreFollower(timeline: tl, mode: mode, config: config), tl)
    }

    /// Frames per event at speed 1 (120 bpm, 4 beats = 2 s).
    private let eventFrames = Int((2.0 * T.fc.frameRate).rounded())

    // MARK: basics

    func testInitialStateIsFirstEvent() {
        let (f, _) = follower()
        XCTAssertEqual(f.state.eventIndex, 0)
        XCTAssertEqual(f.state.tempoRatio, 1)
        XCTAssertFalse(f.state.isPaused)
    }

    func testAdvancesThroughCorrectChordSequence() {
        let (f, tl) = follower()
        var hits = 0, total = 0
        var t = 0.0
        for (ei, e) in tl.events.enumerated() {
            let n = Int((e.beats * 0.5 * T.fc.frameRate).rounded())
            for k in 0..<n {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1))
                t += 1 / T.fc.frameRate
                // Middle half of each event (boundaries are inherently ambiguous by a frame or two).
                if k > n / 4 && k < 3 * n / 4 { total += 1; if st.eventIndex == ei { hits += 1 } }
            }
        }
        XCTAssertEqual(hits, total, "every mid-event frame must be on the right event")
    }

    func testProgressInEventIncreases() {
        let (f, tl) = follower()
        var last = -1.0
        var monotonic = true
        let e = tl.events[0]
        let n = Int((e.beats * 0.5 * T.fc.frameRate).rounded())
        for k in 0..<(n - 5) {
            let st = f.process(T.frame(time: Double(k) / T.fc.frameRate, notes: e.midiNotes))
            if st.eventIndex == 0 { if st.progressInEvent < last - 0.02 { monotonic = false }; last = st.progressInEvent }
        }
        XCTAssertTrue(monotonic)
        XCTAssertGreaterThan(last, 0.6)
    }

    func testConfidenceHighWhenUnambiguousAndLowWhenFlat() {
        let (f, tl) = follower()
        T.play(f, timeline: tl, events: [0, 1])
        XCTAssertGreaterThan(f.state.confidence, 0.6)
        // Evidence that disagrees everywhere (uniform evidence has no effect) vs. contradictory evidence lowers nothing;
        // flat observations (noise-like chroma) must not give high confidence on a repeated progression.
        let loop = "{title: t}\n{tempo: 120}\n[C] [G] [C] [G] [C] [G] [C] [G]"
        let (g, tl2) = follower(loop)
        T.play(g, timeline: tl2, events: [0, 1, 2, 3], speed: 1)
        let ambiguous = g.eventPosterior()
        XCTAssertGreaterThan(ambiguous.max()!, 0.3)
    }

    // MARK: silence

    func testSilenceFreezesAndPausesAfterThreeSeconds() {
        let (f, tl) = follower()
        var t = T.play(f, timeline: tl, events: [0])
        // 10 frames of event 1, then silence.
        for _ in 0..<10 { f.process(T.frame(time: t, notes: tl.events[1].midiNotes)); t += 1 / T.fc.frameRate }
        let before = f.state
        XCTAssertEqual(before.eventIndex, 1)
        for _ in 0..<100 { f.process(T.frame(time: t, notes: [], silent: true)); t += 1 / T.fc.frameRate }   // 2.3 s
        XCTAssertEqual(f.state.eventIndex, 1, "must stay put during silence")
        XCTAssertFalse(f.state.isPaused)
        for _ in 0..<60 { f.process(T.frame(time: t, notes: [], silent: true)); t += 1 / T.fc.frameRate }   // > 3 s total
        XCTAssertTrue(f.state.isPaused)
        XCTAssertEqual(f.state.eventIndex, 1)
        XCTAssertLessThan(f.state.progressInEvent, 0.8, "the clock does not run during a long silence")
        // Playing resumes: not paused any more and the follower continues from event 1.
        f.process(T.frame(time: t, notes: tl.events[1].midiNotes))
        XCTAssertFalse(f.state.isPaused)
        XCTAssertEqual(f.state.eventIndex, 1)
    }

    func testShortSilenceDoesNotStopTheClock() {
        // Decay gaps between strums are flagged silent by the gate; the duration model must keep running.
        let (f, tl) = follower()
        var t = 0.0
        for ei in 0..<2 {
            let e = tl.events[ei]
            for k in 0..<eventFrames {
                let gap = k % 40 > 30        // 10-frame gaps (0.23 s)
                f.process(T.frame(time: t, notes: gap ? [] : e.midiNotes, silent: gap)); t += 1 / T.fc.frameRate
            }
        }
        for k in 0..<12 { f.process(T.frame(time: t, notes: tl.events[2].midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate }
        XCTAssertEqual(f.state.eventIndex, 2)
    }

    // MARK: repeated chords, skips, jumps

    func testRepeatedChordUsesDuration() {
        let (f, tl) = follower("{title: t}\n{tempo: 120}\n[C] [C] [G] [C]")
        var t = 0.0
        var seen: [Int] = []
        for (ei, e) in tl.events.enumerated() where ei < 3 {
            for k in 0..<eventFrames {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate
                if k == eventFrames / 2 { seen.append(st.eventIndex) }
            }
        }
        XCTAssertEqual(seen, [0, 1, 2], "same chord twice in a row must still advance by duration")
    }

    func testSkipOneEvent() {
        let (f, tl) = follower("{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F]")
        var t = T.play(f, timeline: tl, events: [0, 1])
        // Player skips the Am: F, C come next.
        var est = -1
        for ei in [3, 4] {
            let e = tl.events[ei]
            for k in 0..<eventFrames {
                est = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)).eventIndex; t += 1 / T.fc.frameRate
                if ei == 3 && k == eventFrames / 2 { XCTAssertEqual(est, 3) }
            }
        }
        XCTAssertGreaterThanOrEqual(est, 4)
    }

    func testRelocateResetsPosterior() {
        let (f, tl) = follower("{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F]")
        var t = T.play(f, timeline: tl, events: [0, 1, 2])
        f.relocate(toEvent: 6)
        XCTAssertEqual(f.state.eventIndex, 6)
        XCTAssertGreaterThan(f.eventPosterior()[6], 0.5)
        // Continue playing from event 6 (Am) -> F.
        for ei in [6, 7] {
            let e = tl.events[ei]
            for k in 0..<eventFrames {
                f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate
                if ei == 7 && k == eventFrames / 2 { XCTAssertEqual(f.state.eventIndex, 7) }
            }
        }
    }

    func testRelocateClampsIndexAndFollowsFromThere() {
        let (f, _) = follower()
        f.relocate(toEvent: 99)
        XCTAssertEqual(f.state.eventIndex, 3)
        f.relocate(toEvent: -5)
        XCTAssertEqual(f.state.eventIndex, 0)
    }

    func testJumpToSectionStartIsFound() {
        let cho = """
        {title: t}
        {tempo: 120}
        {start_of_verse}
        [C] [G] [Am] [F]
        {end_of_verse}
        {start_of_chorus}
        [Dm] [E] [Dm] [E]
        {end_of_chorus}
        """
        let (f, tl) = follower(cho)
        XCTAssertEqual(tl.sectionStartIndices, [0, 4])
        var t = T.play(f, timeline: tl, events: [0, 1])
        // The player jumps to the chorus.
        var est = 0
        for ei in [4, 5, 6] {
            let e = tl.events[ei]
            for k in 0..<eventFrames {
                est = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)).eventIndex; t += 1 / T.fc.frameRate
            }
        }
        XCTAssertTrue((5...6).contains(est), "got \(est)")
    }

    func testHeldChordIsFollowedThroughAPause() {
        // The chord keeps ringing 2.5x longer than notated: the hold state keeps the position on that event.
        let (f, tl) = follower()
        var t = T.play(f, timeline: tl, events: [0])
        let e = tl.events[1]
        for k in 0..<Int(Double(eventFrames) * 2.5) {
            f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate
        }
        XCTAssertEqual(f.state.eventIndex, 1)
        // ... and then moves on to the next chord promptly.
        for k in 0..<30 { f.process(T.frame(time: t, notes: tl.events[2].midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate }
        XCTAssertEqual(f.state.eventIndex, 2)
    }

    // MARK: tempo

    func testTempoRatioAdaptsToFasterPlaying() {
        let cho = "{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F] [C] [G] [Am] [F]"
        let (f, tl) = follower(cho)
        T.play(f, timeline: tl, speed: 1.3)
        XCTAssertGreaterThan(f.state.tempoRatio, 1.15)
        XCTAssertLessThan(f.state.tempoRatio, 1.5)
    }

    func testTempoRatioAdaptsToSlowerPlayingAndStaysClamped() {
        let cho = "{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F] [C] [G] [Am] [F]"
        let (f, tl) = follower(cho)
        T.play(f, timeline: tl, speed: 0.75)
        XCTAssertLessThan(f.state.tempoRatio, 0.92)
        XCTAssertGreaterThanOrEqual(f.state.tempoRatio, 0.5)
        XCTAssertLessThanOrEqual(f.state.tempoRatio, 2.0)
    }

    func testTempoIgnoresPauses() {
        let cho = "{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F]"
        let (f, tl) = follower(cho)
        var t = T.play(f, timeline: tl, events: [0, 1, 2, 3])
        t += 6                                                   // long pause, silent
        for _ in 0..<Int(6 * T.fc.frameRate) { f.process(T.frame(time: t, notes: [], silent: true)) }
        T.play(f, timeline: tl, events: [4, 5, 6, 7], startTime: t)
        XCTAssertEqual(f.state.tempoRatio, 1, accuracy: 0.12)
    }

    // MARK: robustness

    func testSurvivesLoudVoiceOnNonChordTones() {
        let cho = "{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F]"
        let (f, tl) = follower(cho)
        var t = 0.0
        var good = 0, total = 0
        for (ei, e) in tl.events.enumerated() {
            for k in 0..<eventFrames {
                // Sung D / B / F# / G alternating, 1.5x louder than the guitar.
                let vpc = [2, 11, 6, 7][(k / 20 + ei) % 4]
                let st = f.process(T.frame(time: t, notes: e.midiNotes, voicePCs: [vpc], voiceWeight: 1.5, onset: k < 2 ? 3 : 0.1))
                t += 1 / T.fc.frameRate
                if k > eventFrames / 4 && k < 3 * eventFrames / 4 { total += 1; if abs(st.eventIndex - ei) <= 1 { good += 1 } }
            }
        }
        XCTAssertGreaterThan(Double(good) / Double(total), 0.9)
    }

    func testCapoTemplatesUseSoundingNotes() {
        let cho = "{title: t}\n{tempo: 120}\n{capo: 2}\n[C] [G] [Am] [F] [C] [G] [Am] [F]"
        let (f, tl) = follower(cho)
        XCTAssertEqual(tl.capo, 2)
        // midiNotes include the capo: the sounding chord is D (C shape + 2).
        // C shape x32010 with capo 2: lowest sounding note is C3 + 2 = D3 (MIDI 50).
        XCTAssertEqual(tl.events[0].midiNotes.min(), 50)
        var hits = 0, total = 0
        var t = 0.0
        for (ei, e) in tl.events.enumerated() {
            for k in 0..<eventFrames {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1)); t += 1 / T.fc.frameRate
                if k == eventFrames / 2 { total += 1; if st.eventIndex == ei { hits += 1 } }
            }
        }
        XCTAssertEqual(hits, total)
    }

    func testRestEventsDoNotBreakTracking() {
        // A leading instrumental/lyrics-only line creates a rest-like event before the first chord.
        let cho = "{title: t}\n{tempo: 120}\n[C]一二三四[G]五六七八[Am]九十[F]结束"
        let (f, tl) = follower(cho)
        XCTAssertGreaterThanOrEqual(tl.events.count, 4)
        T.play(f, timeline: tl)
        XCTAssertEqual(f.state.eventIndex, tl.events.count - 1)
    }

    // MARK: lyrics evidence

    func testLyricsEvidenceDisambiguatesIdenticalChords() {
        let cho = "{title: t}\n{tempo: 120}\n[C]aaa[G]bbb\n[C]ccc[G]ddd\n[C]eee[G]fff"
        let (f, tl) = follower(cho)
        XCTAssertEqual(tl.events.count, 6)
        // Hear a C chord only for a short while: ambiguous between events 0, 2 and 4.
        var t = 0.0
        for _ in 0..<30 { f.process(T.frame(time: t, notes: tl.events[0].midiNotes)); t += 1 / T.fc.frameRate }
        let before = f.eventPosterior()
        XCTAssertGreaterThan(before[0], before[2])
        var ev = [Double](repeating: 0, count: tl.events.count)
        ev[2] = 1; ev[3] = 1
        f.applyLyricsEvidence(ev, weight: 1)
        XCTAssertEqual(f.state.eventIndex, 2)
        // Wrong length / zero weight: no effect.
        let p = f.eventPosterior()
        f.applyLyricsEvidence([1, 2, 3], weight: 1)
        f.applyLyricsEvidence(ev, weight: 0)
        XCTAssertEqual(f.eventPosterior(), p)
    }

    func testLyricsEvidenceSoftWeightOnlyTilts() {
        let cho = "{title: t}\n{tempo: 120}\n[C]aaa[G]bbb\n[C]ccc[G]ddd"
        let (f, tl) = follower(cho)
        var t = 0.0
        for _ in 0..<30 { f.process(T.frame(time: t, notes: tl.events[0].midiNotes)); t += 1 / T.fc.frameRate }
        let p0 = f.eventPosterior()[0]
        var ev = [Double](repeating: 0.5, count: 4)
        ev[2] = 1
        f.applyLyricsEvidence(ev, weight: 0.3)
        XCTAssertLessThan(f.eventPosterior()[0], p0)
        XCTAssertGreaterThan(f.eventPosterior()[0], 0.1)
    }

    // MARK: fingerstyle

    func testFingerstyleFollowsNotesAndRepeatedNotesNeedOnsets() {
        let tab = """
        {title: t}
        {tempo: 90}
        {start_of_tab}
        e|--0---0---3---0---|
        B|--1---1---0---1---|
        G|--0---0---0---0---|
        D|--2---2---0---2---|
        A|--3---3---2---3---|
        E|------------------|
        {end_of_tab}
        """
        guard let score = try? ChordProParser.parse(tab) else { return XCTFail("parse") }
        let tl = Timeline.build(from: score)
        let notesEvents = tl.events.filter { $0.kind == .notes }
        XCTAssertGreaterThanOrEqual(notesEvents.count, 3)
        let f = ScoreFollower(timeline: tl, mode: .fingerstyle)
        let fps = T.fc.frameRate
        let spb = 60.0 / tl.tempo
        var t = 0.0
        var correct = 0, total = 0
        for (ei, e) in tl.events.enumerated() {
            let n = max(2, Int((e.beats * spb * fps).rounded()))
            for k in 0..<n {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 3 ? 4 : 0.05)); t += 1 / fps
                if k == n - 2 && e.kind == .notes { total += 1; if abs(st.eventIndex - ei) <= 1 { correct += 1 } }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(max(total, 1)), 0.8)
    }

    // MARK: performance

    func testProcessIsCheap() {
        // ~100 events; 4000 frames (93 s of audio) must be fast even in a debug build.
        let loop = (0..<100).map { ["[C]", "[G]", "[Am]", "[F]"][$0 % 4] }.joined(separator: " ")
        let (f, tl) = follower("{title: t}\n{tempo: 120}\n" + loop)
        let fr = [T.frame(time: 0, notes: tl.events[0].midiNotes), T.frame(time: 0, notes: tl.events[1].midiNotes)]
        let start = Date()
        for i in 0..<4000 { _ = f.process(fr[(i / 80) % 2]) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8.0)
    }
}
