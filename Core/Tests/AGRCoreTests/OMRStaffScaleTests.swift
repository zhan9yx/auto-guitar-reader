import XCTest
@testable import AGRCore

/// The staff detector's pixel limits are for a page about 1000 px wide; they scale with the page.
final class OMRStaffScaleTests: XCTestCase {
    private func bitmap(_ c: OMRCanvas) -> Bitmap { OMRVision.binarize(c.img).bm }

    /// A 3000 px wide page: staff at u = 60 plus a chain of six equally spaced rules four times as far apart
    /// (ruled text). The dominant small gap (60) must reject the chain, as it does on a 1000 px page.
    func testSpacingWindowScalesWithPageWidth() {
        var c = OMRCanvas(width: 3000, height: 2000)
        for i in 0..<6 { c.hline(x0: 100, x1: 2900, y: 100 + 60 * i, t: 3) }
        for i in 0..<6 { c.hline(x0: 100, x1: 2900, y: 600 + 240 * i, t: 3) }
        let staves = OMRStaffDetector.detect(bitmap(c))
        XCTAssertEqual(staves.count, 1)
        XCTAssertEqual(staves.first?.u ?? 0, 60, accuracy: 1)
    }

    /// Lines 14 px thick are ordinary on a 3000 px wide page; only a band much thicker than that is a fused watermark.
    func testThickLinesOnWidePageAreNotFusedBands() {
        var c = OMRCanvas(width: 3000, height: 900)
        for i in 0..<6 { c.hline(x0: 100, x1: 2900, y: 200 + 60 * i, t: 14) }
        let staves = OMRStaffDetector.detect(bitmap(c))
        XCTAssertEqual(staves.count, 1)
        XCTAssertEqual(staves.first?.thickness, 14)
    }
}
