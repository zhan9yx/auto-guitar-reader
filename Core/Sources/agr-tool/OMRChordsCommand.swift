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

    static func run(_ args: [String]) -> Int32 {
        var input: String?, ocr: String?, gt: String?, boxes: String?, meta: String?
        var synth: String?, real: String?, ids: Set<String>?
        var maxN = Int.max, stride = 1, verbose = false, worst = 6, useOracle = false
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
            default: input = a
            }
            i += 1
        }
        _ = meta
        let fm = FileManager.default
        var total = Counts()
        var perPage: [(String, Counts)] = []
        var byStyle: [String: Counts] = [:]
        var ms = 0.0
        func evalPage(_ pgm: String, _ ocrPath: String?, _ g: [GTChord], style: String, label: String, boxesPath: String? = nil) {
            guard let img = try? GrayImage.readPGM(path: pgm) else { print("cannot read \(pgm)"); return }
            let t0 = Date()
            let r = OMRChordsDebug.readChords(image: img, ocr: loadOCR(ocrPath), oracle: useOracle ? boxesPath.map(oracleFromBoxes) : nil)
            ms += Date().timeIntervalSince(t0) * 1000
            let c = score(gt: g, pred: r, verbose: verbose, label: label)
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
                evalPage("\(real)/\(f)", "\(ocrDir)/\(id).ocr.json", gtFromScore("\(gt)/\(id).agr.json"), style: "real", label: id)
            }
        } else if let input {
            let g = boxes.map(gtFromBoxes) ?? gt.map(gtFromScore) ?? []
            evalPage(input, ocr, g, style: "page", label: (input as NSString).lastPathComponent, boxesPath: boxes)
        } else { print("usage: agr-tool omr-chords page.pgm --ocr f.json [--gt gt.agr.json|--boxes b.json] | --synth dir | --real dir --gt dir"); return 2 }
        print("TOTAL  " + total.line)
        for (s, c) in byStyle.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-14@ ", s as NSString) + c.line) }
        let bad = perPage.filter { $0.1.tp < $0.1.gt || $0.1.pred > $0.1.tp || $0.1.shapeOK < $0.1.shapeGT }.sorted { ($0.1.gt - $0.1.tp) + ($0.1.pred - $0.1.tp) > ($1.1.gt - $1.1.tp) + ($1.1.pred - $1.1.tp) }
        for (l, c) in bad.prefix(worst) { print("  worst \(l): " + c.line) }
        print(String(format: "pages %d  %.0f ms/page", perPage.count, ms / Double(max(1, perPage.count))))
        return 0
    }
}
