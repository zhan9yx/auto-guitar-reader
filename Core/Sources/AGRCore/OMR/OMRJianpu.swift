import Foundation

/// A recognised numbered-notation note (pixel geometry kept for debugging).
struct JianpuNote {
    var cx: Double, x0: Double, x1: Double
    var top: Double, bottom: Double
    var degree: Int
    var conf: Double
    var accidental = 0
    var above = 0, below = 0
    var levels = 0
    var dots = 0
    var dashes = 0
    var tie = false
    var measure = -1
    var beat = 0.0
    var duration = 0.0
}

struct JianpuReadResult {
    var measures: [[MelodyNote]]
    var issues: [OMRIssue]
    var notes: [JianpuNote] = []
    var rowTop: Double = 0, rowBottom: Double = 0
    var lyricRows: [LyricRow] = []
    /// x of the measure boundaries used (measures.count + 1 entries).
    var boundaries: [Double] = []
}

/// Numbered-notation (简谱) melody + lyrics reader for one tab system.
///
/// Call site (per system, after `OMRStaffDetector.detect` / `barlines`):
/// ```
/// let r = OMRJianpuReader.read(gray: image, bitmap: bm, staff: st, nextStaffTop: staves[si+1].top, bars: bars,
///                              ocr: ocr, timeSignature: meta.timeSignature)
/// // r.measures[mi] -> NotationMeasure.melody for measure mi (bars[mi]..bars[mi+1]); r.issues -> report
/// ```
/// `bitmap` is the deskewed page binarisation (staff lines may still be present), `ocr` the page's (deskew-mapped) OCR tokens.
enum OMRJianpuReader {
    typealias Result = JianpuReadResult

    static func read(gray: GrayImage, bitmap bm: Bitmap, staff: TabStaff, nextStaffTop: Double?, bars: [BarlineStructure],
                     ocr: [OCRToken], timeSignature: TimeSignature, lineIndex: Int = 0,
                     classifier: JianpuClassifier = .shared) -> Result {
        var measureCount = max(0, bars.count - 1)
        var res = Result(measures: [[MelodyNote]](repeating: [], count: measureCount), issues: [])
        guard measureCount > 0 else { return res }
        let u = staff.u
        let W = bm.w, H = bm.h
        func issue(_ kind: OMRIssueKind, _ mi: Int?, _ msg: String, conf: Double = 0) -> OMRIssue {
            OMRIssue(kind: kind, path: "sections[0].lines[{L}].system.measures[\(mi ?? 0)].melody", message: msg,
                     context: "\(lineIndex)|jianpu", confidence: conf)
        }

        // ---- region below the staff
        let xa = max(0, Int((min(Double(bars.first!.x0), Double(staff.x0)) - 0.5 * u).rounded(.down)))
        let xb = min(W, Int((max(Double(bars.last!.x1), Double(staff.x1)) + 1.0 * u).rounded(.up)))
        let ya = min(H - 1, Int((staff.bottom + 0.5 * u).rounded()))
        let limit = nextStaffTop.map { $0 - 5.0 * u } ?? Double(H)
        let yb = min(H, Int(limit.rounded()))
        guard xb - xa > 8, yb - ya > 8 else { res.issues.append(issue(.jianpuUnread, nil, "no room below staff")); return res }
        let crop = OMRVision.crop(bm, IRect(x0: xa, y0: ya, x1: xb, y1: yb))
        let lab0 = OMRVision.label(crop)

        // ---- digit candidates -> digit row
        struct Cand { var c: Component; var label: String; var dist: Double }
        var cands: [Cand] = []
        for c in lab0.comps {
            let r = c.rect
            let h = Double(r.h), w = Double(r.w)
            guard h >= 0.75 * u, h <= 2.9 * u, w >= 0.2 * u, w <= 2.0 * u, c.area >= 12 else { continue }
            let b = OMRVision.extract(lab0, c)
            if let k = classifier.classify(b), JianpuClassifier.digitLabels.contains(k.label), k.dist < 0.33 {
                cands.append(Cand(c: c, label: k.label, dist: k.dist))
            }
        }
        guard !cands.isEmpty else { res.issues.append(issue(.jianpuUnread, nil, "no numbered-notation digits found")); return res }
        cands.sort { $0.c.rect.cy < $1.c.rect.cy }
        var clusters: [[Cand]] = []
        for k in cands {
            if let l = clusters.last {
                let mc = l.map { $0.c.rect.cy }.reduce(0, +) / Double(l.count)
                if k.c.rect.cy - mc <= 0.6 * u { clusters[clusters.count - 1].append(k); continue }
            }
            clusters.append([k])
        }
        let maxCount = clusters.map(\.count).max() ?? 0
        let rowThreshold = 0.5 * Double(maxCount)
        guard let rowCl = clusters.first(where: { Double($0.count) >= rowThreshold }) else { return res }
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let rowTop = median(rowCl.map { Double($0.c.rect.y0) }) + Double(ya)
        let rowBottom: Double = { let s = rowCl.map { Double($0.c.rect.y1) }.sorted(); return (s.isEmpty ? 0 : s[Int(Double(s.count - 1) * 0.35)]) + Double(ya) }()
        let Hd = rowBottom - rowTop
        let medW = median(rowCl.map { Double($0.c.rect.w) })
        let refW: Double = { let s = rowCl.map { Double($0.c.rect.w) }.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, s.count * 3 / 4)] }()
        res.rowTop = rowTop; res.rowBottom = rowBottom

        // ---- lyrics rows (OCR) -> limit for octave dots below
        let lyricRows = OMRLyrics.rows(ocr: ocr, width: gray.width, height: gray.height, bm: bm, yFrom: rowBottom,
                                       yTo: limit, xRange: Double(xa)...Double(xb), digitH: Hd, u: u)
        res.lyricRows = lyricRows
        let lyricTop = lyricRows.first.map { $0.top + 0.35 * ($0.bottom - $0.top) } ?? Double.infinity
        if ProcessInfo.processInfo.environment["AGR_JP_DEBUG"] != nil { for lr in lyricRows { print("   lyricRow \(Int(lr.top))-\(Int(lr.bottom)) inkTop \(Int(lr.inkTop)) \(lr.syllables.map { $0.text }.joined())") } }

        // ---- split the region at the digit baseline: upper part (digits, dots above, arcs, dashes, accidentals),
        // lower part (underlines are scanned per note; octave dots below are components of the lower part)
        let cutRow = Int(rowBottom.rounded()) + 1 - ya      // rows >= cutRow (crop coords) belong to the lower part
        var upperBM = crop, lowerBM = crop
        for y in 0..<crop.h { for x in 0..<crop.w {
            if y >= cutRow { upperBM.d[y * crop.w + x] = 0 } else { lowerBM.d[y * crop.w + x] = 0 }
        } }
        let lab = OMRVision.label(upperBM)
        let labLow = OMRVision.label(lowerBM)

        // ---- glyphs in the row
        func offsetRect(_ r: IRect) -> IRect { IRect(x0: r.x0 + xa, y0: r.y0 + ya, x1: r.x1 + xa, y1: r.y1 + ya) }
        var notes: [JianpuNote] = []
        var used = Set<Int>()
        var barXs: [Double] = []
        var parenXs: [Double] = []
        // barlines of the jianpu row (the left system line may reach up to the staff, so any height is allowed)
        for c in lab0.comps {
            let r = offsetRect(c.rect)
            let h = Double(r.h), w = Double(r.w)
            let overlap = Double(min(r.y1, Int(rowBottom + 0.15 * Hd)) - max(r.y0, Int(rowTop - 0.15 * Hd)))
            if overlap >= 0.6 * Hd && h / w >= 5 && h <= 6 * u && w <= 0.3 * Hd && (h >= 1.08 * Hd || w <= 2.5) && Double(c.area) >= 0.72 * w * h { barXs.append(r.cx) }
        }
        let barSet = barXs
        for c in lab.comps {
            let r = offsetRect(c.rect)
            let h = Double(r.h), w = Double(r.w)
            if ProcessInfo.processInfo.environment["AGR_JP_DEBUG"] == "all", r.cy > rowTop - 2 * u, r.cy < rowBottom + 2 * u { print("   ALL x\(r.x0)-\(r.x1) y\(r.y0)-\(r.y1) area \(c.area)") }
            if barSet.contains(where: { abs($0 - r.cx) < 2.5 }) && w <= 0.3 * Hd && h / max(w, 1) >= 4 { used.insert(c.id); continue }
            // geometry of a note glyph relative to the row
            guard r.cy >= rowTop - 0.12 * Hd, r.cy <= rowBottom + 0.12 * Hd else { continue }
            guard h >= 0.72 * Hd, h <= 1.4 * Hd, w >= 0.2 * u, c.area >= 12 else { continue }
            var b = OMRVision.extract(lab, c)
            // merged neighbours (touching digits): the glyph matches no single digit well and is much wider than usual
            let single = classifier.classify(b)
            let goodSingle = single.map { JianpuClassifier.digitLabels.contains($0.label) && $0.dist < 0.2 } ?? false
            if !goodSingle && refW > 0 && w > 1.5 * refW && w < 5.5 * refW {
                let parts = max(2, Int((w / refW).rounded()))
                let cuts = splitColumns(b, parts: parts)
                var start = 0
                for cutAt in cuts + [b.w] {
                    let sub = OMRVision.crop(b, IRect(x0: start, y0: 0, x1: cutAt, y1: b.h))
                    if sub.w >= 3, let kk = classifier.classify(sub, allowed: JianpuClassifier.digitLabels) {
                        notes.append(JianpuNote(cx: Double(r.x0 + start + cutAt) / 2, x0: Double(r.x0 + start), x1: Double(r.x0 + cutAt),
                                                top: Double(r.y0), bottom: Double(r.y1), degree: Int(kk.label)!, conf: 0.4))
                    }
                    start = cutAt
                }
                used.insert(c.id)
                res.issues.append(issue(.lowConfidenceGlyph, nil, "split touching digits", conf: 0.4))
                continue
            }
            guard let k = classifier.classify(b) else { continue }
            if k.label == "(" || k.label == ")" { parenXs.append(r.cx); used.insert(c.id); continue }
            if k.label == "#" || k.label == "b" { continue }   // accidentals are handled below
            var label = k.label
            var conf = max(0, 1 - k.dist / 0.4)
            if !JianpuClassifier.digitLabels.contains(label) {
                // digit-sized glyph in the digit row that is not a digit prototype: force the nearest digit unless it is far off
                guard let d = classifier.classify(b, allowed: JianpuClassifier.digitLabels), d.dist < 0.42, w / h > 0.25 else { continue }
                label = d.label; conf = max(0, 1 - d.dist / 0.5) * 0.5
                res.issues.append(issue(.lowConfidenceGlyph, nil, "digit-like glyph read as \(label)", conf: conf))
            }
            used.insert(c.id)
            notes.append(JianpuNote(cx: r.cx, x0: Double(r.x0), x1: Double(r.x1), top: Double(r.y0), bottom: Double(r.y1),
                                    degree: Int(label)!, conf: conf))
        }
        notes.sort { $0.cx < $1.cx }
        if ProcessInfo.processInfo.environment["AGR_JP_DEBUG"] != nil { print("   barXs \(barXs.map { Int($0) }.sorted()) Hd \(Hd) medW \(medW)") }
        guard !notes.isEmpty else { res.issues.append(issue(.jianpuUnread, nil, "no notes")); return res }

        // ---- attach marks
        let barMin = (bars.map { $0.cx } + barXs)
        func nearBar(_ x: Double, _ d: Double) -> Bool { barMin.contains { abs($0 - x) <= d } }
        func nearestNote(_ x: Double, maxDist: Double) -> Int? {
            var bi = -1, bd = Double.infinity
            for (i, n) in notes.enumerated() { let d = abs(n.cx - x); if d < bd { bd = d; bi = i } }
            return bd <= maxDist && bi >= 0 ? bi : nil
        }
        let thinLimit: Double = 0.2 * Hd + 1.5
        let thinMinW: Double = 0.5 * Hd
        let thick = median(lab.comps.filter { Double($0.rect.h) <= thinLimit && Double($0.rect.w) >= thinMinW }.map { Double($0.rect.h) })
        var underlines: [(x0: Double, x1: Double, levels: Int)] = []
        var dashes: [Double] = []
        var arcs: [(x0: Double, x1: Double)] = []
        let dbg = ProcessInfo.processInfo.environment["AGR_JP_DEBUG"] != nil
        for c in lab.comps where !used.contains(c.id) {
            let r = offsetRect(c.rect)
            let h = Double(r.h), w = Double(r.w)
            if dbg, r.cy > rowTop - 2 * u, r.cy < rowBottom + 2 * u { print("   comp x\(r.x0)-\(r.x1) y\(r.y0)-\(r.y1) area \(c.area) row \(Int(rowTop))-\(Int(rowBottom)) Hd \(Hd) lyricTop \(lyricTop)") }
            if c.area < 2 { continue }
            // thin horizontal strokes: underline (below digits) or dash (mid height)
            if h <= max(3.5, 0.22 * Hd) && w >= 0.4 * Hd && w / h >= 2.5 {
                if r.cy >= rowBottom - 0.05 * Hd && r.cy <= rowBottom + 1.1 * u + 0.3 * Hd {
                    let lv = thick > 0 && h > 1.9 * thick ? Int((h / thick).rounded()) : 1
                    underlines.append((Double(r.x0), Double(r.x1), min(3, lv)))
                } else if r.cy >= rowTop + 0.25 * Hd && r.cy <= rowTop + 0.8 * Hd {
                    dashes.append(r.cx)
                }
                continue
            }
            // slurs / ties above the digits
            if w >= 0.7 * Hd && h <= 0.9 * Hd && h >= 2 && w / h >= 2.2 && r.cy < rowTop - 0.05 * Hd {
                arcs.append((Double(r.x0), Double(r.x1)))
                continue
            }
            // small blobs: octave dots, augmentation dots
            if w >= 0.1 * Hd, h >= 0.1 * Hd, w <= 0.55 * Hd, h <= 0.55 * Hd, w / h >= 0.5, w / h <= 2.0,
               Double(c.area) >= 0.45 * w * h {
                if r.cy < rowTop - 0.02 * Hd {
                    guard r.cy >= rowTop - 1.5 * u - 0.3 * Hd else { continue }
                    if let i = nearestNote(r.cx, maxDist: max(0.45 * Hd, 0.6 * (notes[0].x1 - notes[0].x0) + 2)),
                       abs(notes[i].cx - r.cx) <= 0.5 * (notes[i].x1 - notes[i].x0) + 2.5 { notes[i].above += 1 }
                } else if r.cy >= rowTop + 0.3 * Hd && r.cy <= rowBottom + 0.1 * Hd {
                    // augmentation dot: right of a digit
                    var bi = -1, bd = Double.infinity
                    for (i, n) in notes.enumerated() where r.cx > n.x1 - 1.0 {
                        let d = r.cx - n.x1
                        if d < bd { bd = d; bi = i }
                    }
                    if bi >= 0, bd <= 0.9 * u + 0.3 * Hd, !nearBar(r.cx, 0.9 * u) || bd < 0.5 * u { notes[bi].dots += 1 }
                }
                continue
            }
            // accidentals: left of a digit
            if h >= 0.3 * Hd, h <= 1.0 * Hd, w >= 0.15 * Hd, w <= 0.9 * Hd, r.cy >= rowTop - 0.2 * Hd, r.cy <= rowBottom + 0.2 * Hd {
                var bi = -1, bd = Double.infinity
                for (i, n) in notes.enumerated() where Double(r.x1) <= n.x0 + 0.15 * u {
                    let d = n.x0 - Double(r.x1)
                    if d < bd { bd = d; bi = i }
                }
                if bi >= 0, bd <= 0.9 * u {
                    let b = OMRVision.extract(lab, c)
                    if let k = classifier.classify(b, allowed: ["#", "b", "o", "(", ")", "0", "1", "2", "3", "4", "5", "6", "7"]), k.dist < 0.4 {
                        if k.label == "#" { notes[bi].accidental = 1 } else if k.label == "b" { notes[bi].accidental = -1 }
                    }
                }
            }
        }
        if dbg { for n in notes { print("   note x\(Int(n.cx)) y\(Int(n.top))-\(Int(n.bottom)) deg \(n.degree) above \(n.above) below \(n.below) dots \(n.dots)") } }
        // underline levels per note: vertical scan below each digit; a run counts when it spans the digit width
        // (octave dots are narrower). A run thicker than a single line (merged double underline) counts several levels.
        var runsPerNote = [[(Int, Int)]](repeating: [], count: notes.count)
        let scanEnd = min(H - 1, Int(min(rowBottom + 1.9 * u, lyricTop - 1)))
        let dotLimit1 = min(rowBottom + 1.35 * u, lyricTop - 1)
        var dotsBelow = [Int](repeating: 0, count: notes.count)
        for i in notes.indices {
            let n = notes[i]
            let c0 = Int(n.cx.rounded())
            let xs0 = Int(n.x0.rounded(.up)) + 1, xs1 = Int(n.x1.rounded(.down)) - 1
            guard xs1 > xs0 else { continue }
            func inkRow(_ y: Int) -> Bool { bm.ink(c0 - 1, y) || bm.ink(c0, y) || bm.ink(c0 + 1, y) }
            var y = Int(rowBottom.rounded()) + 1
            var lastDotMid = 0
            while y <= scanEnd {
                if inkRow(y) {
                    let st = y
                    while y <= scanEnd && inkRow(y) { y += 1 }
                    let en = y - 1
                    let mid = (st + en) / 2
                    var cover = 0
                    for x in xs0...xs1 where bm.ink(x, mid) || bm.ink(x, st) || bm.ink(x, en) { cover += 1 }
                    if Double(cover) >= 0.8 * Double(xs1 - xs0 + 1) { if Double(st) <= rowBottom + 0.9 * u + 2 { runsPerNote[i].append((st, en)) } }
                    else if Double(en - st + 1) <= 0.6 * Hd && Double(en - st + 1) >= 0.12 * Hd && cover <= xs1 - xs0 {
                        // a dot is a compact blob: its horizontal extent is about its height
                        var l = c0, rr = c0
                        while bm.ink(l - 1, mid) && c0 - l < 40 { l -= 1 }
                        while bm.ink(rr + 1, mid) && rr - c0 < 40 { rr += 1 }
                        let th = Double(en - st + 1), wd = Double(rr - l + 1)
                        // first dot must lie within the normal zone, a second (octave -2) may sit further down
                        if wd <= max(1.8 * th, th + 4) && wd >= 0.6 * th && (Double(mid) <= dotLimit1 || (dotsBelow[i] > 0 && Double(mid) <= dotLimit1 + 0.8 * u && Double(mid - lastDotMid) >= 0.35 * u && Double(mid - lastDotMid) <= 0.85 * u)) { dotsBelow[i] += 1; lastDotMid = mid }
                    }
                } else { y += 1 }
            }
        }
        if dbg { for i in notes.indices { print("   scan note x\(Int(notes[i].cx)) deg \(notes[i].degree) x0 \(Int(notes[i].x0)) x1 \(Int(notes[i].x1)) runs \(runsPerNote[i]) dotsBelow \(dotsBelow[i]) scanEnd \(scanEnd) rowBottom \(Int(rowBottom))") } }
        let ths = runsPerNote.flatMap { $0.map { Double($0.1 - $0.0 + 1) } }.sorted()
        let t1 = ths.isEmpty ? 2.0 : ths[ths.count / 4]
        let gUL = max(1.0, t1)
        for i in notes.indices {
            var lv = 0
            for r in runsPerNote[i] { lv += max(1, Int((((Double(r.1 - r.0 + 1)) + gUL) / (t1 + gUL)).rounded())) }
            notes[i].levels = min(lv, 3)
            notes[i].below += dotsBelow[i]
        }
        // dashes extend the note on their left
        for dx in dashes {
            var bi = -1
            for (i, n) in notes.enumerated() where n.cx < dx { bi = i }
            if bi >= 0 { notes[bi].dashes += 1 }
        }
        // slur arcs
        for a in arcs {
            guard let l = nearestNote(a.x0, maxDist: 1.6 * u + 0.5 * medW), let r = nearestNote(a.x1, maxDist: 1.6 * u + 0.5 * medW) else { continue }
            if r > l { for k in l..<r { notes[k].tie = true } }
            else if l == r, a.x1 > notes[l].cx + 0.5 * u { notes[l].tie = true }
        }

        // ---- measures + beats
        // Measure boundaries: the jianpu row's own barlines (clustered); tab barlines are only a fallback because
        // strum arrows / stems can look like barlines in the tab.
        var jb: [Double] = []
        for x in barXs.sorted() {
            if let l = jb.last, x - l <= 1.0 * u { jb[jb.count - 1] = (l + x) / 2 } else { jb.append(x) }
        }
        let tabCenters = bars.map { $0.cx }
        let edgeL = min(tabCenters.first!, Double(staff.x0)), edgeR = max(tabCenters.last!, Double(staff.x1) - 1)
        jb = jb.filter { $0 >= edgeL - 1.5 * u && $0 <= edgeR + 1.5 * u }
        if !jb.isEmpty {
            if abs(jb.first! - edgeL) > 1.5 * u { jb.insert(edgeL, at: 0) }
            if abs(jb.last! - edgeR) > 1.5 * u { jb.append(edgeR) }
        }
        let bc: [Double] = jb.count >= 2 ? jb : tabCenters
        res.boundaries = bc
        if jb.count >= 2 && jb.count != tabCenters.count {
            res.issues.append(issue(.barlineMismatch, nil, "jianpu row has \(jb.count - 1) measures, tab has \(tabCenters.count - 1)", conf: 0.5))
        }
        measureCount = max(0, bc.count - 1)
        res.measures = [[MelodyNote]](repeating: [], count: measureCount)
        for i in notes.indices {
            var m = -1
            for k in 0..<measureCount where bc[k] - 1.0 <= notes[i].cx && notes[i].cx < bc[k + 1] - 1.0 { m = k }
            // a first note glued to its left barline is still inside the measure
            notes[i].measure = m
        }
        let unitScale = Double(timeSignature.unit) / 4.0
        let measureBeats = Double(timeSignature.beats)
        var perMeasure = [[Int]](repeating: [], count: measureCount)
        for (i, n) in notes.enumerated() where n.measure >= 0 { perMeasure[n.measure].append(i) }
        for mi in 0..<measureCount {
            var t = 0.0
            for i in perMeasure[mi] {
                var q = 1.0 / Double(1 << notes[i].levels)
                if notes[i].dots == 1 { q *= 1.5 } else if notes[i].dots >= 2 { q *= 1.75 }
                q += Double(notes[i].dashes)
                notes[i].beat = t
                notes[i].duration = q * unitScale
                t += q * unitScale
            }
            if !perMeasure[mi].isEmpty, abs(t - measureBeats) > 1e-6 {
                res.issues.append(issue(.beatSumMismatch, mi, "melody beats sum \(t) != \(measureBeats)", conf: 0.5))
            }
        }

        // ---- lyrics
        let slots = notes.filter { $0.measure >= 0 }.map { OMRLyrics.NoteSlot(x: $0.cx, isRest: $0.degree == 0) }
        let pitchEst: Double = {
            let xs = notes.map(\.cx)
            guard xs.count > 1 else { return 2 * Hd }
            var d: [Double] = []
            for i in 1..<xs.count { d.append(xs[i] - xs[i - 1]) }
            return max(median(d), 0.8 * Hd)
        }()
        let al = OMRLyrics.align(rows: lyricRows, notes: slots, pitch: pitchEst)
        if al.conflicts > 0 {
            res.issues.append(issue(.lyricAlignment, nil, "\(al.conflicts) lyric syllable(s) could not be aligned cleanly", conf: 0.5))
        }
        var slotIdx = 0
        for mi in 0..<measureCount {
            for i in perMeasure[mi] {
                let n = notes[i]
                var lyr: [String] = []
                for v in 0..<lyricRows.count { lyr.append(al.lyrics[v][slotIdx]) }
                res.measures[mi].append(MelodyNote(beat: n.beat, duration: n.duration, degree: n.degree, accidental: n.degree == 0 ? 0 : n.accidental,
                                                   octave: n.degree == 0 ? 0 : n.above - n.below, tieToNext: n.tie, lyrics: lyr))
                slotIdx += 1
            }
        }
        res.notes = notes
        return res
    }

    /// Column indices (inside the glyph bitmap) at which a merged glyph is split into `parts` pieces.
    static func splitColumns(_ b: Bitmap, parts: Int) -> [Int] {
        var colInk = [Int](repeating: 0, count: b.w)
        for y in 0..<b.h { for x in 0..<b.w where b.d[y * b.w + x] != 0 { colInk[x] += 1 } }
        var cuts: [Int] = []
        for p in 1..<parts {
            let center = b.w * p / parts
            let lo = max(1, center - b.w / (3 * parts)), hi = min(b.w - 1, center + b.w / (3 * parts))
            var best = center, bv = Int.max
            if lo <= hi { for x in lo...hi where colInk[x] < bv { bv = colInk[x]; best = x } }
            cuts.append(best)
        }
        return cuts
    }
}

// MARK: - Page-level entry point (debug command, tests)

/// Public convenience wrapper that runs deskew, staff detection and the jianpu reader on a whole page.
public enum OMRJianpuPage {
    public struct SystemResult {
        public var measures: [[MelodyNote]]
        public var issues: [OMRIssue]
        public var staffTop: Double
        public var boundaries: [Double] = []
        public var rowTop: Double = 0, rowBottom: Double = 0
        public var tabBars: [Double] = []
    }

    public static func read(image: GrayImage, ocr: [OCRToken], timeSignature: TimeSignature) -> [SystemResult] {
        var image = image
        var ocr = ocr
        var (bm, _, bg, _) = OMRVision.binarize(image)
        let slope = OMRDeskew.estimateSlope(bm)
        if slope != 0 {
            image = OMRDeskew.rotate(image, slope: slope, fill: UInt8(max(0, min(255, bg))))
            ocr = ocr.map { t in
                var t = t
                let W = Double(image.width), H = Double(image.height)
                let c = OMRDeskew.forward(x: (t.x + t.width / 2) * W, y: (t.y + t.height / 2) * H, slope: slope, width: image.width, height: image.height)
                t.x = c.0 / W - t.width / 2; t.y = c.1 / H - t.height / 2
                return t
            }
            bm = OMRVision.binarize(image).bm
        }
        let staves = OMRStaffDetector.detect(bm)
        var out: [SystemResult] = []
        for (i, st) in staves.enumerated() {
            let bars = OMRStaffDetector.barlines(bm, staff: st)
            let r = OMRJianpuReader.read(gray: image, bitmap: bm, staff: st, nextStaffTop: i + 1 < staves.count ? staves[i + 1].top : nil,
                                         bars: bars, ocr: ocr, timeSignature: timeSignature, lineIndex: i)
            out.append(SystemResult(measures: r.measures, issues: r.issues, staffTop: st.top, boundaries: r.boundaries, rowTop: r.rowTop, rowBottom: r.rowBottom, tabBars: bars.map { $0.cx }))
        }
        return out
    }
}
