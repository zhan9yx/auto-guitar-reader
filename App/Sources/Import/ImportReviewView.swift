import SwiftUI
import UIKit
import AGRCore

/// Review screen shown after an import: preview, edit metadata, optionally edit as text, then save.
@MainActor
struct ImportReviewView: View {
    let draft: ImportDraft
    var onSave: (ImportDraft) -> Void
    var onCancel: () -> Void
    /// Problems found by the importer (OMR validation / AI repair). Merged with the local notation lint.
    /// Tap one to scroll to and flash its measure.
    var issues: [ReviewIssue] = []

    @State private var score: Score
    @State private var showTextEditor = false
    @State private var editingMeasure: NotationMeasureRef?
    @State private var flash: NotationMeasureRef?
    @State private var flashTask: Task<Void, Never>?
    @State private var notationOptions = NotationOptions()
    @State private var thumbnails: [UIImage] = []

    init(draft: ImportDraft, issues: [ReviewIssue] = [], onSave: @escaping (ImportDraft) -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.issues = issues
        self.onSave = onSave
        self.onCancel = onCancel
        _score = State(initialValue: draft.score)
    }

    var body: some View {
        NavigationStack {
            Form {
                warningsSection

                if !thumbnails.isEmpty {
                    SwiftUI.Section("原图") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(thumbnails.indices), id: \.self) { index in
                                    Image(uiImage: thumbnails[index])
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                MetaFormSection(meta: $score.meta)

                if isNotation {
                    issuesSection
                }

                SwiftUI.Section {
                    if isNotation {
                        notationPreview
                    } else {
                        ScrollView {
                            ScoreDocumentView(score: score, fontSize: 15, showsTitleHeader: false)
                        }
                        .frame(height: 320)
                        Button {
                            showTextEditor = true
                        } label: {
                            Label("编辑为文本", systemImage: "square.and.pencil")
                        }
                    }
                } header: {
                    Text(isNotation ? "预览（六线谱 · 点击小节修改）" : "预览（文本谱）")
                } footer: {
                    Text(draft.sourceDescription.isEmpty ? "" : "来源：\(draft.sourceDescription)")
                }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var result = draft
                        result.score = score
                        onSave(result)
                    }
                    .disabled(score.meta.title.trimmed.isEmpty)
                }
            }
            .measureEditSheet(score: $score, editing: $editingMeasure)
            .sheet(isPresented: $showTextEditor) {
                NavigationStack {
                    ScoreEditorEntry(score: score) { updated in
                        score = updated
                    }
                }
            }
            .task {
                if thumbnails.isEmpty {
                    thumbnails = draft.pageImages.compactMap { UIImage(data: $0.data) }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Notation preview + issues

    private var isNotation: Bool { NotationScore.hasSystemLines(score) }

    private var allIssues: [ReviewIssue] {
        let local = NotationLint.issues(for: score).filter { candidate in !issues.contains(candidate) }
        return (issues + local).sorted { $0.severity > $1.severity }
    }

    private var notationPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    ScoreDocumentView(
                        score: score,
                        fontSize: 14,
                        showsTitleHeader: false,
                        notationOptions: notationOptions,
                        flashMeasure: flash,
                        notationBackground: Color(uiColor: .secondarySystemGroupedBackground),
                        onTapMeasure: { ref, _ in editingMeasure = ref }
                    )
                }
                .frame(height: 380)
                .onChange(of: flash) { _, ref in
                    guard let ref = ref else { return }
                    withAnimation { proxy.scrollTo(NotationLineID(line: ref.line), anchor: .top) }
                }
            }
            Toggle("显示和弦图", isOn: $notationOptions.showDiagrams)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let items = allIssues
        if !items.isEmpty {
            SwiftUI.Section {
                ForEach(items) { issue in
                    Button {
                        focus(issue)
                    } label: {
                        Label {
                            Text(issue.message)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        } icon: {
                            Image(systemName: icon(for: issue.severity))
                                .foregroundStyle(color(for: issue.severity))
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("需要检查的地方（\(items.count)）")
            } footer: {
                Text("点击一项会滚动到对应小节并闪烁；点击谱面中的小节可以直接修改。")
            }
        }
    }

    private func icon(for severity: ReviewIssue.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: ReviewIssue.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    /// Scrolls to the issue's measure and flashes it for ~1.2 s; an issue without a measure opens nothing.
    private func focus(_ issue: ReviewIssue) {
        guard let ref = issue.measureRef else { return }
        flashTask?.cancel()
        flash = nil
        flashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            flash = ref
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { flash = nil }
        }
    }

    // MARK: Warnings

    private var computedWarnings: [String] {
        var items = draft.warnings
        let chordCount = ScoreStats.chordCount(score)
        if score.sections.isEmpty || ScoreStats.lineCount(score) == 0 {
            items.append("没有识别到任何内容。可以点击“编辑为文本”手动输入，或返回重新选择更清晰的图片。")
        } else if !isNotation, score.meta.mode == .strumSing, ScoreStats.tabLineCount(score) == 0, chordCount < 4 {
            items.append("只识别到 \(chordCount) 个和弦，识别结果可能不完整。建议检查预览，必要时点击“编辑为文本”修正。")
        }
        return items
    }

    @ViewBuilder
    private var warningsSection: some View {
        let items = computedWarnings
        if !items.isEmpty {
            SwiftUI.Section {
                ForEach(Array(items.indices), id: \.self) { index in
                    Label {
                        Text(items[index])
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
