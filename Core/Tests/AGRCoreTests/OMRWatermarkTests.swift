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
}
