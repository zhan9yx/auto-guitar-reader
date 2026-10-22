import XCTest
@testable import AGRCore

final class SystemFormatTests: XCTestCase {
    func testAsciiTabLayout() {
        let sys = V2.score().sections[0].lines[0].system!
        let text = NotationSystemFormatter.asciiTab(sys)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix("e ") }, text)
        let strings = lines.filter { $0.count > 2 && "eBGDAE".contains($0.first!) && $0.dropFirst().first == " " }
        XCTAssertEqual(strings.count, 6)
        XCTAssertEqual(Set(strings.map(\.count)).count, 1, "all string rows have the same width")
        XCTAssertTrue(strings[0].contains("|:"), "start repeat")
        XCTAssertTrue(strings[0].contains(":|") && strings[0].hasSuffix("|]"))
        XCTAssertTrue(lines[0].contains("G7(3)") || lines[1].contains("G7(3)"))
        XCTAssertTrue(text.contains("x"))
        XCTAssertTrue(text.contains("1."), "verse 1 row")
        XCTAssertTrue(text.contains("2."), "verse 2 row")
        XCTAssertTrue(text.contains("3'"), "octave dot above")
    }

    func testAsciiTabFrettedAndStroke() {
        let m = NotationMeasure(tab: [TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 6, fret: 10), TabNote(string: 1, fret: 3, technique: .hammerOn)], stroke: .down),
                                      TabEvent(beat: 2, duration: 1, notes: [TabNote.chordTone(string: 3)], stroke: .up)],
                                rightBarline: .final)
        let text = NotationSystemFormatter.asciiTab(NotationSystem(measures: [m]))
        XCTAssertTrue(text.contains("|10"))
        XCTAssertTrue(text.contains("3h"))
        XCTAssertTrue(text.contains("v"))
        XCTAssertTrue(text.contains("^"))
        XCTAssertEqual(NotationSystemFormatter.asciiTab(NotationSystem()), "")
    }

    func testChordProExportOfSystemsRoundTripsChordsAndLyrics() throws {
        let s = V2.score()
        let cho = ChordProExporter.export(s)
        XCTAssertTrue(cho.contains("[C]小星星你"), cho)
        XCTAssertTrue(cho.contains("[G7]在哪里呀"), "normalized chord name is used inside brackets")
        XCTAssertTrue(cho.contains("{c: chord names: G7(3) = G7}"), cho)
        XCTAssertTrue(cho.contains("repeat start")); XCTAssertTrue(cho.contains("repeat end"))
        XCTAssertTrue(cho.contains("2 verses, only verse 1 exported"))
        XCTAssertFalse(cho.contains("一二三四"))
        let back = try ChordProParser.parse(cho)
        let lines = back.sections.flatMap(\.lines)
        let lyricLines = lines.filter { $0.kind == .lyrics }
        XCTAssertEqual(lyricLines.count, 1)
        XCTAssertEqual(lyricLines[0].segments.compactMap(\.chord), ["C", "G7", "Am", "F"])
        XCTAssertEqual(lyricLines[0].lyricText, "小星星你在哪里呀我在这里好想你啊")
    }

    func testChordOnlySystemExportsChordLine() throws {
        let sys = NotationSystem(measures: [NotationMeasure(chords: [ChordMark(name: "G")]), NotationMeasure(chords: [ChordMark(name: "D(7)")])])
        let s = Score(sections: [Section(lines: [Line.system(sys)])])
        let cho = ChordProExporter.export(s)
        XCTAssertTrue(cho.contains("[G] [D7]"), cho)
    }
}
