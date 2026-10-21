import SwiftUI
import UIKit
import AGRCore

/// Review screen shown after an import: preview, edit metadata, optionally edit as text, then save.
@MainActor
struct ImportReviewView: View {
    let draft: ImportDraft
    var onSave: (ImportDraft) -> Void
    var onCancel: () -> Void

    @State private var score: Score
    @State private var showTextEditor = false
    @State private var thumbnails: [UIImage] = []

    init(draft: ImportDraft, onSave: @escaping (ImportDraft) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
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

                SwiftUI.Section {
                    ScrollView {
                        ScoreDocumentView(score: score, fontSize: 15, showsTitleHeader: false)
                    }
                    .frame(height: 320)
                    Button {
                        showTextEditor = true
                    } label: {
                        Label("编辑为文本", systemImage: "square.and.pencil")
                    }
                } header: {
                    Text("预览（文本谱）")
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
            .sheet(isPresented: $showTextEditor) {
                NavigationStack {
                    ScoreTextEditorView(score: score) { updated in
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

    // MARK: Warnings

    private var computedWarnings: [String] {
        var items = draft.warnings
        let chordCount = ScoreStats.chordCount(score)
        if score.sections.isEmpty || ScoreStats.lineCount(score) == 0 {
            items.append("没有识别到任何内容。可以点击“编辑为文本”手动输入，或返回重新选择更清晰的图片。")
        } else if score.meta.mode == .strumSing, ScoreStats.tabLineCount(score) == 0, chordCount < 4 {
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
