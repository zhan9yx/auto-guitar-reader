import SwiftUI
import AGRCore

/// Lists the AI's proposed fixes (before → after as compact text) with an accept toggle each.
/// "应用所选" calls `onApply` with the original score plus the accepted fixes.
@MainActor
struct AIFixReviewView: View {
    let proposal: AIFixProposal
    var onApply: (Score) -> Void
    var onCancel: () -> Void

    @State private var accepted: Set<String>

    init(proposal: AIFixProposal, onApply: @escaping (Score) -> Void, onCancel: @escaping () -> Void) {
        self.proposal = proposal
        self.onApply = onApply
        self.onCancel = onCancel
        _accepted = State(initialValue: Set(proposal.fixes.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                if proposal.fixes.isEmpty {
                    SwiftUI.Section {
                        Text("AI 没有给出可以安全应用的修正。")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(proposal.fixes) { fix in
                    fixSection(fix)
                }
                if !proposal.rejected.isEmpty {
                    SwiftUI.Section {
                        DisclosureGroup("未采用的建议（\(proposal.rejected.count)）") {
                            ForEach(proposal.rejected) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.reason)
                                        .font(.footnote)
                                    if !item.issueIDs.isEmpty {
                                        Text("问题：" + item.issueIDs.joined(separator: "、"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("这些建议没通过校验（越界、拍数变差、字段不合法等），已自动丢弃。")
                    }
                }
                if !proposal.unresolvedIssueIDs.isEmpty {
                    SwiftUI.Section {
                        Text("AI 没有把握，未改动：" + proposal.unresolvedIssueIDs.joined(separator: "、"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("AI 校对建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用所选（\(accepted.count)）") {
                        onApply(proposal.result(accepting: accepted).score)
                    }
                    .disabled(accepted.isEmpty)
                }
            }
        }
    }

    private func binding(for fix: AppliedFix) -> Binding<Bool> {
        Binding(
            get: { accepted.contains(fix.id) },
            set: { isOn in
                if isOn { accepted.insert(fix.id) } else { accepted.remove(fix.id) }
            }
        )
    }

    private func title(for fix: AppliedFix) -> String {
        let messages = proposal.issues(for: fix).map(\.message)
        return messages.isEmpty ? "修正 \(fix.id)" : messages.joined(separator: "；")
    }

    @ViewBuilder
    private func fixSection(_ fix: AppliedFix) -> some View {
        SwiftUI.Section {
            Toggle(isOn: binding(for: fix)) {
                Text(title(for: fix))
                    .font(.subheadline.weight(.medium))
            }
            ForEach(Array(fix.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("原")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Text(change.before)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("改")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text(change.after)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .opacity(accepted.contains(fix.id) ? 1 : 0.45)
            }
            if !fix.notes.isEmpty {
                Text("AI 说明：" + fix.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
