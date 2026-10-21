import XCTest
@testable import AGRCore

final class PlaybackPlannerTests: XCTestCase {
    func chordScore(_ names: [String], pattern: StrumPattern? = nil, mode: PlayMode = .strumSing, capo: Int = 0,
                    tempo: Double = 120, beats: Double? = nil, patterns: [StrumPattern] = [], sectionPattern: String? = nil) -> Score {
        let line = Line(kind: .chords, segments: names.map { ChordSegment(chord: $0, text: "", beats: beats) })
        return Score(meta: ScoreMeta(title: "t", capo: capo, tempo: tempo, mode: mode), strumPatterns: patterns,
                     sections: [Section(id: "a", lines: [line], strumPatternID: sectionPattern)])
    }
    func plan(_ s: Score, _ o: PlaybackOptions, transpose: Int = 0) -> [NoteEvent] {
        PerformancePlanner.plan(Timeline.build(from: s, options: TimelineOptions(transpose: transpose)), score: s, options: o)
    }
    func opts(_ p: StrumPattern? = nil, humanize: Double = 0) -> PlaybackOptions {
        PlaybackOptions(strumPattern: p, humanize: humanize)
    }
    /// Groups notes into strokes (gap > 0.12 s starts a new stroke).
    func strokes(_ notes: [NoteEvent]) -> [[NoteEvent]] {
        var out: [[NoteEvent]] = []
        for n in notes.sorted(by: { $0.time < $1.time }) {
            if let last = out.last?.last, n.time - last.time < 0.12 { out[out.count - 1].append(n) } else { out.append([n]) }
        }
        return out
    }

    func testDownStrumGoesLowToHighWithInterStringDelay() {
        let s = chordScore(["C"], pattern: nil, beats: 4)
        let notes = plan(s, opts(StrumPattern(id: "d", name: "d", subdivision: 1, strokes: "D---")))
        let st = strokes(notes)
        XCTAssertEqual(st.count, 1)
        let n = st[0]
        XCTAssertEqual(n.map(\.stringIndex), [1, 2, 3, 4, 5])
        XCTAssertEqual(n.map(\.midi), [48, 52, 55, 60, 64])
        for (a, b) in zip(n, n.dropFirst()) {
            let d = b.time - a.time
            XCTAssertGreaterThanOrEqual(d, 0.008 - 1e-9)
            XCTAssertLessThanOrEqual(d, 0.025 + 1e-9)
        }
    }

    func testUpStrumGoesHighToLowOnTopStrings() {
        let s = chordScore(["G"], beats: 4)
        let notes = plan(s, opts(StrumPattern(id: "u", name: "u", subdivision: 1, strokes: "U---")))
        let n = strokes(notes)[0]
        XCTAssertEqual(n.count, 4)
        XCTAssertEqual(n.map(\.stringIndex), [5, 4, 3, 2])
        XCTAssertEqual(n.map(\.midi), [67, 59, 55, 50])
    }

    func testTimingWithinPattern() {
        // 120 bpm → 0.5 s/beat; pop8 "D-DU-UDU" in eighths: strokes at slots 0,2,3,5,6,7.
        let s = chordScore(["C"], beats: 4)
        let notes = plan(s, opts(.defaultPop))
        let st = strokes(notes)
        XCTAssertEqual(st.count, 6)
        let expectedBeats = [0.0, 1.0, 1.5, 2.5, 3.0, 3.5]
        for (stroke, b) in zip(st, expectedBeats) {
            XCTAssertEqual(stroke.map(\.time).min()!, b * 0.5, accuracy: 1e-9)
        }
        // Beat 1 is accented relative to an off-beat down/up.
        let vel = st.map { $0.map(\.velocity).max()! }
        XCTAssertGreaterThan(vel[0], vel[1])
        XCTAssertGreaterThan(vel[1], vel[2])
        XCTAssertGreaterThan(vel[0], vel[3])
        // Pattern repeats per measure for a 2-measure chord.
        let s2 = chordScore(["C"], beats: 8)
        XCTAssertEqual(strokes(plan(s2, opts(.defaultPop))).count, 12)
    }

    func testPatternRestartsAtEachMeasureAndMidMeasureChangesKeepPhase() {
        let s = chordScore(["C", "G"], beats: 2)    // two chords share one measure
        let st = strokes(plan(s, opts(.defaultPop)))
        // Slots 0..3 → D(0) -(1) D(2) U(3) for C ; slots 4..7 → -(4) U(5) D(6) U(7) for G.
        XCTAssertEqual(st.map { $0.map(\.time).min()! }, [0, 0.5, 0.75, 1.25, 1.5, 1.75])
    }

    func testDeterminismAndSeeds() {
        let s = chordScore(["C", "G", "Am", "F"])
        let a = plan(s, PlaybackOptions(humanize: 0.8, seed: 42))
        let b = plan(s, PlaybackOptions(humanize: 0.8, seed: 42))
        let c = plan(s, PlaybackOptions(humanize: 0.8, seed: 43))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        // Without humanize the seed is irrelevant.
        XCTAssertEqual(plan(s, PlaybackOptions(humanize: 0, seed: 1)), plan(s, PlaybackOptions(humanize: 0, seed: 99)))
        // Humanize keeps times non-negative and sorted.
        XCTAssertTrue(a.allSatisfy { $0.time >= 0 })
        XCTAssertEqual(a.map(\.time), a.map(\.time).sorted())
    }

    func testTabNotesMapToExactMidi() {
        let m = TabMeasure(beats: 4, events: [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 6, fret: 0)]),
            TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 1, fret: 3)]),
            TabEvent(beat: 2, duration: 2, notes: [TabNote(string: 4, fret: 2), TabNote(string: 3, fret: 2)]),
        ])
        let s = Score(meta: ScoreMeta(title: "t", capo: 2, tempo: 120),
                      sections: [Section(id: "a", lines: [Line(kind: .tab, tab: TabBlock(measures: [m]))])])
        let notes = plan(s, opts(), transpose: 1)
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes[0].midi, 40 + 2 + 1); XCTAssertEqual(notes[0].stringIndex, 0)
        XCTAssertEqual(notes[0].time, 0, accuracy: 1e-9)
        XCTAssertEqual(notes[1].midi, 64 + 3 + 2 + 1); XCTAssertEqual(notes[1].stringIndex, 5)
        XCTAssertEqual(notes[1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(Set(notes[2...].map(\.midi)), [52 + 2 + 1, 57 + 2 + 1])
        XCTAssertEqual(Set(notes[2...].map(\.stringIndex)), [2, 3])
        // Same-string durations: note 0 (string 0) has no successor → at least its event duration.
        XCTAssertGreaterThanOrEqual(notes[0].duration, 0.5)
    }

    func testTabDurationEndsAtNextNoteOnSameString() {
        let m = TabMeasure(beats: 4, events: [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 2, fret: 1)]),
            TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 1, fret: 0)]),
            TabEvent(beat: 3, duration: 1, notes: [TabNote(string: 2, fret: 3)]),
        ])
        let s = Score(meta: ScoreMeta(title: "t", tempo: 120),
                      sections: [Section(id: "a", lines: [Line(kind: .tab, tab: TabBlock(measures: [m]))])])
        let notes = plan(s, opts())
        let first = notes.first { $0.time == 0 }!
        XCTAssertEqual(first.duration, 1.5, accuracy: 1e-9)   // until beat 3
    }

    func testTabTechniques() {
        let m = TabMeasure(beats: 4, events: [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 1, fret: 3)]),
            TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 1, fret: 3, technique: .tie)]),
            TabEvent(beat: 2, duration: 1, notes: [TabNote(string: 2, fret: 3, technique: .mute)]),
        ])
        let s = Score(meta: ScoreMeta(title: "t", tempo: 120),
                      sections: [Section(id: "a", lines: [Line(kind: .tab, tab: TabBlock(measures: [m]))])])
        let notes = plan(s, opts())
        XCTAssertEqual(notes.count, 2)                       // the tie is not re-plucked
        XCTAssertLessThanOrEqual(notes[1].duration, 0.1)     // muted note is short
        XCTAssertLessThan(notes[1].velocity, 0.5)
    }

    func testCountInClicksAndOffset() {
        let s = chordScore(["C"], beats: 4)
        let o = PlaybackOptions(tempoScale: 1, strumPattern: .defaultPop, countInBeats: 4, humanize: 0)
        let notes = plan(s, o)
        let clicks = notes.filter(\.isClick)
        XCTAssertEqual(clicks.map(\.time), [0, 0.5, 1.0, 1.5])
        XCTAssertGreaterThan(clicks[0].velocity, clicks[1].velocity)
        XCTAssertTrue(clicks.allSatisfy { $0.stringIndex == -1 && $0.eventIndex == -1 })
        let music = notes.filter { !$0.isClick }
        XCTAssertEqual(music.map(\.time).min()!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(notes.map(\.time), notes.map(\.time).sorted())
        XCTAssertEqual(PerformancePlanner.countInSeconds(Timeline.build(from: s), o), 2.0, accuracy: 1e-12)
        // No count-in → no clicks.
        XCTAssertTrue(plan(s, opts(.defaultPop)).allSatisfy { !$0.isClick })
    }

    func testMetronomeClicksEveryBeat() {
        let s = chordScore(["C"], beats: 4)
        let notes = plan(s, PlaybackOptions(strumPattern: .defaultPop, humanize: 0, metronome: true))
        XCTAssertEqual(notes.filter(\.isClick).map(\.time), [0, 0.5, 1.0, 1.5])
    }

    func testTempoScale() {
        let s = chordScore(["C", "G"], beats: 4)
        let a = plan(s, PlaybackOptions(strumPattern: .defaultPop, humanize: 0))
        let b = plan(s, PlaybackOptions(tempoScale: 2, strumPattern: .defaultPop, humanize: 0))
        XCTAssertEqual(b.map(\.time).max()!, a.map(\.time).max()! / 2, accuracy: 0.03)
        XCTAssertEqual(a.count, b.count)
    }

    func testNotesRingUntilNextStrokeOnSameStringOrChordChange() {
        let pat = StrumPattern(id: "d", name: "d", subdivision: 1, strokes: "D---")
        // C → G: A-string (index 1) is played in both: C's note lasts until G's A-string onset (≈ 4 beats = 2 s).
        let cg = plan(chordScore(["C", "G"], beats: 4), opts(pat))
        let cA = cg.first { $0.stringIndex == 1 && $0.time < 1 }!
        let gA = cg.first { $0.stringIndex == 1 && $0.time > 1 }!
        XCTAssertEqual(cA.duration, gA.time - cA.time, accuracy: 1e-9)
        // C → D: D shape mutes the A string, so the note is damped at the chord change (2 s), not left ringing.
        let cd = plan(chordScore(["C", "D"], beats: 4), opts(pat))
        let a = cd.first { $0.stringIndex == 1 }!
        XCTAssertEqual(a.duration, 2.0, accuracy: 1e-9)
    }

    func testFingerstyleModeUsesArpeggioForChords() {
        let s = chordScore(["C"], mode: .fingerstyle, beats: 4)
        let notes = plan(s, opts())
        // "B321B321": bass on lowest played string (A), then strings 3, 2, 1 (D, B, high E).
        XCTAssertEqual(notes.map(\.stringIndex), [1, 3, 4, 5, 3, 3, 4, 5])
        // Beat-3 bass alternates to the fifth (G3 = 55 on the D string).
        XCTAssertEqual(notes.map(\.midi), [48, 55, 60, 64, 55, 55, 60, 64])
    }

    func testBassNoteAlternatesToFifthOnBeatThree() {
        let s = chordScore(["C"], beats: 4)
        let notes = plan(s, opts(StrumPattern(id: "b", name: "b", subdivision: 1, strokes: "B-B-")))
        XCTAssertEqual(notes.map(\.midi), [48, 55])
        XCTAssertEqual(notes.map(\.stringIndex), [1, 3])
    }

    func testMutedChuckIsShortAndQuiet() {
        let s = chordScore(["Am"], beats: 4)
        let notes = plan(s, opts(StrumPattern(id: "x", name: "x", subdivision: 1, strokes: "X---")))
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.duration <= 0.06 && $0.velocity <= 0.35 })
    }

    func testSinglePluckDigits() {
        let s = chordScore(["G"], beats: 4)
        let notes = plan(s, opts(StrumPattern(id: "p", name: "p", subdivision: 1, strokes: "6-1-")))
        XCTAssertEqual(notes.map(\.stringIndex), [0, 5])
        XCTAssertEqual(notes.map(\.midi), [43, 67])
    }

    func testSectionPatternOverridesOptionsPattern() {
        let custom = StrumPattern(id: "mine", name: "m", subdivision: 1, strokes: "D-D-")
        let s = chordScore(["C"], beats: 4, patterns: [custom], sectionPattern: "mine")
        let st = strokes(plan(s, opts(.arpeggio)))
        XCTAssertEqual(st.count, 2)
        XCTAssertEqual(st.map { $0.map(\.time).min()! }, [0, 1.0])
    }

    func testSwingDelaysOffBeats() {
        let s = chordScore(["C"], beats: 4)
        let straight = strokes(plan(s, PlaybackOptions(strumPattern: .defaultPop, swing: 0, humanize: 0)))
        let swung = strokes(plan(s, PlaybackOptions(strumPattern: .defaultPop, swing: 1, humanize: 0)))
        // Stroke 3 sits on an off-beat 8th (slot 3).
        XCTAssertGreaterThan(swung[2].map(\.time).min()!, straight[2].map(\.time).min()!)
        XCTAssertEqual(swung[0].map(\.time).min()!, straight[0].map(\.time).min()!)
    }

    func testEventIndexLinksBackToTimeline() {
        let s = chordScore(["C", "G"], beats: 4)
        let t = Timeline.build(from: s)
        let notes = PerformancePlanner.plan(t, score: s, options: opts(.defaultPop))
        for n in notes {
            let e = t.events[n.eventIndex]
            XCTAssertGreaterThanOrEqual(n.time, t.seconds(forBeat: e.startBeat) - 1e-9)
            XCTAssertLessThan(n.time, t.seconds(forBeat: e.endBeat) + 1e-9)
        }
    }
}
