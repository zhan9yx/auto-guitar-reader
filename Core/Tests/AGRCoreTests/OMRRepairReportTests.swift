import XCTest
@testable import AGRCore

/// Every place the engine coerces data to make a measure add up must leave an issue behind.
final class OMRRepairReportTests: XCTestCase {
    private func twoBars(_ f: inout OMRJianpuFixture) { f.tab.bar(x: 20); f.tab.bar(x: 270); f.tab.bar(x: 500) }
    private func secondMeasure(_ f: inout OMRJianpuFixture) {
        for (i, d) in ["6", "5", "3", "2"].enumerated() { f.note(d, x: 300 + 50 * i) }
    }

    func testJianpuFixtureReadsDigits() {
        var f = OMRJianpuFixture()
        twoBars(&f)
        for (i, d) in ["1", "2", "3", "5"].enumerated() { f.note(d, x: 60 + 50 * i) }
        secondMeasure(&f)
        let r = f.page()
        let ms = r.lines.first?.system?.measures ?? []
        XCTAssertEqual(ms.map { $0.melody.map(\.degree) }, [[1, 2, 3, 5], [6, 5, 3, 2]], "\(r.issues.map(\.message))")
        XCTAssertFalse(r.issues.contains { $0.kind == .dataRepaired || $0.kind == .barlineMismatch })
    }

    /// Rests are stretched to fill the bar; that edit is reported with the measure.
    func testRestRescaleIsReported() {
        var f = OMRTabFixture()
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        f.crossWithStem(x: 60, string: 3); f.crossWithStem(x: 120, string: 3); f.rest(x: 180, betweenStrings: 3)
        for x in [300, 360, 420, 470] { f.crossWithStem(x: x, string: 3) }
        let r = f.page()
        XCTAssertEqual(r.lines.first?.system?.measures.first?.tab.map(\.duration), [1, 1, 2], "durations")
        let repairs = r.issues.filter { $0.kind == .dataRepaired }
        XCTAssertEqual(repairs.count, 1, "\(r.issues.map(\.message))")
        XCTAssertTrue(repairs.first?.path.hasSuffix("measures[0]") ?? false)
        XCTAssertEqual(repairs.first?.confidence ?? 1, OMRIssue.repairConfidence)
        XCTAssertFalse(r.issues.contains { $0.kind == .beatSumMismatch }, "the bar adds up after the repair")
    }

    /// No clef digits and no header: 4/4 is a guess and says so.
    func testAssumedTimeSignatureIsReported() {
        var f = OMRTabFixture()
        f.bar(x: 20); f.bar(x: 500)
        f.crossWithStem(x: 100, string: 3)
        let r = f.page()
        XCTAssertTrue(r.issues.contains { $0.kind == .headerMissing && $0.message.contains("4/4") && $0.confidence <= OMRIssue.repairConfidence }, "\(r.issues.map(\.message))")
    }

    /// A tall thin glyph in the digit row is dropped as a barline remnant. A thin "1" looks the same, so it is reported with its box.
    func testDroppedThinGlyphIsReportedWithItsLocation() throws {
        var f = OMRJianpuFixture()
        twoBars(&f)
        for (i, d) in ["1", "2", "3", "5"].enumerated() { f.note(d, x: 60 + 50 * i) }
        secondMeasure(&f)
        // 3 px x 18 px: not a barline (shorter than the row), thinner than any digit
        f.tab.canvas.rect(x0: 233, y0: f.digitTop + 2, x1: 236, y1: f.digitTop + 20)
        let r = f.page()
        let issue = try XCTUnwrap(r.issues.first { $0.kind == .lowConfidenceGlyph && $0.message.contains("thin tall glyph") }, "\(r.issues.map(\.message))")
        let crop = try XCTUnwrap(issue.imageCrop)
        XCTAssertEqual(crop.page, 0)
        XCTAssertEqual(crop.x * Double(f.tab.canvas.width), 233, accuracy: 1)
        XCTAssertEqual(crop.y * Double(f.tab.canvas.height), Double(f.digitTop + 2), accuracy: 1)
        XCTAssertTrue(issue.path.contains("measures[0]"))
        XCTAssertEqual(issue.confidence, OMRIssue.repairConfidence)
    }

    /// The jianpu row's own barlines are discarded when their count differs from the tab's.
    func testJianpuBarlineSubstitutionIsReported() {
        var f = OMRJianpuFixture()
        twoBars(&f)
        for (i, d) in ["1", "2", "3", "5"].enumerated() { f.note(d, x: 60 + 50 * i) }
        secondMeasure(&f)
        // two extra jianpu barlines (row height + 4 px), none of them matching the tab
        for x in [150, 390] { f.tab.canvas.vline(x: x, y0: f.digitTop - 2, y1: f.digitTop + f.digitH + 2) }
        let r = f.page()
        let issues = r.issues.filter { $0.kind == .barlineMismatch }
        // 150 and 390 leave a doubled gap that the tab bar at 270 splits (reported), and the counts still differ (reported)
        XCTAssertTrue(issues.contains { $0.message.contains("added to the jianpu row") }, "\(r.issues.map(\.message))")
        let used = issues.first { $0.message.contains("tab barlines used") }
        XCTAssertNotNil(used, "\(r.issues.map(\.message))")
        XCTAssertTrue(issues.allSatisfy { $0.confidence == OMRIssue.repairConfidence })
        // placement still follows the tab bars
        XCTAssertEqual(r.lines.first?.system?.measures.map { $0.melody.count }, [4, 4])
    }

    /// A dotted note with no underline that makes the bar 3/4 beat long gets an underline; the edit is reported.
    func testUnderlineRewriteIsReported() throws {
        var f = OMRJianpuFixture()
        twoBars(&f)
        let xs = [60, 100, 140, 180, 220]
        for (i, d) in ["1", "2", "3", "5", "6"].enumerated() { f.note(d, x: xs[i]) }
        // augmentation dot after the 1
        let d1 = f.tab.canvas.digit("1", x: 600, top: 0, h: 22)   // measure the glyph width only (off the page)
        f.tab.canvas.disc(cx: 60 + (d1.x1 - d1.x0) + 5, cy: f.digitTop + 14, r: 2)
        // two underlines under the 2
        let w2 = JianpuClassifier.shared.protos.filter { $0.label == "2" }.sorted { $0.aspect < $1.aspect }
        let width2 = Int((22 * Double(w2[w2.count / 2].aspect) / 100).rounded())
        f.underline(x0: 100, x1: 100 + width2, level: 2)
        secondMeasure(&f)
        let r = f.page()
        let melody = r.lines.first?.system?.measures.first?.melody ?? []
        let repairs = r.issues.filter { $0.kind == .dataRepaired }
        XCTAssertEqual(melody.map(\.degree), [1, 2, 3, 5, 6], "\(r.issues.map(\.message))")
        XCTAssertEqual(melody.map(\.duration), [0.75, 0.25, 1, 1, 1], "durations; issues \(r.issues.map(\.message))")
        XCTAssertEqual(repairs.count, 1, "\(r.issues.map(\.message))")
        XCTAssertTrue(repairs.first?.path.contains("measures[0]") ?? false)
        XCTAssertFalse(r.issues.contains { $0.kind == .beatSumMismatch && $0.path.contains("measures[0].melody") })
    }
}
