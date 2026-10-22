import XCTest
@testable import AGRCore

final class SystemPlaybackTests: XCTestCase {
    private func plan(_ s: Score, _ o: PlaybackOptions = PlaybackOptions(humanize: 0), options: TimelineOptions = .init()) -> [NoteEvent] {
        PerformancePlanner.plan(Timeline.build(from: s, options: options), score: s, options: o)
    }

    func testPrintedTabIsPlayedIgnoringStrumPatterns() {
        var s = V2.score(measures: [V2.measure(chord: "C", shape: "x32010", syllables: [["a"]])])
        s.strumPatterns = [StrumPattern.defaultPop]
        s.sections[0].strumPatternID = "pop8"
        let ev = plan(s, PlaybackOptions(strumPattern: .defaultPop, humanize: 0))
        // Printed: [5,3,2,1] at 0, [4] at 1, [3] at 2, [2] at 3 → 4+1+1+1 notes. Chord-tone midi from shape x32010.
        XCTAssertEqual(ev.count, 7)
        XCTAssertEqual(ev.filter { $0.time < 0.05 }.map(\.midi).sorted(), [48, 55, 60, 64])
        XCTAssertEqual(ev.filter { abs($0.time - 0.6) < 1e-6 }.map(\.midi), [52], "beat 1 at 100 bpm: × on string 4 = fret 2 of the C shape")
    }

    func testStrokeEventsStrumListedStringsInDirection() {
        let down = TabEvent(beat: 0, duration: 1, notes: [5, 4, 3, 2].map { TabNote.chordTone(string: $0) }, stroke: .down)
        let up = TabEvent(beat: 2, duration: 1, notes: [5, 4, 3, 2].map { TabNote.chordTone(string: $0) }, stroke: .up)
        let m = NotationMeasure(chords: [ChordMark(name: "C", shape: ChordShape(frets: [-1, 3, 2, 0, 1, 0]))], tab: [down, up])
        let ev = plan(V2.score(measures: [m]))
        XCTAssertEqual(ev.count, 8)
        let d = ev.filter { $0.time < 1 }.sorted { $0.time < $1.time }
        XCTAssertEqual(d.map(\.midi), [48, 52, 55, 60], "down: low to high")
        XCTAssertTrue(d[0].time < d[3].time)
        let u = ev.filter { $0.time >= 1 }.sorted { $0.time < $1.time }
        XCTAssertEqual(u.map(\.midi), [60, 55, 52, 48], "up: high to low")
    }

    func testMutedStringInShapeIsSkipped() {
        let m = NotationMeasure(chords: [ChordMark(name: "C", shape: ChordShape(frets: [-1, 3, 2, 0, 1, 0]))],
                                tab: [TabEvent(beat: 0, duration: 1, notes: [6, 5].map { TabNote.chordTone(string: $0) })])
        XCTAssertEqual(plan(V2.score(measures: [m])).map(\.midi), [48])
    }

    func testChordOnlyMeasureFallsBackToStrumPattern() {
        let m = NotationMeasure(chords: [ChordMark(name: "G")])
        let ev = plan(V2.score(measures: [m]))
        XCTAssertGreaterThan(ev.count, 6)
        XCTAssertTrue(ev.allSatisfy { !$0.isMelody })
    }

    func testRepeatsArePlayedTwice() {
        let single = plan(V2.score(measures: [V2.measure(chord: "C", syllables: [["a"]])]))
        let rep = plan(V2.score(measures: [V2.measure(chord: "C", syllables: [["a"]], left: .startRepeat, right: .endRepeat)]))
        XCTAssertEqual(rep.count, single.count * 2)
        XCTAssertEqual(rep.map(\.time).max()!, single.map(\.time).max()! + 4 * 0.6, accuracy: 1e-6)
    }

    func testMelodyOffByDefaultAndOnWhenRequested() {
        let s = V2.score(measures: [V2.measure(chord: "C", syllables: [["a"], ["b"], ["c"], ["d"]])])
        XCTAssertFalse(plan(s).contains { $0.isMelody })
        let ev = plan(s, PlaybackOptions(humanize: 0, playMelody: true)).filter(\.isMelody)
        XCTAssertEqual(ev.count, 4)
        XCTAssertEqual(ev.map(\.midi), [60, 62, 76, 65], "1 2 3' 4 with C tonic; 3 is one octave up")
        XCTAssertTrue(ev.allSatisfy { $0.stringIndex == -2 && $0.velocity < 0.7 })
        XCTAssertEqual(ev[1].time, 0.6, accuracy: 1e-9)
    }

    func testMelodyKeyAndOctaveFit() {
        var s = V2.score(measures: [NotationMeasure(melody: [
            MelodyNote(beat: 0, duration: 1, degree: 1, octave: 1), MelodyNote(beat: 1, duration: 1, degree: 5, octave: 1, tieToNext: true),
            MelodyNote(beat: 2, duration: 1, degree: 5, octave: 1), MelodyNote(beat: 3, duration: 1, degree: 0)])])
        s.meta.key = "A"
        let ev = plan(s, PlaybackOptions(humanize: 0, playMelody: true)).filter(\.isMelody)
        // A tonic: 60+9 = 69, +12 = 81 > 76 → whole piece shifted down an octave.
        XCTAssertEqual(ev.map(\.midi), [69, 76], "rest skipped, tie merged")
        XCTAssertEqual(ev[1].duration, 2 * 0.6 * 0.96, accuracy: 1e-9)
    }

    func testMelodyRendersInSequencer() {
        let s = V2.score(measures: [NotationMeasure(melody: [MelodyNote(beat: 0, duration: 2, degree: 1)])])
        let ev = plan(s, PlaybackOptions(humanize: 0, playMelody: true))
        let samples = OfflineRenderer.render(ev, sampleRate: 8000, tail: 0.2)
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.01)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    func testEventIndexRefersToTimelineEvent() {
        let s = V2.score()
        let tl = Timeline.build(from: s)
        let ev = PerformancePlanner.plan(tl, score: s, options: PlaybackOptions(humanize: 0))
        XCTAssertTrue(ev.allSatisfy { tl.events.indices.contains($0.eventIndex) })
        let last = ev.max { $0.time < $1.time }!
        XCTAssertEqual(last.eventIndex, 6)
    }
}
