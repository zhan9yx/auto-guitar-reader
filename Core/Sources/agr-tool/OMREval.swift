import AGRCore
import Foundation

/// `agr-tool omr eval --synth <split dir> [--max N] [--stride K] [--style S] [--json out.json] [--no-ocr] [--worst N]`
/// `agr-tool omr eval --images <dir> --gt <dir> [--ids real-000,real-002] [--json out.json]`
/// Runs the OMR engine over a dataset and scores it with OMRScorer (pooled per-category counts + group accuracies).
enum OMREval {
    struct Item { var name: String; var style: String; var pages: [String]; var gt: String }

    static func run(_ args: [String]) -> Int32 {
        var synth: String?, images: String?, gt: String?, json: String?
        var maxN = Int.max, stride = 1, worst = 8, useOCR = true
        var style: String?, ids: Set<String>?, ocrDir: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--synth": synth = args[i + 1]; i += 2
            case "--images": images = args[i + 1]; i += 2
            case "--gt": gt = args[i + 1]; i += 2
            case "--json": json = args[i + 1]; i += 2
            case "--max": maxN = Int(args[i + 1]) ?? maxN; i += 2
            case "--stride": stride = Int(args[i + 1]) ?? 1; i += 2
            case "--worst": worst = Int(args[i + 1]) ?? 8; i += 2
            case "--style": style = args[i + 1]; i += 2
            case "--ids": ids = Set(args[i + 1].split(separator: ",").map(String.init)); i += 2
            case "--ocr": ocrDir = args[i + 1]; i += 2
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
                items.append(Item(name: id, style: "real", pages: ["\(images)/\(f)"], gt: "\(gt)/\(id).agr.json"))
            }
        } else { print("usage: agr-tool omr eval --synth dir | --images dir --gt dir"); return 2 }
        items = items.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
        if items.count > maxN { items = Array(items.prefix(maxN)) }

        var pooled: [String: CategoryScore] = [:]
        var lyr = LyricsScore()
        var perPage: [(String, String, Double)] = []
        var byStyle: [String: [Double]] = [:]
        var ms = 0.0, pagesTotal = 0
        var flagged = (flaggedPages: 0, errPages: 0)
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
            let r = OMRScorer.compare(groundTruth: g, predicted: score)
            func add(_ k: String, _ c: CategoryScore) { var x = pooled[k] ?? CategoryScore(); x.tp += c.tp; x.fp += c.fp; x.fn += c.fn; pooled[k] = x }
            add("header", r.header); add("chords", r.chords); add("chordShapes", r.chordShapes); add("tab", r.tab)
            add("tabEvents", r.tabEvents); add("strokes", r.strokes); add("rhythm", r.rhythm); add("melody", r.melody)
            add("barlines", r.barlines); add("measures", r.measures)
            lyr.groundTruthChars += r.lyrics.groundTruthChars; lyr.predictedChars += r.lyrics.predictedChars; lyr.editDistance += r.lyrics.editDistance
            perPage.append((it.name, it.style, r.overall))
            byStyle[it.style, default: []].append(r.overall)
            if r.overall < 0.999 { flagged.errPages += 1; if !report.issues.isEmpty { flagged.flaggedPages += 1 } }
        }
        func acc(_ keys: [String]) -> Double? {
            var t = CategoryScore(); for k in keys { if let c = pooled[k] { t.tp += c.tp; t.fp += c.fp; t.fn += c.fn } }
            return t.isEmpty ? nil : t.accuracy
        }
        var groups: [(String, Double, Double?)] = [
            ("tab", 0.30, acc(["tab", "strokes"])), ("melody", 0.20, acc(["melody"])),
            ("lyrics", 0.20, lyr.groundTruthChars == 0 && lyr.predictedChars == 0 ? nil : max(0, 1 - Double(lyr.editDistance) / Double(max(1, lyr.groundTruthChars)))),
            ("chords", 0.15, acc(["chords", "chordShapes"])), ("rhythm", 0.05, acc(["rhythm"])),
            ("barlines", 0.05, acc(["barlines", "measures"])), ("header", 0.05, acc(["header"])),
        ]
        groups = groups.map { ($0.0, $0.1, $0.2) }
        let wsum = groups.compactMap { $0.2 == nil ? nil : $0.1 }.reduce(0, +)
        let overall = groups.reduce(0.0) { $0 + ($1.2 ?? 0) * $1.1 } / max(wsum, 1e-9)
        var out = "pages \(pagesTotal) scores \(perPage.count)  mean \(String(format: "%.0f", ms / Double(max(1, pagesTotal)))) ms/page\n"
        for k in ["header", "chords", "chordShapes", "tab", "tabEvents", "strokes", "rhythm", "melody", "barlines", "measures"] {
            if let c = pooled[k] { out += String(format: "%-12@ tp %5d fp %5d fn %5d  acc %6.2f%%\n", k as NSString, c.tp, c.fp, c.fn, c.accuracy * 100) }
        }
        out += String(format: "lyrics       gt %d pred %d edit %d  acc %.2f%%\n", lyr.groundTruthChars, lyr.predictedChars, lyr.editDistance, (1 - lyr.cer) * 100)
        for g in groups { out += String(format: "  group %-8@ w %.2f  %@\n", g.0 as NSString, g.1, g.2.map { String(format: "%6.2f%%", $0 * 100) } ?? "-") }
        let meanPage = perPage.map { $0.2 }.reduce(0, +) / Double(max(1, perPage.count))
        out += String(format: "OVERALL pooled %.2f%%   mean-per-page %.2f%%\n", overall * 100, meanPage * 100)
        for (s, v) in byStyle.sorted(by: { $0.key < $1.key }) { out += String(format: "  style %-14@ n %3d  mean %.2f%%\n", s as NSString, v.count, v.reduce(0, +) / Double(v.count) * 100) }
        out += "worst: " + perPage.sorted { $0.2 < $1.2 }.prefix(worst).map { "\($0.0)(\($0.1)) \(String(format: "%.1f", $0.2 * 100))" }.joined(separator: ", ") + "\n"
        print(out)
        if let json {
            var d: [String: Any] = ["overallPooled": overall, "meanPerPage": meanPage, "pages": pagesTotal, "msPerPage": ms / Double(max(1, pagesTotal))]
            for (k, c) in pooled { d["cat." + k] = ["tp": c.tp, "fp": c.fp, "fn": c.fn, "acc": c.accuracy] }
            for g in groups { if let a = g.2 { d["group." + g.0] = a } }
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: json)) }
        }
        return 0
    }
}
