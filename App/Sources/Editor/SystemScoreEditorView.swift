import SwiftUI
import AGRCore

/// Chooses the editor for a score: notation (`.system`) scores cannot be expressed as ChordPro text, so they use
/// the measure editor; everything else keeps the ChordPro text editor.
@MainActor
struct ScoreEditorEntry: View {
    let score: Score
    var onSave: (Score) -> Void

    var body: some View {
        if NotationScore.hasSystemLines(score) {
            SystemScoreEditorView(score: score, onSave: onSave)
        } else {
            ScoreTextEditorView(score: score, onSave: onSave)
        }
    }
}

/// Editor for scores with notation systems: metadata form + the rendered notation; tap a measure to edit it.
@MainActor
struct SystemScoreEditorView: View {
    let original: Score
    var onSave: (Score) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var score: Score
    @State private var editing: NotationMeasureRef?

    init(score: Score, onSave: @escaping (Score) -> Void) {
        self.original = score
        self.onSave = onSave
        _score = State(initialValue: score)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                Label {
                    Text("这是六线谱 / 简谱格式的曲谱，无法转换成 ChordPro 文本编辑。点击下方谱面中的某个小节，可以修改和弦、六线谱、简谱和歌词。")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
            }

            MetaFormSection(meta: $score.meta)

            SwiftUI.Section("谱面（点击小节编辑）") {
                ScoreDocumentView(
                    score: score,
                    fontSize: 14,
                    showsTitleHeader: false,
                    notationBackground: Color(uiColor: .secondarySystemGroupedBackground),
                    onTapMeasure: { ref, _ in editing = ref }
                )
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("编辑谱面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(score)
                    dismiss()
                }
            }
        }
        .measureEditSheet(score: $score, editing: $editing)
    }
}
