import Foundation

public enum OMREngine {
    public typealias PageInput = (image: GrayImage, ocr: [OCRToken], fileName: String?)

    public static func recognize(pages: [PageInput], options: OMROptions = OMROptions()) -> (score: Score, report: OMRReport) {
        let t0 = Date()
        var report = OMRReport()
        report.pageCount = pages.count
        var score = Score(meta: ScoreMeta(source: ScoreSource(kind: .image)))
        var lines: [Line] = []
        var headerDone = false
        for (pi, page) in pages.enumerated() {
            let r = OMRPage.process(page: pi, image: page.image, ocr: page.ocr, options: options)
            score.pages.append(PageImage(fileName: page.fileName ?? "page-\(pi).jpg", width: page.image.width, height: page.image.height))
            if !headerDone || pi == 0 { score.meta = mergeMeta(score.meta, r.meta); headerDone = true }
            else if score.meta.title.isEmpty { score.meta = mergeMeta(score.meta, r.meta) }
            for (k, v) in r.chordDefinitions where score.chordDefinitions[k] == nil { score.chordDefinitions[k] = v }
            let base = lines.count
            lines.append(contentsOf: r.lines)
            report.issues.append(contentsOf: r.issues.map { var i = $0; i.path = i.path.replacingOccurrences(of: "{L}", with: "\(base + (Int(i.context.split(separator: "|").first ?? "0") ?? 0))"); return i })
            report.removedText.append(contentsOf: r.removedText)
            report.systemCount += r.lines.count
        }
        score.meta.source = ScoreSource(kind: .image, fileName: pages.first?.fileName)
        if !lines.isEmpty { score.sections = [Section(id: "s0", name: "", kind: .other, lines: lines)] }
        report.milliseconds = Date().timeIntervalSince(t0) * 1000
        return (score, report)
    }

    private static func mergeMeta(_ a: ScoreMeta, _ b: ScoreMeta) -> ScoreMeta {
        var m = a
        if m.title.isEmpty { m.title = b.title }
        if m.artist == nil { m.artist = b.artist }
        if m.key == nil { m.key = b.key }
        if m.capo == 0 { m.capo = b.capo }
        if b.tempo != 80 && m.tempo == 80 { m.tempo = b.tempo }
        if m.timeSignature == TimeSignature() { m.timeSignature = b.timeSignature }
        if m.composer == nil { m.composer = b.composer }
        if m.lyricist == nil { m.lyricist = b.lyricist }
        for c in b.credits where !m.credits.contains(c) { m.credits.append(c) }
        return m
    }
}

struct PageResult {
    var lines: [Line] = []
    var meta = ScoreMeta()
    var chordDefinitions: [String: ChordShape] = [:]
    var issues: [OMRIssue] = []
    var removedText: [String] = []
}

enum OMRPage {
    static func process(page: Int, image: GrayImage, ocr: [OCRToken], options: OMROptions) -> PageResult {
        var res = PageResult()
        let (bm, _, _, _) = OMRVision.binarize(image)
        let staves = OMRStaffDetector.detect(bm)
        if staves.isEmpty {
            res.issues.append(OMRIssue(kind: .noStaff, path: "sections[0]", message: "no six-line tab staff found on page \(page)"))
            return res
        }
        let clean = OMRStaffDetector.removeLines(bm, staves: staves)
        let H = Double(image.height), W = Double(image.width)
        let beats = 4.0
        for (si, st) in staves.enumerated() {
            let bars = OMRStaffDetector.barlines(bm, staff: st)
            let mts = OMRTabAnalyzer.analyze(bm: bm, clean: clean, staff: st, bars: bars, beats: beats, classifier: .shared)
            var measures: [NotationMeasure] = []
            for (mi, mt) in mts.enumerated() {
                var m = NotationMeasure(tab: mt.events)
                m.leftBarline = bars.indices.contains(mi) ? simple(bars[mi].kind) : .single
                m.rightBarline = bars.indices.contains(mi + 1) ? simple(bars[mi + 1].kind) : .single
                if abs(mt.beatSum - beats) > 1e-6 {
                    res.issues.append(OMRIssue(kind: .beatSumMismatch, path: "sections[0].lines[{L}].system.measures[\(mi)]",
                                               message: "tab beats sum \(mt.beatSum) != \(beats)", context: "\(res.lines.count)"))
                }
                measures.append(m)
            }
            let top = st.top - 10 * st.u, bottom = st.bottom + 12 * st.u
            _ = (top, bottom, W, si)
            let anchor = PageAnchor(page: page, y: max(0, top / H), height: min(1, (bottom - top) / H))
            res.lines.append(Line.system(NotationSystem(measures: measures), anchor: anchor))
        }
        return res
    }

    static func simple(_ k: BarlineKind) -> BarlineKind { k }
}
