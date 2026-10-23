import XCTest
@testable import AGRCore

final class OMRWatermarkTests: XCTestCase {
    private func context() -> OMRTextContext {
        var c = OMRTextContext()
        c.pageWidth = 1000; c.pageHeight = 1500; c.staffSpacing = 12
        c.firstSystemTop = 400
        c.lastSystemBottom = 1200
        return c
    }

    func testWideTitleNearPageTopIsKept() {
        // A tightly cropped screenshot puts the title in the top 3 % of the page.
        let title = OCRToken(text: "月光下的凤尾竹", x: 0.30, y: 0.010, width: 0.40, height: 0.020)
        XCTAssertNil(OMRWatermark.isNonScoreText(title, context: context()))
    }

    func testFormerSyntheticSiteNamesAreNoLongerSpecialCased() {
        let t = OCRToken(text: "吉他控", x: 0.40, y: 0.05, width: 0.12, height: 0.02)
        XCTAssertNil(OMRWatermark.isNonScoreText(t, context: context()))
    }

    func testUrlStillRemoved() {
        let t = OCRToken(text: "www.example-tabs.com", x: 0.30, y: 0.010, width: 0.40, height: 0.020)
        XCTAssertEqual(OMRWatermark.isNonScoreText(t, context: context()), .url)
    }

    // MARK: Phrases never delete lyrics inside a system band

    /// One system: staff 400...470 (u = 14); band = 253...687.
    private func bandContext() -> OMRTextContext {
        var c = OMRTextContext()
        c.pageWidth = 1000; c.pageHeight = 1500; c.staffSpacing = 14
        c.firstSystemTop = 400
        c.lastSystemBottom = 470 + 12 * 14
        let st = TabStaff(lines: (0..<6).map { 400 + 14 * Double($0) }, thickness: 2, x0: 50, x1: 950)
        c.systemBands = OMRWatermark.systemBands(staves: [st])
        return c
    }
    private func token(_ text: String, y: Double, x: Double = 0.2, w: Double = 0.3) -> OCRToken {
        OCRToken(text: text, x: x, y: y, width: w, height: 0.012)
    }

    func testSystemBandsCoverChordRowsThroughLyricsAndDoNotOverlap() {
        let mk = { (top: Double) in TabStaff(lines: (0..<6).map { top + 14 * Double($0) }, thickness: 2, x0: 50, x1: 950) }
        let b = OMRWatermark.systemBands(staves: [mk(400), mk(900)])
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0].lowerBound, 400 - 10.5 * 14, accuracy: 1e-9)
        XCTAssertEqual(b[0].upperBound, 900 - 10.5 * 14, accuracy: 1e-9)
        XCTAssertEqual(b[1].lowerBound, b[0].upperBound, accuracy: 1e-9)
        XCTAssertEqual(b[1].upperBound, 970 + 15.5 * 14, accuracy: 1e-9)
    }

    func testLyricWithAdPhraseInsideSystemSurvivesAndFooterAdIsRemoved() {
        let c = bandContext()
        // cy = 0.40 * 1500 = 600: below the staff, among the lyric rows
        XCTAssertNil(OMRWatermark.isNonScoreText(token("请关注我的心", y: 0.394), context: c))
        XCTAssertNil(OMRWatermark.isNonScoreText(token("从未经历过风雨", y: 0.394), context: c))
        XCTAssertNil(OMRWatermark.isNonScoreText(token("请勿打扰我", y: 0.394), context: c))
        XCTAssertNil(OMRWatermark.isNonScoreText(token("下载不了我的爱", y: 0.394), context: c))
        // footer: cy = 0.95 * 1500 = 1425, outside every band
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("扫码关注公众号xxx", y: 0.944), context: c), .phrase)
        // the same text between the header and the first chord band is still an ad
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("扫码关注公众号xxx", y: 0.05), context: c), .phrase)
    }

    func testStrongSignalsStillRemoveInsideSystemBand() {
        let c = bandContext()
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("www.guitar-tabs.com", y: 0.394), context: c), .url)
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("微信：13812345678", y: 0.394), context: c), .phoneNumber)
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("QQ:123456789", y: 0.394), context: c), .phoneNumber)
        var q = c
        q.qrRects = [OMRPixelBox(x0: 600, y0: 580, x1: 760, y1: 740)]
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("扫我", y: 0.394, x: 0.62, w: 0.05), context: q), .qrCode)
        XCTAssertNil(OMRWatermark.isNonScoreText(token("扫我", y: 0.394, x: 0.2, w: 0.05), context: q))
    }

    func testLatinPhrasesNeedWholeWords() {
        let c = bandContext()
        // titles / lyrics in the header region or footer are not call-to-action text
        XCTAssertNil(OMRWatermark.isNonScoreText(token("Scandal", y: 0.05), context: c))
        XCTAssertNil(OMRWatermark.isNonScoreText(token("Follow Me", y: 0.05), context: c))
        XCTAssertNil(OMRWatermark.isNonScoreText(token("Followers of the Sun", y: 0.05), context: c))
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("Scan to follow us on WeChat", y: 0.944), context: c), .phrase)
        XCTAssertEqual(OMRWatermark.isNonScoreText(token("Copyright 2020", y: 0.05), context: c), .phrase)
        XCTAssertTrue(OMRWatermark.containsWord("wechat id", "wechat"))
        XCTAssertFalse(OMRWatermark.containsWord("mywechatx", "wechat"))
    }

    /// Through the engine path: staff + OCR on a tall canvas.
    func testEngineKeepsLyricNearStaffAndRemovesFooterAd() {
        var f = OMRTabFixture(width: 520, height: 500)
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        f.crossWithStem(x: 60, string: 3)
        let lyric = OCRToken(text: "请关注我的心", x: 0.2, y: 0.40, width: 0.2, height: 0.03)
        let footer = OCRToken(text: "扫码关注公众号xxx", x: 0.2, y: 0.93, width: 0.4, height: 0.03)
        let r = OMRPage.process(page: 0, image: f.canvas.img, ocr: [lyric, footer], options: OMROptions())
        XCTAssertTrue(r.removedText.contains("扫码关注公众号xxx"), "removed \(r.removedText)")
        XCTAssertFalse(r.removedText.contains("请关注我的心"), "removed \(r.removedText)")
    }
}
