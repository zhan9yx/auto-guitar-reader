import Foundation

public struct AIAssistProgress: Sendable, Equatable {
    public var completedBatches: Int
    public var totalBatches: Int
    public var message: String
    public var fraction: Double { totalBatches == 0 ? 1 : Double(completedBatches) / Double(totalBatches) }
    public init(completedBatches: Int, totalBatches: Int, message: String) {
        self.completedBatches = completedBatches
        self.totalBatches = totalBatches
        self.message = message
    }
}

public struct AIAssistReport: Sendable {
    /// Corrected score (the original one in `dryRun` mode).
    public var score: Score
    public var applied: [AppliedFix]
    public var rejected: [RejectedFix]
    /// Issues for which the model returned no ops ("unsure").
    public var unresolvedIssueIDs: [String]
    /// Set when a fatal error (401, network, timeout, …) stopped the run early.
    public var fatalError: AIError?
    public var requestCount: Int
    public init(score: Score, applied: [AppliedFix] = [], rejected: [RejectedFix] = [], unresolvedIssueIDs: [String] = [],
                fatalError: AIError? = nil, requestCount: Int = 0) {
        self.score = score
        self.applied = applied
        self.rejected = rejected
        self.unresolvedIssueIDs = unresolvedIssueIDs
        self.fatalError = fatalError
        self.requestCount = requestCount
    }
}

/// Runs the AI correction loop: batches issues, asks the model for patches, validates and applies
/// them one fix at a time. Never throws; problems end up in `rejected`.
public struct AIAssistService: Sendable {
    public let client: AIChatClient

    public init(client: AIChatClient) { self.client = client }

    /// Real OpenAI-compatible endpoint from `config`.
    public init(config: AIProviderConfig) { self.client = OpenAICompatibleClient(config: config) }

    /// Convenience: `(correctedScore, applied, rejected)`. `dryRun` validates everything but returns the original score.
    public func correct(score: Score, issues: [AIIssue], config: AIProviderConfig,
                        dryRun: Bool = false) async -> (Score, [AppliedFix], [RejectedFix]) {
        let r = await correctDetailed(score: score, issues: issues, config: config, dryRun: dryRun)
        return (r.score, r.applied, r.rejected)
    }

    public func correctDetailed(score: Score, issues: [AIIssue], config: AIProviderConfig, dryRun: Bool = false,
                                progress: (@Sendable (AIAssistProgress) -> Void)? = nil) async -> AIAssistReport {
        let planned = AIAssistPromptBuilder.requests(score: score, issues: issues,
                                                     batchSize: config.maxIssuesPerRequest, vision: config.supportsVision)
        var working = score
        var applied: [AppliedFix] = []
        var rejected: [RejectedFix] = []
        var unresolved: [String] = []
        var fatal: AIError?
        var sent = 0
        var counter = 0
        let total = planned.count

        for (batchIndex, item) in planned.enumerated() {
            let ids = item.issues.map(\.id)
            if let fatal {
                rejected.append(RejectedFix(id: "skip-\(batchIndex)", issueIDs: ids, reason: "已跳过：\(fatal.localizedDescription)"))
                continue
            }
            progress?(AIAssistProgress(completedBatches: batchIndex, totalBatches: total,
                                       message: "AI 校对中 \(batchIndex + 1)/\(total)…"))
            sent += 1
            let text: String
            do {
                text = try await client.complete(item.request).content
            } catch {
                let e = (error as? AIError) ?? .network(error.localizedDescription)
                rejected.append(RejectedFix(id: "batch-\(batchIndex)", issueIDs: ids, reason: e.localizedDescription))
                if e.isFatal { fatal = e }
                continue
            }
            let patch: ScorePatch
            do { patch = try ScorePatch.parse(modelOutput: text) } catch {
                rejected.append(RejectedFix(id: "batch-\(batchIndex)", issueIDs: ids, reason: "\(error)"))
                continue
            }
            if patch.ops.isEmpty {
                unresolved.append(contentsOf: ids)
                continue
            }
            for group in Self.groupOps(patch.ops, batchIssues: item.issues) {
                counter += 1
                let fixID = "fix-\(counter)"
                if let reason = group.problem {
                    rejected.append(RejectedFix(id: fixID, issueIDs: group.issueIDs, ops: group.ops, reason: reason.description))
                    continue
                }
                switch Self.tryApply(ops: group.ops, to: working) {
                case .success(let (next, changes)):
                    applied.append(AppliedFix(id: fixID, issueIDs: group.issueIDs, ops: group.ops, changes: changes, notes: patch.notes))
                    working = next
                case .failure(let reason):
                    rejected.append(RejectedFix(id: fixID, issueIDs: group.issueIDs, ops: group.ops, reason: reason.description))
                }
            }
        }
        progress?(AIAssistProgress(completedBatches: total, totalBatches: total, message: "AI 校对完成"))
        return AIAssistReport(score: dryRun ? score : working, applied: applied, rejected: rejected,
                              unresolvedIssueIDs: unresolved, fatalError: fatal, requestCount: sent)
    }

    // MARK: Applying selected fixes (review UI)

    /// Re-applies `fixes` (e.g. the ones the user accepted after a dry run) to `score`, in order.
    /// Fixes that no longer apply cleanly are returned as rejected.
    public static func apply(fixes: [AppliedFix], to score: Score) -> (Score, [RejectedFix]) {
        var working = score
        var failed: [RejectedFix] = []
        for fix in fixes {
            switch tryApply(ops: fix.ops, to: working) {
            case .success(let (next, _)): working = next
            case .failure(let reason): failed.append(RejectedFix(id: fix.id, issueIDs: fix.issueIDs, ops: fix.ops, reason: reason.description))
            }
        }
        return (working, failed)
    }

    // MARK: Internals

    struct OpGroup {
        var issueIDs: [String]
        var ops: [PatchOp]
        var problem: String?
    }

    /// Groups ops by issue id (atomic units) and checks scope rules.
    static func groupOps(_ ops: [PatchOp], batchIssues: [AIIssue]) -> [OpGroup] {
        let byID = Dictionary(batchIssues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var grouped: [String: [PatchOp]] = [:]
        var problems: [String: String] = [:]
        for var op in ops {
            if op.issue == nil, batchIssues.count == 1 { op.issue = batchIssues[0].id }
            let key = op.issue ?? ""
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(op)
            if problems[key] != nil { continue }
            guard let id = op.issue, !id.isEmpty else { problems[key] = "补丁缺少 issue 字段"; continue }
            guard let issue = byID[id] else { problems[key] = "未知的问题 id：\(id)"; continue }
            if let why = scopeViolation(op: op, issue: issue) { problems[key] = why }
        }
        return order.map { OpGroup(issueIDs: $0.isEmpty ? [] : [$0], ops: grouped[$0] ?? [], problem: problems[$0]) }
    }

    /// Ops must stay inside the flagged line (`sections[i].lines[j]`), or inside the issue path itself
    /// when it is not under a line. unknownChord fixes may also add `chordDefinitions`.
    static func scopeViolation(op: PatchOp, issue: AIIssue) -> String? {
        guard let opTokens = try? ScorePath.parse(op.path) else { return "路径无效：\(op.path)" }
        guard let issueTokens = try? ScorePath.parse(issue.path) else { return "问题路径无效：\(issue.path)" }
        var scope = issueTokens
        for i in 0..<max(0, issueTokens.count - 1) {
            if issueTokens[i] == .key("lines"), case .index = issueTokens[i + 1] {
                scope = Array(issueTokens[0...(i + 1)])
                break
            }
        }
        if opTokens.starts(with: scope) { return nil }
        if issue.kind == .unknownChord, opTokens.first == .key("chordDefinitions") { return nil }
        return "超出问题范围：\(op.path) 不在 \(ScorePath.render(scope)) 内"
    }

    static func tryApply(ops: [PatchOp], to score: Score) -> Result<(Score, [AIChange]), ApplyFailure> {
        do {
            let next = try ScorePatcher.apply(ops, to: score)
            if next == score { return .failure(ApplyFailure("补丁没有产生任何变化")) }
            return .success((next, changes(for: ops, before: score, after: next)))
        } catch let e as PatchError {
            return .failure(ApplyFailure(e.description))
        } catch {
            return .failure(ApplyFailure("\(error)"))
        }
    }

    struct ApplyFailure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    /// Before → after texts, one entry per touched measure / location.
    static func changes(for ops: [PatchOp], before: Score, after: Score) -> [AIChange] {
        var result: [AIChange] = []
        var seen = Set<[PathToken]>()
        for op in ops {
            guard let tokens = try? ScorePath.parse(op.path) else { continue }
            let key = containerKey(tokens)
            let insideMeasure = key.count < tokens.count
            if !insideMeasure && op.op == .insert {
                result.append(AIChange(path: op.path, before: "（新增）", after: render(value: op.value, tokens: tokens)))
            } else if !insideMeasure && op.op == .delete {
                result.append(AIChange(path: op.path, before: AICompactRenderer.describe(path: op.path, in: before), after: "（删除）"))
            } else {
                guard seen.insert(key).inserted else { continue }
                let p = ScorePath.render(key)
                result.append(AIChange(path: p, before: AICompactRenderer.describe(path: p, in: before),
                                       after: AICompactRenderer.describe(path: p, in: after)))
            }
        }
        return result
    }

    static func containerKey(_ tokens: [PathToken]) -> [PathToken] {
        for i in 1..<max(1, tokens.count - 1) where tokens[i] == .key("measures") && tokens[i - 1] == .key("system") {
            if case .index = tokens[i + 1] { return Array(tokens[0...(i + 1)]) }
        }
        return tokens
    }

    static func render(value: AIJSONValue?, tokens: [PathToken]) -> String {
        guard let value else { return "(无)" }
        if tokens.count >= 2, tokens[tokens.count - 2] == .key("measures"), let m = try? value.decode(NotationMeasure.self) {
            return AICompactRenderer.render(measure: m)
        }
        let t = value.compactText
        return t.count > 240 ? String(t.prefix(240)) + "…" : t
    }
}
