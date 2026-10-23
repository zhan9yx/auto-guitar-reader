import Foundation

/// Decides, page by page, whether an imported image page is taken from the OMR engine or from the Vision-OCR text
/// reconstruction (`OCRScoreReconstructor`), and assembles the combined `Score`.
///
/// The App runs `OMREngine.recognizePage` on each page and hands the results here, so the choice and the merge are plain
/// Core code with unit tests. A page whose OMR result is missing (image could not be decoded, the run was abandoned)
/// is simply a text page.
public enum OMRImportPolicy {
    /// Mean number of reported issues per measure above which a page's OMR reading is not trusted and the page falls back
    /// to its OCR text. Every wrongly read measure usually carries two or three issues (tab and melody beat sums, a repair),
    /// so 1.0 means "on average every measure is flagged". NOT CALIBRATED: a starting guess to be tuned on the real
    /// evaluation set (phase 2): compare OMR vs text accuracy per page against the issue density.
    public static let maxIssuesPerMeasure = 1.0

    public enum Choice: Equatable, Sendable {
        case omr
        case text(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        /// No result for this page (decode failure, cancelled run).
        case unavailable
        /// No six-line tab staff found.
        case noStaff
        /// More issues per measure than `maxIssuesPerMeasure`.
        case tooManyIssues
        /// The result failed a sanity check (empty system, anchor outside the page, non-finite numbers).
        case unexpectedResult
    }

    public struct PageDecision: Equatable, Sendable {
        public var page: Int
        public var choice: Choice
        public var systemCount: Int
        public var issueCount: Int
        public var issuesPerMeasure: Double
    }

    /// Issues that say something about the reading's quality. Removed watermark text and "no staff" are not about it.
    static func countsTowardsDensity(_ kind: OMRIssueKind) -> Bool {
        kind != .suspectedWatermark && kind != .noStaff
    }

    public static func decide(page: Int, result: OMRPageResult?) -> PageDecision {
        guard let r = result else {
            return PageDecision(page: page, choice: .text(.unavailable), systemCount: 0, issueCount: 0, issuesPerMeasure: 0)
        }
        let issues = r.issues.filter { countsTowardsDensity($0.kind) }.count
        let density = Double(issues) / Double(max(1, r.measureCount))
        func d(_ c: Choice) -> PageDecision {
            PageDecision(page: page, choice: c, systemCount: r.systemCount, issueCount: issues, issuesPerMeasure: density)
        }
        if r.systemCount == 0 { return d(.text(.noStaff)) }
        if sanityProblem(r) != nil { return d(.text(.unexpectedResult)) }
        if density > maxIssuesPerMeasure { return d(.text(.tooManyIssues)) }
        return d(.omr)
    }

    /// Why a result cannot be a real reading, nil when it looks plausible.
    static func sanityProblem(_ r: OMRPageResult) -> String? {
        for line in r.lines {
            guard let system = line.system, !system.measures.isEmpty else { return "empty system" }
            if let a = line.anchor {
                guard a.y.isFinite, a.height.isFinite, a.y >= 0, a.y <= 1, a.height >= 0, a.y + a.height <= 1 + 1e-9, a.page == r.pageIndex
                else { return "anchor outside the page" }
            }
        }
        return nil
    }

    // MARK: Combining

    public struct PageInput: Sendable {
        public var ocr: OCRPage
        public var omr: OMRPageResult?
        public init(ocr: OCRPage, omr: OMRPageResult?) { self.ocr = ocr; self.omr = omr }
    }

    public struct Combined: Sendable {
        public var score: Score
        /// Issues of the pages that use OMR, with paths into `score`.
        public var issues: [OMRIssue]
        public var decisions: [PageDecision]
        public var removedText: [String]
        public var systemCount: Int
    }

    /// One line of the combined score, tagged with where it came from.
    private struct Entry {
        var page: Int
        var y: Double
        var line: Line
        var textSection: Int?          // index in the text reconstruction, nil for OMR lines
        var omrPage: Int?              // page of an OMR line; `localLine` is its index within that page
        var localLine = 0
    }

    /// Takes the OMR reading of each page that passes `decide` and the OCR text reconstruction of every other page.
    /// Page order and `Line.anchor`s are kept: lines are ordered by (page, anchor y), consecutive lines of the same
    /// origin share a section, and text sections keep their printed names.
    public static func combine(pages: [PageInput], fallbackTitle: String? = nil) -> Combined {
        let decisions = pages.enumerated().map { decide(page: $0.offset, result: $0.element.omr) }
        let omrPages = Set(decisions.filter { $0.choice == .omr }.map(\.page))
        let pageImages = pages.enumerated().map { i, p in
            PageImage(fileName: p.ocr.imageFileName ?? "page-\(i).jpg", width: p.ocr.pixelWidth, height: p.ocr.pixelHeight)
        }

        // text reading of every page (also supplies header fields the OMR page did not read)
        let text = omrPages.count == pages.count ? Score() : OCRScoreReconstructor.reconstruct(pages: pages.map(\.ocr), fallbackTitle: fallbackTitle)

        var entries: [Entry] = []
        for (si, section) in text.sections.enumerated() {
            for line in section.lines {
                let page = line.anchor?.page ?? 0
                if omrPages.contains(page) { continue }
                entries.append(Entry(page: page, y: line.anchor?.y ?? 0, line: line, textSection: si))
            }
        }
        for p in omrPages.sorted() {
            guard let r = pages[p].omr else { continue }
            for (li, line) in r.lines.enumerated() {
                entries.append(Entry(page: p, y: line.anchor?.y ?? 0, line: line, textSection: nil, omrPage: p, localLine: li))
            }
        }
        // stable: text lines of a page keep their reconstruction order, OMR lines their system order
        let ordered = entries.enumerated().sorted { a, b in
            (a.element.page, a.element.y, a.offset) < (b.element.page, b.element.y, b.offset)
        }.map(\.element)

        var sections: [Section] = []
        var lastKey: String?
        var omrPlacement: [Int: [Int: (section: Int, line: Int)]] = [:]   // page -> local line -> final place
        for e in ordered {
            let key = e.textSection.map { "t\($0)" } ?? "omr"
            if key != lastKey {
                if let ts = e.textSection {
                    let src = text.sections[ts]
                    sections.append(Section(id: "", name: src.name, kind: src.kind, lines: [], strumPatternID: src.strumPatternID))
                } else {
                    sections.append(Section(id: "", name: "", kind: .other, lines: []))
                }
                lastKey = key
            }
            let si = sections.count - 1
            var line = e.line
            if e.textSection != nil { line.id = "s\(si)l\(sections[si].lines.count)" }
            if let p = e.omrPage { omrPlacement[p, default: [:]][e.localLine] = (si, sections[si].lines.count) }
            sections[si].lines.append(line)
        }
        for i in sections.indices { sections[i].id = "s\(i)" }

        // header: the first page's reading leads, every other reading only fills what it left empty
        let omrMetas = omrPages.sorted().compactMap { pages[$0].omr?.meta }
        let textMetas = omrPages.count == pages.count ? [] : [text.meta]
        let metas = omrPages.contains(0) ? omrMetas + textMetas : textMetas + omrMetas
        var meta = ScoreMeta(source: ScoreSource(kind: .image))
        for m in metas { meta = OMREngine.mergeMeta(meta, m) }
        if meta.title.isEmpty, let t = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { meta.title = t }

        var definitions: [String: ChordShape] = [:]
        var issues: [OMRIssue] = []
        var removed: [String] = []
        var systems = 0
        for p in omrPages.sorted() {
            guard let r = pages[p].omr else { continue }
            for (k, v) in r.chordDefinitions where definitions[k] == nil { definitions[k] = v }
            removed.append(contentsOf: r.removedText)
            systems += r.systemCount
            for issue in r.issues {
                let local = Int(issue.context.split(separator: "|").first ?? "0") ?? 0
                let place = omrPlacement[p]?[local] ?? (0, 0)
                issues.append(issue.placed(section: place.section, firstLine: place.line - local))
            }
        }

        var score = Score(meta: meta, chordDefinitions: definitions, sections: sections, pages: pageImages)
        score.arrangement = nil
        return Combined(score: score, issues: issues, decisions: decisions, removedText: removed, systemCount: systems)
    }
}
