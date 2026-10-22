import SwiftUI
import AGRCore

@MainActor
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ScoreStore.self) private var store
    @State private var showRestoreConfirm = false

    var body: some View {
        @Bindable var s = settings

        Form {
            SwiftUI.Section {
                TextField("服务器地址", text: $s.serverURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("设备 ID") {
                    Text(settings.deviceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("社区")
            } footer: {
                Text("默认 http://localhost:8000（模拟器可直连本机）。真机请填写服务器的局域网地址。")
            }

            SwiftUI.Section("显示") {
                VStack(alignment: .leading) {
                    Text("默认字号：\(Int(settings.defaultFontSize))")
                    Slider(value: $s.defaultFontSize, in: 12...36, step: 1)
                }
                Picker("默认谱面模式", selection: $s.defaultDisplayMode) {
                    ForEach(ScoreDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            SwiftUI.Section {
                Picker("显示方式", selection: $s.autoScrollStyle) {
                    ForEach(AutoScrollStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                VStack(alignment: .leading) {
                    Text("当前行位置：\(Int(settings.scrollAnchorRatio * 100))%（距屏幕顶部）")
                    Slider(value: $s.scrollAnchorRatio, in: 0.1...0.6, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("最大滚动速度：\(String(format: "%.1f", settings.scrollMaxSpeed)) 屏/秒")
                    Slider(value: $s.scrollMaxSpeed, in: 0.2...1.2, step: 0.1)
                }
                Stepper(value: $s.scrollManualOverrideSeconds, in: 1...10, step: 1) {
                    Text("手动拖动后暂停自动滚动：\(Int(settings.scrollManualOverrideSeconds)) 秒")
                }
            } header: {
                Text("自动滚动")
            } footer: {
                Text("平滑滚动：谱面随演奏匀速滑动；翻页：当前行越过屏幕 2/3 时整体翻半屏（适合 iPad 横屏）。最大速度与当前行位置仅用于平滑滚动。")
            }

            SwiftUI.Section("跟随") {
                Toggle("启用歌词识别（辅助定位）", isOn: $s.lyricsRecognitionEnabled)
                Picker("识别语言", selection: $s.recognitionLanguage) {
                    ForEach(RecognitionLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .disabled(!settings.lyricsRecognitionEnabled)
                Picker("跟随灵敏度", selection: $s.followSensitivity) {
                    ForEach(FollowSensitivity.allCases) { sensitivity in
                        Text(sensitivity.label).tag(sensitivity)
                    }
                }
                Text(settings.followSensitivity.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("模拟弹奏") {
                Picker("默认节奏型", selection: $s.strumPatternID) {
                    Text("跟随谱面").tag(String?.none)
                    ForEach(settings.availableStrumPatterns) { pattern in
                        Text(pattern.name).tag(String?.some(pattern.id))
                    }
                }
                Stepper(value: $s.countInBeats, in: 0...8) {
                    Text("预备拍：\(settings.countInBeats) 拍")
                }
            }

            SwiftUI.Section("曲库") {
                Button("恢复示例曲谱") {
                    showRestoreConfirm = true
                }
            }

            SwiftUI.Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("恢复内置示例曲谱？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("恢复") {
                store.restoreSamples()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
