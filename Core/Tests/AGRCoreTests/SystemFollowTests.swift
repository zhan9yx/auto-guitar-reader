import XCTest
@testable import AGRCore

final class SystemFollowTests: XCTestCase {
    typealias T = FollowTest

    func testStrumSingSystemTimelineIsFollowed() {
        let tl = Timeline.build(from: V2.score())
        XCTAssertEqual(tl.events.count, 7)
        let f = ScoreFollower(timeline: tl, mode: .strumSing)
        var hits = 0, total = 0
        var t = 0.0
        let spb = 60.0 / tl.tempo
        for (ei, e) in tl.events.enumerated() {
            let n = Int((e.beats * spb * T.fc.frameRate).rounded())
            for k in 0..<n {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1))
                t += 1 / T.fc.frameRate
                if k > n / 4 && k < 3 * n / 4 { total += 1; if st.eventIndex == ei { hits += 1 } }
            }
        }
        XCTAssertEqual(hits, total, "chord events of the expanded repeat are followed in order")
    }

    func testFingerstyleSystemTimelineIsFollowedByNoteEvents() {
        var s = V2.score(mode: .fingerstyle)
        // Distinct single notes so every event is identifiable.
        let tabs: [[TabEvent]] = [
            [TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 5, fret: 3)]), TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 3, fret: 0)]),
             TabEvent(beat: 2, duration: 1, notes: [TabNote(string: 2, fret: 1)]), TabEvent(beat: 3, duration: 1, notes: [TabNote(string: 1, fret: 3)])],
            [TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 4, fret: 0)]), TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 2, fret: 3)]),
             TabEvent(beat: 2, duration: 1, notes: [TabNote(string: 3, fret: 2)]), TabEvent(beat: 3, duration: 1, notes: [TabNote(string: 1, fret: 0)])],
        ]
        s.sections[0].lines[0].system!.measures = tabs.map { NotationMeasure(tab: $0) }
        s.meta.tempo = 90
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events.count, 8)
        XCTAssertTrue(tl.events.allSatisfy { $0.kind == .notes })
        let f = ScoreFollower(timeline: tl, mode: .fingerstyle)
        var hits = 0, total = 0
        var t = 0.0
        let spb = 60.0 / tl.tempo
        for (ei, e) in tl.events.enumerated() {
            let n = Int((e.beats * spb * T.fc.frameRate).rounded())
            for k in 0..<n {
                let st = f.process(T.frame(time: t, notes: e.midiNotes, onset: k < 2 ? 3 : 0.1))
                t += 1 / T.fc.frameRate
                if k > n / 3 && k < 2 * n / 3 { total += 1; if st.eventIndex == ei { hits += 1 } }
            }
        }
        XCTAssertGreaterThan(Double(hits) / Double(total), 0.9)
    }

    func testLyricsAlignerUsesVerseOfThePass() throws {
        let tl = Timeline.build(from: V2.score())
        let al = LyricsAligner(timeline: tl)
        // Verse 2 text ("一二三四五六") only exists in the repeated pass (events 3, 4).
        let r = try XCTUnwrap(al.update(transcript: "一二三四五六"))
        let best = r.evidence.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(best, 4)
        XCTAssertLessThan(r.evidence[1], 0.5)
        let al2 = LyricsAligner(timeline: tl)
        let r2 = try XCTUnwrap(al2.update(transcript: "小星星你在哪里"))
        XCTAssertEqual(r2.evidence.enumerated().max { $0.element < $1.element }!.offset, 1)
    }
}
