import Foundation
import Observation
import AGRCore

/// The slice of `CommunityClient` the profile screens need (lets tests substitute a fake server).
protocol ProfileRemote: Sendable {
    func me() async throws -> CommunityProfile
    func updateMe(_ update: CommunityProfileUpdate) async throws -> CommunityProfile
    func uploadAvatar(data: Data, mimeType: String) async throws -> CommunityProfile
    func deleteAvatar() async throws -> CommunityProfile
    func fetchAvatar(for profile: CommunityProfile) async throws -> Data?
    func user(id: String) async throws -> CommunityProfile
    func userScores(userID: String, page: Int, pageSize: Int) async throws -> CommunitySearchResponse
    func myScores(page: Int, pageSize: Int) async throws -> CommunitySearchResponse
    func favorites(page: Int, pageSize: Int) async throws -> CommunitySearchResponse
    func favorite(scoreID: String) async throws -> CommunityFavoriteState
    func unfavorite(scoreID: String) async throws -> CommunityFavoriteState
    func deleteScore(id: String) async throws
}

extension CommunityClient: ProfileRemote {}

/// Offline-first owner of the user's own profile: edits are applied and persisted locally at once and pushed to the
/// server whenever it is reachable (on every edit, on appear and on foreground). Dirty fields win over the server.
@Observable
@MainActor
final class ProfileStore {
    static let shared = ProfileStore()
    static let listPageSize = 50

    private(set) var local: LocalProfile
    private(set) var avatarData: Data?
    private(set) var isSyncing = false
    private(set) var syncError: String?

    private(set) var uploads: [CommunityScoreSummary] = []
    private(set) var uploadsTotal = 0
    private(set) var uploadsError: String?
    private(set) var isLoadingUploads = false

    private(set) var favorites: [CommunityScoreSummary] = []
    private(set) var favoritesTotal = 0
    private(set) var favoritesError: String?
    private(set) var isLoadingFavorites = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var remoteProvider: () -> (any ProfileRemote)?
    @ObservationIgnored private weak var settings: SettingsStore?

    init(directory: URL = ProfileStore.defaultDirectory(),
         defaultNickname: String? = nil,
         now: @escaping () -> Date = Date.init,
         remoteProvider: @escaping () -> (any ProfileRemote)? = { nil }) {
        self.directory = directory
        self.now = now
        self.remoteProvider = remoteProvider
        let fallback = defaultNickname
            ?? UserDefaults.standard.string(forKey: SettingsStore.Keys.nickname)
            ?? "吉他手"
        if let data = try? Data(contentsOf: directory.appendingPathComponent("profile.json")),
           let stored = try? ProfileStore.decoder().decode(LocalProfile.self, from: data) {
            local = stored
        } else {
            local = LocalProfile(nickname: fallback, now: now())
        }
        if local.hasAvatarImage {
            avatarData = try? Data(contentsOf: directory.appendingPathComponent("avatar.jpg"))
            if avatarData == nil { local.hasAvatarImage = false }
        }
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Profile", isDirectory: true)
    }

    /// Wires the store to the app settings (server URL / device id). Safe to call repeatedly.
    func attach(settings: SettingsStore) {
        self.settings = settings
        remoteProvider = { [weak settings] in settings?.communityClient().map { $0 as any ProfileRemote } }
        // A device that never edited its profile keeps showing the nickname it had in Settings.
        if local.lastSyncedAt == nil, local.dirty == [.nickname], settings.nickname != local.nickname {
            local.nickname = ProfileRules.nickname(settings.nickname).isEmpty ? local.nickname : ProfileRules.nickname(settings.nickname)
            persist()
        }
    }

    // MARK: Derived

    var displayNickname: String { local.nickname.isEmpty ? "吉他手" : local.nickname }
    var stats: CommunityProfileStats { local.server?.stats ?? CommunityProfileStats() }
    var userID: String? { local.server?.userID }

    // MARK: Editing (always works offline)

    func update(_ edit: LocalProfile.Edit) {
        local.apply(edit, now: now())
        if let name = edit.nickname.map(ProfileRules.nickname), !name.isEmpty { settings?.nickname = name }
        persist()
        Task { await sync() }
    }

    /// `jpeg` is the already cropped / downscaled image (see `AvatarImageProcessor`).
    func setAvatarImage(jpeg: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: avatarFileURL, options: .atomic)
        } catch {
            syncError = "无法保存头像：\(error.localizedDescription)"
            return
        }
        avatarData = jpeg
        update(LocalProfile.Edit(avatarImage: true))
    }

    func setAvatarEmoji(_ emoji: String?) {
        removeAvatarFile()
        update(LocalProfile.Edit(avatarEmoji: .some(emoji)))
    }

    // MARK: Sync

    /// Pushes pending edits, then refreshes the cached server profile. Never throws: failures are kept in `syncError`
    /// and the edits stay pending for the next attempt.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for _ in 0..<3 {
            syncError = nil
            guard let remote = remoteProvider() else {
                syncError = local.hasPendingChanges ? "无法连接服务器，修改已保存在本机，稍后自动同步。" : nil
                return
            }
            do {
                try await syncOnce(remote)
            } catch {
                handleSyncFailure(error)
                return
            }
            if !local.hasPendingChanges { break }
        }
    }

    private func syncOnce(_ remote: any ProfileRemote) async throws {
        var contacted = false
        let sent = local
        if let update = sent.pendingUpdate() {
            let response = try await remote.updateMe(update)
            contacted = true
            var covered = sent.dirty.subtracting([.avatar])
            if sent.avatarEmoji != nil { covered.insert(.avatar) }
            local.markSynced(covered, sentSnapshot: sent)
            local.merge(server: response, now: now())
        }
        let avatarSent = local
        switch avatarSent.pendingAvatarAction {
        case .upload:
            guard let data = avatarData else {
                local.dirty.remove(.avatar)
                break
            }
            let response = try await remote.uploadAvatar(data: data, mimeType: "image/jpeg")
            contacted = true
            local.markSynced([.avatar], sentSnapshot: avatarSent)
            if !local.dirty.contains(.avatar) { local.avatarSourceURL = response.avatarURL }
            local.merge(server: response, now: now())
        case .remove:
            let response = try await remote.deleteAvatar()
            contacted = true
            local.markSynced([.avatar], sentSnapshot: avatarSent)
            local.merge(server: response, now: now())
        case .none:
            break
        }
        if !contacted {
            local.merge(server: try await remote.me(), now: now())
        }
        persist()
        await refreshAvatarImage(remote)
        persist()
    }

    /// Downloads the server's avatar image when it is newer than the cached file.
    private func refreshAvatarImage(_ remote: any ProfileRemote) async {
        guard !local.dirty.contains(.avatar), let server = local.server else { return }
        guard let url = server.avatarURL else {
            if local.hasAvatarImage { removeAvatarFile(); local.hasAvatarImage = false; local.avatarSourceURL = nil }
            return
        }
        guard local.avatarSourceURL != url || !local.hasAvatarImage else { return }
        guard let data = try? await remote.fetchAvatar(for: server), !data.isEmpty, !local.dirty.contains(.avatar) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: avatarFileURL, options: .atomic)
        } catch { return }
        avatarData = data
        local.hasAvatarImage = true
        local.avatarSourceURL = url
        local.avatarEmoji = nil
    }

    private func handleSyncFailure(_ error: Error) {
        if let community = error as? CommunityError, case .http(let status, _) = community,
           (400..<500).contains(status), status != 429 {
            // The server will never accept these edits as they are: drop them instead of retrying forever.
            local.dirty = []
            persist()
            syncError = "服务器拒绝了修改：\(describeError(error))"
        } else {
            syncError = local.hasPendingChanges
                ? "暂时无法同步，修改已保存在本机：\(describeError(error))"
                : describeError(error)
        }
    }

    // MARK: Lists

    func loadUploads() async {
        guard !isLoadingUploads else { return }
        guard let remote = remoteProvider() else { uploadsError = "服务器地址无效，请在“设置”中检查。"; return }
        isLoadingUploads = true
        defer { isLoadingUploads = false }
        do {
            let response = try await remote.myScores(page: 1, pageSize: Self.listPageSize)
            uploads = response.items
            uploadsTotal = response.total
            uploadsError = nil
        } catch {
            uploadsError = describeError(error)
        }
    }

    func loadFavorites() async {
        guard !isLoadingFavorites else { return }
        guard let remote = remoteProvider() else { favoritesError = "服务器地址无效，请在“设置”中检查。"; return }
        isLoadingFavorites = true
        defer { isLoadingFavorites = false }
        do {
            let response = try await remote.favorites(page: 1, pageSize: Self.listPageSize)
            favorites = response.items
            favoritesTotal = response.total
            favoritesError = nil
        } catch {
            favoritesError = describeError(error)
        }
    }

    /// Deletes one of my uploads on the server, then drops it from the list and refreshes the stats.
    func deleteUpload(id: String) async throws {
        guard let remote = remoteProvider() else { throw CommunityError.invalidURL }
        try await remote.deleteScore(id: id)
        if uploads.contains(where: { $0.id == id }) {
            uploads.removeAll { $0.id == id }
            uploadsTotal = max(0, uploadsTotal - 1)
        }
        if favorites.contains(where: { $0.id == id }) { favoritesTotal = max(0, favoritesTotal - 1) }
        favorites.removeAll { $0.id == id }
        Task { await sync() }
    }

    /// Sets the favorite state on the server; returns the authoritative state.
    @discardableResult
    func setFavorite(scoreID: String, favorite: Bool) async throws -> CommunityFavoriteState {
        guard let remote = remoteProvider() else { throw CommunityError.invalidURL }
        let state: CommunityFavoriteState
        if favorite {
            state = try await remote.favorite(scoreID: scoreID)
        } else {
            state = try await remote.unfavorite(scoreID: scoreID)
        }
        if !state.favorited {
            if favorites.contains(where: { $0.id == scoreID }) { favoritesTotal = max(0, favoritesTotal - 1) }
            favorites.removeAll { $0.id == scoreID }
        }
        if let index = uploads.firstIndex(where: { $0.id == scoreID }) {
            uploads[index].favorites = state.favorites
            uploads[index].favoritedByMe = state.favorited
        }
        return state
    }

    // MARK: Persistence

    private var profileFileURL: URL { directory.appendingPathComponent("profile.json") }
    private var avatarFileURL: URL { directory.appendingPathComponent("avatar.jpg") }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ProfileStore.encoder().encode(local).write(to: profileFileURL, options: .atomic)
        } catch {
            // Non-fatal: the in-memory state is still correct for this launch.
        }
    }

    private func removeAvatarFile() {
        try? FileManager.default.removeItem(at: avatarFileURL)
        avatarData = nil
    }

    nonisolated static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    nonisolated static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
