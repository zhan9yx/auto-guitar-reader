import XCTest
@testable import AGRCore

final class OMRImportPolicyTests: XCTestCase {
    private func system(page: Int, y: Double, measures: Int = 4) -> Line {
        Line.system(NotationSystem(measures: (0..<measures).map { _ in NotationMeasure() }),
                    anchor: PageAnchor(page: page, y: y, height: 0.2))
    }
    private func issue(_ kind: OMRIssueKind = .beatSumMismatch, local: Int = 0) -> OMRIssue {
        OMRIssue(kind: kind, path: "sections[0].lines[{L}].system.measures[1]", message: "m", context: "\(local)")
    }
    private func result(page: Int, systems: Int = 2, issues: [OMRIssue] = [], title: String = "") -> OMRPageResult {
        OMRPageResult(pageIndex: page, lines: (0..<systems).map { system(page: page, y: 0.1 + 0.3 * Double($0)) },
                      meta: ScoreMeta(title: title), chordDefinitions: [:], issues: issues, removedText: [], milliseconds: 1)
    }
    private func lyricPage(_ file: String, text: String = "我想要一个温暖的家") -> OCRPage {
        let tokens = text.enumerated().map { i, ch in OCRToken(text: String(ch), x: 0.1 + 0.06 * Double(i), y: 0.30, width: 0.05, height: 0.03) }
        return OCRPage(tokens: tokens, imageFileName: file, pixelWidth: 1000, pixelHeight: 1400)
    }
    private func emptyPage(_ file: String) -> OCRPage { OCRPage(tokens: [], imageFileName: file, pixelWidth: 1000, pixelHeight: 1400) }

    // MARK: decide

    func testDecideNeedsStaffAndLowIssueDensity() {
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: nil).choice, .text(.unavailable))
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: result(page: 0, systems: 0)).choice, .text(.noStaff))
        // 8 measures: 8 issues = 1.0 per measure is still accepted, 9 is not
        let eight = (0..<8).map { _ in issue() }
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: result(page: 0, issues: eight)).choice, .omr)
        let nine = eight + [issue()]
        let d = OMRImportPolicy.decide(page: 0, result: result(page: 0, issues: nine))
        XCTAssertEqual(d.choice, .text(.tooManyIssues))
        XCTAssertEqual(d.issuesPerMeasure, 9.0 / 8.0, accuracy: 1e-9)
        XCTAssertEqual(OMRImportPolicy.maxIssuesPerMeasure, 1.0)
    }

    func testRemovedWatermarkTextDoesNotCountAsReadingIssues() {
        let noisy = (0..<40).map { _ in issue(.suspectedWatermark) }
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: result(page: 0, issues: noisy)).choice, .omr)
    }

    func testDecideRejectsUnexpectedResults() {
        var r = result(page: 0)
        r.lines[0].system = NotationSystem(measures: [])
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: r).choice, .text(.unexpectedResult))
        var off = result(page: 0)
        off.lines[1].anchor = PageAnchor(page: 0, y: 0.9, height: 0.4)
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: off).choice, .text(.unexpectedResult))
        var nan = result(page: 0)
        nan.lines[0].anchor = PageAnchor(page: 0, y: .nan, height: 0.1)
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: nan).choice, .text(.unexpectedResult))
        var wrongPage = result(page: 0)
        wrongPage.lines[0].anchor = PageAnchor(page: 3, y: 0.1, height: 0.1)
        XCTAssertEqual(OMRImportPolicy.decide(page: 0, result: wrongPage).choice, .text(.unexpectedResult))
    }

    // MARK: combine

    func testPageWithoutStavesKeepsItsOCRTextAndPageOrderAndAnchors() throws {
        let pages = [
            OMRImportPolicy.PageInput(ocr: emptyPage("p0.jpg"), omr: result(page: 0, issues: [issue(local: 1)], title: "月光")),
            OMRImportPolicy.PageInput(ocr: lyricPage("p1.jpg"), omr: result(page: 1, systems: 0)),
            OMRImportPolicy.PageInput(ocr: emptyPage("p2.jpg"), omr: result(page: 2, issues: [issue(local: 0)])),
        ]
        let c = OMRImportPolicy.combine(pages: pages, fallbackTitle: "x")
        XCTAssertEqual(c.decisions.map(\.choice), [.omr, .text(.noStaff), .omr])
        let lines = c.score.sections.flatMap(\.lines)
        XCTAssertEqual(lines.compactMap { $0.anchor?.page }, [0, 0, 1, 2, 2], "page order")
        XCTAssertEqual(lines.map(\.kind), [.system, .system, .lyrics, .system, .system])
        let lyric = try XCTUnwrap(lines.first { $0.kind == .lyrics })
        XCTAssertEqual(lyric.segments.map(\.text).joined(), "我想要一个温暖的家")
        XCTAssertEqual(lyric.anchor?.page, 1)
        XCTAssertEqual(c.score.meta.title, "月光")
        XCTAssertEqual(c.score.pages.map(\.fileName), ["p0.jpg", "p1.jpg", "p2.jpg"])
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count, "line ids are unique")
        XCTAssertEqual(c.systemCount, 4)
    }

    func testIssuePathsPointAtTheCombinedScore() throws {
        let pages = [
            OMRImportPolicy.PageInput(ocr: lyricPage("p0.jpg"), omr: nil),
            OMRImportPolicy.PageInput(ocr: emptyPage("p1.jpg"), omr: result(page: 1, issues: [issue(local: 1)])),
        ]
        let c = OMRImportPolicy.combine(pages: pages)
        XCTAssertEqual(c.decisions.map(\.choice), [.text(.unavailable), .omr])
        // page 0 contributes one text section holding the lyric; the OMR section follows
        let flat = c.score.sections.enumerated().flatMap { s, sec in sec.lines.enumerated().map { (s, $0.offset, $0.element) } }
        let second = try XCTUnwrap(flat.filter { $0.2.kind == .system }.dropFirst().first)
        let p = try XCTUnwrap(c.issues.first?.path)
        XCTAssertEqual(p, "sections[\(second.0)].lines[\(second.1)].system.measures[1]")
    }

    func testBusyPageFallsBackWhileCleanPageKeepsOMR() {
        let busy = (0..<30).map { _ in issue() }
        let pages = [
            OMRImportPolicy.PageInput(ocr: emptyPage("p0.jpg"), omr: result(page: 0)),
            OMRImportPolicy.PageInput(ocr: lyricPage("p1.jpg"), omr: result(page: 1, issues: busy)),
        ]
        let c = OMRImportPolicy.combine(pages: pages)
        XCTAssertEqual(c.decisions.map(\.choice), [.omr, .text(.tooManyIssues)])
        XCTAssertTrue(c.issues.isEmpty, "issues of a page that fell back describe data that is not in the score")
        XCTAssertEqual(c.score.sections.flatMap(\.lines).map(\.kind), [.system, .system, .lyrics])
    }

    func testAllOMRGivesASingleSectionLikeTheEngine() {
        let pages = [
            OMRImportPolicy.PageInput(ocr: emptyPage("p0.jpg"), omr: result(page: 0)),
            OMRImportPolicy.PageInput(ocr: emptyPage("p1.jpg"), omr: result(page: 1)),
        ]
        let c = OMRImportPolicy.combine(pages: pages)
        XCTAssertEqual(c.score.sections.count, 1)
        XCTAssertEqual(c.score.sections[0].lines.count, 4)
    }

    func testAllTextEqualsTheReconstruction() {
        let ocr = [lyricPage("p0.jpg")]
        let c = OMRImportPolicy.combine(pages: [OMRImportPolicy.PageInput(ocr: ocr[0], omr: nil)], fallbackTitle: "T")
        let direct = OCRScoreReconstructor.reconstruct(pages: ocr, fallbackTitle: "T")
        XCTAssertEqual(c.score.sections.map(\.lines.count), direct.sections.map(\.lines.count))
        XCTAssertEqual(c.score.meta.title, direct.meta.title)
        XCTAssertEqual(c.systemCount, 0)
    }

    /// The engine path: one real page through `recognizePage`.
    func testRecognizePageMatchesRecognize() {
        var f = OMRTabFixture(width: 520, height: 300)
        f.bar(x: 20); f.bar(x: 270); f.bar(x: 500)
        f.crossWithStem(x: 60, string: 3)
        let r = OMREngine.recognizePage(index: 0, image: f.canvas.img, ocr: [])
        let whole = OMREngine.recognize(pages: [(f.canvas.img, [], nil)])
        XCTAssertEqual(r.systemCount, whole.report.systemCount)
        XCTAssertEqual(r.issues.map(\.message), whole.report.issues.map(\.message))
        XCTAssertEqual(r.lines.compactMap { $0.anchor }, whole.score.sections.flatMap(\.lines).compactMap { $0.anchor })
    }
}
