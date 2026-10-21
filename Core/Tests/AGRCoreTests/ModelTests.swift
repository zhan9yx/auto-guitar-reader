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
