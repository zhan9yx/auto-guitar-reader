import XCTest
@testable import AGRCore

final class OMRTabRhythmTests: XCTestCase {
    private func measures(_ r: PageResult) -> [NotationMeasure] { r.lines.first?.system?.measures ?? [] }

    /// A plain stem is one beat (GT_SPEC). Two unbeamed strums with a printed rest after each
    /// are 1 + 1 + 1 + 1, not a pair of half notes.
    func testStrumRestStrumRestKeepsQuarters() {
        var f = OMRTabFixture()
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        f.crossWithStem(x: 50, string: 3); f.rest(x: 110, betweenStrings: 3)
        f.crossWithStem(x: 160, string: 3); f.rest(x: 220, betweenStrings: 3)
        f.crossWithStem(x: 300, string: 3); f.crossWithStem(x: 360, string: 3)
        f.crossWithStem(x: 420, string: 3); f.crossWithStem(x: 470, string: 3)
        let r = f.page()
        let ms = measures(r)
        XCTAssertEqual(ms.count, 2, "issues \(r.issues.map(\.message))")
        guard ms.count == 2 else { return }
        XCTAssertEqual(ms[0].tab.map(\.duration), [1, 1, 1, 1])
        XCTAssertEqual(ms[0].tab.map { $0.notes.isEmpty }, [false, true, false, true])
        XCTAssertEqual(ms[1].tab.map(\.duration), [1, 1, 1, 1])
        XCTAssertFalse(r.issues.contains { $0.kind == .beatSumMismatch })
    }

    /// Two quarters and nothing else do not become half notes: the bar is flagged instead.
    func testTwoPlainStemsAreQuartersAndBarIsFlagged() {
        var f = OMRTabFixture()
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        f.crossWithStem(x: 70, string: 3); f.crossWithStem(x: 170, string: 3)
        for x in [300, 360, 420, 470] { f.crossWithStem(x: x, string: 3) }
        let r = f.page()
        let ms = measures(r)
        XCTAssertEqual(ms.first?.tab.map(\.duration), [1, 1])
        XCTAssertTrue(r.issues.contains { $0.kind == .beatSumMismatch })
    }

    /// A stem that hangs from a note inside the staff, through the lower strings, is a stem: one note, not a strum over
    /// every string it crosses.
    func testStemThroughLowerStringsIsNotAStrum() {
        var f = OMRTabFixture()
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        for x in [50, 110, 170, 230] {
            f.canvas.cross(cx: x, cy: f.lineY(4), size: 10)
            f.canvas.vline(x: x, y0: f.lineY(4) + 7, y1: f.bottom + Int(1.7 * Double(f.u)))
        }
        for x in [300, 360, 420, 470] { f.crossWithStem(x: x, string: 3) }
        let r = f.page()
        let m = r.lines.first?.system?.measures.first
        XCTAssertEqual(m?.tab.count, 4)
        XCTAssertEqual(m?.tab.map { $0.notes.count }, [1, 1, 1, 1], "issues \(r.issues.map(\.message))")
        XCTAssertTrue(m?.tab.allSatisfy { $0.stroke == nil } ?? false)
    }
}
