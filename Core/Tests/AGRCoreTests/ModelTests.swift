import XCTest
@testable import AGRCore

final class ModelTests: XCTestCase {
    func testChordParsing() {
        XCTAssertEqual(ChordSymbol("Am7")?.pitchClasses, [9, 0, 4, 7])
        XCTAssertEqual(ChordSymbol("C/G")?.bassPitchClass, 7)
        XCTAssertEqual(ChordSymbol("Bbmaj7")?.description, "Bbmaj7")
        XCTAssertEqual(ChordSymbol("F#m7b5")?.quality, .halfDim7)
        XCTAssertEqual(ChordSymbol("G")?.transposed(by: 2).description, "A")
        XCTAssertNil(ChordSymbol("我"))
        XCTAssertNil(ChordSymbol("Hello"))
        XCTAssertNil(ChordSymbol("Am/X"))
    }

    func testScoreRoundTripAndLenientDecode() throws {
        let line = Line(kind: .lyrics, segments: [ChordSegment(chord: "G", text: "我曾经"), ChordSegment(chord: "C", text: "跨过")])
        let score = Score(meta: ScoreMeta(title: "测试", capo: 2), sections: [Section(id: "v1", name: "主歌", kind: .verse, lines: [line])])
        let decoded = try ScoreCoding.decode(ScoreCoding.encode(score))
        XCTAssertEqual(decoded, score)
        let minimal = try ScoreCoding.decode(Data(#"{"meta":{"title":"x"},"sections":[]}"#.utf8))
        XCTAssertEqual(minimal.meta.tempo, 80)
        XCTAssertEqual(minimal.meta.tuning, ScoreMeta.standardTuning)
    }
}

final class ModelLeniencyTests: XCTestCase {
    func testExtendedChordQualities() {
        XCTAssertEqual(ChordSymbol("C6/9")?.quality, .sixNine)
        XCTAssertNil(ChordSymbol("C6/9")?.bass)
        XCTAssertEqual(ChordSymbol("E7#9")?.quality, .dom7sharp9)
        XCTAssertEqual(ChordSymbol("Cmaj7(9)")?.quality, .maj9)
        XCTAssertEqual(ChordSymbol("Cadd11")?.quality, .add11)
        XCTAssertEqual(ChordSymbol("C6/G")?.bass, 7)
        XCTAssertNil(ChordSymbol("C/9"))
        XCTAssertEqual(ChordSymbol("C6/9")?.description, "C6/9")
    }

    func testLenientLineDecoding() throws {
        let json = #"{"meta":{"title":"t"},"sections":[{"id":"s0","name":"","kind":"verse","lines":[{"kind":"comment","text":"hi"},{"kind":"lyrics","segments":[{"chord":"G"}]}]}],"chordDefinitions":{"G":{"frets":[3,2,0,0,0,3]}}}"#
        let score = try ScoreCoding.decode(Data(json.utf8))
        XCTAssertEqual(score.sections[0].lines[0].segments, [])
        XCTAssertEqual(score.sections[0].lines[1].segments[0].text, "")
        XCTAssertEqual(score.chordDefinitions["G"]?.baseFret, 1)
    }
}
