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
        var carriedTime: TimeSignature?
        for (pi, page) in pages.enumerated() {
            let r = OMRPage.process(page: pi, image: page.image, ocr: page.ocr, options: options, knownTime: carriedTime)
            if r.meta.timeSignature.beats > 0 { carriedTime = r.meta.timeSignature }
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

struct BuiltSystem {
    var staff: TabStaff
    var bars: [BarlineStructure]
    var measures: [NotationMeasure]
    /// Pixel x of each tab event (`TabEvent` itself has no x). Parallel to `measures`.
    var eventX: [[Double]]
}

enum OMRPage {
    static func process(page: Int, image: GrayImage, ocr: [OCRToken], options: OMROptions, trace: OMRTrace? = nil, knownTime: TimeSignature? = nil) -> PageResult {
        var res = PageResult()
        var image = image
        var ocr = ocr
        var (bm, _, bgLevel, inkLevel) = OMRVision.binarize(image)
        var bmLine = OMRVision.binarize(image, threshold: Int(bgLevel - 0.22 * (bgLevel - inkLevel))).bm
        let slope = OMRDeskew.estimateSlope(bmLine)
        if slope != 0 {
            image = OMRDeskew.rotate(image, slope: slope, fill: UInt8(max(0, min(255, bgLevel))))
            ocr = ocr.map { t in
                var t = t
                let W = Double(image.width), H = Double(image.height)
                let c = OMRDeskew.forward(x: (t.x + t.width / 2) * W, y: (t.y + t.height / 2) * H, slope: slope, width: image.width, height: image.height)
                t.x = c.0 / W - t.width / 2; t.y = c.1 / H - t.height / 2
                return t
            }
            bm = OMRDeskew.rotate(bm, slope: slope)
            bmLine = OMRDeskew.rotate(bmLine, slope: slope)
        }
        OMRVision.removeSolidBlobs(&bm)
        OMRVision.removeSolidBlobs(&bmLine)
        let staves = OMRStaffDetector.detect(bmLine)
        if ProcessInfo.processInfo.environment["AGR_OMR_TRACE"] != nil {
            FileHandle.standardError.write(Data("slope \(slope) staves \(staves.count) u \(staves.first.map { $0.u } ?? 0)\n".utf8))
        }
        if staves.isEmpty {
            res.issues.append(OMRIssue(kind: .noStaff, path: "sections[0]", message: "no six-line tab staff found on page \(page)"))
            return res
        }
        let clean = OMRStaffDetector.removeLines(bm, staves: staves)
        let lineClean = bmLine
        trace?.image = image
        let H = Double(image.height), W = Double(image.width)
        var beats = 4.0
        var unit = 4
        var timeFromClef = false
        if let known = knownTime, known.beats > 0 {
            beats = Double(known.beats)
            unit = known.unit
            res.meta.timeSignature = known
            timeFromClef = true
        }
        // time signature from the first staff's clef area
        do {
            let st = staves[0]
            let bars = OMRStaffDetector.barlines(bmLine, dark: bm, clean: clean, staff: st)
            let mts = OMRTabAnalyzer.analyze(bm: bm, clean: clean, staff: st, bars: bars, beats: beats, unit: unit, classifier: .shared)
            if let ts = mts.first?.timeSig, ts.beats > 0, ts.beats <= 12, [2, 4, 8].contains(ts.unit) {
                beats = Double(ts.beats) * (ts.unit == 8 ? 1 : 1); unit = ts.unit
                res.meta.timeSignature = TimeSignature(beats: ts.beats, unit: ts.unit)
                timeFromClef = true
            }
        }
        var built: [BuiltSystem] = []
        for (si, st) in staves.enumerated() {
            let bars = OMRStaffDetector.barlines(bmLine, dark: bm, clean: clean, staff: st)
            if ProcessInfo.processInfo.environment["AGR_OMR_TRACE"] != nil {
                FileHandle.standardError.write(Data(" staff y \(Int(st.top)) bars \(bars.count) x \(st.x0)-\(st.x1)\n".utf8))
            }
            trace?.add(IRect(x0: st.x0, y0: Int(st.top), x1: st.x1, y1: Int(st.bottom)), (255, 0, 0), "staff")
            for b in bars { trace?.add(IRect(x0: b.x0 - 1, y0: Int(st.top) - 4, x1: b.x1 + 1, y1: Int(st.bottom) + 4), (0, 160, 0)) }
            let mts = OMRTabAnalyzer.analyze(bm: bm, clean: clean, staff: st, bars: bars, beats: beats, unit: unit, classifier: .shared, trace: trace)
            var measures: [NotationMeasure] = []
            for (mi, mt) in mts.enumerated() {
                var m = NotationMeasure(tab: mt.events)
                if bars.indices.contains(mi) {
                    let k = bars[mi].kind
                    if k == .startRepeat || k == .startEndRepeat { m.leftBarline = .startRepeat }
                }
                if bars.indices.contains(mi + 1) {
                    let k = bars[mi + 1].kind
                    if k == .double || k == .final { m.rightBarline = k }
                    if k == .endRepeat || k == .startEndRepeat { m.rightBarline = .endRepeat }
                }
                if abs(mt.beatSum - beats) > 1e-6 {
                    res.issues.append(OMRIssue(kind: .beatSumMismatch, path: "sections[0].lines[{L}].system.measures[\(mi)]",
                                               message: "tab beats sum \(mt.beatSum) != \(beats)", context: "\(si)"))
                }
                measures.append(m)
            }
            built.append(BuiltSystem(staff: st, bars: bars, measures: measures, eventX: mts.map(\.eventX)))
        }

        var ctx = OMRTextContext()
        ctx.pageIndex = page
        ctx.pageWidth = W
        ctx.pageHeight = H
        ctx.staffSpacing = staves[0].u
        ctx.firstSystemTop = staves[0].top
        ctx.lastSystemBottom = staves.last.map { $0.bottom + 12 * $0.u }
        var kept: [OCRToken] = []
        if options.removeWatermarkText {
            for t in ocr {
                if let why = OMRWatermark.isNonScoreText(t, context: ctx) {
                    res.removedText.append(t.text)
                    res.issues.append(OMRIssue(kind: .suspectedWatermark, path: "pages[\(page)]",
                                               message: "non-score text (\(why.rawValue))", ocrSnippets: [t.text]))
                } else {
                    kept.append(t)
                }
            }
        } else {
            kept = ocr
        }

        var clefTS: (beats: Int, unit: Int)?
        if timeFromClef { clefTS = (beats: res.meta.timeSignature.beats, unit: res.meta.timeSignature.unit) }
        let header = OMRHeaderReader.read(ocr: kept, pageWidth: image.width, pageHeight: image.height,
                                           firstStaffTop: staves[0].top, staffSpacing: staves[0].u,
                                           timeSignature: clefTS, pageIndex: page, lastSystemBottom: ctx.lastSystemBottom)
        mergeHeader(header, into: &res.meta, keepClefTime: timeFromClef)
        res.issues.append(contentsOf: header.issues)
        for s in header.nonScoreText where !res.removedText.contains(s) { res.removedText.append(s) }

        // The clef digits are sometimes missed, and the header then supplies 6/8 after the tab
        // was read in 4/4. Durations are in the time signature's beat, so re-read the tab.
        let sig = res.meta.timeSignature
        if sig.beats > 0, (Int(beats.rounded()) != sig.beats || unit != sig.unit) {
            beats = Double(sig.beats)
            unit = sig.unit
            for si in built.indices {
                let mts = OMRTabAnalyzer.analyze(bm: bm, clean: clean, staff: built[si].staff, bars: built[si].bars,
                                                  beats: beats, unit: unit, classifier: .shared)
                guard mts.count == built[si].measures.count else { continue }
                for mi in mts.indices { built[si].measures[mi].tab = mts[mi].events }
                built[si].eventX = mts.map(\.eventX)
            }
        }

        let pageBeats = res.meta.timeSignature.beats > 0 ? Double(res.meta.timeSignature.beats) : beats
        let inputs: [ChordSystemInput] = built.enumerated().map { si, sys in
            let band: Double? = si > 0 ? max(built[si - 1].staff.bottom + 2 * sys.staff.u, sys.staff.top - 10.5 * sys.staff.u) : nil
            let spans = measureSpans(staff: sys.staff, bars: sys.bars, eventX: sys.eventX, events: sys.measures.map(\.tab), beats: pageBeats)
            return ChordSystemInput(staff: sys.staff, bandTop: band, spans: spans)
        }
        let chordRs = OMRChordReader.readPage(bm: bm, gray: image, systems: inputs, ocr: kept)
        attachPrintedMarks(ocr: kept, width: W, height: H, built: &built)
        for si in built.indices {
            let chordTop: Double? = chordRs.indices.contains(si) ? chordRs[si].bandTop : nil
            if chordRs.indices.contains(si) {
                let cr = chordRs[si]
                res.issues.append(contentsOf: cr.issues)
                for (mi, marks) in cr.measures.enumerated() where mi < built[si].measures.count {
                    built[si].measures[mi].chords = marks
                    for mark in marks {
                        guard let shape = mark.shape, !mark.name.isEmpty, res.chordDefinitions[mark.name] == nil else { continue }
                        res.chordDefinitions[mark.name] = shape
                    }
                }
            }
            let nextTop = si + 1 < built.count ? built[si + 1].staff.top : nil
            let jr = OMRJianpuReader.read(gray: image, bitmap: bm, staff: built[si].staff, nextStaffTop: nextTop,
                                          bars: built[si].bars, ocr: kept, timeSignature: res.meta.timeSignature,
                                          lineIndex: res.lines.count)
            res.issues.append(contentsOf: jr.issues)
            for (mi, mel) in jr.measures.enumerated() where mi < built[si].measures.count {
                built[si].measures[mi].melody = mel
            }
            for (mi, ms) in jr.marks.enumerated() where mi < built[si].measures.count {
                for m in ms where !built[si].measures[mi].marks.contains(m) { built[si].measures[mi].marks.append(m) }
            }
            var contentBottom: Double?
            if jr.rowBottom > jr.rowTop { contentBottom = jr.rowBottom }
            if let lb = jr.lyricRows.map(\.bottom).max() { contentBottom = max(contentBottom ?? lb, lb) }
            let anchor = systemAnchor(page: page, staff: built[si].staff, chordTop: chordTop, contentBottom: contentBottom, pageHeight: H)
            res.lines.append(Line.system(NotationSystem(measures: built[si].measures), anchor: anchor))
        }
        return res
    }

    /// Section names and volta numbers are printed text. They sit above a system and are not tab glyphs.
    static func attachPrintedMarks(ocr: [OCRToken], width W: Double, height H: Double, built: inout [BuiltSystem]) {
        guard W > 0, H > 0, !built.isEmpty else { return }
        for t in ocr {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let cx = (t.x + t.width / 2) * W
            let cy = (t.y + t.height / 2) * H
            if let nums = voltaNumbers(text) {
                guard let si = systemIndex(containingX: cx, y: cy, built: built, bandAbove: 2.6, bandBelow: 0.2) else { continue }
                let u = built[si].staff.u
                let bars = built[si].bars
                guard bars.count >= 2 else { continue }
                var mi = 0
                for k in 0..<(bars.count - 1) where cx >= bars[k].xAfter - 0.4 * u { mi = k }
                guard mi < built[si].measures.count else { continue }
                if built[si].measures[mi].volta != nums { built[si].measures[mi].volta = nums }
                continue
            }
            let folded = ChordNameNormalizer.foldWidth(text)
            guard SectionHeaderParser.isSectionLabel(folded), text.count <= 12 else { continue }
            guard let si = nearestSystemBelow(x: cx, y: cy, built: built) else { continue }
            guard !built[si].measures.isEmpty else { continue }
            if !built[si].measures[0].marks.contains(text) { built[si].measures[0].marks.insert(text, at: 0) }
        }
    }

    /// "1." / "2." / "1,2." as printed on a volta bracket. A bare digit is a fret or a time signature, not a volta.
    static func voltaNumbers(_ raw: String) -> [Int]? {
        let s = ChordNameNormalizer.foldWidth(raw).filter { !$0.isWhitespace }
        guard s.contains(".") || s.contains(",") || s.contains("，") else { return nil }
        var t = s
        if t.hasSuffix(".") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        let parts = t.split { $0 == "," || $0 == "，" || $0 == "." }
        var nums: [Int] = []
        for p in parts {
            guard let v = Int(p), (1...8).contains(v), p.count == 1 else { return nil }
            nums.append(v)
        }
        return nums.isEmpty ? nil : nums
    }

    static func systemIndex(containingX x: Double, y: Double, built: [BuiltSystem], bandAbove: Double, bandBelow: Double) -> Int? {
        var best: (Int, Double)?
        for (si, sys) in built.enumerated() {
            let st = sys.staff
            guard x >= Double(st.x0) - 2 * st.u, x <= Double(st.x1) + 2 * st.u else { continue }
            guard y >= st.top - bandAbove * st.u, y <= st.top + bandBelow * st.u else { continue }
            let d = abs(st.top - y)
            if best == nil || d < best!.1 { best = (si, d) }
        }
        return best?.0
    }

    static func nearestSystemBelow(x: Double, y: Double, built: [BuiltSystem]) -> Int? {
        var best: (Int, Double)?
        for (si, sys) in built.enumerated() {
            let st = sys.staff
            let gap = st.top - y
            guard gap > -0.4 * st.u, gap < 16 * st.u else { continue }
            guard x >= Double(st.x0) - 6 * st.u, x <= Double(st.x0) + 10 * st.u else { continue }
            if best == nil || gap < best!.1 { best = (si, gap) }
        }
        return best?.0
    }

    /// Measure gaps from barline `x0`/`x1` (`xAfter` / `xBefore` include repeat dots).
    /// `TabEvent` has no x; `eventX` is the analyzer's pixel anchor for each event.
    static func measureSpans(staff: TabStaff, bars: [BarlineStructure], eventX: [[Double]], events: [[TabEvent]], beats: Double) -> [MeasureSpan] {
        let n = max(0, bars.count - 1)
        let fitted = OMRChordReader.spans(bars: bars, staff: staff, beats: beats)
        let edges: [(Double, Double)]
        if fitted.count == n, n == events.count {
            edges = fitted.map { ($0.x0, $0.x1) }
        } else if n > 0 {
            edges = (0..<n).map { (bars[$0].xAfter, bars[$0 + 1].xBefore) }
        } else {
            return []
        }
        return edges.enumerated().map { i, e in
            var anchors: [(x: Double, beat: Double)] = []
            if eventX.indices.contains(i), events.indices.contains(i) {
                for pair in zip(eventX[i], events[i]) { anchors.append((x: pair.0, beat: pair.1.beat)) }
            }
            return MeasureSpan(x0: e.0, x1: e.1, beats: beats, anchors: anchors)
        }
    }

    static func mergeHeader(_ header: OMRHeaderResult, into meta: inout ScoreMeta, keepClefTime: Bool) {
        let h = header.meta
        if !h.title.isEmpty { meta.title = h.title }
        if let v = h.artist, !v.isEmpty { meta.artist = v }
        if let v = h.composer { meta.composer = v }
        if let v = h.lyricist { meta.lyricist = v }
        if let v = h.arranger { meta.arranger = v }
        if let v = h.key, !v.isEmpty { meta.key = v }
        if header.found.contains("capo") { meta.capo = h.capo }
        if header.found.contains("tempo") { meta.tempo = h.tempo }
        if !keepClefTime, header.found.contains("time") { meta.timeSignature = h.timeSignature }
        for c in h.credits where !c.isEmpty && !meta.credits.contains(c) { meta.credits.append(c) }
    }

    /// Staff band widened up to the chord-band top and down through the last lyric / jianpu row.
    /// Normalised to the deskewed page and clamped to 0...1.
    static func systemAnchor(page: Int, staff: TabStaff, chordTop: Double?, contentBottom: Double?, pageHeight H: Double) -> PageAnchor {
        var top = staff.top - 10 * staff.u
        var bottom = staff.bottom + 12 * staff.u
        if let c = chordTop { top = min(top, c) }
        if let b = contentBottom { bottom = max(bottom, b) }
        guard H > 0 else { return PageAnchor(page: page, y: 0, height: 0) }
        let y0 = min(1, max(0, top / H))
        let y1 = min(1, max(0, bottom / H))
        let y = min(y0, y1)
        return PageAnchor(page: page, y: y, height: min(1 - y, max(0, y1 - y)))
    }

    static func simple(_ k: BarlineKind) -> BarlineKind { k }
}

/// A normalised page region worth a second, zoomed OCR pass (small chord names above the diagrams).
public struct OMRRegion: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var scale: Double
}

extension OMREngine {
    /// Regions where a dedicated OCR pass on a crop (upscaled by `scale`) finds small text that
    /// full-page OCR misses (chord names above the diagrams). iOS may run Vision on these crops too.
    public static func ocrRegions(image: GrayImage) -> [OMRRegion] {
        let (bm, _, _, _) = OMRVision.binarize(image)
        let staves = OMRStaffDetector.detect(bm)
        let W = Double(image.width), H = Double(image.height)
        var out: [OMRRegion] = []
        for st in staves {
            let y0 = max(0, st.top - 9.5 * st.u), y1 = st.top - 0.3 * st.u
            out.append(OMRRegion(x: 0, y: y0 / H, width: 1, height: (y1 - y0) / H, scale: 2.5))
        }
        _ = W
        return out
    }
}
