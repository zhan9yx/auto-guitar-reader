import XCTest
@testable import AGRCore

final class ImportScoreImporterTests: XCTestCase {
    typealias S = ImportTestSupport

    private let verse = "我曾经跨过山和大海"
    /// GB18030 bytes of "七里香 - 周杰伦\nCapo: 2\n\n[主歌]\nC       G\n我曾经跨过山和大海\n"
    private let gbHex = "c6dfc0efcfe3202d20d6dcbddcc2d70a4361706f3a20320a0a5bd6f7b8e85d0a4320202020202020470aced2d4f8beadbfe7b9fdc9bdbacdb4f3baa30a"
    private let sheet = "七里香 - 周杰伦\nCapo: 2\n\n[主歌]\nC       G\n我曾经跨过山和大海\n"

    // MARK: TextWidth

    func testTextWidthColumns() {
        XCTAssertEqual(TextWidth.columns("abc"[...]), 3)
        XCTAssertEqual(TextWidth.columns("我曾经"[...]), 6)
        XCTAssertEqual(TextWidth.columns("Hi 我们"[...]), 7)
        XCTAssertEqual(TextWidth.columns("，。！"[...]), 6)        // CJK punctuation
        XCTAssertEqual(TextWidth.columns("ＡＢ"[...]), 4)           // full-width Latin
        XCTAssertEqual(TextWidth.columns("あいう한글"[...]), 10)
        XCTAssertEqual(TextWidth.columns("e\u{301}"[...]), 1)       // combining accent
        XCTAssertEqual(TextWidth.columns(""[...]), 0)
        XCTAssertEqual(TextWidth.columns("　"[...]), 2)            // ideographic space
        XCTAssertEqual(TextWidth.columns("a我b"[...].dropFirst()), 3)
    }

    // MARK: Decoding

    func testDecodeUTF8WithAndWithoutBOM() throws {
        let plain = Data(sheet.utf8)
        XCTAssertEqual(TextDecoder.decode(plain), sheet)
        XCTAssertEqual(TextDecoder.decode(Data([0xEF, 0xBB, 0xBF]) + plain), sheet)
    }

    func testDecodeUTF16WithBOM() throws {
        let le = Data([0xFF, 0xFE]) + (sheet.data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(TextDecoder.decode(le), sheet)
        let be = Data([0xFE, 0xFF]) + (sheet.data(using: .utf16BigEndian) ?? Data())
        XCTAssertEqual(TextDecoder.decode(be), sheet)
        let score = try ScoreImporter.importData(le, fileName: "x.txt")
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(S.allLines(score).first.map(S.render), "[C]我曾经跨[G]过山和大海")
    }

    func testDecodeUTF16WithoutBOMByZeroPattern() {
        let ascii = "{title: Hi}\n[C]hello world\n"
        XCTAssertEqual(TextDecoder.decode(ascii.data(using: .utf16LittleEndian) ?? Data()), ascii)
        XCTAssertEqual(TextDecoder.decode(ascii.data(using: .utf16BigEndian) ?? Data()), ascii)
    }

    /// Apple platforms decode GB18030 through `String.Encoding(rawValue: 0x80000632)`.
    /// swift-corelibs-foundation on Linux does not implement that encoding, so `TextDecoder` falls back to glibc iconv.
    func testFoundationGB18030EncodingAvailability() {
        let data = S.hexData(gbHex)
        let viaFoundation = String(data: data, encoding: String.Encoding(rawValue: 0x8000_0632))
        #if os(macOS) || os(iOS)
        XCTAssertEqual(viaFoundation, sheet)
        #else
        // Documented behaviour on Linux: Foundation cannot decode it (nil); the importer must still succeed below.
        if let viaFoundation { XCTAssertEqual(viaFoundation, sheet) }
        #endif
    }

    func testDecodeGB18030Fallback() throws {
        let data = S.hexData(gbHex)
        guard GB18030.decode(data) != nil else { throw XCTSkip("GB18030 decoding unavailable on this platform") }
        XCTAssertEqual(TextDecoder.decode(data), sheet)
        let score = try ScoreImporter.importData(data, fileName: "七里香.txt")
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.artist, "周杰伦")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(S.allLines(score).first.map(S.render), "[C]我曾经跨[G]过山和大海")
    }

    // MARK: Format detection

    func testDetectByExtension() {
        let text = Data("[C]x".utf8)
        for ext in ["cho", "chopro", "chordpro", "pro", "crd"] {
            XCTAssertEqual(ScoreImporter.detectFormat(data: text, fileName: "a.\(ext)"), .chordpro, ext)
        }
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("x".utf8), fileName: "a.agr.json"), .agr)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("x".utf8), fileName: "a.musicxml"), .musicXML)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("x".utf8), fileName: "a.mxl"), .musicXML)
    }

    func testDetectBySniffing() {
        let tab = ["e|--0--|", "B|--1--|", "G|--0--|", "D|--2--|", "A|--3--|", "E|-----|"].joined(separator: "\n")
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data(tab.utf8), fileName: "x.txt"), .asciiTab)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("{title: x}\n[C]la".utf8), fileName: nil), .chordpro)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data(sheet.utf8), fileName: "x.txt"), .chordText)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("<?xml version=\"1.0\"?><score-partwise/>".utf8), fileName: nil), .musicXML)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data("{\"format\":\"agr-score\",\"version\":1}".utf8), fileName: "x.json"), .agr)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data([0x50, 0x4B, 0x03, 0x04]), fileName: nil), .musicXML)
        XCTAssertNil(ScoreImporter.detectFormat(data: Data("   ".utf8), fileName: "x.txt"))
        XCTAssertNil(ScoreImporter.detectFormat(data: Data("<?xml version=\"1.0\"?><html/>".utf8), fileName: "x.xml"))
    }

    func testDetectTabWithExtensionTab() {
        let tab = ["e|--0--|", "B|--1--|", "G|--0--|", "D|--2--|", "A|--3--|", "E|-----|"].joined(separator: "\n")
        let withLyrics = "Some intro words\nmore words here\nand more words\n" + tab
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data(withLyrics.utf8), fileName: "song.tab"), .asciiTab)
        XCTAssertEqual(ScoreImporter.detectFormat(data: Data(withLyrics.utf8), fileName: "song.txt"), .chordText)
    }

    // MARK: importData / importText

    func testImportDataSetsSourceAndFileNameTitleFallback() throws {
        let score = try ScoreImporter.importData(Data("[C]la la\n[G]na na".utf8), fileName: "我的歌.cho")
        XCTAssertEqual(score.meta.source?.kind, .chordpro)
        XCTAssertEqual(score.meta.source?.fileName, "我的歌.cho")
        XCTAssertNotNil(score.meta.source?.importedAt)
        XCTAssertEqual(score.meta.title, "我的歌")
    }

    func testImportDataAGRJSONRoundTrip() throws {
        let original = try ChordProParser.parse("{title: 晴天}\n{capo: 1}\n[C]故事的[G]小黄花")
        let data = try ScoreCoding.encode(original)
        let imported = try ScoreImporter.importData(data, fileName: "晴天.agr.json")
        XCTAssertEqual(imported, original)
        let bom = try ScoreImporter.importData(Data([0xEF, 0xBB, 0xBF]) + data, fileName: nil)
        XCTAssertEqual(bom, original)
    }

    func testImportDataErrors() {
        XCTAssertThrowsError(try ScoreImporter.importData(Data(), fileName: "a.txt")) { XCTAssertEqual($0 as? ImportError, .empty) }
        XCTAssertThrowsError(try ScoreImporter.importData(Data("   \n".utf8), fileName: "a.txt")) { XCTAssertEqual($0 as? ImportError, .empty) }
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0])
        XCTAssertThrowsError(try ScoreImporter.importData(zip, fileName: "a.mxl")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedFormat("mxl"))
        }
        XCTAssertThrowsError(try ScoreImporter.importData(Data("{\"format\":\"agr-score\",\"sections\":5}".utf8), fileName: "a.agr.json")) {
            guard case .malformed? = $0 as? ImportError else { return XCTFail("expected malformed") }
        }
    }

    func testImportTextAutoDetectsChordPro() throws {
        let score = try ScoreImporter.importText("{title: Auto}\n[C]hello [G]world")
        XCTAssertEqual(score.meta.title, "Auto")
        XCTAssertEqual(score.meta.source?.kind, .chordpro)
    }

    func testImportTextAutoDetectsChordOverLyrics() throws {
        let score = try ScoreImporter.importText("[Verse]\nC         G     Am\n\(verse)\n", title: "Fallback")
        XCTAssertEqual(score.meta.source?.kind, .chordText)
        XCTAssertEqual(score.meta.title, "Fallback")
        XCTAssertEqual(S.allLines(score).first.map(S.render), "[C]我曾经跨过[G]山和大[Am]海")
    }

    func testImportTextAutoDetectsAsciiTab() throws {
        let tab = "Etude\n\n" + ["e|--0--3--|", "B|--1--0--|", "G|--0--0--|", "D|--2--0--|", "A|--3--2--|", "E|-----3--|"].joined(separator: "\n")
        let score = try ScoreImporter.importText(tab)
        XCTAssertEqual(score.meta.source?.kind, .asciiTab)
        XCTAssertEqual(score.meta.mode, .fingerstyle)
        XCTAssertEqual(score.meta.title, "Etude")
    }

    func testImportTextMixedChordSheetWithTabKeepsLyricsAndTabs() throws {
        let text = """
        前奏
        e|--0--3--|
        B|--1--0--|
        G|--0--0--|
        D|--2--0--|
        A|--3--2--|
        E|-----3--|

        主歌
        C         G
        我曾经跨过山和大海
        F         C
        也穿过人山人海
        副歌
        Am  G
        啦啦啦啦
        """
        let score = try ScoreImporter.importText(text)
        XCTAssertEqual(score.meta.source?.kind, .chordText)
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse, .chorus])
        XCTAssertEqual(score.sections[0].lines.map(\.kind), [.tab])
        XCTAssertEqual(score.sections[1].lines.map(\.kind), [.lyrics, .lyrics])
        XCTAssertEqual(score.meta.mode, .strumSing)
    }

    func testImportTextEmptyThrows() {
        XCTAssertThrowsError(try ScoreImporter.importText("\n\n")) { XCTAssertEqual($0 as? ImportError, .empty) }
    }

    func testImportedScoresSurviveJSONRoundTrip() throws {
        let tab = ["e|--0--3--|", "B|--1--0--|", "G|--0--0--|", "D|--2--0--|", "A|--3--2--|", "E|-----3--|"].joined(separator: "\n")
        let scores: [Score] = [
            try ScoreImporter.importText(sheet),
            try ScoreImporter.importText("{title: x}\n{define: Am base-fret 1 frets x 0 2 2 1 0}\n[Am]la [C]la"),
            try ScoreImporter.importText(tab),
            OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: [S.token("C", x: 0.1, y: 0.25), S.token("啦啦啦", x: 0.1, y: 0.28),
                                                                       S.token("啦啦", x: 0.1, y: 0.4)], imageFileName: "a.jpg", pixelWidth: 10, pixelHeight: 20)]),
        ]
        for score in scores {
            let back = try ScoreCoding.decode(ScoreCoding.encode(score))
            XCTAssertEqual(back, score)
        }
    }

    func testChordPlaceholdersInChordTextHaveParseableChords() throws {
        let score = try ScoreImporter.importText("C  G/B  Am7  Fmaj7\nla la la la la la\n")
        for seg in S.allLines(score).flatMap(\.segments) {
            if let chord = seg.chord { XCTAssertNotNil(ChordSymbol(chord), chord) }
        }
    }
}
