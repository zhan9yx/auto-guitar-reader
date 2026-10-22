import SwiftUI
import AGRCore

/// "我的" tab: own profile, stats, uploads, favorites, practice history and recently opened scores.
@MainActor
struct ProfileView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ScoreStore.self) private var scores
    @Environment(AppModel.self) private var appModel

    @State private var profile = ProfileStore.shared
    @State private var practice = PracticeStore.shared
    @State private var showEditor = false
    @State private var detail: CommunityScoreSummary?
    @State private var pendingDelete: CommunityScoreSummary?
    @State private var actionError: String?

    var body: some View {
        List {
            SwiftUI.Section {
                header
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            SwiftUI.Section {
                statsRow
            }
            SwiftUI.Section("练习记录") {
                PracticeSectionView(log: practice.log)
            }
            SwiftUI.Section {
                uploadsRows
            } header: {
                Text("我的上传")
            }
            SwiftUI.Section {
                favoritesRows
            } header: {
                Text("我的收藏")
            }
            SwiftUI.Section("最近打开") {
                recentRows
            }
        }
        .navigationTitle("我的")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditSheet(store: profile)
        }
        .sheet(item: $detail) { summary in
            CommunityDetailView(summary: summary)
        }
        .confirmationDialog(
            "删除这份上传？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("从社区删除", role: .destructive) {
                Task { await delete(item) }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("“\(item.title)”将从社区永久移除，其他人将无法再下载；本地曲库不受影响。")
        }
        .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            profile.attach(settings: settings)
            practice.reload()
            await profile.sync()
            await profile.loadUploads()
            await profile.loadFavorites()
        }
        .refreshable {
            practice.reload()
            await profile.sync()
            await profile.loadUploads()
            await profile.loadFavorites()
        }
        .onChange(of: settings.serverURLString) {
            Task {
                await profile.sync()
                await profile.loadUploads()
                await profile.loadFavorites()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(emoji: profile.local.avatarEmoji, imageData: profile.avatarData,
                       name: profile.displayNickname, size: 88)
            Text(profile.displayNickname)
                .font(.title2.weight(.semibold))
            if let level = profile.local.level {
                ProfileChip(text: level.label, systemImage: "guitars", prominent: true)
            }
            if !profile.local.bio.isEmpty {
                Text(profile.local.bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !profile.local.genres.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(profile.local.genres, id: \.self) { ProfileChip(text: $0) }
                }
                .frame(maxWidth: .infinity)
            }
            syncStatus
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if profile.isSyncing {
            Label("正在同步…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let message = profile.syncError {
            Label(message, systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        } else if profile.local.hasPendingChanges {
            Label("修改待同步", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statsRow: some View {
        HStack {
            ProfileStatCell(value: "\(scores.summaries.count)", title: "本地曲谱")
            ProfileStatCell(value: "\(profile.stats.uploads)", title: "我的上传")
            ProfileStatCell(value: "\(profile.stats.downloads)", title: "被下载")
            ProfileStatCell(value: "\(profile.stats.favoritesReceived)", title: "被收藏")
        }
        .padding(.vertical, 4)
    }

    // MARK: Uploads / favorites

    @ViewBuilder
    private var uploadsRows: some View {
        if profile.isLoadingUploads && profile.uploads.isEmpty {
            ProgressView()
        } else if let message = profile.uploadsError, profile.uploads.isEmpty {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        } else if profile.uploads.isEmpty {
            Text("还没有上传。在曲库中长按曲谱，选择“上传到社区”。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(profile.uploads) { item in
                CommunityRow(summary: item)
                    .onTapGesture { detail = item }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var favoritesRows: some View {
        if profile.isLoadingFavorites && profile.favorites.isEmpty {
            ProgressView()
        } else if let message = profile.favoritesError, profile.favorites.isEmpty {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        } else if profile.favorites.isEmpty {
            Text("在社区里点心形按钮收藏喜欢的曲谱。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(profile.favorites) { item in
                CommunityRow(summary: item)
                    .onTapGesture { detail = item }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await unfavorite(item) }
                        } label: {
                            Label("取消收藏", systemImage: "heart.slash")
                        }
                        .tint(.orange)
                    }
            }
        }
    }

    // MARK: Recent

    private struct RecentEntry: Identifiable {
        let open: RecentOpen
        let summary: ScoreSummary
        var id: UUID { open.scoreID }
    }

    @ViewBuilder
    private var recentRows: some View {
        let existing: [RecentEntry] = practice.log.recentOpens.compactMap { open in
            scores.summary(for: open.scoreID).map { RecentEntry(open: open, summary: $0) }
        }
        if existing.isEmpty {
            Text("打开过的曲谱会出现在这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(existing.prefix(8))) { entry in
                Button {
                    appModel.open(scoreID: entry.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let artist = entry.summary.artist, !artist.isEmpty {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(entry.open.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func delete(_ item: CommunityScoreSummary) async {
        do {
            try await profile.deleteUpload(id: item.id)
        } catch {
            actionError = describeError(error)
        }
    }

    private func unfavorite(_ item: CommunityScoreSummary) async {
        do {
            try await profile.setFavorite(scoreID: item.id, favorite: false)
        } catch {
            actionError = describeError(error)
        }
    }
}
