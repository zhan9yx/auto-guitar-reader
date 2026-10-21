import SwiftUI
import AGRCore

/// Read-only preview of a community score with download / report actions.
@MainActor
struct CommunityDetailView: View {
    let summary: CommunityScoreSummary

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(ScoreStore.self) private var store

    @State private var score: Score?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isDownloading = false
    @State private var downloadedID: UUID?
    @State private var notice: String?
    @State private var showReportOptions = false
    @State private var reportDone = false

    private static let reportReasons: [String] = ["垃圾 / 广告内容", "侵权内容", "谱面错误或乱码", "其他"]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(summary.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) {
                                showReportOptions = true
                            } label: {
                                Label("举报", systemImage: "flag")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    downloadBar
                }
        }
        .task {
            await loadScore()
        }
        .confirmationDialog("举报原因", isPresented: $showReportOptions, titleVisibility: .visible) {
            ForEach(Self.reportReasons, id: \.self) { reason in
                Button(reason) {
                    Task { await report(reason: reason) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("已提交举报", isPresented: $reportDone) {
            Button("好", role: .cancel) {}
        } message: {
            Text("感谢反馈，我们会尽快处理。")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在加载曲谱…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = loadError {
            ContentUnavailableView {
                Label("无法加载曲谱", systemImage: "wifi.exclamationmark")
            } description: {
                Text(loadError)
            } actions: {
                Button("重试") {
                    Task { await loadScore() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let score = score {
            ScrollView {
                ScoreDocumentView(score: score, fontSize: 17)
            }
        }
    }

    private var downloadBar: some View {
        VStack(spacing: 6) {
            if let notice = notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await download() }
            } label: {
                if isDownloading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if downloadedID != nil {
                    Label("已下载到曲库", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("下载到曲库", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(score == nil || isDownloading)
        }
        .padding()
        .background(.bar)
    }

    // MARK: Actions

    private func loadScore() async {
        isLoading = true
        loadError = nil
        guard let client = settings.communityClient() else {
            isLoading = false
            loadError = "服务器地址无效，请在“设置”中检查。"
            return
        }
        do {
            score = try await client.fetchScore(id: summary.id)
            isLoading = false
        } catch {
            isLoading = false
            loadError = describeError(error)
        }
    }

    private func download() async {
        guard let remote = score, let client = settings.communityClient() else { return }
        isDownloading = true
        notice = nil
        defer { isDownloading = false }

        var local = remote
        local.id = UUID()
        var assets: [(name: String, data: Data)] = []
        var fetched = Set<String>()
        var assetFailed = false
        for page in remote.pages where fetched.insert(page.fileName).inserted {
            do {
                let data = try await client.fetchAsset(scoreID: summary.id, name: page.fileName)
                // Must be exactly what ScoreStore will write, or `pages[].fileName` would not match the file.
                guard try ScoreStore.sanitizedFileName(page.fileName) == page.fileName, !data.isEmpty else {
                    assetFailed = true
                    break
                }
                assets.append((name: page.fileName, data: data))
            } catch {
                assetFailed = true
                break
            }
        }
        if assetFailed {
            // Keep the text score usable even if the original images could not be fetched.
            local.removePageData()
            assets = []
            notice = "原图下载失败，已仅保存文本谱。"
        }

        do {
            let saved = try store.save(score: local, pageImages: assets)
            downloadedID = saved.id
        } catch {
            notice = "保存失败：\(describeError(error))"
        }
    }

    private func report(reason: String) async {
        guard let client = settings.communityClient() else { return }
        do {
            try await client.report(scoreID: summary.id, reason: reason)
            reportDone = true
        } catch {
            notice = "举报失败：\(describeError(error))"
        }
    }
}
