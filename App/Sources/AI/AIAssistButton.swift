import SwiftUI
import AGRCore

/// Drop-in control for the import review screen: confirm (optional) → run → review sheet → write back.
///
///     AIAssistButton(score: $score, issues: issues)
///
/// `issues` come from the OMR report. The button is disabled while there are none. It reads
/// `SettingsStore` from the environment, so it must live inside the app's environment.
@MainActor
struct AIAssistButton: View {
    @Binding var score: Score
    let issues: [AIIssue]

    @Environment(SettingsStore.self) private var settings
    @State private var coordinator = AIAssistCoordinator()
    @State private var proposal: AIFixProposal?
    @State private var showConfirm = false
    @State private var showError = false
    @State private var pendingSummary = ""

    var body: some View {
        Button {
            start()
        } label: {
            if coordinator.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(coordinator.progress?.message ?? "AI 校对中…")
                }
            } else {
                Label("AI 校对（\(issues.count) 处）", systemImage: "sparkles")
            }
        }
        .disabled(issues.isEmpty || coordinator.isRunning)
        .onAppear { coordinator.attach(settings: settings) }
        .confirmationDialog("发送给 AI 服务？", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("发送") { run() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingSummary)
        }
        .alert("AI 校对", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .sheet(item: $proposal) { item in
            AIFixReviewView(
                proposal: item,
                onApply: { newScore in
                    score = newScore
                    proposal = nil
                },
                onCancel: { proposal = nil }
            )
        }
    }

    private func start() {
        coordinator.attach(settings: settings)
        guard coordinator.isAvailable else {
            coordinator.errorMessage = coordinator.unavailableReason
            showError = true
            return
        }
        if coordinator.requiresConfirmation, let summary = coordinator.preSendSummary(score: score, issues: issues) {
            pendingSummary = summary.text
            showConfirm = true
        } else {
            run()
        }
    }

    private func run() {
        let snapshot = score
        let flagged = issues
        Task {
            let result = await coordinator.proposeFixes(score: snapshot, issues: flagged)
            if let result {
                proposal = result
            } else if coordinator.errorMessage != nil {
                showError = true
            }
        }
    }
}
