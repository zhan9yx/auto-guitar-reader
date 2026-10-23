import AGRCore
import Foundation

/// `agr-tool omr eval --synth <split dir> [--max N] [--stride K] [--style S] [--json out.json] [--no-ocr] [--worst N]`
/// `agr-tool omr eval --images <dir> --gt <dir> [--ocr <dir>] [--ids real-000,real-002] [--metric v1|v2|both] [--json out.json]`
/// Runs the OMR engine over a dataset and scores it with OMRScorer. Prints, per category, pooled (all counts summed)
/// and macro (mean over pages) precision / recall / accuracy, the weighted groups, and a per-page table.
/// Output is deterministic given identical recognizer output (timing goes to stderr). The engine itself is not
/// deterministic across processes (Swift hash seeding): repeat the command in a shell loop and average, e.g.
///   for r in 1 2 3; do agr-tool omr eval --images pgm --gt gt --ocr ocr > run.$r.txt; done
/// (`SWIFT_DETERMINISTIC_HASHING=1` pins the seed for a reproducible single run).
/// `--metric v1` selects the legacy metric (default v2, see OMRScorer); `--metric both` scores the SAME recognizer output
/// with v1 and v2 (v1 report first), which removes engine run-to-run noise from a v1 vs v2 comparison.
enum OMREval {
    struct Item { var name: String; var style: String; var pages: [String]; var gt: String; var meta: String? = nil }

    static func run(_ args: [String]) -> Int32 {
        var synth: String?, images: String?, gt: String?, json: String?
        var maxN = Int.max, stride = 1, useOCR = true
        var style: String?, ids: Set<String>?, ocrDir: String?, metrics = [OMRMetric.v2]
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--synth": synth = args[i + 1]; i += 2
            case "--images": images = args[i + 1]; i += 2
            case "--gt": gt = args[i + 1]; i += 2
            case "--json": json = args[i + 1]; i += 2
            case "--max": maxN = Int(args[i + 1]) ?? maxN; i += 2
            case "--stride": stride = Int(args[i + 1]) ?? 1; i += 2
            case "--worst": i += 2  // ignored (per-page table is always printed)
            case "--style": style = args[i + 1]; i += 2
            case "--ids": ids = Set(args[i + 1].split(separator: ",").map(String.init)); i += 2
            case "--ocr": ocrDir = args[i + 1]; i += 2
            case "--metric":
                let ms = args[i + 1] == "both" ? ["v1", "v2"] : [args[i + 1]]
                guard ms.allSatisfy({ OMRMetric(rawValue: $0) != nil }) else { print("--metric must be v1, v2 or both"); return 2 }
                metrics = ms.compactMap { OMRMetric(rawValue: $0) }; i += 2
            case "--no-ocr": useOCR = false; i += 1
            default: i += 1
            }
        }
        var items: [Item] = []
        let fm = FileManager.default
        if let synth {
            for s in ((try? fm.contentsOfDirectory(atPath: synth)) ?? []).sorted() where s.hasPrefix("s") {
                let dir = "\(synth)/\(s)"
                var pages: [String] = []
                for p in 0..<12 where fm.fileExists(atPath: "\(dir)/page-\(p).pgm") { pages.append("\(dir)/page-\(p).pgm") }
                var st = ""
                if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json")),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { st = o["style"] as? String ?? "" }
                if let style, st != style { continue }
                items.append(Item(name: s, style: st, pages: pages, gt: "\(dir)/score.agr.json"))
            }
        } else if let images, let gt {
            for f in ((try? fm.contentsOfDirectory(atPath: images)) ?? []).sorted() where f.hasSuffix(".pgm") {
                let id = String(f.dropLast(4))
                if let ids, !ids.contains(id) { continue }
                guard fm.fileExists(atPath: "\(gt)/\(id).agr.json") else { continue }
                items.append(Item(name: id, style: "real", pages: ["\(images)/\(f)"], gt: "\(gt)/\(id).agr.json", meta: "\(gt)/\(id).meta.json"))
            }
        } else { print("usage: agr-tool omr eval --synth dir | --images dir --gt dir"); return 2 }
        items = items.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        if items.count > maxN { items = Array(items.prefix(maxN)) }

        func counts(_ r: OMRScoreReport, _ k: String) -> CategoryScore {
            switch k {
            case "header": return r.header
            case "chords": return r.chords
            case "chordShapes": return r.chordShapes
            case "tab": return r.tab
            case "tabEvents": return r.tabEvents
            case "strokes": return r.strokes
            case "rhythm": return r.rhythm
            case "melody": return r.melody
            case "barlines": return r.barlines
            case "measures": return r.measures
            case "cleanliness": return r.cleanliness
            default: return r.lyrics.counts
            }
        }
        var scored: [(name: String, style: String, g: Score, p: Score, marks: [String])] = []
        var ms = 0.0, pagesTotal = 0
        for it in items {
            guard let gtData = try? Data(contentsOf: URL(fileURLWithPath: it.gt)), let g = try? ScoreCoding.decode(gtData) else { continue }
            var inputs: [OMREngine.PageInput] = []
            for p in it.pages {
                guard let img = try? GrayImage.readPGM(path: p) else { continue }
                var toks: [OCRToken] = []
                if useOCR {
                    let dir = ocrDir ?? ((p as NSString).deletingLastPathComponent + "/ocr")
                    let stem = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                    toks = OMRCommand.loadOCR("\(dir)/\(stem).ocr.json")
                }
                inputs.append((img, toks, (p as NSString).lastPathComponent))
            }
            let (score, report) = OMREngine.recognize(pages: inputs)
            ms += report.milliseconds; pagesTotal += inputs.count
            var marks: [String] = []
            if let mp = it.meta, let d = try? Data(contentsOf: URL(fileURLWithPath: mp)),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { marks = o["watermarks"] as? [String] ?? [] }
            scored.append((it.name, it.style, g, score, marks))
        }
        FileHandle.standardError.write(Data(String(format: "mean %.0f ms/page\n", ms / Double(max(1, pagesTotal))).utf8))

        for metric in metrics {
            let cats = ["header", "chords", "chordShapes", "tab", "tabEvents", "strokes", "rhythm", "melody", "barlines", "measures"]
            + (metric == .v2 ? ["cleanliness"] : [])
            let reports: [(name: String, style: String, r: OMRScoreReport)] = scored.map {
                ($0.name, $0.style, OMRScorer.compare(groundTruth: $0.g, predicted: $0.p, metric: metric, watermarks: $0.marks))
            }
            // Pooled counts and macro (mean over pages where the category is non-empty).
            var pooled: [String: CategoryScore] = [:]
            var macro: [String: (p: Double, r: Double, a: Double, n: Int)] = [:]
            var lyr = LyricsScore()
            var macroLyr: (a: Double, n: Int) = (0, 0)
            for (_, _, r) in reports {
                for k in cats + ["lyrics"] {
                    let c = counts(r, k)
                    var x = pooled[k] ?? CategoryScore(); x.add(c); pooled[k] = x
                    let empty = k == "lyrics" ? (r.lyrics.groundTruthChars == 0 && r.lyrics.predictedChars == 0) : c.isEmpty
                    if !empty {
                        var m = macro[k] ?? (0, 0, 0, 0)
                        m.p += c.precision; m.r += c.recall; m.a += k == "lyrics" ? r.lyrics.accuracy : c.accuracy; m.n += 1
                        macro[k] = m
                    }
                }
                lyr.groundTruthChars += r.lyrics.groundTruthChars; lyr.predictedChars += r.lyrics.predictedChars; lyr.editDistance += r.lyrics.editDistance
                if r.lyrics.groundTruthChars + r.lyrics.predictedChars > 0 { macroLyr.a += r.lyrics.accuracy; macroLyr.n += 1 }
            }
            let weights = metric == .v2 ? OMRScorer.weightsV2 : OMRScorer.weights
            func acc(_ keys: [String]) -> Double? {
                var t = CategoryScore(); for k in keys { if let c = pooled[k] { t.add(c) } }
                return t.isEmpty ? nil : t.accuracy
            }
            let lyrAcc: Double? = lyr.groundTruthChars == 0 && lyr.predictedChars == 0 ? nil : max(0, 1 - Double(lyr.editDistance) / Double(max(1, lyr.groundTruthChars)))
            let groupKeys = ["tab", "melody", "lyrics", "chords", "rhythm", "barlines", "header"] + (metric == .v2 ? ["cleanliness"] : [])
            let groupAcc: [String: Double?] = [
                "tab": acc(["tab", "strokes"]), "melody": acc(["melody"]), "lyrics": lyrAcc, "chords": acc(["chords", "chordShapes"]),
                "rhythm": acc(["rhythm"]), "barlines": acc(["barlines", "measures"]), "header": acc(["header"]), "cleanliness": acc(["cleanliness"]),
            ]
            let groups: [(String, Double, Double?)] = groupKeys.map { ($0, weights[$0] ?? 0, groupAcc[$0] ?? nil) }
            let wsum = groups.compactMap { $0.2 == nil ? nil : $0.1 }.reduce(0, +)
            let overall = groups.reduce(0.0) { $0 + ($1.2 ?? 0) * $1.1 } / max(wsum, 1e-9)
            let meanPage = reports.map { $0.r.overall }.reduce(0, +) / Double(max(1, reports.count))
            func pct(_ x: Double) -> String { String(format: "%6.2f", x * 100) }

            var out = "metric \(metric.rawValue)  pages \(pagesTotal) scores \(reports.count)\n"
            out += "category        tp    fp    fn |  pooled P      R    acc | macro  P      R    acc  (pages)\n"
            for k in cats + ["lyrics"] {
                guard let c = pooled[k] else { continue }
                let m = macro[k]
                let mm = m.map { "\(pct($0.p / Double($0.n))) \(pct($0.r / Double($0.n))) \(pct($0.a / Double($0.n)))  (\($0.n))" } ?? "     -      -      -  (0)"
                if k == "lyrics" {
                    out += "lyrics gt \(lyr.groundTruthChars) pred \(lyr.predictedChars) edit \(lyr.editDistance)".padding(toLength: 36, withPad: " ", startingAt: 0)
                        + "| \(pct(c.precision)) \(pct(c.recall)) \(pct(lyrAcc ?? 1)) | \(mm)\n"
                } else {
                    out += k.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: " %5d %5d %5d | ", c.tp, c.fp, c.fn)
                        + "\(pct(c.precision)) \(pct(c.recall)) \(pct(c.isEmpty ? 1 : c.accuracy)) | \(mm)\n"
                }
            }
            out += "groups (weight, pooled acc, macro acc):\n"
            for g in groups {
                // macro group accuracy = mean of per-page group accuracies over pages where the group is included
                let vals = reports.compactMap { $0.r.groups[g.0] }.filter { $0.included }.map(\.accuracy)
                let mac = vals.isEmpty ? "     -" : pct(vals.reduce(0, +) / Double(vals.count))
                out += String(format: "  group %-11@ w %.2f  pooled %@  macro %@\n", g.0 as NSString, g.1, (g.2.map { pct($0) } ?? "     -") as NSString, mac as NSString)
            }
            out += "OVERALL pooled \(String(format: "%.2f", overall * 100))%   mean-per-page \(String(format: "%.2f", meanPage * 100))%\n"
            var byStyle: [String: [Double]] = [:]
            for (_, s, r) in reports { byStyle[s, default: []].append(r.overall) }
            for (s, v) in byStyle.sorted(by: { $0.key < $1.key }) { out += String(format: "  style %-14@ n %3d  mean %.2f%%\n", s as NSString, v.count, v.reduce(0, +) / Double(v.count) * 100) }
            out += "per page (overall and group accuracy %):\n"
            out += "  page          overall    tab  melody lyrics chords rhythm  barl  header clean\n"
            for (n, _, r) in reports {
                func g(_ k: String) -> String { r.groups[k].flatMap { $0.included ? pct($0.accuracy) : nil } ?? "     -" }
                out += "  " + n.padding(toLength: 12, withPad: " ", startingAt: 0) + "  \(pct(r.overall))  \(g("tab"))  \(g("melody"))  \(g("lyrics"))  \(g("chords"))  \(g("rhythm"))  \(g("barlines"))  \(g("header"))  \(g("cleanliness"))\n"
            }
            print(out)
            if let json = json.map({ metrics.count > 1 ? $0 + "." + metric.rawValue : $0 }) {
                var d: [String: Any] = ["metric": metric.rawValue, "overallPooled": overall, "meanPerPage": meanPage, "pages": pagesTotal]
                for (k, c) in pooled {
                    var e: [String: Any] = ["tp": c.tp, "fp": c.fp, "fn": c.fn, "precision": c.precision, "recall": c.recall, "acc": c.accuracy]
                    if let m = macro[k], m.n > 0 { e["macroPrecision"] = m.p / Double(m.n); e["macroRecall"] = m.r / Double(m.n); e["macroAcc"] = m.a / Double(m.n); e["pages"] = m.n }
                    d["cat." + k] = e
                }
                for g in groups { if let a = g.2 { d["group." + g.0] = a } }
                d["perPage"] = reports.map { ["page": $0.name, "overall": $0.r.overall] as [String: Any] }
                if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: json)) }
            }
        }
        return 0
    }
}
