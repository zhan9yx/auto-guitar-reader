import SwiftUI
import AGRCore

/// Edits a score as ChordPro text (+ metadata form). Saving re-parses the text with `ChordProParser`
/// and merges ids / page anchors back from the original when the line structure is unchanged.
@MainActor
struct ScoreTextEditorView: View {
    let original: Score
    var onSave: (Score) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var meta: ScoreMeta
    @State private var errorMessage: String?
    @State private var pendingScore: Score?
    @State private var showAnchorWarning = false

    init(score: Score, onSave: @escaping (Score) -> Void) {
        self.original = score
        self.onSave = onSave
        _text = State(initialValue: ChordProExporter.export(score))
        _meta = State(initialValue: score.meta)
    }

    var body: some View {
        Form {
            MetaFormSection(meta: $meta)

            SwiftUI.Section {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 360)
            } header: {
                Text("谱面文本（ChordPro）")
            } footer: {
                Text("用 [C] 标记和弦，{sov}/{soc} 标记段落，{c: 说明} 添加注释。")
            }
        }
        .navigationTitle("编辑谱面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { attemptSave() }
            }
        }
        .alert("无法解析谱面文本", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("行结构已变化", isPresented: $showAnchorWarning) {
            Button("继续保存", role: .destructive) {
                if let score = pendingScore {
                    commit(score)
                }
            }
            Button("取消", role: .cancel) {
                pendingScore = nil
            }
        } message: {
            Text("文本的行数与原图识别结果不一致，原图上每一行的定位（用于原图模式高亮）将被清除。原图本身仍可查看。")
        }
    }

    private func attemptSave() {
        do {
            let parsed = try ChordProParser.parse(text)
            let merged = ScoreMerger.merge(parsed: parsed, original: original, editedMeta: meta)
            if merged.anchorsDropped {
                pendingScore = merged.score
                showAnchorWarning = true
            } else {
                commit(merged.score)
            }
        } catch {
            errorMessage = describeError(error)
        }
    }

    private func commit(_ score: Score) {
        onSave(score)
        dismiss()
    }
}
