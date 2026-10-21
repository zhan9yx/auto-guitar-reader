import SwiftUI
import AGRCore

/// Community tab: debounced search, sort picker, paginated results, detail sheet.
@MainActor
struct CommunityView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel = CommunityViewModel()
    @State private var selected: CommunityScoreSummary?

    var body: some View {
        content
            .navigationTitle("社区")
            .searchable(text: $viewModel.query, prompt: "搜索歌名、歌手或拼音首字母")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("排序", selection: $viewModel.sort) {
                        ForEach(CommunitySortOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }
            .sheet(item: $selected) { summary in
                CommunityDetailView(summary: summary)
            }
            .task {
                viewModel.attach(settings: settings)
                if !viewModel.hasLoadedOnce {
                    await viewModel.reload()
                }
            }
            .onChange(of: viewModel.query) {
                viewModel.scheduleReload()
            }
            .onChange(of: viewModel.sort) {
                Task { await viewModel.reload() }
            }
            .onChange(of: settings.serverURLString) {
                viewModel.scheduleReload()
            }
            .refreshable {
                await viewModel.reload()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = viewModel.errorMessage, viewModel.items.isEmpty {
            ContentUnavailableView {
                Label("无法加载社区", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.items.isEmpty {
            if viewModel.query.trimmed.isEmpty {
                ContentUnavailableView(
                    "社区里还没有曲谱",
                    systemImage: "music.note.list",
                    description: Text("从曲库中长按曲谱，选择“上传到社区”来分享第一首吧。")
                )
            } else {
                ContentUnavailableView.search(text: viewModel.query)
            }
        } else {
            List {
                ForEach(viewModel.items) { item in
                    Button {
                        selected = item
                    } label: {
                        CommunityRow(summary: item)
                    }
                    .buttonStyle(.plain)
                    .task {
                        await viewModel.loadMoreIfNeeded(current: item)
                    }
                }
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct CommunityRow: View {
    let summary: CommunityScoreSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(1)
                ModeBadge(mode: summary.mode)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let artist = summary.artist, !artist.isEmpty {
                    Text(artist)
                }
                if let key = summary.key, !key.isEmpty {
                    Text("原调 \(key)")
                }
                if summary.pageCount > 0 {
                    Label("\(summary.pageCount)", systemImage: "photo")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack(spacing: 12) {
                Label(summary.uploader, systemImage: "person.circle")
                Label("\(summary.downloads)", systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
