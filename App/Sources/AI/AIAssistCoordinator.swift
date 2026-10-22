import Foundation
import Observation
import AGRCore

/// What will leave the device for one assist run (shown in the 发送前确认 dialog).
struct AIPreSendSummary: Equatable {
    var host: String
    var model: String
    var issueCount: Int
    var requestCount: Int
    var imageCount: Int
    var characterCount: Int

    var text: String {
        var lines = [
            "将向 \(host)（模型 \(model)）发送 \(requestCount) 次请求，共 \(issueCount) 处可疑内容。",
            "内容：可疑位置的文字化乐谱片段与 OCR 文字（约 \(characterCount) 字，含固定说明）。",
        ]
        lines.append(imageCount > 0 ? "另含 \(imageCount) 张局部裁剪图。" : "不发送图片。")
        lines.append("不会上传整份曲谱或整页原图。")
        return lines.joined(separator: "\n")
    }
}

/// Runs the AI assist for flagged import issues and hands the result to the review UI.
///
/// Usage from the import review screen (see docs/AI.md):
///
///     let coordinator = AIAssistCoordinator()          // one per screen, @State
///     coordinator.attach(settings: settings)           // onAppear
///     if coordinator.requiresConfirmation, let s = coordinator.preSendSummary(score: score, issues: issues) { …show s.text… }
///     if let proposal = await coordinator.proposeFixes(score: score, issues: issues) {
///         // present AIFixReviewView(proposal: proposal, onApply: { score = $0 }, onCancel: {…})
///     } else if let message = coordinator.errorMessage { …show message… }
///
/// `AIAssistButton` bundles all of this into one control.
@Observable
@MainActor
final class AIAssistCoordinator {
    /// True while a request batch is in flight.
    var isRunning = false
    /// Latest progress (nil when idle).
    var progress: AIAssistProgress?
    /// User-readable failure of the last run (nil when it went fine or was never run).
    var errorMessage: String?

    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private let clientFactory: (AIProviderConfig) -> AIChatClient

    init(clientFactory: @escaping (AIProviderConfig) -> AIChatClient = { OpenAICompatibleClient(config: $0) }) {
        self.clientFactory = clientFactory
    }

    func attach(settings: SettingsStore) {
        self.settings = settings
    }

    /// AI assist is enabled and fully configured.
    var isAvailable: Bool { settings?.ai.providerConfig != nil }

    /// Why it is not available (nil when it is).
    var unavailableReason: String? { settings?.ai.unavailableReason ?? "设置未就绪" }

    /// The user asked to confirm before anything is sent.
    var requiresConfirmation: Bool { settings?.ai.confirmBeforeSend ?? true }

    func preSendSummary(score: Score, issues: [AIIssue]) -> AIPreSendSummary? {
        guard let config = settings?.ai.providerConfig else { return nil }
        let planned = AIAssistPromptBuilder.requests(score: score, issues: issues,
                                                     batchSize: config.maxIssuesPerRequest, vision: config.supportsVision)
        let images = planned.reduce(0) { $0 + $1.request.messages.reduce(0) { $0 + $1.images.count } }
        let chars = planned.reduce(0) { $0 + $1.request.messages.reduce(0) { $0 + $1.text.count } }
        return AIPreSendSummary(host: config.baseURL.host ?? config.baseURL.absoluteString, model: config.model,
                                issueCount: issues.count, requestCount: planned.count, imageCount: images, characterCount: chars)
    }

    /// Asks the model for fixes (a dry run: `score` is not modified). Returns nil when AI is not available,
    /// there is nothing to fix, or a fatal error (bad key, network, timeout) produced no fix; `errorMessage` says why.
    /// Confirmation (`requiresConfirmation`) is the caller's job; this sends immediately.
    func proposeFixes(score: Score, issues: [AIIssue]) async -> AIFixProposal? {
        errorMessage = nil
        guard !isRunning else { return nil }
        guard let config = settings?.ai.providerConfig else {
            errorMessage = unavailableReason
            return nil
        }
        guard !issues.isEmpty else {
            errorMessage = "没有需要 AI 校对的问题"
            return nil
        }
        isRunning = true
        progress = AIAssistProgress(completedBatches: 0, totalBatches: 0, message: "准备中…")
        defer {
            isRunning = false
            progress = nil
        }
        let service = AIAssistService(client: clientFactory(config))
        let report = await service.correctDetailed(score: score, issues: issues, config: config, dryRun: true) { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }
        if let fatal = report.fatalError, report.applied.isEmpty {
            errorMessage = fatal.localizedDescription
            return nil
        }
        if report.applied.isEmpty && report.rejected.isEmpty {
            errorMessage = "AI 没有发现可以安全修正的地方"
            return nil
        }
        return AIFixProposal(original: score, issues: issues, fixes: report.applied, rejected: report.rejected,
                             unresolvedIssueIDs: report.unresolvedIssueIDs)
    }
}
