import XCTest
@testable import AGRCore

final class ChordNameNormalizerTests: XCTestCase {
    private func n(_ s: String) -> NormalizedChordName { ChordNameNormalizer.normalize(s) }

    func testPlainNames() {
        XCTAssertEqual(n("Am7").symbol, ChordSymbol("Am7"))
        XCTAssertEqual(n("C/G").symbol, ChordSymbol("C/G"))
        XCTAssertEqual(n("Dsus").symbol?.quality, .sus4)
        XCTAssertEqual(n("Dsus4").symbol?.quality, .sus4)
        XCTAssertEqual(n("F#m").symbol, ChordSymbol(root: 6, quality: .minor))
    }

    func testStringVariantInParentheses() {
        let d = n("D7(5)")
        XCTAssertEqual(d.symbol, ChordSymbol("D7"))
        XCTAssertEqual(d.variant, 5)
        XCTAssertNil(d.optionalExtension)
        XCTAssertEqual(d.written, "D7(5)")
        XCTAssertEqual(n("G7(3)").symbol, ChordSymbol("G7"))
        XCTAssertEqual(n("G7(3)").variant, 3)
        XCTAssertEqual(n("C(5)").symbol, ChordSymbol("C"))
        XCTAssertEqual(n("C(5)").variant, 5)
        XCTAssertEqual(n("Am(6)").variant, 6)
    }

    func testOptionalSeventh() {
        let d = n("D(7)")
        XCTAssertEqual(d.symbol, ChordSymbol("D7"))
        XCTAssertEqual(d.optionalExtension, "7")
        XCTAssertNil(d.variant)
        XCTAssertEqual(n("Am(7)").symbol, ChordSymbol("Am7"))
        XCTAssertEqual(n("D(9)").symbol?.quality, .add9)
        XCTAssertEqual(n("Dsus4(7)").symbol?.quality, .dom7sus4)
    }

    func testNamedParenthesesExtensions() {
        XCTAssertEqual(n("Em7(b5)").symbol, ChordSymbol("Em7b5"))
        XCTAssertEqual(n("C(add9)").symbol, ChordSymbol("Cadd9"))
    }

    func testFullWidthAndGlyphs() {
        XCTAssertEqual(n("Ｃ").symbol, ChordSymbol("C"))
        XCTAssertEqual(n("Ａｍ７").symbol, ChordSymbol("Am7"))
        XCTAssertEqual(n("B♭").symbol, ChordSymbol("Bb"))
        XCTAssertEqual(n("F♯m7").symbol, ChordSymbol("F#m7"))
        XCTAssertEqual(n("Ｃ／Ｇ").symbol, ChordSymbol("C/G"))
        XCTAssertEqual(n("Ｄ７（５）").variant, 5)
        XCTAssertEqual(n(" G7 (3) ").symbol, ChordSymbol("G7"))
    }

    func testLowercaseAndSlashBass() {
        XCTAssertEqual(n("am").symbol, ChordSymbol("Am"))
        XCTAssertEqual(n("C/g").symbol, ChordSymbol("C/G"))
    }

    func testUnparseable() {
        XCTAssertNil(n("N.C.").symbol)
        XCTAssertNil(n("").symbol)
        XCTAssertNil(n("xyz").symbol)
        XCTAssertEqual(n("xyz").key, "xyz")
    }

    func testKeys() {
        XCTAssertEqual(n("Ｇ７(3)").key, n("G7(3)").key)
        XCTAssertNotEqual(n("G7(3)").key, n("G7").key)
        XCTAssertNotEqual(n("D(7)").key, n("D7").key)
        XCTAssertEqual(n("Bb").key, n("A#").key)
        XCTAssertEqual(ChordNameNormalizer.symbol("D7(5)"), ChordSymbol("D7"))
    }

    func testTonicPitchClass() {
        func pc(_ k: String?) -> Int { ScoreMeta(key: k).tonicPitchClass }
        XCTAssertEqual(pc("C"), 0); XCTAssertEqual(pc("G"), 7); XCTAssertEqual(pc("Bb"), 10)
        XCTAssertEqual(pc("1=D"), 2); XCTAssertEqual(pc("1=♭B"), 10); XCTAssertEqual(pc("Am"), 0)
        XCTAssertEqual(pc(nil), 0); XCTAssertEqual(pc("???"), 0)
    }
}
