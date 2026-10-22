import SwiftUI
import AGRCore

/// Identifies the uploader a sheet should show.
struct ProfileTarget: Identifiable, Hashable {
    let userID: String
    let nickname: String
    var id: String { userID }
}

/// Sheet wrapper used from the community list.
@MainActor
struct PublicProfileSheet: View {
    let target: ProfileTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PublicProfileView(userID: target.userID, nicknameHint: target.nickname)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

/// Another user's public profile: avatar, nickname, bio, level, genres, stats and their uploads.
@MainActor
struct PublicProfileView: View {
    let userID: String
    var nicknameHint: String = ""

    @Environment(SettingsStore.self) private var settings

    @State private var profile: CommunityProfile?
    @State private var uploads: [CommunityScoreSummary] = []
    @State private var uploadsTotal = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var detail: CommunityScoreSummary?
    @State private var isLoadingMore = false
    @State private var page = 1

    private static let pageSize = 20

    var body: some View {
        List {
            if let profile {
                SwiftUI.Section {
                    header(profile)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                SwiftUI.Section {
                    HStack {
                        ProfileStatCell(value: "\(profile.stats.uploads)", title: "上传")
                        ProfileStatCell(value: "\(profile.stats.downloads)", title: "被下载")
                        ProfileStatCell(value: "\(profile.stats.favoritesReceived)", title: "被收藏")
                    }
                    .padding(.vertical, 4)
                }
                SwiftUI.Section("TA 的上传") {
                    if uploads.isEmpty {
                        Text("还没有公开的曲谱。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(uploads) { item in
                        CommunityRow(summary: item)
                            .onTapGesture { detail = item }
                            .task { await loadMoreIfNeeded(current: item) }
                    }
                    if isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            } else if isLoading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法加载资料", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(profile?.nickname ?? (nicknameHint.isEmpty ? "用户资料" : nicknameHint))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { summary in
            CommunityDetailView(summary: summary)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func header(_ profile: CommunityProfile) -> some View {
        VStack(spacing: 10) {
            AvatarView(emoji: profile.avatarEmoji, imageData: nil, imageURL: avatarURL(for: profile),
                       name: profile.nickname, size: 88)
            Text(profile.nickname)
                .font(.title2.weight(.semibold))
            if let level = profile.level {
                ProfileChip(text: level.label, systemImage: "guitars", prominent: true)
            }
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !profile.genres.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(profile.genres, id: \.self) { ProfileChip(text: $0) }
                }
                .frame(maxWidth: .infinity)
            }
            Text("加入于 " + profile.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func avatarURL(for profile: CommunityProfile) -> URL? {
        guard let client = settings.communityClient() else { return nil }
        return try? client.avatarURL(for: profile)
    }

    // MARK: Loading

    private func load() async {
        guard let client = settings.communityClient() else {
            isLoading = false
            errorMessage = "服务器地址无效，请在“设置”中检查。"
            return
        }
        if profile == nil { isLoading = true }
        errorMessage = nil
        do {
            async let loadedProfile = client.user(id: userID)
            async let firstPage = client.userScores(userID: userID, page: 1, pageSize: Self.pageSize)
            let (p, s) = try await (loadedProfile, firstPage)
            profile = p
            uploads = s.items
            uploadsTotal = s.total
            page = 1
        } catch {
            if profile == nil { errorMessage = describeError(error) }
        }
        isLoading = false
    }

    private func loadMoreIfNeeded(current item: CommunityScoreSummary) async {
        guard !isLoadingMore, uploads.count < uploadsTotal,
              let index = uploads.firstIndex(where: { $0.id == item.id }), index >= uploads.count - 3,
              let client = settings.communityClient() else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await client.userScores(userID: userID, page: page + 1, pageSize: Self.pageSize)
            let known = Set(uploads.map { $0.id })
            uploads.append(contentsOf: next.items.filter { !known.contains($0.id) })
            uploadsTotal = next.total
            page += 1
        } catch {
            // Keep what is shown; pulling to refresh retries.
        }
    }
}
