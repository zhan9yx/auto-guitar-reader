import XCTest
@testable import AGRCore

/// Gray-level steps in the barline and underline tests are fractions of the page contrast, not 8-bit constants.
final class OMRContrastTests: XCTestCase {
    /// Paper 200, ink 100 (contrast 100). A 2 px stroke at gray 120 next to a 3 px stroke at gray 100: the second is only
    /// one column wider but clearly darker, so it is the heavy bar of a final barline. A step of 40 levels (absolute) misses it.
    func testHeavyBarIsDarkerByAFractionOfContrast() throws {
        var f = OMRTabFixture(width: 300, height: 200, paper: 200, ink: 100)
        f.canvas.rect(x0: 100, y0: f.top - 1, x1: 102, y1: f.bottom + 2, 120)
        f.canvas.rect(x0: 106, y0: f.top - 1, x1: 109, y1: f.bottom + 2, 100)
        let bm = OMRVision.binarize(f.canvas.img).bm
        let st = try XCTUnwrap(OMRStaffDetector.detect(bm).first)
        for contrast in [nil, 100.0] as [Double?] {
            let bars = OMRStaffDetector.barlines(bm, staff: st, gray: f.canvas.img, contrast: contrast)
            let group = try XCTUnwrap(bars.first { $0.x0 >= 100 && $0.x1 <= 110 }, "bars \(bars.map { ($0.x0, $0.x1) })")
            XCTAssertEqual(group.kind, .final, "contrast \(String(describing: contrast))")
        }
    }

    /// The same two strokes on a full-contrast page, 20 levels apart, stay a plain double bar.
    func testSmallGrayStepOnFullContrastPageIsNotHeavy() throws {
        var f = OMRTabFixture(width: 300, height: 200)
        f.canvas.rect(x0: 100, y0: f.top - 1, x1: 102, y1: f.bottom + 2, 20)
        f.canvas.rect(x0: 106, y0: f.top - 1, x1: 109, y1: f.bottom + 2, 0)
        let bm = OMRVision.binarize(f.canvas.img).bm
        let st = try XCTUnwrap(OMRStaffDetector.detect(bm).first)
        let bars = OMRStaffDetector.barlines(bm, staff: st, gray: f.canvas.img)
        XCTAssertEqual(bars.first { $0.x0 >= 100 && $0.x1 <= 110 }?.kind, .double)
    }

    /// Two underlines that touch leave a ridge only 20 levels high on a contrast-100 page: still two underlines (a sixteenth).
    func testTouchingUnderlinesRidgeScalesWithContrast() throws {
        var f = OMRJianpuFixture(paper: 200, ink: 100)
        f.tab.bar(x: 20); f.tab.bar(x: 270); f.tab.bar(x: 500)
        var xs: [(Int, Int)] = []
        for (i, d) in ["1", "2", "3", "5"].enumerated() { xs.append(f.note(d, x: 60 + 50 * i)) }
        let y0 = f.digitTop + f.digitH + 3
        for i in 0..<3 { f.tab.canvas.rect(x0: xs[i].0, y0: y0, x1: xs[i].1, y1: y0 + 2) }          // one underline each, 2 px
        // fourth note: two 2 px strokes with a one-pixel ridge between, 5 rows in all
        let (a, b) = xs[3]
        f.tab.canvas.rect(x0: a, y0: y0, x1: b, y1: y0 + 2)
        f.tab.canvas.rect(x0: a, y0: y0 + 2, x1: b, y1: y0 + 3, 120)
        f.tab.canvas.rect(x0: a, y0: y0 + 3, x1: b, y1: y0 + 5)
        for (i, d) in ["6", "5", "3", "2"].enumerated() { f.note(d, x: 300 + 50 * i) }
        let r = f.page()
        let melody = r.lines.first?.system?.measures.first?.melody ?? []
        XCTAssertEqual(melody.map(\.degree), [1, 2, 3, 5], "\(r.issues.map(\.message))")
        XCTAssertEqual(melody.map(\.duration), [0.5, 0.5, 0.5, 0.25])
    }
}
