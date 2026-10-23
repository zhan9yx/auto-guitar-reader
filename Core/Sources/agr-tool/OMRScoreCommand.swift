import AGRCore
import Foundation

/// `agr-tool omr-score --gt a.agr.json --pred b.agr.json [--json]` — compares a predicted AGR v2 score with the
/// ground truth (see `OMRScorer`); prints a table or, with `--json`, the JSON report.
enum OMRScoreCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var gt: String?, pred: String?, json = false, metric = OMRMetric.v2, marks: [String] = []
        var i = 0
        func fail(_ m: String) -> Int32 {
            FileHandle.standardError.write(Data("agr-tool omr-score: \(m)\nusage: agr-tool omr-score --gt a.agr.json --pred b.agr.json [--json] [--metric v1|v2] [--meta gt.meta.json]\n".utf8))
            return 2
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--gt", "--pred":
                guard i + 1 < arguments.count else { return fail("missing value for \(arguments[i])") }
                if arguments[i] == "--gt" { gt = arguments[i + 1] } else { pred = arguments[i + 1] }
                i += 2
            case "--json": json = true; i += 1
            case "--metric":
                guard i + 1 < arguments.count, let m = OMRMetric(rawValue: arguments[i + 1]) else { return fail("--metric must be v1 or v2") }
                metric = m; i += 2
            case "--meta":  // GT meta.json: `watermarks` feed the v2 cleanliness category
                guard i + 1 < arguments.count else { return fail("missing value for --meta") }
                if let d = try? Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { marks = o["watermarks"] as? [String] ?? [] }
                i += 2
            default: return fail("unexpected argument \(arguments[i])")
            }
        }
        guard let gt, let pred else { return fail("--gt and --pred are required") }
        do {
            let g = try ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: gt)))
            let p = try ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: pred)))
            let report = OMRScorer.compare(groundTruth: g, predicted: p, metric: metric, watermarks: marks)
            if json {
                FileHandle.standardOutput.write(try report.jsonData())
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(report.summary)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("agr-tool omr-score: \(error)\n".utf8))
            return 1
        }
    }
}
