import SwiftUI
import AGRCore

/// Title / artist / key / capo / tempo / mode form rows (used by the editor and the import review).
/// Place inside a `Form` or `List`.
struct MetaFormSection: View {
    @Binding var meta: ScoreMeta
    var header: String = "曲谱信息"

    var body: some View {
        SwiftUI.Section(header) {
            TextField("标题", text: $meta.title)
            TextField("歌手 / 作者", text: $meta.artist.orEmpty())
            TextField("原调（如 G、Em）", text: $meta.key.orEmpty())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Stepper(value: $meta.capo, in: 0...12) {
                Text("变调夹（Capo）：\(meta.capo == 0 ? "无" : "\(meta.capo) 品")")
            }
            Stepper(value: $meta.tempo, in: 30...300, step: 1) {
                Text("速度：\(Int(meta.tempo)) BPM")
            }
            Picker("类型", selection: $meta.mode) {
                ForEach(PlayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }
}
