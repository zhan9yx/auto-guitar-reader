import AGRCore
import Foundation

/// `agr-tool omr-chords page.pgm --ocr page.ocr.json [--gt gt.agr.json | --boxes page.boxes.json] [--meta meta.json] [-v]`
/// `agr-tool omr-chords --synth <split dir> [--max N] [--stride K] [--worst N]`
/// `agr-tool omr-chords --real <images dir> --gt <gt dir> --ids real-000,real-001 [--ocr <ocr dir>]`
/// Chord name / position / diagram accuracy (plus header + watermark reports once available).
enum OMRChordsCommand {
    struct GTChord { var sys: Int; var m: Int; var name: String; var beat: Double; var frets: [Int]? }

    struct Counts {
        var gt = 0, pred = 0, tp = 0, nameOnly = 0       // nameOnly: name matched in the right measure, beat wrong
        var shapeGT = 0, shapeOK = 0, shapePredWrong = 0
        mutating func add(_ o: Counts) {
            gt += o.gt; pred += o.pred; tp += o.tp; nameOnly += o.nameOnly
            shapeGT += o.shapeGT; shapeOK += o.shapeOK; shapePredWrong += o.shapePredWrong
        }
        var recall: Double { gt == 0 ? 1 : Double(tp) / Double(gt) }
        var precision: Double { pred == 0 ? 1 : Double(tp) / Double(pred) }
        var f1: Double { let p = precision, r = recall; return p + r == 0 ? 0 : 2 * p * r / (p + r) }
        var shapeAcc: Double { shapeGT == 0 ? 1 : Double(shapeOK) / Double(shapeGT) }
        var line: String {
            String(format: "chords gt %d pred %d tp %d  R %.4f P %.4f F1 %.4f | wrongBeat %d | shapes %d/%d = %.4f (wrongShape %d)",
                   gt, pred, tp, recall, precision, f1, nameOnly, shapeOK, shapeGT, shapeAcc, shapePredWrong)
        }
    }

    static func loadOCR(_ path: String?) -> [OCRToken] {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let t = try? JSONDecoder().decode([OCRToken].self, from: d) else { return [] }
        return t
    }

    static func gtFromBoxes(_ path: String) -> [GTChord] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let els = o["elements"] as? [[String: Any]] else { return [] }
        let sysIDs = Array(Set(els.compactMap { $0["sys"] as? Int })).sorted()
        func rank(_ s: Int) -> Int { sysIDs.firstIndex(of: s) ?? 0 }
        var diagrams: [String: [Int]] = [:]
        for e in els where e["label"] as? String == "chord_diagram" {
            if let s = e["sys"] as? Int, let m = e["m"] as? Int, let c = e["chord"] as? Int, let f = e["frets"] as? [Int] { diagrams["\(s)|\(m)|\(c)"] = f }
        }
        var out: [GTChord] = []
        for e in els where e["label"] as? String == "chord_name" {
            guard let s = e["sys"] as? Int, let m = e["m"] as? Int, let t = e["text"] as? String else { continue }
            let c = e["chord"] as? Int ?? 0
            out.append(GTChord(sys: rank(s), m: m, name: t, beat: (e["beat"] as? Double) ?? 0, frets: diagrams["\(s)|\(m)|\(c)"]))
        }
        return out
    }

    static func oracleFromBoxes(_ path: String) -> [OMRChordsDebug.OracleSystem] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let els = o["elements"] as? [[String: Any]] else { return [] }
        let sysIDs = Array(Set(els.compactMap { $0["sys"] as? Int })).sorted()
        var out: [OMRChordsDebug.OracleSystem] = []
        for s in sysIDs {
            var lines: [(Int, Double, Double, Double)] = []
            var meas: [(Int, Double, Double)] = []
            var beats: Double?
            for e in els where e["sys"] as? Int == s {
                guard let bb = e["bbox"] as? [Double], bb.count == 4 else { continue }
                if e["label"] as? String == "staff_line", let st = e["string"] as? Int { lines.append((st, (bb[1] + bb[3]) / 2, bb[0], bb[2])) }
                if e["label"] as? String == "measure", let m = e["m"] as? Int { meas.append((m, bb[0], bb[2])); beats = e["beats"] as? Double }
            }
            lines.sort { $0.0 < $1.0 }
            guard lines.count == 6 else { continue }
            out.append(.init(lineYs: lines.map { $0.1 }, x0: lines[0].2, x1: lines[0].3, measureX: meas.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }, beats: beats))
        }
        return out
    }

    /// y bands (pixels) of the GT system lines on a page of the given height.
    static func bandsFromScore(_ path: String, height: Int) -> [(Double, Double)] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let s = try? ScoreCoding.decode(d) else { return [] }
        var out: [(Double, Double)] = []
        for sec in s.sections { for l in sec.lines where l.system != nil {
            if let a = l.anchor { out.append((a.y * Double(height) - 0.01 * Double(height), (a.y + a.height) * Double(height))) }
        } }
        return out
    }

    static func gtFromScore(_ path: String) -> [GTChord] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let s = try? ScoreCoding.decode(d) else { return [] }
        var out: [GTChord] = []
        var sys = 0
        for sec in s.sections {
            for l in sec.lines {
                guard let sy = l.system else { continue }
                for (mi, m) in sy.measures.enumerated() {
                    for c in m.chords { out.append(GTChord(sys: sys, m: mi, name: c.name, beat: c.beat, frets: c.shape?.frets)) }
                }
                sys += 1
            }
        }
        return out
    }

    /// Measure-independent score: chords of a system compared as ordered name sequences (LCS); shapes of matched pairs.
    static func seqScore(gt: [GTChord], pred: OMRPageChords, verbose: Bool, label: String) -> Counts {
        var c = Counts()
        let nSys = max(pred.systems.count, (gt.map { $0.sys }.max() ?? -1) + 1)
        for si in 0..<nSys {
            let g = gt.filter { $0.sys == si }.sorted { ($0.m, $0.beat) < ($1.m, $1.beat) }
            var p: [ChordMark] = []
            if si < pred.systems.count { for ms in pred.systems[si].measures { p += ms } }
            c.gt += g.count; c.pred += p.count
            let gk = g.map { ChordNameNormalizer.key($0.name) }, pk = p.map { ChordNameNormalizer.key($0.name) }
            var L = [[Int]](repeating: [Int](repeating: 0, count: pk.count + 1), count: gk.count + 1)
            for i in stride(from: gk.count - 1, through: 0, by: -1) { for j in stride(from: pk.count - 1, through: 0, by: -1) {
                L[i][j] = gk[i] == pk[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            } }
            var i = 0, j = 0
            var matchedG = Set<Int>()
            while i < gk.count && j < pk.count {
                if gk[i] == pk[j] {
                    c.tp += 1; matchedG.insert(i)
                    if let f = g[i].frets { c.shapeGT += 1; if p[j].shape?.frets == f { c.shapeOK += 1 } else { c.shapePredWrong += 1
                        if verbose { print("  [\(label)] sys\(si) #\(i) \(g[i].name) shape gt \(f) pred \(p[j].shape?.frets ?? [])") } } }
                    i += 1; j += 1
                } else if L[i + 1][j] >= L[i][j + 1] { i += 1 } else { j += 1 }
            }
            for (k, gc) in g.enumerated() where !matchedG.contains(k) {
                if gc.frets != nil { c.shapeGT += 1 }
                if verbose { print("  [\(label)] sys\(si) #\(k) MISSING \(gc.name) (m\(gc.m) @\(gc.beat))") }
            }
            if verbose && p.count != c.tp { print("  [\(label)] sys\(si) pred names \(p.map { $0.name })  gt \(g.map { $0.name })") }
        }
        return c
    }

    static func score(gt: [GTChord], pred: OMRPageChords, verbose: Bool, label: String) -> Counts {
        var c = Counts()
        let nSys = max(pred.systems.count, (gt.map { $0.sys }.max() ?? -1) + 1)
        for si in 0..<nSys {
            let g = gt.filter { $0.sys == si }
            var p: [(m: Int, mark: ChordMark)] = []
            if si < pred.systems.count { for (mi, ms) in pred.systems[si].measures.enumerated() { for ch in ms { p.append((mi, ch)) } } }
            c.gt += g.count; c.pred += p.count
            var used = Set<Int>()
            var unmatchedG: [GTChord] = []
            for gc in g {
                if let j = p.indices.first(where: { !used.contains($0) && p[$0].m == gc.m && abs(p[$0].mark.beat - gc.beat) < 0.0625 && ChordNameNormalizer.key(p[$0].mark.name) == ChordNameNormalizer.key(gc.name) }) {
                    used.insert(j); c.tp += 1
                    if let f = gc.frets { c.shapeGT += 1; if p[j].mark.shape?.frets == f { c.shapeOK += 1 } else {
                        c.shapePredWrong += 1
                        if verbose { print("  [\(label)] sys\(si) m\(gc.m) \(gc.name) shape gt \(f) pred \(p[j].mark.shape?.frets ?? [])") } } }
                } else { unmatchedG.append(gc) }
            }
            for gc in unmatchedG {
                if let j = p.indices.first(where: { !used.contains($0) && p[$0].m == gc.m && ChordNameNormalizer.key(p[$0].mark.name) == ChordNameNormalizer.key(gc.name) }) {
                    used.insert(j); c.nameOnly += 1
                    if gc.frets != nil { c.shapeGT += 1; if p[j].mark.shape?.frets == gc.frets { c.shapeOK += 1 } }
                    if verbose { print("  [\(label)] sys\(si) m\(gc.m) \(gc.name) beat gt \(gc.beat) pred \(p[j].mark.beat)") }
                } else {
                    if gc.frets != nil { c.shapeGT += 1 }
                    if verbose { print("  [\(label)] sys\(si) m\(gc.m) MISSING \(gc.name) @\(gc.beat) shape \(gc.frets ?? [])") }
                }
            }
            for (j, pc) in p.enumerated() where !used.contains(j) {
                if verbose { print("  [\(label)] sys\(si) m\(pc.m) EXTRA \(pc.mark.name) @\(pc.mark.beat)") }
            }
        }
        return c
    }

    // MARK: header / watermark evaluation

    static func norm(_ s: String?) -> String {
        ChordNameNormalizer.foldWidth(s ?? "").lowercased().filter { !$0.isWhitespace }
    }

    static func headerTokens(_ m: ScoreMeta) -> [String: String] {
        var t: [String: String] = ["title": norm(m.title), "artist": norm(m.artist)]
        t["key"] = norm(m.key).replacingOccurrences(of: "1=", with: "")
        t["capo"] = "\(m.capo)"
        t["tempo"] = "\(Int(m.tempo.rounded()))"
        t["time"] = "\(m.timeSignature.beats)/\(m.timeSignature.unit)"
        return t
    }

    struct HeaderCounts {
        var ok: [String: Int] = [:], n: [String: Int] = [:]
        mutating func add(gt: ScoreMeta, pred: ScoreMeta, label: String, verbose: Bool) {
            let g = headerTokens(gt), p = headerTokens(pred)
            for (k, v) in g {
                n[k, default: 0] += 1
                if p[k] == v { ok[k, default: 0] += 1 } else if verbose { print("  [\(label)] header \(k): gt '\(v)' pred '\(p[k] ?? "")'") }
            }
        }
        var line: String {
            let keys = ["title", "artist", "key", "time", "capo", "tempo"]
            let all = keys.map { "\($0) \(ok[$0] ?? 0)/\(n[$0] ?? 0)" }.joined(separator: "  ")
            let tot = keys.reduce(0) { $0 + (ok[$1] ?? 0) }, den = keys.reduce(0) { $0 + (n[$1] ?? 0) }
            return all + String(format: "  | fields %.4f", den == 0 ? 1 : Double(tot) / Double(den))
        }
    }

    struct WMCounts {
        var tp = 0, fp = 0, fn = 0, tn = 0
        var missed: [String] = [], falsePos: [String] = []
        var recall: Double { tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn) }
        var precision: Double { tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp) }
    }

    struct PixelCounts {
        var glyphBefore = 0, glyphKept = 0, residueBefore = 0, residueAfter = 0, pages = 0
        var wmBefore = 0, wmAfter = 0
        var kindBefore: [String: Int] = [:], kindKept: [String: Int] = [:]
        var qrGT = 0, qrHit = 0, qrFalse = 0
    }

    static func boxesDoc(_ path: String) -> (els: [[String: Any]], w: Int, h: Int)? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let els = o["elements"] as? [[String: Any]] else { return nil }
        return (els, o["width"] as? Int ?? 0, o["height"] as? Int ?? 0)
    }

    /// Synth: header + text classification + pixel cleaning over a split directory.
    static func runWatermarkSynth(_ synth: String, maxN: Int, stride: Int, verbose: Bool) -> Int32 {
        let fm = FileManager.default
        var hc = HeaderCounts()
        var wm = WMCounts()
        var px = PixelCounts()
        var n = 0
        for (k, s) in ((try? fm.contentsOfDirectory(atPath: synth)) ?? []).sorted().filter({ $0.hasPrefix("s") }).enumerated() where k % stride == 0 && n < maxN {
            n += 1
            let dir = "\(synth)/\(s)"
            var pages: [(img: GrayImage, ocr: [OCRToken], boxes: (els: [[String: Any]], w: Int, h: Int))] = []
            for p in 0..<12 where fm.fileExists(atPath: "\(dir)/page-\(p).pgm") {
                guard let img = try? GrayImage.readPGM(path: "\(dir)/page-\(p).pgm"), let b = boxesDoc("\(dir)/page-\(p).boxes.json") else { continue }
                pages.append((img, loadOCR("\(dir)/ocr/page-\(p).ocr.json"), b))
            }
            let repeated = OMRWatermark.repeatedTexts(pages: pages.map { $0.ocr })
            for (pi, pg) in pages.enumerated() {
                let W = Double(pg.img.width), H = Double(pg.img.height)
                var layout = OMRChordsDebug.detectLayout(image: pg.img, ocr: pg.ocr)
                // staff detection may fail on blurry pages: fall back to the ground-truth layout so the text rules are judged on their own
                if layout.firstStaffTop == nil {
                    let sl = pg.boxes.els.filter { $0["label"] as? String == "staff_line" }.compactMap { ($0["bbox"] as? [Double]).map { ($0[1] + $0[3]) / 2 } }.sorted()
                    if sl.count >= 6 { layout = .init(firstStaffTop: sl[0], staffSpacing: sl[1] - sl[0], lastSystemBottom: sl.last! + 12 * (sl[1] - sl[0])) }
                }
                let reasons = OMRChordsDebug.classifyText(width: pg.img.width, height: pg.img.height, ocr: pg.ocr, layout: layout, pageIndex: pi, repeated: repeated[pi])
                let nonScoreBoxes: [(bbox: [Double], text: String, page: Bool)] = pg.boxes.els.compactMap { e in
                    guard (e["nonScore"] as? Bool) == true, let t = e["text"] as? String, let b = e["bbox"] as? [Double] else { return nil }
                    return (b, norm(t), (e["label"] as? String) == "page_number")
                }
                for (ti, t) in pg.ocr.enumerated() {
                    let cx = (t.x + t.width / 2) * W, cy = (t.y + t.height / 2) * H
                    let tn = norm(t.text)
                    // a token is a watermark when it lies in a non-score element box AND its text is part of that element's text
                    let inWM = tn.count >= 1 && nonScoreBoxes.contains { e in
                        if tn.count < 2 && !e.page { return false }
                        guard cx >= e.bbox[0] - 4 && cx <= e.bbox[2] + 4 && cy >= e.bbox[1] - 4 && cy <= e.bbox[3] + 4 else { return false }
                        if e.text.contains(tn) || tn.contains(e.text) { return true }
                        let hits = tn.filter { e.text.contains($0) }.count      // OCR garbles diagonal text: fuzzy character overlap
                        return tn.count >= 3 && Double(hits) >= 0.6 * Double(tn.count)
                    }
                    // tokens that only contain notation glyphs (x, digits) are never watermarks in the GT sense
                    let flagged = reasons[ti] != nil
                    if inWM && flagged { wm.tp += 1 } else if inWM { wm.fn += 1; wm.missed.append("\(s)/p\(pi): \(t.text)") }
                    else if flagged { wm.fp += 1; wm.falsePos.append("\(s)/p\(pi): \(t.text) [\(reasons[ti]!.rawValue)]") } else { wm.tn += 1 }
                }
                // header (page 0 only)
                if pi == 0, let gt = try? ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: "\(dir)/score.agr.json"))) {
                    let hr = OMRChordsDebug.readHeader(width: pg.img.width, height: pg.img.height, ocr: pg.ocr, layout: layout)
                    hc.add(gt: gt.meta, pred: hr.meta, label: s, verbose: verbose)
                }
                // pixels
                let before = OMRChordsDebug.inkMask(pg.img, loose: true)
                let (cleaned, rep) = OMRWatermark.clean(pg.img)
                let after = OMRChordsDebug.inkMask(cleaned, loose: true)
                let beforeStd = OMRChordsDebug.inkMask(pg.img), afterStd = OMRChordsDebug.inkMask(cleaned)
                let w = pg.img.width, h = pg.img.height
                var cover = [Bool](repeating: false, count: w * h)
                var glyph = [Bool](repeating: false, count: w * h)
                var glyphKind = [UInt8](repeating: 0, count: w * h)
                var wmBox = [Bool](repeating: false, count: w * h)
                let kinds = ["tab_cross", "tab_fret", "chord_dot", "jianpu_digit", "lyric_char", "tab_clef"]
                for e in pg.boxes.els {
                    if (e["nonScore"] as? Bool) == true, let b = e["bbox"] as? [Double], b.count == 4, (e["label"] as? String) != "page_number", (e["label"] as? String) != "wm_qr" {
                        for y in max(0, Int(b[1]))..<min(h, Int(b[3]) + 1) { for x in max(0, Int(b[0]))..<min(w, Int(b[2]) + 1) { wmBox[y * w + x] = true } }
                    }
                    guard (e["nonScore"] as? Bool) != true, let b = e["bbox"] as? [Double], b.count == 4 else { continue }
                    let lab = e["label"] as? String ?? ""
                    let pad = lab == "staff_line" || lab == "barline" ? 3 : 2
                    for y in max(0, Int(b[1]) - pad)..<min(h, Int(b[3]) + pad + 1) { for x in max(0, Int(b[0]) - pad)..<min(w, Int(b[2]) + pad + 1) {
                        cover[y * w + x] = true
                        if let ki = kinds.firstIndex(of: lab) { glyph[y * w + x] = true; glyphKind[y * w + x] = UInt8(ki + 1) }
                    } }
                }
                for i in 0..<(w * h) {
                    if glyph[i] && beforeStd[i] != 0 {
                        px.glyphBefore += 1; let k = kinds[Int(glyphKind[i]) - 1]; px.kindBefore[k, default: 0] += 1
                        if afterStd[i] != 0 { px.glyphKept += 1; px.kindKept[k, default: 0] += 1 }
                    }
                    if wmBox[i] && !cover[i] { if before[i] != 0 { px.wmBefore += 1 }; if after[i] != 0 { px.wmAfter += 1 } }
                    if !cover[i] { if before[i] != 0 { px.residueBefore += 1 }; if after[i] != 0 { px.residueAfter += 1 } }
                }
                px.pages += 1
                let qrs = pg.boxes.els.filter { $0["label"] as? String == "wm_qr" }.compactMap { $0["bbox"] as? [Double] }
                px.qrGT += qrs.count
                for q in qrs where rep.qrBoxes.contains(where: { r in
                    let ix = max(Double(r[0]), q[0]), iy = max(Double(r[1]), q[1]), ix2 = min(Double(r[2]), q[2]), iy2 = min(Double(r[3]), q[3])
                    return ix2 > ix && iy2 > iy && (ix2 - ix) * (iy2 - iy) >= 0.4 * (q[2] - q[0]) * (q[3] - q[1]) }) { px.qrHit += 1 }
                for r in rep.qrBoxes where verbose { print("   [\(s)/p\(pi)] qr box \(r) gt \(qrs.map { $0.map { Int($0) } })") }
                for r in rep.qrBoxes where !qrs.contains(where: { q in
                    max(Double(r[0]), q[0]) < min(Double(r[2]), q[2]) && max(Double(r[1]), q[1]) < min(Double(r[3]), q[3]) }) { px.qrFalse += 1 }
            }
        }
        print("HEADER (synth page 0, \(n) scores): " + hc.line)
        print(String(format: "WATERMARK TEXT (OCR tokens): tp %d fp %d fn %d tn %d  recall %.4f precision %.4f", wm.tp, wm.fp, wm.fn, wm.tn, wm.recall, wm.precision))
        for m in wm.missed.prefix(verbose ? 60 : 12) { print("   missed: \(m)") }
        for m in wm.falsePos.prefix(verbose ? 60 : 12) { print("   false+: \(m)") }
        print(String(format: "PIXELS (%d pages): notation glyph ink kept %.4f (%d/%d); non-notation residue ink %d -> %d (%.1f%% removed); QR %d/%d found, %d false",
                     px.pages, px.glyphBefore == 0 ? 1 : Double(px.glyphKept) / Double(px.glyphBefore), px.glyphKept, px.glyphBefore,
                     px.residueBefore, px.residueAfter, px.residueBefore == 0 ? 0 : 100 * Double(px.residueBefore - px.residueAfter) / Double(px.residueBefore),
                     px.qrHit, px.qrGT, px.qrFalse))
        print("   notation kept per kind: " + px.kindBefore.sorted { $0.key < $1.key }.map { String(format: "%@ %.3f", $0.key, Double(px.kindKept[$0.key] ?? 0) / Double($0.value)) }.joined(separator: "  "))
        print(String(format: "   ink inside watermark boxes (outside notation boxes, loose threshold): %d -> %d (%.1f%% removed)", px.wmBefore, px.wmAfter, px.wmBefore == 0 ? 0 : 100 * Double(px.wmBefore - px.wmAfter) / Double(px.wmBefore)))
        return 0
    }

    /// Real pages: header vs GT meta, watermark text recall vs meta.json lists, false positives against GT score text.
    static func runWatermarkReal(images: String, gt: String, ids: Set<String>?, ocrDir: String, verbose: Bool) -> Int32 {
        let fm = FileManager.default
        var hc = HeaderCounts()
        var hit = 0, total = 0, fpTok = 0, flaggedTok = 0, tokens = 0
        for f in ((try? fm.contentsOfDirectory(atPath: images)) ?? []).sorted() where f.hasSuffix(".pgm") {
            let id = String(f.dropLast(4))
            if let ids, !ids.contains(id) { continue }
            guard let score = try? ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: "\(gt)/\(id).agr.json"))),
                  let img = try? GrayImage.readPGM(path: "\(images)/\(f)") else { continue }
            let ocr = loadOCR("\(ocrDir)/\(id).ocr.json")
            let layout = OMRChordsDebug.detectLayout(image: img, ocr: ocr)
            let hr = OMRChordsDebug.readHeader(width: img.width, height: img.height, ocr: ocr, layout: layout)
            hc.add(gt: score.meta, pred: hr.meta, label: id, verbose: verbose)
            let reasons = OMRChordsDebug.classifyText(width: img.width, height: img.height, ocr: ocr, layout: layout)
            // GT score text (title, artist, lyrics, chord names)
            var scoreText = score.meta.title + (score.meta.artist ?? "")
            for sec in score.sections { for l in sec.lines { for m in l.system?.measures ?? [] { for n in m.melody { for v in n.lyrics { scoreText += v } } } } }
            var wmStrings: [String] = []
            if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(gt)/\(id).meta.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let l = o["watermarks"] as? [String] { wmStrings = l }
            let descriptive = ["QR code", "logo", "watermark", "banner", "icon", "decoration", "ornament", "photo", "noise", "fragments", "marks", "box", "analysis", "parenthes", "page number", "(page number)", "cropped", "circle"]
            for ws in wmStrings where !descriptive.contains(where: { ws.lowercased().contains($0.lowercased()) }) && ws.count >= 3 {
                let wn = norm(ws)
                total += 1
                var found = false
                for (i, t) in ocr.enumerated() {
                    let tn = norm(t.text)
                    guard tn.count >= 2 else { continue }
                    if (wn.contains(tn) || tn.contains(wn)) && reasons[i] != nil { found = true }
                }
                if found { hit += 1 } else if verbose { print("  [\(id)] watermark text not flagged: \(ws)") }
            }
            for (i, t) in ocr.enumerated() {
                tokens += 1
                guard let r = reasons[i] else { continue }
                flaggedTok += 1
                let tn = norm(t.text)
                if tn.count >= 2, norm(scoreText).contains(tn) { fpTok += 1; if verbose { print("  [\(id)] FALSE+ \(t.text) [\(r.rawValue)]") } }
            }
        }
        print("HEADER (real): " + hc.line)
        print(String(format: "WATERMARK TEXT (real): GT text watermarks flagged %d/%d = %.4f; flagged tokens %d/%d, of which overlapping GT score text %d", hit, total, total == 0 ? 1 : Double(hit) / Double(total), flaggedTok, tokens, fpTok))
        return 0
    }

    static func run(_ args: [String]) -> Int32 {
        if args.first == "clean", args.count >= 3 {
            // agr-tool omr-chords clean in.pgm out.pgm [--no-qr]
            guard let img = try? GrayImage.readPGM(path: args[1]) else { print("cannot read"); return 1 }
            let (out, rep) = OMRWatermark.clean(img, removeQR: !args.contains("--no-qr"))
            try? out.writePGM(path: args[2])
            print("bg \(rep.background) ink \(rep.ink) overlay px \(rep.overlayPixels) color px \(rep.colorPixels) qr \(rep.qrBoxes)")
            return 0
        }
        if args.first == "watermark" {
            var synth: String?, images: String?, gt: String?, ids: Set<String>?, ocrDir: String?
            var maxN = Int.max, stride = 1, verbose = false
            var i = 1
            while i < args.count {
                func val() -> String { i += 1; return i < args.count ? args[i] : "" }
                switch args[i] {
                case "--synth": synth = val()
                case "--real": images = val()
                case "--gt": gt = val()
                case "--ocr": ocrDir = val()
                case "--ids": ids = Set(val().split(separator: ",").map(String.init))
                case "--max": maxN = Int(val()) ?? maxN
                case "--stride": stride = Int(val()) ?? 1
                case "-v": verbose = true
                default: break
                }
                i += 1
            }
            if let synth { return runWatermarkSynth(synth, maxN: maxN, stride: stride, verbose: verbose) }
            if let images, let gt { return runWatermarkReal(images: images, gt: gt, ids: ids, ocrDir: ocrDir ?? "\(images)/ocr", verbose: verbose) }
            print("usage: agr-tool omr-chords watermark --synth dir | --real images --gt gtdir [--ids a,b] [-v]")
            return 2
        }
        var input: String?, ocr: String?, gt: String?, boxes: String?, meta: String?
        var synth: String?, real: String?, ids: Set<String>?
        var maxN = Int.max, stride = 1, verbose = false, worst = 6, useOracle = false, useClean = false, useBands = false, seqMode = false
        var i = 0
        while i < args.count {
            let a = args[i]
            func val() -> String { i += 1; return i < args.count ? args[i] : "" }
            switch a {
            case "--ocr": ocr = val()
            case "--gt": gt = val()
            case "--boxes": boxes = val()
            case "--meta": meta = val()
            case "--synth": synth = val()
            case "--real": real = val()
            case "--ids": ids = Set(val().split(separator: ",").map(String.init))
            case "--max": maxN = Int(val()) ?? maxN
            case "--stride": stride = Int(val()) ?? 1
            case "--worst": worst = Int(val()) ?? 6
            case "-v": verbose = true
            case "--oracle": useOracle = true
            case "--clean": useClean = true
            case "--bands": useBands = true
            case "--seq": seqMode = true
            default: input = a
            }
            i += 1
        }
        _ = meta
        let fm = FileManager.default
        var total = Counts(), totalSeq = Counts()
        var perPage: [(String, Counts)] = []
        var byStyle: [String: Counts] = [:]
        var ms = 0.0
        func evalPage(_ pgm: String, _ ocrPath: String?, _ g: [GTChord], style: String, label: String, boxesPath: String? = nil, bands: [(Double, Double)]? = nil) {
            guard let img = try? GrayImage.readPGM(path: pgm) else { print("cannot read \(pgm)"); return }
            let t0 = Date()
            let r = OMRChordsDebug.readChords(image: img, ocr: loadOCR(ocrPath), oracle: useOracle ? boxesPath.map(oracleFromBoxes) : nil, clean: useClean, bands: bands)
            ms += Date().timeIntervalSince(t0) * 1000
            let c = score(gt: g, pred: r, verbose: verbose && !seqMode, label: label)
            totalSeq.add(seqScore(gt: g, pred: r, verbose: verbose && seqMode, label: label))
            total.add(c); perPage.append((label, c)); byStyle[style, default: Counts()].add(c)
        }
        if let synth {
            var n = 0
            for (k, s) in ((try? fm.contentsOfDirectory(atPath: synth)) ?? []).sorted().filter({ $0.hasPrefix("s") }).enumerated() where k % stride == 0 && n < maxN {
                n += 1
                let dir = "\(synth)/\(s)"
                var style = ""
                if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { style = o["style"] as? String ?? "" }
                for p in 0..<12 where fm.fileExists(atPath: "\(dir)/page-\(p).pgm") {
                    evalPage("\(dir)/page-\(p).pgm", "\(dir)/ocr/page-\(p).ocr.json", gtFromBoxes("\(dir)/page-\(p).boxes.json"), style: style, label: "\(s)/p\(p)", boxesPath: "\(dir)/page-\(p).boxes.json")
                }
            }
        } else if let real, let gt {
            let ocrDir = ocr ?? "\(real)/ocr"
            for f in ((try? fm.contentsOfDirectory(atPath: real)) ?? []).sorted() where f.hasSuffix(".pgm") {
                let id = String(f.dropLast(4))
                if let ids, !ids.contains(id) { continue }
                guard fm.fileExists(atPath: "\(gt)/\(id).agr.json") else { continue }
                var bands: [(Double, Double)]?
                if useBands, let img = try? GrayImage.readPGM(path: "\(real)/\(f)") { bands = bandsFromScore("\(gt)/\(id).agr.json", height: img.height) }
                evalPage("\(real)/\(f)", "\(ocrDir)/\(id).ocr.json", gtFromScore("\(gt)/\(id).agr.json"), style: "real", label: id, bands: bands)
            }
        } else if let input {
            let g = boxes.map(gtFromBoxes) ?? gt.map(gtFromScore) ?? []
            evalPage(input, ocr, g, style: "page", label: (input as NSString).lastPathComponent, boxesPath: boxes)
        } else { print("usage: agr-tool omr-chords page.pgm --ocr f.json [--gt gt.agr.json|--boxes b.json] | --synth dir | --real dir --gt dir"); return 2 }
        print("TOTAL  " + total.line)
        print("SEQ    " + totalSeq.line + "   (measure/beat-independent, ordered per system)")
        for (s, c) in byStyle.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-14@ ", s as NSString) + c.line) }
        let bad = perPage.filter { $0.1.tp < $0.1.gt || $0.1.pred > $0.1.tp || $0.1.shapeOK < $0.1.shapeGT }.sorted { ($0.1.gt - $0.1.tp) + ($0.1.pred - $0.1.tp) > ($1.1.gt - $1.1.tp) + ($1.1.pred - $1.1.tp) }
        for (l, c) in bad.prefix(worst) { print("  worst \(l): " + c.line) }
        print(String(format: "pages %d  %.0f ms/page", perPage.count, ms / Double(max(1, perPage.count))))
        return 0
    }
}
