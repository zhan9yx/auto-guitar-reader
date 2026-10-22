import AGRCore
import Foundation

/// Offline simulation of the AI assist loop (see docs/AI.md):
///   agr-tool ai-dump-requests --score x.agr.json --issues issues.json --out dir/ [--vision] [--batch N]
///   (a local subagent writes dir/<key>.response.json for every request)
///   agr-tool ai-apply --score x.agr.json --responses dir/ [--out fixed.agr.json] [--dry-run]
enum AICommand {
    struct Index: Codable {
        var version = 1
        var batchSize: Int
        var vision: Bool
        var issues: [AIIssue]
        var requests: [Entry]
        struct Entry: Codable {
            var key: String
            var issueIDs: [String]
            var promptFile: String
            var responseFile: String
        }
    }

    struct Report: Codable {
        var applied: [AppliedFix]
        var rejected: [RejectedFix]
        var unresolvedIssueIDs: [String]
        var requestCount: Int
        var error: String?
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    static func options(_ args: [String]) -> (values: [String: String], flags: Set<String>)? {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var i = 0
        let valued: Set<String> = ["--score", "--issues", "--out", "--responses", "--batch", "--report"]
        while i < args.count {
            let a = args[i]
            if valued.contains(a) {
                guard i + 1 < args.count else { return nil }
                values[a] = args[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else { return nil }
        }
        return (values, flags)
    }

    static func config(batch: Int, vision: Bool) -> AIProviderConfig {
        AIProviderConfig(baseURL: AIProviderConfig.deepSeekBaseURL, model: "recorded", apiKey: "recorded",
                         supportsVision: vision, maxIssuesPerRequest: batch)
    }

    static func loadScore(_ path: String) throws -> Score {
        try ScoreCoding.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // MARK: ai-dump-requests

    static func dump(_ args: [String]) -> Int32 {
        guard let (v, f) = options(args), let scorePath = v["--score"], let issuesPath = v["--issues"], let out = v["--out"] else {
            return fail("usage: agr-tool ai-dump-requests --score x.agr.json --issues issues.json --out dir/ [--vision] [--batch N]")
        }
        do {
            let score = try loadScore(scorePath)
            let issues = try JSONDecoder().decode([AIIssue].self, from: try Data(contentsOf: URL(fileURLWithPath: issuesPath)))
            let batch = Int(v["--batch"] ?? "") ?? 8
            let vision = f.contains("--vision")
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let planned = AIAssistPromptBuilder.requests(score: score, issues: issues, batchSize: batch, vision: vision)
            var entries: [Index.Entry] = []
            for item in planned {
                let key = item.request.fixtureKey
                var messages: [AIJSONValue] = []
                for m in item.request.messages {
                    var files: [AIJSONValue] = []
                    for (n, img) in m.images.enumerated() {
                        let name = "\(key).crop-\(n + 1).jpg"
                        try img.write(to: dir.appendingPathComponent(name))
                        files.append(.string(name))
                    }
                    messages.append(.object(["role": .string(m.role.rawValue), "text": .string(m.text), "images": .array(files)]))
                }
                let req = AIJSONValue.object(["key": .string(key), "issueIDs": .array(item.issues.map { .string($0.id) }),
                                              "messages": .array(messages)])
                try req.data(pretty: true).write(to: dir.appendingPathComponent("\(key).request.json"))
                let promptFile = "\(key).prompt.txt"
                try Data(AIAssistPromptBuilder.promptText(for: item.request).utf8).write(to: dir.appendingPathComponent(promptFile))
                entries.append(Index.Entry(key: key, issueIDs: item.issues.map(\.id), promptFile: promptFile,
                                           responseFile: "\(key).response.json"))
            }
            let index = Index(batchSize: batch, vision: vision, issues: issues, requests: entries)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(index).write(to: dir.appendingPathComponent("index.json"))
            for e in entries { print("\(e.promptFile) -> write \(e.responseFile)") }
            print("\(entries.count) request(s), \(issues.count) issue(s) in \(out)")
            return 0
        } catch {
            return fail("agr-tool ai-dump-requests: \(error)")
        }
    }

    // MARK: ai-apply

    static func apply(_ args: [String]) -> Int32 {
        guard let (v, f) = options(args), let scorePath = v["--score"], let respDir = v["--responses"] else {
            return fail("usage: agr-tool ai-apply --score x.agr.json --responses dir/ [--issues issues.json] [--out fixed.agr.json] [--report report.json] [--dry-run]")
        }
        do {
            let score = try loadScore(scorePath)
            let dir = URL(fileURLWithPath: respDir, isDirectory: true)
            var batch = 8, vision = false
            var issues: [AIIssue]
            let indexURL = dir.appendingPathComponent("index.json")
            if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
                batch = index.batchSize
                vision = index.vision
                issues = index.issues
            } else if let p = v["--issues"] {
                issues = try JSONDecoder().decode([AIIssue].self, from: try Data(contentsOf: URL(fileURLWithPath: p)))
            } else {
                return fail("agr-tool ai-apply: no index.json in \(respDir); pass --issues issues.json")
            }
            if let p = v["--issues"] {
                issues = try JSONDecoder().decode([AIIssue].self, from: try Data(contentsOf: URL(fileURLWithPath: p)))
            }
            if let b = v["--batch"].flatMap({ Int($0) }) { batch = b }
            if f.contains("--vision") { vision = true }
            let service = AIAssistService(client: RecordedAIClient(directory: dir))
            let dry = f.contains("--dry-run")
            let (fIssues, fBatch, fVision) = (issues, batch, vision)
            let report = runBlocking { await service.correctDetailed(score: score, issues: fIssues, config: config(batch: fBatch, vision: fVision), dryRun: dry) }
            let outPath = v["--out"] ?? dir.appendingPathComponent("result.agr.json").path
            if !dry { try ScoreCoding.encode(report.score).write(to: URL(fileURLWithPath: outPath)) }
            let rep = Report(applied: report.applied, rejected: report.rejected, unresolvedIssueIDs: report.unresolvedIssueIDs,
                             requestCount: report.requestCount, error: report.fatalError?.localizedDescription)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let repPath = v["--report"] ?? dir.appendingPathComponent("report.json").path
            try enc.encode(rep).write(to: URL(fileURLWithPath: repPath))
            print("applied \(report.applied.count), rejected \(report.rejected.count), unresolved \(report.unresolvedIssueIDs.count)"
                  + (dry ? " (dry run, score not written)" : ", wrote \(outPath)"))
            for r in report.rejected { print("  rejected \(r.id) [\(r.issueIDs.joined(separator: ","))]: \(r.reason)") }
            return 0
        } catch {
            return fail("agr-tool ai-apply: \(error)")
        }
    }

    /// Runs an async operation to completion from synchronous CLI code.
    private final class Box<T>: @unchecked Sendable { var value: T? }
    static func runBlocking<T>(_ op: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await op()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "ai-dump-requests": return dump(Array(args.dropFirst()))
        case "ai-apply": return apply(Array(args.dropFirst()))
        default: return fail("usage: agr-tool <ai-dump-requests|ai-apply> …")
        }
    }
}
