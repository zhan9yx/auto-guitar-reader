import AGRCore
import Foundation

enum OMRCommand {
    static func loadOCR(_ path: String?) -> [OCRToken] {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let t = try? JSONDecoder().decode([OCRToken].self, from: d) else { return [] }
        return t
    }

    static func run(_ args: [String]) -> Int32 {
        if args.first == "debug", args.count > 1 {
            do {
                let img = try GrayImage.readPGM(path: args[1])
                print(OMRDebug.stages(img))
                return 0
            } catch { print("error: \(error)"); return 1 }
        }
        if args.first == "dump-clean", args.count > 2 {
            do { try OMRDebug.dumpClean(try GrayImage.readPGM(path: args[1]), path: args[2]); return 0 } catch { print(error); return 1 }
        }
        if args.first == "train", args.count >= 3 {
            // agr-tool omr train <synth split dir> <out.tsv> [maxScores]
            let dir = args[1]
            let maxScores = args.count > 3 ? Int(args[3]) ?? 100000 : 100000
            var lines: [String] = []
            let fm = FileManager.default
            let scores = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().prefix(maxScores)
            for s in scores {
                for p in 0..<6 {
                    let base = "\(dir)/\(s)/page-\(p)"
                    if fm.fileExists(atPath: base + ".pgm") { lines += OMRTraining.samples(pgmPath: base + ".pgm", boxesPath: base + ".boxes.json") }
                }
            }
            try? lines.joined(separator: "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
            print("samples \(lines.count)")
            return 0
        }
        var input: String?, ocr: String?, out: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--ocr": ocr = args[i + 1]; i += 2
            case "-o": out = args[i + 1]; i += 2
            default: input = args[i]; i += 1
            }
        }
        guard let input else { print("usage: agr-tool omr page.pgm [--ocr page.ocr.json] [-o out.agr.json]"); return 2 }
        do {
            let img = try GrayImage.readPGM(path: input)
            let (score, report) = OMREngine.recognize(pages: [(img, loadOCR(ocr), (input as NSString).lastPathComponent)])
            let data = try ScoreCoding.encode(score)
            if let out { try data.write(to: URL(fileURLWithPath: out)) } else { FileHandle.standardOutput.write(data) }
            FileHandle.standardError.write(Data("systems \(report.systemCount) issues \(report.issues.count) \(Int(report.milliseconds)) ms\n".utf8))
            return 0
        } catch { print("error: \(error)"); return 1 }
    }
}
