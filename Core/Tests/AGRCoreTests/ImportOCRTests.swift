import XCTest
@testable import AGRCore

final class ImportOCRTests: XCTestCase {
    typealias S = ImportTestSupport

    private func t(_ text: String, _ x: Double, _ y: Double, w: Double? = nil, h: Double = 0.02) -> OCRToken {
        S.token(text, x: x, y: y, w: w, h: h)
    }

    /// Chord row (y 0.25) over lyric row (y 0.28): 0.01 per display column starting at x = 0.10.
    private func chordLyricTokens(yChord: Double = 0.25, yLyric: Double = 0.28) -> [OCRToken] {
        [
            t("C", 0.10, yChord), t("G", 0.20, yChord), t("Am", 0.26, yChord),
            t("我曾经跨过山和大海", 0.10, yLyric),
        ]
    }

    func testChordRowAttachesToLyricCharactersByX() {
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: chordLyricTokens())])
        let lines = S.allLines(score)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .lyrics)
        XCTAssertEqual(S.render(lines[0]), "[C]我曾经跨过[G]山和大[Am]海")
        XCTAssertEqual(score.meta.source?.kind, .image)
    }

    func testUnsortedTokensGiveSameResult() {
        let sorted = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: chordLyricTokens())])
        let shuffled = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: chordLyricTokens().reversed())])
        XCTAssertEqual(S.allLines(sorted).map(S.render), S.allLines(shuffled).map(S.render))
        XCTAssertEqual(S.allLines(sorted).first?.anchor, S.allLines(shuffled).first?.anchor)
    }

    func testRowsSplitIntoMultipleTokens() {
        // Lyrics split into 3 tokens with small gaps; chords as separate tokens.
        let tokens = [
            t("我曾经", 0.10, 0.28), t("跨过山", 0.17, 0.28), t("和大海", 0.24, 0.28),
            t("C", 0.10, 0.25), t("G", 0.17, 0.25), t("Am", 0.24, 0.25),
        ]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        let line = S.allLines(score)[0]
        XCTAssertEqual(line.segments.compactMap(\.chord), ["C", "G", "Am"])
        XCTAssertEqual(line.lyricText.replacingOccurrences(of: " ", with: ""), "我曾经跨过山和大海")
        XCTAssertEqual(line.segments[1].text.replacingOccurrences(of: " ", with: ""), "跨过山")
    }

    func testSeveralChordsInsideOneTokenAreSplitByColumn() {
        // One chord token "C         G     Am" spanning the same 18 columns as the lyric.
        let tokens = [t("C         G     Am", 0.10, 0.25), t("我曾经跨过山和大海", 0.10, 0.28)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(S.render(S.allLines(score)[0]), "[C]我曾经跨过[G]山和大[Am]海")
    }

    func testChordBeyondLyricEndKeepsChordWithEmptyText() {
        let tokens = [t("C", 0.10, 0.25), t("G", 0.40, 0.25), t("你好", 0.10, 0.28)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        let line = S.allLines(score)[0]
        XCTAssertEqual(line.segments, [ChordSegment(chord: "C", text: "你好"), ChordSegment(chord: "G", text: "")])
    }

    func testChordRowFarFromLyricRowBecomesChordsLine() {
        let tokens = [t("C", 0.10, 0.20), t("G", 0.20, 0.20), t("啦啦啦", 0.10, 0.40)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        let lines = S.allLines(score)
        XCTAssertEqual(lines.map(\.kind), [.chords, .lyrics])
        XCTAssertEqual(lines[0].segments.compactMap(\.chord), ["C", "G"])
        XCTAssertEqual(lines[1].segments, [ChordSegment(chord: nil, text: "啦啦啦")])
    }

    func testAnchorCoversChordRowThroughLyricRow() throws {
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: chordLyricTokens())])
        let a = try XCTUnwrap(S.allLines(score)[0].anchor)
        XCTAssertEqual(a.page, 0)
        XCTAssertEqual(a.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(a.height, 0.30 - 0.25, accuracy: 1e-9)
    }

    func testLyricOnlyRowAnchorAndKind() throws {
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: [t("纯歌词一行", 0.1, 0.5)])])
        let line = S.allLines(score)[0]
        XCTAssertEqual(line.kind, .lyrics)
        XCTAssertEqual(line.anchor?.page, 0)
        XCTAssertEqual(line.anchor?.y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(line.anchor?.height ?? -1, 0.02, accuracy: 1e-9)
    }

    // MARK: Metadata / title / headers

    func testTitleArtistAndMetadataRows() {
        let tokens = [
            t("七里香", 0.35, 0.05, h: 0.05),
            t("演唱：周杰伦", 0.30, 0.12),
            t("原调：G 选调：C 变调夹：2", 0.10, 0.16),
            t("速度 ♩=86", 0.10, 0.19),
            t("[主歌]", 0.10, 0.24),
            t("C", 0.10, 0.28), t("窗外的麻雀", 0.10, 0.31),
            t("在电线杆上多嘴", 0.10, 0.36),
        ]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.artist, "周杰伦")
        XCTAssertEqual(score.meta.key, "G")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(score.meta.tempo, 86)
        XCTAssertEqual(score.sections.map(\.name), ["主歌"])
        XCTAssertEqual(score.sections[0].lines.count, 2)
    }

    func testArtistRowWithoutColonAndEnglishMetadata() {
        let tokens = [
            t("Yesterday", 0.3, 0.05, h: 0.05),
            t("Artist: The Beatles", 0.1, 0.12),
            t("Capo 3", 0.1, 0.15), t("Key: F", 0.1, 0.18), t("BPM 96", 0.1, 0.21),
            t("la la la", 0.1, 0.25),
        ]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(score.meta.title, "Yesterday")
        XCTAssertEqual(score.meta.artist, "The Beatles")
        XCTAssertEqual(score.meta.capo, 3)
        XCTAssertEqual(score.meta.key, "F")
        XCTAssertEqual(score.meta.tempo, 96)
    }

    func testTitleWithDashSplitsArtist() {
        let tokens = [t("七里香 - 周杰伦", 0.2, 0.05, h: 0.05), t("啦啦啦啦", 0.1, 0.2)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.artist, "周杰伦")
    }

    func testNoTitleWhenTopRowIsNotLargerAndFallbackTitleIsUsed() {
        let tokens = [t("我曾经跨过山和大海", 0.1, 0.1), t("他们说你不该如此", 0.1, 0.14)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)], fallbackTitle: "Scan 1")
        XCTAssertEqual(score.meta.title, "Scan 1")
        XCTAssertEqual(S.allLines(score).count, 2)
    }

    func testLyricRowDirectlyBelowChordRowIsNeverTheTitle() {
        let tokens = [t("C", 0.1, 0.05, h: 0.05), t("大字歌词", 0.1, 0.1, h: 0.05), t("小字", 0.1, 0.3)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(score.meta.title, "")
    }

    func testSectionHeaderRows() {
        let tokens = [
            t("前奏", 0.1, 0.10), t("C G Am F", 0.1, 0.13),
            t("【副歌】", 0.1, 0.20), t("啦啦啦", 0.1, 0.24),
            t("Verse 2", 0.1, 0.30), t("hello world", 0.1, 0.33),
            t("间奏", 0.1, 0.40),
        ]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(score.sections.map(\.name), ["前奏", "副歌", "Verse 2", "间奏"])
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .chorus, .verse, .interlude])
        XCTAssertEqual(score.sections[0].lines.first?.kind, .chords)
        XCTAssertEqual(score.sections[0].lines.first?.segments.compactMap(\.chord), ["C", "G", "Am", "F"])
        XCTAssertTrue(score.sections[3].lines.isEmpty)
    }

    // MARK: Tab digits, pages, robustness

    func testSixTabDigitRowsBecomeOneTabMarker() throws {
        var tokens: [OCRToken] = [t("前奏", 0.1, 0.08)]
        let rows = ["0---3---0", "1---1---1", "2-------2", "2---------", "3---------", "x---------"]
        for (i, r) in rows.enumerated() { tokens.append(t(r, 0.1, 0.12 + Double(i) * 0.02)) }
        tokens.append(t("啦啦啦", 0.1, 0.4))
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        let lines = S.allLines(score)
        XCTAssertEqual(lines.map(\.kind), [.comment, .lyrics])
        XCTAssertEqual(lines[0].text, "[tab]")
        let a = try XCTUnwrap(lines[0].anchor)
        XCTAssertEqual(a.y, 0.12, accuracy: 1e-9)
        XCTAssertEqual(a.height, 0.12 + 5 * 0.02 + 0.02 - 0.12, accuracy: 1e-9)
    }

    func testTwoPagesPageImagesAnchorsAndContinuingSection() {
        let p0 = OCRPage(tokens: [t("[主歌]", 0.1, 0.1), t("C", 0.1, 0.15), t("第一页歌词", 0.1, 0.18)],
                         imageFileName: "a.jpg", pixelWidth: 1000, pixelHeight: 1400)
        let p1 = OCRPage(tokens: [t("G", 0.1, 0.1), t("第二页歌词", 0.1, 0.13)], imageFileName: nil, pixelWidth: 800, pixelHeight: 1200)
        let score = OCRScoreReconstructor.reconstruct(pages: [p0, p1])
        XCTAssertEqual(score.pages, [PageImage(fileName: "a.jpg", width: 1000, height: 1400),
                                     PageImage(fileName: "page-1.jpg", width: 800, height: 1200)])
        XCTAssertEqual(score.sections.count, 1)
        let lines = score.sections[0].lines
        XCTAssertEqual(lines.map { $0.anchor?.page }, [0, 1])
        XCTAssertEqual(S.render(lines[1]), "[G]第二页歌词")
    }

    func testEmptyPagesAndNoPages() {
        XCTAssertTrue(OCRScoreReconstructor.reconstruct(pages: []).sections.isEmpty)
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: [], imageFileName: "x.png", pixelWidth: 10, pixelHeight: 20),
                                                              OCRPage(tokens: [t("   ", 0.1, 0.1)])])
        XCTAssertTrue(score.sections.isEmpty)
        XCTAssertEqual(score.pages.count, 2)
        XCTAssertEqual(score.pages[0].fileName, "x.png")
    }

    func testNoiseRowsAreDropped() {
        let tokens = [t("—", 0.1, 0.1), t("12", 0.5, 0.9), t("歌词一", 0.1, 0.3), t("歌词二", 0.1, 0.34)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(S.allLines(score).count, 2)
    }

    func testOCRChordConfusionsAreNormalized() {
        let tokens = [t("Arn7", 0.10, 0.25), t("C1G", 0.20, 0.25), t("Ｄ", 0.30, 0.25), t("我曾经跨过山和大海", 0.10, 0.28)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(S.allLines(score)[0].segments.compactMap(\.chord), ["Am7", "C/G", "D"])
    }

    func testMostlyLyricRowWithStrayLetterIsNotChordRow() {
        let tokens = [t("Hello A world again", 0.1, 0.3), t("second lyric row", 0.1, 0.34)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(S.allLines(score).map(\.kind), [.lyrics, .lyrics])
    }

    func testVerticallyOverlappingTokensClusterIntoOneRow() {
        // Slightly jittered y values belong to the same row.
        let tokens = [t("C", 0.10, 0.250), t("G", 0.20, 0.253), t("Am", 0.26, 0.248), t("我曾经跨过山和大海", 0.10, 0.28)]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens)])
        XCTAssertEqual(S.allLines(score).count, 1)
        XCTAssertEqual(S.allLines(score)[0].segments.compactMap(\.chord), ["C", "G", "Am"])
    }

    func testOCRTokenAndPageCodable() throws {
        let page = OCRPage(tokens: chordLyricTokens(), imageFileName: "p.jpg", pixelWidth: 100, pixelHeight: 200)
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(OCRPage.self, from: data), page)
    }

    func testRealisticPageEndToEnd() {
        let tokens = [
            t("晴天", 0.4, 0.04, h: 0.05),
            t("词曲：周杰伦", 0.3, 0.10),
            t("Capo: 1  Key: C", 0.1, 0.13),
            t("[Intro]", 0.1, 0.17), t("C  G  Am  Em", 0.1, 0.20),
            t("[Verse]", 0.1, 0.25),
            t("C", 0.10, 0.29), t("Em", 0.16, 0.29),
            t("故事的小黄花", 0.10, 0.32),
            t("Am", 0.10, 0.37), t("G", 0.20, 0.37),
            t("从出生那年就飘着", 0.10, 0.40),
        ]
        let score = OCRScoreReconstructor.reconstruct(pages: [OCRPage(tokens: tokens, imageFileName: "qt.png", pixelWidth: 1080, pixelHeight: 1920)])
        XCTAssertEqual(score.meta.title, "晴天")
        XCTAssertEqual(score.meta.composer, "周杰伦")
        XCTAssertEqual(score.meta.lyricist, "周杰伦")
        XCTAssertEqual(score.meta.capo, 1)
        XCTAssertEqual(score.meta.key, "C")
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse])
        let verse = score.sections[1].lines
        XCTAssertEqual(S.render(verse[0]), "[C]故事的[Em]小黄花")
        XCTAssertEqual(S.render(verse[1]), "[Am]从出生那年[G]就飘着")
        XCTAssertTrue(verse.allSatisfy { $0.anchor != nil })
    }
}
