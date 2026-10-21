import SwiftUI
import AGRCore

/// Server-side upload limits (defaults of server/app/settings.py: AGR_MAX_ASSETS / AGR_MAX_ASSET_BYTES).
enum UploadLimits {
    static let maxAssets = 10
    static let maxAssetBytes = 5 * 1024 * 1024

    static func mimeType(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "image/jpeg"
        }
    }
}

enum UploadError: LocalizedError {
    case tooManyPages(Int)
    case pageTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .tooManyPages(let count):
            return "原图共 \(count) 页，社区最多接受 \(UploadLimits.maxAssets) 页。请关闭“包含原始图片”后再上传。"
        case .pageTooLarge(let name):
            return "原图 \(name) 超过 \(UploadLimits.maxAssetBytes / 1024 / 1024) MB，社区不接受。请关闭“包含原始图片”后再上传。"
        }
    }
}

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
            if includeImages && !score.pages.isEmpty {
                // The server requires every uploaded asset to be referenced by `pages[].fileName` and vice versa
                // (no duplicates, no unreferenced files).
                var seen = Set<String>()
                var uniquePages: [PageImage] = []
                for page in score.pages where seen.insert(page.fileName).inserted {
                    uniquePages.append(page)
                }
                score.pages = uniquePages
                if uniquePages.count > UploadLimits.maxAssets {
                    throw UploadError.tooManyPages(uniquePages.count)
                }
                for page in uniquePages {
                    guard let data = store.pageImageData(scoreID: summary.id, name: page.fileName) else {
                        throw ScoreStoreError.missingPage(page.fileName)
                    }
                    if data.count > UploadLimits.maxAssetBytes {
                        throw UploadError.pageTooLarge(page.fileName)
                    }
                    assets.append((name: page.fileName, data: data, mimeType: UploadLimits.mimeType(forFileName: page.fileName)))
                }
            } else {
                // Without images the server rejects `pages` entries it has no asset for: strip them
                // (line anchors are harmless and kept).
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
