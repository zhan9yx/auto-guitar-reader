import SwiftUI
import UIKit

/// Sheet for importing pasted text (ChordPro / chord-over-lyrics / ASCII tab).
@MainActor
struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel

    @State private var title: String = ""
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("标题（可选）") {
                    TextField("例如：晴天", text: $title)
                }
                SwiftUI.Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 260)
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            text = pasted
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("粘贴谱面文本")
                } footer: {
                    Text("支持 ChordPro、和弦在歌词上方的文本（吉他谱网站复制）以及 ASCII 六线谱。")
                }
            }
            .navigationTitle("粘贴文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let pastedText = text
                        let pastedTitle = title
                        dismiss()
                        Task {
                            await appModel.importCoordinator.importText(pastedText, title: pastedTitle)
                        }
                    }
                    .disabled(text.trimmed.isEmpty)
                }
            }
        }
    }
}
