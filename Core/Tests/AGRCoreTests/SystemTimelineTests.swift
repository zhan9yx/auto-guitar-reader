import XCTest
@testable import AGRCore

final class SystemTimelineTests: XCTestCase {
    private func ms(_ spec: [(left: BarlineKind, right: BarlineKind, volta: [Int], marks: [String])]) -> [NotationMeasure] {
        spec.map { NotationMeasure(leftBarline: $0.left, rightBarline: $0.right, volta: $0.volta, marks: $0.marks) }
    }
    private func plain(_ n: Int) -> [NotationMeasure] { (0..<n).map { _ in NotationMeasure() } }
    private func order(_ m: [NotationMeasure]) -> [Int] { RepeatExpander.expand(m).map(\.index) }

    // MARK: repeat expansion

    func testNoRepeats() { XCTAssertEqual(order(plain(3)), [0, 1, 2]) }

    func testSimpleRepeat() {
        var m = plain(4)
        m[1].leftBarline = .startRepeat
        m[2].rightBarline = .endRepeat
        XCTAssertEqual(order(m), [0, 1, 2, 1, 2, 3])
        let passes = RepeatExpander.expand(m).map(\.pass)
        XCTAssertEqual(passes, [0, 0, 0, 1, 1, 0])
    }

    func testRepeatWithoutStartGoesToSectionStart() {
        var m = plain(3)
        m[1].rightBarline = .endRepeat
        XCTAssertEqual(order(m), [0, 1, 0, 1, 2])
    }

    func testVoltas() {
        var m = plain(5)
        m[0].leftBarline = .startRepeat
        m[2].volta = [1]; m[2].rightBarline = .endRepeat
        m[3].volta = [2]
        XCTAssertEqual(order(m), [0, 1, 2, 0, 1, 3, 4])
    }

    func testThreeVoltasPlayThreePasses() {
        var m = plain(5)
        m[0].leftBarline = .startRepeat
        m[1].volta = [1]; m[1].rightBarline = .endRepeat
        m[2].volta = [2]; m[2].rightBarline = .endRepeat
        m[3].volta = [3]
        XCTAssertEqual(order(m), [0, 1, 0, 2, 0, 3, 4])
    }

    func testStartEndRepeatBetweenTwoRepeats() {
        var m = plain(4)
        m[0].leftBarline = .startRepeat
        m[1].rightBarline = .startEndRepeat
        m[3].rightBarline = .endRepeat
        XCTAssertEqual(order(m), [0, 1, 0, 1, 2, 3, 2, 3])
        var m2 = plain(4)
        m2[0].leftBarline = .startRepeat
        m2[2].leftBarline = .startEndRepeat      // marker on the left side of the next measure
        m2[3].rightBarline = .endRepeat
        XCTAssertEqual(order(m2), [0, 1, 0, 1, 2, 3, 2, 3])
    }

    func testDalSegnoAlFine() {
        var m = plain(5)
        m[1].marks = ["Segno"]
        m[3].marks = ["Fine"]
        m[4].marks = ["D.S. al Fine"]
        XCTAssertEqual(order(m), [0, 1, 2, 3, 4, 1, 2, 3])
    }

    func testDaCapoAndNoInfiniteLoop() {
        var m = plain(3)
        m[2].marks = ["D.C."]
        XCTAssertEqual(order(m), [0, 1, 2, 0, 1, 2])
        var bad = plain(2)
        bad[0].rightBarline = .endRepeat; bad[1].rightBarline = .startEndRepeat
        XCTAssertLessThan(order(bad).count, 100)
    }

    func testDSAlCoda() {
        var m = plain(6)
        m[1].marks = ["Segno"]
        m[2].marks = ["To Coda"]
        m[3].marks = ["D.S. al Coda"]
        m[5].marks = ["Coda"]
        XCTAssertEqual(order(m), [0, 1, 2, 3, 1, 2, 5])
    }

    // MARK: system timeline

    func testChordGranularityRepeatsAndVerses() {
        let tl = Timeline.build(from: V2.score())
        XCTAssertEqual(tl.events.count, 7)
        XCTAssertEqual(tl.systemMeasures.count, 7)
        XCTAssertEqual(tl.totalBeats, 28)
        XCTAssertTrue(tl.events.allSatisfy { $0.fromSystem && $0.kind == .chord })
        XCTAssertEqual(tl.events.map(\.lyric), ["小星星你", "在哪里呀", "我在这里", "一二三四", "五六七八", "甲乙丙丁", "好想你啊"])
        XCTAssertEqual(tl.events.map(\.verse), [0, 0, 0, 1, 1, 1, 0])
        XCTAssertEqual(tl.events.map { $0.chord?.description }, ["C", "G7", "Am", "C", "G7", "Am", "F"])
        XCTAssertEqual(tl.events[3].startBeat, 12)
        XCTAssertEqual(tl.events.map(\.beats), Array(repeating: 4, count: 7))
        XCTAssertEqual(tl.events[0].progressInLine, 0...0.25)
        XCTAssertEqual(tl.events[3].progressInLine, 0...0.25)
        XCTAssertEqual(tl.events[6].progressInLine, 0.75...1)
        XCTAssertEqual(tl.sectionPasses.count, 1)
        // Printed shape wins for C; library for G7.
        XCTAssertEqual(tl.events[0].voicing?.frets, [-1, 3, 2, 0, 1, 0])
        XCTAssertEqual(tl.events[0].midiNotes, [48, 52, 55, 60, 64])
        XCTAssertEqual(tl.events[1].voicing, VoicingLibrary.voicing(for: ChordSymbol("G7")!))
    }

    func testChordSpansCarryOverAndSplitInsideMeasure() {
        let m0 = NotationMeasure(chords: [ChordMark(name: "C", beat: 0), ChordMark(name: "G", beat: 2)],
                                 melody: [MelodyNote(beat: 0, duration: 1, degree: 1, lyrics: ["我"]),
                                          MelodyNote(beat: 2, duration: 1, degree: 2, lyrics: ["你"]),
                                          MelodyNote(beat: 3, duration: 1, degree: 3, lyrics: ["他"])])
        let m1 = NotationMeasure(melody: [MelodyNote(beat: 0, duration: 1, degree: 5, lyrics: ["她"])])
        let tl = Timeline.build(from: V2.score(measures: [m0, m1]))
        XCTAssertEqual(tl.events.count, 2, "no new chord in m1 → G continues")
        XCTAssertEqual(tl.events[0].beats, 2); XCTAssertEqual(tl.events[0].lyric, "我")
        XCTAssertEqual(tl.events[1].beats, 6); XCTAssertEqual(tl.events[1].lyric, "你他她")
        XCTAssertEqual(tl.events[1].progressInLine, 0.25...1)
    }

    func testChordCarryAcrossSystemsSplitsEventsPerLine() {
        var s = V2.score(measures: [NotationMeasure(chords: [ChordMark(name: "C")])])
        s.sections[0].lines.append(Line.system(NotationSystem(measures: [NotationMeasure()])))
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events.count, 2)
        XCTAssertEqual(tl.events[1].chord?.description, "C")
        XCTAssertEqual(tl.events[1].line.lineIndex, 1)
    }

    func testRepeatsSpanSystemsAndVerseClamps() {
        let a = V2.measure(chord: "C", syllables: [["甲", "乙"]], left: .startRepeat)
        let b = V2.measure(chord: "G", syllables: [["丙"]], right: .endRepeat)   // one verse only
        var s = V2.score(measures: [a])
        s.sections[0].lines.append(Line.system(NotationSystem(measures: [b])))
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events.map(\.lyric), ["甲", "丙", "乙", "丙"], "verse index clamped to the verses available")
        XCTAssertEqual(tl.events.map(\.line.lineIndex), [0, 1, 0, 1])
    }

    func testSectionPassWithoutRepeatsUsesPassForVerse() {
        var s = V2.score(measures: [V2.measure(chord: "C", syllables: [["甲", "乙"]])])
        s.arrangement = ["s1", "s1"]
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events.map(\.lyric), ["甲", "乙"])
    }

    func testFingerstyleTabEventGranularity() {
        var s = V2.score(mode: .fingerstyle)
        s.sections[0].lines[0].system!.measures = [
            NotationMeasure(chords: [ChordMark(name: "C", shape: ChordShape(frets: [-1, 3, 2, 0, 1, 0]))],
                            tab: [V2.ct([5, 3, 2, 1], 0, 1),
                                  TabEvent(beat: 1, duration: 1, notes: [TabNote.chordTone(string: 6)]),   // muted in the shape
                                  TabEvent(beat: 2, duration: 1, notes: [TabNote(string: 1, fret: 3), TabNote.chordTone(string: 4)])],
                            melody: [MelodyNote(beat: 1, duration: 1, degree: 3, lyrics: ["啊"])])
        ]
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events.count, 3)
        XCTAssertEqual(tl.events[0].kind, .notes)
        XCTAssertEqual(tl.events[0].midiNotes, [48, 55, 60, 64])
        XCTAssertEqual(tl.events[0].noteStrings, [5, 3, 2, 1])
        XCTAssertEqual(tl.events[1].kind, .rest, "× on a string the shape mutes is skipped")
        XCTAssertEqual(tl.events[1].lyric, "啊")
        XCTAssertEqual(tl.events[2].midiNotes, [67, 52], "explicit fret as printed; × on string 4 = fret 0 of D")
        XCTAssertEqual(tl.events[2].beats, 2)
        XCTAssertEqual(tl.events.map(\.beats), [1, 1, 2])
        // Granularity override.
        let chordTL = Timeline.build(from: s, options: TimelineOptions(granularity: .chord))
        XCTAssertEqual(chordTL.events.count, 1)
        XCTAssertEqual(chordTL.events[0].lyric, "啊")
    }

    func testTransposeAndCapo() {
        var s = V2.score()
        s.meta.capo = 2
        let tl = Timeline.build(from: s)
        XCTAssertEqual(tl.events[0].midiNotes, [50, 54, 57, 62, 66])
        let up = Timeline.build(from: V2.score(), options: TimelineOptions(transpose: 2))
        XCTAssertEqual(up.events[0].chord?.description, "D")
        XCTAssertEqual(up.events[0].voicing, VoicingLibrary.voicing(for: ChordSymbol("D")!))
    }

    func testLegacyLinesStillWork() throws {
        let score = try ChordProParser.parse("{title: t}\n[C]hello [G]world")
        let tl = Timeline.build(from: score)
        XCTAssertEqual(tl.events.count, 2)
        XCTAssertTrue(tl.events.allSatisfy { !$0.fromSystem })
        XCTAssertTrue(tl.systemMeasures.isEmpty)
    }
}
