import Foundation
import AGRCore

/// Profile fields that can be edited offline and synced later.
enum ProfileField: String, Codable, CaseIterable, Sendable {
    case nickname, bio, level, genres, avatar
}

/// The device's own copy of the user's profile (`profile.json`), plus which fields still need to reach the server.
/// Offline-first rule: dirty fields always win over what the server says; clean fields follow the server.
struct LocalProfile: Codable, Equatable, Sendable {
    var nickname: String
    var bio: String
    var level: CommunityLevel?
    var genres: [String]
    /// Emoji avatar. Mutually exclusive with `hasAvatarImage`.
    var avatarEmoji: String?
    /// A custom avatar image is stored next to `profile.json` (see `ProfileStore.avatarFileURL`).
    var hasAvatarImage: Bool
    /// Fields edited locally and not yet accepted by the server.
    var dirty: Set<ProfileField>
    /// Last profile received from the server (cache for offline display: stats, public id, ...).
    var server: CommunityProfile?
    /// `avatarURL` the cached avatar image file was downloaded from (server-sourced images only).
    var avatarSourceURL: String?
    var lastSyncedAt: Date?
    var updatedAt: Date

    init(nickname: String, now: Date = Date()) {
        self.nickname = nickname
        bio = ""
        level = nil
        genres = []
        avatarEmoji = nil
        hasAvatarImage = false
        // A brand-new device pushes its nickname so that the server stops using the placeholder "匿名".
        dirty = [.nickname]
        server = nil
        avatarSourceURL = nil
        lastSyncedAt = nil
        updatedAt = now
    }

    var hasPendingChanges: Bool { !dirty.isEmpty }

    // MARK: Local edits

    struct Edit: Sendable {
        var nickname: String?
        var bio: String?
        var level: CommunityLevel??
        var genres: [String]?
        /// `.some(nil)` clears the avatar entirely.
        var avatarEmoji: String??
        var avatarImage: Bool?    // true = a new image file was stored

        init(nickname: String? = nil, bio: String? = nil, level: CommunityLevel?? = nil, genres: [String]? = nil,
             avatarEmoji: String?? = nil, avatarImage: Bool? = nil) {
            self.nickname = nickname
            self.bio = bio
            self.level = level
            self.genres = genres
            self.avatarEmoji = avatarEmoji
            self.avatarImage = avatarImage
        }
    }

    /// Applies (sanitized) edits locally and marks the touched fields dirty.
    mutating func apply(_ edit: Edit, now: Date = Date()) {
        if let value = edit.nickname {
            let clean = ProfileRules.nickname(value)
            if !clean.isEmpty, clean != nickname { nickname = clean; dirty.insert(.nickname) }
        }
        if let value = edit.bio {
            let clean = ProfileRules.bio(value)
            if clean != bio { bio = clean; dirty.insert(.bio) }
        }
        if let value = edit.level, value != level { level = value; dirty.insert(.level) }
        if let value = edit.genres {
            let clean = ProfileRules.genres(value)
            if clean != genres { genres = clean; dirty.insert(.genres) }
        }
        if let emoji = edit.avatarEmoji {
            let clean = emoji.flatMap { ProfileRules.emoji($0) }
            avatarEmoji = clean
            hasAvatarImage = false
            avatarSourceURL = nil
            dirty.insert(.avatar)
        } else if edit.avatarImage == true {
            avatarEmoji = nil
            hasAvatarImage = true
            avatarSourceURL = nil
            dirty.insert(.avatar)
        }
        updatedAt = now
    }

    // MARK: Sync

    /// The `PUT /me` body for the dirty text fields (nil when only the avatar — or nothing — is pending).
    /// An emoji avatar travels in the same request; image uploads / removals are separate calls.
    func pendingUpdate() -> CommunityProfileUpdate? {
        var update = CommunityProfileUpdate()
        var any = false
        if dirty.contains(.nickname) { update.nickname = nickname; any = true }
        if dirty.contains(.bio) { update.bio = bio; any = true }
        if dirty.contains(.level) { update.level = .some(level); any = true }
        if dirty.contains(.genres) { update.genres = genres; any = true }
        if dirty.contains(.avatar), let emoji = avatarEmoji { update.avatarEmoji = .some(emoji); any = true }
        return any ? update : nil
    }

    enum AvatarSync: Equatable { case none, upload, remove }

    /// What has to happen to the server-side avatar for a pending avatar edit that is not an emoji.
    var pendingAvatarAction: AvatarSync {
        guard dirty.contains(.avatar), avatarEmoji == nil else { return .none }
        return hasAvatarImage ? .upload : .remove
    }

    /// Takes over a server response: every field that is not dirty adopts the server's value.
    mutating func merge(server remote: CommunityProfile, now: Date = Date()) {
        server = remote
        lastSyncedAt = now
        if !dirty.contains(.nickname) { nickname = remote.nickname }
        if !dirty.contains(.bio) { bio = remote.bio }
        if !dirty.contains(.level) { level = remote.level }
        if !dirty.contains(.genres) { genres = remote.genres }
        if !dirty.contains(.avatar) {
            avatarEmoji = remote.avatarEmoji
            if remote.avatarURL == nil {
                hasAvatarImage = false
                avatarSourceURL = nil
            } else {
                // The image itself is (re)downloaded by the store when `avatarSourceURL` differs.
                hasAvatarImage = hasAvatarImage && avatarSourceURL == remote.avatarURL
            }
        }
    }

    /// The server accepted `sent`; fields edited again while the request was in flight stay dirty.
    mutating func markSynced(_ fields: Set<ProfileField>, sentSnapshot sent: LocalProfile) {
        for field in fields {
            switch field {
            case .nickname where nickname == sent.nickname: dirty.remove(.nickname)
            case .bio where bio == sent.bio: dirty.remove(.bio)
            case .level where level == sent.level: dirty.remove(.level)
            case .genres where genres == sent.genres: dirty.remove(.genres)
            case .avatar where avatarEmoji == sent.avatarEmoji && hasAvatarImage == sent.hasAvatarImage:
                dirty.remove(.avatar)
            default: break
            }
        }
    }
}

/// Client-side mirrors of the server's validation (server/app/profiles.py).
enum ProfileRules {
    static func nickname(_ s: String) -> String {
        String(printable(s).trimmingCharacters(in: .whitespaces).prefix(CommunityProfile.maxNicknameLength)).trimmingCharacters(in: .whitespaces)
    }

    static func bio(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.filter { $0 == "\n" || $0 == " " || !isControl($0) })
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CommunityProfile.maxBioLength))
    }

    static func genres(_ list: [String]) -> [String] {
        var out: [String] = []
        for raw in list {
            let g = String(printable(raw).trimmingCharacters(in: .whitespaces).prefix(CommunityProfile.maxGenreLength)).trimmingCharacters(in: .whitespaces)
            if !g.isEmpty, !out.contains(g) { out.append(g) }
            if out.count == CommunityProfile.maxGenres { break }
        }
        return out
    }

    /// Nil when `s` is not a plausible single emoji (letters / digits are rejected like the server does).
    static func emoji(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.count <= 8,
              !t.unicodeScalars.contains(where: { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) }) else { return nil }
        return t
    }

    private static func printable(_ s: String) -> String {
        String(s.unicodeScalars.filter { !isControl($0) })
    }

    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .control
    }
}

/// Fixed palette for the emoji avatar picker.
enum AvatarEmojis {
    static let all: [String] = [
        "🎸", "🎵", "🎶", "🎤", "🎧", "🥁", "🎹", "🎻", "🎺", "🪕", "🎼", "🎷",
        "🐱", "🐶", "🐼", "🦊", "🐯", "🐸", "🐧", "🦄", "🐳", "🦉", "🐰", "🐻",
        "🌟", "🔥", "🌈", "🌙", "☀️", "🍀", "🌸", "🍎", "☕️", "🍉", "🚀", "🎯",
    ]
}

/// Display strings for levels.
extension CommunityLevel {
    var label: String {
        switch self {
        case .beginner: return "入门"
        case .intermediate: return "进阶"
        case .advanced: return "高手"
        }
    }
}

enum GenreSuggestions {
    static let all = ["民谣", "流行", "摇滚", "爵士", "蓝调", "乡村", "古典", "指弹", "金属", "R&B", "轻音乐", "儿歌"]
}
