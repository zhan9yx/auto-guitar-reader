import AGRCore
import Foundation

/// `agr-tool omr-jianpu page.pgm --ocr page.ocr.json [--gt gt.agr.json] [--ts 4/4] [--quiet]`
/// `agr-tool omr-jianpu-train <split dir> <out.tsv> [maxScores]`
/// `agr-tool omr-jianpu-eval <list.txt> [--quiet]` (list lines: pgm ocr gt)
enum OMRJianpuCommand {
    static func loadOCR(_ path: String?) -> [OCRToken] {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let t = try? JSONDecoder().decode([OCRToken].self, from: d) else { return [] }
        return t
    }

    static func describe(_ n: MelodyNote) -> String {
        var s = n.accidental > 0 ? "#" : n.accidental < 0 ? "b" : ""
        s += "\(n.degree)"
        if n.octave > 0 { s += String(repeating: "'", count: n.octave) } else if n.octave < 0 { s += String(repeating: ",", count: -n.octave) }
        s += "/\(n.duration)"
        if n.tieToNext { s += "~" }
        let l = n.lyrics.joined(separator: "|")
        if !l.isEmpty { s += "[\(l)]" }
        return s
    }

    /// Runs the reader on a page; returns the melody-only score (one line per system) for scoring.
    static func predict(_ pgm: String, ocr: String?, ts: TimeSignature, quiet: Bool) throws -> (Score, [OMRIssue]) {
        let img = try GrayImage.readPGM(path: pgm)
        let systems = OMRJianpuPage.read(image: img, ocr: loadOCR(ocr), timeSignature: ts)
        var lines: [Line] = []
        var issues: [OMRIssue] = []
        for (si, s) in systems.enumerated() {
            if !quiet {
                print("system \(si) (staff y=\(Int(s.staffTop)) row \(Int(s.rowTop))-\(Int(s.rowBottom)) bounds \(s.boundaries.map { Int($0) }) tabBars \(s.tabBars.map { Int($0) }))")
                for (mi, m) in s.measures.enumerated() { print("  m\(mi): " + m.map(describe).joined(separator: " ")) }
                for i in s.issues { print("  ! \(i.kind.rawValue) \(i.message)") }
            }
            issues += s.issues
            lines.append(Line.system(NotationSystem(measures: s.measures.map { NotationMeasure(melody: $0) }), anchor: PageAnchor(page: 0, y: 0, height: 0)))
        }
        var score = Score(meta: ScoreMeta())
        score.meta.timeSignature = ts
        score.sections = [Section(id: "s0", name: "", kind: .other, lines: lines)]
        return (score, issues)
    }

    /// GT restricted to melody + lyrics of the lines belonging to `page` (anchor.page), or all lines.
    static func gtMelody(_ path: String, page: Int?) throws -> Score {
        var g = try ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        var lines: [Line] = []
        for sec in g.sections { for l in sec.lines where l.system != nil {
            if let p = page, let a = l.anchor, a.page != p { continue }
            var ll = l
            ll.system = NotationSystem(measures: l.system!.measures.map { NotationMeasure(beats: nil, melody: $0.melody) })
            lines.append(ll)
        } }
        g.sections = [Section(id: "s0", name: "", kind: .other, lines: lines)]
        return g
    }

    static func parseTS(_ s: String) -> TimeSignature? {
        let p = s.split(separator: "/")
        guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
        return TimeSignature(beats: a, unit: b)
    }

    static func run(_ args: [String]) -> Int32 {
        var pgm: String?, ocr: String?, gt: String?, ts: TimeSignature?, quiet = false
        var page: Int?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--ocr": ocr = args[i + 1]; i += 2
            case "--gt": gt = args[i + 1]; i += 2
            case "--ts": ts = parseTS(args[i + 1]); i += 2
            case "--page": page = Int(args[i + 1]); i += 2
            case "--quiet": quiet = true; i += 1
            default: pgm = args[i]; i += 1
            }
        }
        guard let pgm else { print("usage: agr-tool omr-jianpu page.pgm --ocr page.ocr.json [--gt gt.agr.json] [--ts 4/4] [--page N]"); return 2 }
        do {
            var tsig = ts ?? TimeSignature()
            var gtScore: Score?
            if let gt {
                gtScore = try gtMelody(gt, page: page)
                if ts == nil { tsig = gtScore!.meta.timeSignature }
            }
            let (pred, _) = try predict(pgm, ocr: ocr, ts: tsig, quiet: quiet)
            if let g = gtScore {
                if !quiet {
                    for (li, l) in g.sections.flatMap({ $0.lines }).enumerated() {
                        print("GT line \(li)")
                        for (mi, m) in (l.system?.measures ?? []).enumerated() { print("  g\(mi): " + m.melody.map(describe).joined(separator: " ")) }
                    }
                }
                print(OMRScorer.compare(groundTruth: g, predicted: pred).summary)
            }
            return 0
        } catch { print("error: \(error)"); return 1 }
    }

    static func train(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { print("usage: agr-tool omr-jianpu-train <split dir> <out.tsv> [maxScores]"); return 2 }
        let dir = args[0]
        let maxScores = args.count > 2 ? Int(args[2]) ?? 100000 : 100000
        var lines: [String] = []
        let fm = FileManager.default
        for s in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().prefix(maxScores) {
            for p in 0..<8 {
                let base = "\(dir)/\(s)/page-\(p)"
                if fm.fileExists(atPath: base + ".pgm") { lines += OMRJianpuTraining.samples(pgmPath: base + ".pgm", boxesPath: base + ".boxes.json") }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: args[1], atomically: true, encoding: .utf8)
        print("samples \(lines.count)")
        return 0
    }

    /// Evaluates a list of pages ("pgm ocr gt page" per line); prints the aggregate melody/rhythm/lyrics numbers.
    static func eval(_ args: [String]) -> Int32 {
        guard let list = args.first, let txt = try? String(contentsOfFile: list, encoding: .utf8) else { print("usage: agr-tool omr-jianpu-eval list.txt [--quiet] [--per-page]"); return 2 }
        let perPage = args.contains("--per-page")
        var melody = CategoryScore(), rhythm = CategoryScore()
        var lyr = (gt: 0, edit: 0)
        var issueCount = 0, skipped = 0
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 3 else { continue }
            let page = f.count > 3 ? Int(f[3]) : nil
            do {
                let g = try gtMelody(f[2], page: page)
                let (p, iss) = try predict(f[0], ocr: f[1], ts: g.meta.timeSignature, quiet: true)
                let gtLines = g.sections.reduce(0) { $0 + $1.lines.count }, predLines = p.sections.reduce(0) { $0 + $1.lines.count }
                if gtLines != predLines {
                    skipped += 1
                    if perPage { print("SKIP \(f[0]) systems gt \(gtLines) pred \(predLines)") }
                    continue
                }
                let r = OMRScorer.compare(groundTruth: g, predicted: p)
                melody.tp += r.melody.tp; melody.fp += r.melody.fp; melody.fn += r.melody.fn
                rhythm.tp += r.rhythm.tp; rhythm.fp += r.rhythm.fp; rhythm.fn += r.rhythm.fn
                lyr.gt += r.lyrics.groundTruthChars; lyr.edit += r.lyrics.editDistance
                issueCount += iss.count
                if perPage {
                    print(String(format: "%@  melody %.2f%%  lyricsCER %.2f%%  issues %d", ((f[0] as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + (f[0] as NSString).lastPathComponent, r.melody.f1 * 100, r.lyrics.cer * 100, iss.count))
                }
            } catch { print("error \(f[0]): \(error)") }
        }
        print(String(format: "pages-list %@  melody F1 %.2f%% (tp %d fp %d fn %d)  rhythm F1 %.2f%%  lyrics CER %.2f%% (%d/%d)  issues %d  skipped(system-count mismatch) %d",
                     list, melody.f1 * 100, melody.tp, melody.fp, melody.fn, rhythm.f1 * 100,
                     lyr.gt > 0 ? Double(lyr.edit) / Double(lyr.gt) * 100 : 0, lyr.edit, lyr.gt, issueCount, skipped))
        return 0
    }
}
