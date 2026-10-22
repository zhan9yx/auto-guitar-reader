import AGRCore
import Foundation

/// `agr-tool omr-score --gt a.agr.json --pred b.agr.json [--json]` — compares a predicted AGR v2 score with the
/// ground truth (see `OMRScorer`); prints a table or, with `--json`, the JSON report.
enum OMRScoreCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var gt: String?, pred: String?, json = false
        var i = 0
        func fail(_ m: String) -> Int32 {
            FileHandle.standardError.write(Data("agr-tool omr-score: \(m)\nusage: agr-tool omr-score --gt a.agr.json --pred b.agr.json [--json]\n".utf8))
            return 2
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--gt", "--pred":
                guard i + 1 < arguments.count else { return fail("missing value for \(arguments[i])") }
                if arguments[i] == "--gt" { gt = arguments[i + 1] } else { pred = arguments[i + 1] }
                i += 2
            case "--json": json = true; i += 1
            default: return fail("unexpected argument \(arguments[i])")
            }
        }
        guard let gt, let pred else { return fail("--gt and --pred are required") }
        do {
            let g = try ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: gt)))
            let p = try ScoreCoding.decode(Data(contentsOf: URL(fileURLWithPath: pred)))
            let report = OMRScorer.compare(groundTruth: g, predicted: p)
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
