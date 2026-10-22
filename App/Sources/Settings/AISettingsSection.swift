import SwiftUI
import AGRCore

/// Settings → "AI 辅助识别".
@MainActor
struct AISettingsSection: View {
    @Environment(SettingsStore.self) private var settings

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @State private var testState: TestState = .idle

    var body: some View {
        @Bindable var ai = settings.ai

        SwiftUI.Section {
            Toggle("启用 AI 辅助识别", isOn: $ai.isEnabled)

            if ai.isEnabled {
                Picker("服务商", selection: Binding(
                    get: { ai.preset },
                    set: { ai.selectPreset($0) }
                )) {
                    ForEach(AIProviderPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                TextField("Base URL", text: $ai.baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名", text: $ai.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $ai.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Toggle("支持图片（视觉模型）", isOn: $ai.supportsVision)
                Toggle("发送前确认", isOn: $ai.confirmBeforeSend)

                Button {
                    runTest()
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if testState == .testing { ProgressView() }
                    }
                }
                .disabled(testState == .testing || ai.connectionConfig == nil)

                switch testState {
                case .success(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                case .failure(let text):
                    Label(text, systemImage: "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                case .idle, .testing:
                    EmptyView()
                }
            }
        } header: {
            Text("AI 辅助识别")
        } footer: {
            Text(Self.privacyNote)
        }
    }

    static let privacyNote = "可选功能，默认关闭。识别引擎先在本机完成；只有出现可疑之处（拍数不符、低置信度符号、未知和弦、歌词对齐、疑似水印）时，才会把这些可疑处的文字化乐谱片段和 OCR 文字发送到你配置的服务商；开启“支持图片”后还会附上可疑区域的局部裁剪图。不会上传整份曲谱、整页原图或设备信息。API Key 仅保存在本机钥匙串，不会同步或写入设置文件。AI 的每条修改都会先让你确认。"

    private func runTest() {
        guard let config = settings.ai.connectionConfig else { return }
        testState = .testing
        Task {
            let result = await AIConnectionTester.test(config: config)
            switch result {
            case .success(let ok): testState = .success(ok.summary)
            case .failure(let error): testState = .failure(error.localizedDescription)
            }
        }
    }
}
