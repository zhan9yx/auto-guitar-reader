import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

/// Scriptable stand-in for the community server.
actor FakeRemote: ProfileRemote {
    struct Offline: Error {}

    var online = true
    var rejectUpdates: Int?          // HTTP status to answer PUT /me with
    var profile = CommunityProfile(userID: "abc0123456", nickname: "匿名")
    var updates: [CommunityProfileUpdate] = []
    var avatarUploads = 0
    var avatarDeletes = 0
    var avatarFetches = 0
    var meCalls = 0
    var myScoreItems: [CommunityScoreSummary] = []
    var favoriteItems: [CommunityScoreSummary] = []
    var deleted: [String] = []

    func setOnline(_ value: Bool) { online = value }
    func setReject(_ status: Int?) { rejectUpdates = status }
    func setProfile(_ p: CommunityProfile) { profile = p }
    func setScores(mine: [CommunityScoreSummary], favorites: [CommunityScoreSummary]) {
        myScoreItems = mine
        favoriteItems = favorites
    }
    func snapshot() -> (updates: [CommunityProfileUpdate], uploads: Int, deletes: Int, fetches: Int, me: Int, profile: CommunityProfile) {
        (updates, avatarUploads, avatarDeletes, avatarFetches, meCalls, profile)
    }

    private func check() throws { if !online { throw Offline() } }

    func me() async throws -> CommunityProfile { try check(); meCalls += 1; return profile }

    func updateMe(_ update: CommunityProfileUpdate) async throws -> CommunityProfile {
        try check()
        if let status = rejectUpdates { throw CommunityError.http(status: status, detail: "bad") }
        updates.append(update)
        if let v = update.nickname { profile.nickname = v }
        if let v = update.bio { profile.bio = v }
        if let v = update.genres { profile.genres = v }
        if let v = update.level { profile.level = v }
        if let v = update.avatarEmoji {
            profile.avatarEmoji = v
            if v != nil { profile.avatarURL = nil }
        }
        return profile
    }

    func uploadAvatar(data: Data, mimeType: String) async throws -> CommunityProfile {
        try check()
        avatarUploads += 1
        profile.avatarURL = "/api/v1/users/abc0123456/avatar?v=\(avatarUploads)"
        profile.avatarEmoji = nil
        return profile
    }

    func deleteAvatar() async throws -> CommunityProfile {
        try check()
        avatarDeletes += 1
        profile.avatarURL = nil
        profile.avatarEmoji = nil
        return profile
    }

    func fetchAvatar(for profile: CommunityProfile) async throws -> Data? {
        try check()
        avatarFetches += 1
        return Data([9, 9, 9])
    }

    func user(id: String) async throws -> CommunityProfile { try check(); return profile }
    func userScores(userID: String, page: Int, pageSize: Int) async throws -> CommunitySearchResponse {
        try check()
        return CommunitySearchResponse(items: myScoreItems, total: myScoreItems.count, page: page, pageSize: pageSize)
    }
    func myScores(page: Int, pageSize: Int) async throws -> CommunitySearchResponse {
        try check()
        return CommunitySearchResponse(items: myScoreItems, total: myScoreItems.count, page: page, pageSize: pageSize)
    }
    func favorites(page: Int, pageSize: Int) async throws -> CommunitySearchResponse {
        try check()
        return CommunitySearchResponse(items: favoriteItems, total: favoriteItems.count, page: page, pageSize: pageSize)
    }
    func favorite(scoreID: String) async throws -> CommunityFavoriteState {
        try check()
        return CommunityFavoriteState(favorited: true, favorites: 1)
    }
    func unfavorite(scoreID: String) async throws -> CommunityFavoriteState {
        try check()
        favoriteItems.removeAll { $0.id == scoreID }
        return CommunityFavoriteState(favorited: false, favorites: 0)
    }
    func deleteScore(id: String) async throws {
        try check()
        deleted.append(id)
        myScoreItems.removeAll { $0.id == id }
    }
}

final class ProfileStoreTests: XCTestCase {
    @MainActor
    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeStore(dir: URL, remote: FakeRemote?) -> ProfileStore {
        ProfileStore(directory: dir, defaultNickname: "吉他手1234", now: { Date(timeIntervalSince1970: 1_800_000_000) },
                     remoteProvider: { remote })
    }

    /// Edits spawn a background sync; drive one deterministically instead.
    @MainActor
    private func settle(_ store: ProfileStore) async {
        for _ in 0..<5 { await Task.yield() }
        await store.sync()
    }

    // MARK: offline-first

    @MainActor
    func testOfflineEditsPersistAndSurviveRelaunch() async throws {
        let dir = makeDir()
        let store = makeStore(dir: dir, remote: nil)
        store.update(LocalProfile.Edit(nickname: "小明", bio: "爱弹吉他", level: .some(.beginner), genres: ["民谣", "流行"]))
        store.setAvatarEmoji("🎸")
        await settle(store)

        XCTAssertEqual(store.local.nickname, "小明")
        XCTAssertEqual(store.local.dirty, [.nickname, .bio, .level, .genres, .avatar])
        XCTAssertNotNil(store.syncError)

        let relaunched = makeStore(dir: dir, remote: nil)
        XCTAssertEqual(relaunched.local, store.local)
        XCTAssertEqual(relaunched.local.avatarEmoji, "🎸")
    }

    @MainActor
    func testPendingEditsSyncWhenServerBecomesReachable() async throws {
        let remote = FakeRemote()
        await remote.setOnline(false)
        let store = makeStore(dir: makeDir(), remote: remote)
        store.update(LocalProfile.Edit(nickname: "小明", bio: "hi", level: .some(.advanced)))
        await settle(store)
        XCTAssertTrue(store.local.hasPendingChanges)
        XCTAssertNil(store.userID, "never reached the server")

        await remote.setOnline(true)
        await store.sync()
        XCTAssertFalse(store.local.hasPendingChanges)
        XCTAssertNil(store.syncError)
        XCTAssertEqual(store.userID, "abc0123456")
        let snap = await remote.snapshot()
        XCTAssertEqual(snap.profile.nickname, "小明")
        XCTAssertEqual(snap.profile.bio, "hi")
        XCTAssertEqual(snap.profile.level, .advanced)
        XCTAssertEqual(snap.updates.last?.nickname, "小明")
        XCTAssertNil(snap.updates.last?.genres, "untouched fields are not sent")
    }

    @MainActor
    func testDirtyFieldsWinOverServerCleanFieldsFollowIt() async throws {
        let remote = FakeRemote()
        let store = makeStore(dir: makeDir(), remote: remote)
        await store.sync()   // pushes the initial nickname, learns the profile
        XCTAssertFalse(store.local.hasPendingChanges)

        // Another device changes bio + level on the server while this one edits the nickname offline.
        var other = await remote.snapshot().profile
        other.bio = "来自另一台设备"
        other.level = .intermediate
        other.nickname = "被改掉的昵称"
        await remote.setProfile(other)
        await remote.setOnline(false)
        store.update(LocalProfile.Edit(nickname: "本地昵称"))
        await settle(store)
        XCTAssertEqual(store.local.dirty, [.nickname])

        // Merge directly (what a sync response does): dirty nickname survives, clean fields adopt the server.
        var merged = store.local
        merged.merge(server: other)
        XCTAssertEqual(merged.nickname, "本地昵称")
        XCTAssertEqual(merged.bio, "来自另一台设备")
        XCTAssertEqual(merged.level, .intermediate)

        await remote.setOnline(true)
        await store.sync()
        XCTAssertEqual(store.local.nickname, "本地昵称")
        XCTAssertEqual(store.local.bio, "来自另一台设备")
        let snapshot_ = await remote.snapshot()
        XCTAssertEqual(snapshot_.profile.nickname, "本地昵称")
        XCTAssertFalse(store.local.hasPendingChanges)
    }

    func testEditMadeWhileRequestInFlightStaysDirty() {
        var local = LocalProfile(nickname: "A")
        local.apply(LocalProfile.Edit(bio: "one"))
        let sent = local
        local.apply(LocalProfile.Edit(bio: "two"))              // edited again before the response arrived
        local.markSynced([.nickname, .bio], sentSnapshot: sent)
        XCTAssertEqual(local.dirty, [.bio], "nickname synced, newer bio still pending")
    }

    @MainActor
    func testFirstLaunchPushesNicknameAndNoOpEditsStayClean() async throws {
        let remote = FakeRemote()
        let store = makeStore(dir: makeDir(), remote: remote)
        XCTAssertEqual(store.local.nickname, "吉他手1234")
        XCTAssertEqual(store.local.dirty, [.nickname])
        await store.sync()
        let snapshot_ = await remote.snapshot()
        XCTAssertEqual(snapshot_.profile.nickname, "吉他手1234")
        store.update(LocalProfile.Edit(nickname: "吉他手1234", bio: ""))
        XCTAssertFalse(store.local.hasPendingChanges)
    }

    // MARK: avatar

    @MainActor
    func testImageAvatarUploadedOnceAndNotRedownloaded() async throws {
        let remote = FakeRemote()
        let dir = makeDir()
        let store = makeStore(dir: dir, remote: remote)
        await store.sync()
        store.setAvatarImage(jpeg: Data([1, 2, 3, 4]))
        XCTAssertTrue(store.local.hasAvatarImage)
        XCTAssertEqual(store.avatarData, Data([1, 2, 3, 4]))
        await settle(store)
        let snap = await remote.snapshot()
        XCTAssertEqual(snap.uploads, 1)
        XCTAssertEqual(snap.fetches, 0, "the freshly uploaded image is already cached")
        XCTAssertFalse(store.local.hasPendingChanges)
        XCTAssertTrue(store.local.hasAvatarImage)
        XCTAssertEqual(store.local.avatarSourceURL, snap.profile.avatarURL)

        let relaunched = makeStore(dir: dir, remote: remote)
        XCTAssertEqual(relaunched.avatarData, Data([1, 2, 3, 4]))
    }

    @MainActor
    func testEmojiReplacesImageAndRemovalCallsDelete() async throws {
        let remote = FakeRemote()
        let store = makeStore(dir: makeDir(), remote: remote)
        store.setAvatarImage(jpeg: Data([1]))
        await settle(store)
        store.setAvatarEmoji("🎵")
        await settle(store)
        XCTAssertNil(store.avatarData)
        XCTAssertFalse(store.local.hasAvatarImage)
        var snap = await remote.snapshot()
        XCTAssertEqual(snap.profile.avatarEmoji, "🎵")
        XCTAssertNil(snap.profile.avatarURL)

        store.setAvatarEmoji(nil)
        await settle(store)
        snap = await remote.snapshot()
        XCTAssertEqual(snap.deletes, 1)
        XCTAssertNil(store.local.avatarEmoji)
        XCTAssertFalse(store.local.hasPendingChanges)
    }

    @MainActor
    func testServerAvatarIsDownloadedAndCached() async throws {
        let remote = FakeRemote()
        var p = await remote.snapshot().profile
        p.avatarURL = "/api/v1/users/abc0123456/avatar?v=7"
        await remote.setProfile(p)
        let store = makeStore(dir: makeDir(), remote: remote)
        await store.sync()
        XCTAssertEqual(store.avatarData, Data([9, 9, 9]))
        XCTAssertTrue(store.local.hasAvatarImage)
        await store.sync()
        let snapshot_ = await remote.snapshot()
        XCTAssertEqual(snapshot_.fetches, 1, "same version is not downloaded twice")
    }

    // MARK: failures

    @MainActor
    func testRejectedEditsAreDroppedWithMessage() async throws {
        let remote = FakeRemote()
        await remote.setReject(422)
        let store = makeStore(dir: makeDir(), remote: remote)
        await store.sync()
        XCTAssertFalse(store.local.hasPendingChanges, "will never be accepted: not retried forever")
        XCTAssertNotNil(store.syncError)
    }

    @MainActor
    func testRateLimitKeepsEditsPending() async throws {
        let remote = FakeRemote()
        await remote.setReject(429)
        let store = makeStore(dir: makeDir(), remote: remote)
        await store.sync()
        XCTAssertTrue(store.local.hasPendingChanges)
        await remote.setReject(nil)
        await store.sync()
        XCTAssertFalse(store.local.hasPendingChanges)
    }

    // MARK: lists

    @MainActor
    private func summary(_ id: String) -> CommunityScoreSummary {
        CommunityScoreSummary(id: id, title: "T\(id)", favorites: 2, favoritedByMe: true)
    }

    @MainActor
    func testDeleteUploadAndUnfavoriteUpdateLists() async throws {
        let remote = FakeRemote()
        await remote.setScores(mine: [summary("a"), summary("b")], favorites: [summary("b"), summary("c")])
        let store = makeStore(dir: makeDir(), remote: remote)
        await store.loadUploads()
        await store.loadFavorites()
        XCTAssertEqual(store.uploads.map(\.id), ["a", "b"])
        XCTAssertEqual(store.favoritesTotal, 2)

        try await store.deleteUpload(id: "b")
        XCTAssertEqual(store.uploads.map(\.id), ["a"])
        XCTAssertEqual(store.uploadsTotal, 1)
        XCTAssertEqual(store.favorites.map(\.id), ["c"], "a deleted score disappears from favorites too")

        let state = try await store.setFavorite(scoreID: "c", favorite: false)
        XCTAssertFalse(state.favorited)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertEqual(store.favoritesTotal, 0)
    }

    @MainActor
    func testListLoadingWithoutServerReportsError() async {
        let store = makeStore(dir: makeDir(), remote: nil)
        await store.loadUploads()
        XCTAssertNotNil(store.uploadsError)
        do {
            try await store.deleteUpload(id: "x")
            XCTFail("expected failure")
        } catch {}
    }

    // MARK: rules

    func testProfileRules() {
        XCTAssertEqual(ProfileRules.nickname("  " + String(repeating: "字", count: 30) + "  ").count, 24)
        XCTAssertEqual(ProfileRules.nickname("a\u{0}b\nc"), "abc")
        XCTAssertEqual(ProfileRules.bio(String(repeating: "x", count: 300)).count, 200)
        XCTAssertEqual(ProfileRules.bio(" 第一行\n第二行 "), "第一行\n第二行")
        XCTAssertEqual(ProfileRules.genres(["a", " a ", "", "b", "c", "d", "e", "f", "g"]), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(ProfileRules.genres([String(repeating: "g", count: 40)]).first?.count, 20)
        XCTAssertEqual(ProfileRules.emoji(" 🎸 "), "🎸")
        XCTAssertNil(ProfileRules.emoji("abc"))
        XCTAssertNil(ProfileRules.emoji("1"))
        XCTAssertNil(ProfileRules.emoji(""))
        XCTAssertTrue(AvatarEmojis.all.allSatisfy { ProfileRules.emoji($0) != nil })
    }

    func testPendingUpdateOnlyContainsDirtyFields() {
        var local = LocalProfile(nickname: "N")
        local.dirty = []
        XCTAssertNil(local.pendingUpdate())
        local.apply(LocalProfile.Edit(level: .some(nil)))   // clearing the level is an edit too
        local.level = .beginner
        local.dirty = [.level]
        local.apply(LocalProfile.Edit(level: .some(nil)))
        let update = local.pendingUpdate()
        XCTAssertEqual(update?.level, .some(nil))
        XCTAssertNil(update?.nickname)
        let json = String(data: try! JSONEncoder().encode(update), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"level\":null"), json)
    }

    // MARK: favorites (optimistic UI)

    func testFavoriteSnapshotOptimisticToggle() {
        let off = FavoriteSnapshot(favorited: false, count: 0)
        XCTAssertEqual(off.toggled(), FavoriteSnapshot(favorited: true, count: 1))
        XCTAssertEqual(off.toggled().toggled(), off)
        XCTAssertEqual(FavoriteSnapshot(favorited: true, count: 0).toggled().count, 0, "never negative")
        XCTAssertEqual(FavoriteSnapshot(favorited: true, count: -4).count, 0)

        let summary = CommunityScoreSummary(id: "x", title: "T", favorites: 3, favoritedByMe: false)
        let flipped = summary.applying(FavoriteSnapshot(summary: summary).toggled())
        XCTAssertTrue(flipped.favoritedByMe)
        XCTAssertEqual(flipped.favorites, 4)
        let confirmed = flipped.applying(FavoriteSnapshot(state: CommunityFavoriteState(favorited: true, favorites: 9)))
        XCTAssertEqual(confirmed.favorites, 9, "server answer is authoritative")
    }
}
