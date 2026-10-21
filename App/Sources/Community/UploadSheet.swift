import SwiftUI
import AGRCore

/// Confirmation sheet for uploading a library score to the community server.
@MainActor
struct UploadSheet: View {
    let summary: ScoreSummary

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(ScoreStore.self) private var store

    @State private var nickname: String = ""
    @State private var includeImages = true
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var uploaded: CommunityScoreSummary?

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.displayTitle)
                            .font(.headline)
                        if let artist = summary.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("要上传的曲谱")
                }

                SwiftUI.Section {
                    TextField("昵称", text: $nickname)
                } header: {
                    Text("显示的昵称")
                } footer: {
                    Text("社区没有账号体系，仅使用匿名设备 ID 与昵称标识上传者。")
                }

                if summary.hasPages {
                    SwiftUI.Section {
                        Toggle("包含原始图片", isOn: $includeImages)
                    } footer: {
                        Text("关闭后只上传识别出的文本谱，下载者无法使用“原图谱”模式。请确认你有权分享这些图片。")
                    }
                }

                if let uploaded = uploaded {
                    SwiftUI.Section {
                        Label("已上传：\(uploaded.title)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage = errorMessage {
                    SwiftUI.Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                SwiftUI.Section {
                    Button {
                        Task { await upload() }
                    } label: {
                        HStack {
                            Spacer()
                            if isUploading {
                                ProgressView()
                            } else {
                                Text(uploaded == nil ? "上传到社区" : "再次上传")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isUploading || nickname.trimmed.isEmpty)
                }
            }
            .navigationTitle("上传到社区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(uploaded == nil ? "取消" : "完成") { dismiss() }
                }
            }
            .onAppear {
                if nickname.isEmpty {
                    nickname = settings.nickname
                }
            }
        }
    }

    private func upload() async {
        errorMessage = nil
        guard let client = settings.communityClient(nicknameOverride: nickname) else {
            errorMessage = "服务器地址无效，请在“设置”中检查。"
            return
        }
        isUploading = true
        defer { isUploading = false }

        do {
            var score = try store.loadScore(id: summary.id)
            var assets: [(name: String, data: Data, mimeType: String)] = []
            if summary.hasPages && includeImages {
                for page in score.pages {
                    guard let data = store.pageImageData(scoreID: summary.id, name: page.fileName) else {
                        throw ScoreStoreError.notFound
                    }
                    assets.append((name: page.fileName, data: data, mimeType: "image/jpeg"))
                }
            } else {
                score.pages = []
            }
            let result = try await client.upload(score: score, assets: assets)
            uploaded = result
            if nickname.trimmed != settings.nickname {
                settings.nickname = nickname.trimmed
            }
        } catch {
            errorMessage = describeError(error)
        }
    }
}
