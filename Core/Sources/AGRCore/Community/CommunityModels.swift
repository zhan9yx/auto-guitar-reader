import Foundation

// MARK: - Community DTOs (wire format: snake_case JSON, see server/README.md)

public struct CommunityScoreSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var key: String?
    public var mode: PlayMode
    public var uploader: String
    public var downloads: Int
    public var createdAt: Date
    public var pageCount: Int
    /// Public user id of the uploader (`GET /users/{id}`); nil for servers without profiles.
    public var uploaderID: String?
    public var favorites: Int
    /// Only true when the request carried `X-Device-Id` and this device favorited the score.
    public var favoritedByMe: Bool

    public init(id: String, title: String, artist: String? = nil, key: String? = nil,
                mode: PlayMode = .strumSing, uploader: String = "匿名", downloads: Int = 0,
                createdAt: Date = Date(), pageCount: Int = 0,
                uploaderID: String? = nil, favorites: Int = 0, favoritedByMe: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.key = key
        self.mode = mode
        self.uploader = uploader
        self.downloads = downloads
        self.createdAt = createdAt
        self.pageCount = pageCount
        self.uploaderID = uploaderID
        self.favorites = favorites
        self.favoritedByMe = favoritedByMe
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, key, mode, uploader, downloads, favorites
        case createdAt = "created_at"
        case pageCount = "page_count"
        case uploaderID = "uploader_id"
        case favoritedByMe = "favorited_by_me"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        mode = try c.decodeIfPresent(PlayMode.self, forKey: .mode) ?? .strumSing
        uploader = try c.decodeIfPresent(String.self, forKey: .uploader) ?? "匿名"
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        uploaderID = try c.decodeIfPresent(String.self, forKey: .uploaderID)
        favorites = try c.decodeIfPresent(Int.self, forKey: .favorites) ?? 0
        favoritedByMe = try c.decodeIfPresent(Bool.self, forKey: .favoritedByMe) ?? false
        let raw = try c.decode(String.self, forKey: .createdAt)
        guard let date = CommunityDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: c,
                                                   debugDescription: "Invalid ISO-8601 date: \(raw)")
        }
        createdAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(key, forKey: .key)
        try c.encode(mode, forKey: .mode)
        try c.encode(uploader, forKey: .uploader)
        try c.encode(downloads, forKey: .downloads)
        try c.encode(CommunityDate.format(createdAt), forKey: .createdAt)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encodeIfPresent(uploaderID, forKey: .uploaderID)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(favoritedByMe, forKey: .favoritedByMe)
    }
}

public struct CommunitySearchResponse: Codable, Sendable {
    public var items: [CommunityScoreSummary]
    public var total: Int
    public var page: Int
    public var pageSize: Int

    public init(items: [CommunityScoreSummary], total: Int, page: Int, pageSize: Int) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
    }

    enum CodingKeys: String, CodingKey {
        case items, total, page
        case pageSize = "page_size"
    }
}

public enum CommunitySort: String, Sendable {
    case recent, popular
}

public enum CommunityError: Error, Equatable, Sendable {
    /// Non-2xx response. `detail` is the server's `{"detail": "..."}` message when present.
    case http(status: Int, detail: String?)
    case decoding(String)
    case invalidURL
}

/// ISO-8601 parsing tolerant of fractional seconds ("2026-10-21T08:30:00Z" and "...00.123456Z").
enum CommunityDate {
    static func parse(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: string) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) { return d }
        // Foundation's fractional parser rejects >3 digits on some platforms (e.g. Python microseconds): trim.
        if let dot = string.firstIndex(of: "."),
           let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = string[string.index(after: dot)..<zone]
            if digits.count > 3, digits.allSatisfy(\.isNumber) {
                let trimmed = string[..<dot] + "." + digits.prefix(3) + string[zone...]
                return fractional.date(from: String(trimmed))
            }
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Profiles

public enum CommunityLevel: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced
}

public struct CommunityProfileStats: Codable, Hashable, Sendable {
    public var uploads: Int
    public var downloads: Int
    public var favoritesReceived: Int

    public init(uploads: Int = 0, downloads: Int = 0, favoritesReceived: Int = 0) {
        self.uploads = uploads
        self.downloads = downloads
        self.favoritesReceived = favoritesReceived
    }

    enum CodingKeys: String, CodingKey {
        case uploads, downloads
        case favoritesReceived = "favorites_received"
    }
}

/// Profile as served by `GET /me` (with `updatedAt` / `favoritesCount`) and `GET /users/{id}` (without them).
public struct CommunityProfile: Codable, Hashable, Identifiable, Sendable {
    public static let maxNicknameLength = 24
    public static let maxBioLength = 200
    public static let maxGenres = 5
    public static let maxGenreLength = 20
    public static let maxAvatarBytes = 1024 * 1024

    public var userID: String
    public var nickname: String
    public var bio: String
    public var avatarEmoji: String?
    /// Server-relative path (`/api/v1/users/<id>/avatar?v=…`); resolve with `CommunityClient.avatarURL(for:)`.
    public var avatarURL: String?
    public var level: CommunityLevel?
    public var genres: [String]
    public var createdAt: Date
    public var updatedAt: Date?
    public var favoritesCount: Int?
    public var stats: CommunityProfileStats

    public var id: String { userID }

    public init(userID: String, nickname: String, bio: String = "", avatarEmoji: String? = nil, avatarURL: String? = nil,
                level: CommunityLevel? = nil, genres: [String] = [], createdAt: Date = Date(), updatedAt: Date? = nil,
                favoritesCount: Int? = nil, stats: CommunityProfileStats = CommunityProfileStats()) {
        self.userID = userID
        self.nickname = nickname
        self.bio = bio
        self.avatarEmoji = avatarEmoji
        self.avatarURL = avatarURL
        self.level = level
        self.genres = genres
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.favoritesCount = favoritesCount
        self.stats = stats
    }

    enum CodingKeys: String, CodingKey {
        case nickname, bio, level, genres, stats
        case userID = "user_id"
        case avatarEmoji = "avatar_emoji"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case favoritesCount = "favorites_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        nickname = try c.decode(String.self, forKey: .nickname)
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        avatarEmoji = try c.decodeIfPresent(String.self, forKey: .avatarEmoji)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        // Unknown levels from a newer server degrade to nil instead of failing the whole profile.
        level = (try c.decodeIfPresent(String.self, forKey: .level)).flatMap(CommunityLevel.init(rawValue:))
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        stats = try c.decodeIfPresent(CommunityProfileStats.self, forKey: .stats) ?? CommunityProfileStats()
        favoritesCount = try c.decodeIfPresent(Int.self, forKey: .favoritesCount)
        createdAt = try Self.date(c, .createdAt)
        if c.contains(.updatedAt), try !c.decodeNil(forKey: .updatedAt) {
            updatedAt = try Self.date(c, .updatedAt)
        } else {
            updatedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userID, forKey: .userID)
        try c.encode(nickname, forKey: .nickname)
        try c.encode(bio, forKey: .bio)
        try c.encode(avatarEmoji, forKey: .avatarEmoji)
        try c.encode(avatarURL, forKey: .avatarURL)
        try c.encode(level, forKey: .level)
        try c.encode(genres, forKey: .genres)
        try c.encode(stats, forKey: .stats)
        try c.encodeIfPresent(favoritesCount, forKey: .favoritesCount)
        try c.encode(CommunityDate.format(createdAt), forKey: .createdAt)
        if let updatedAt { try c.encode(CommunityDate.format(updatedAt), forKey: .updatedAt) }
    }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let raw = try c.decode(String.self, forKey: key)
        guard let date = CommunityDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid ISO-8601 date: \(raw)")
        }
        return date
    }
}

/// Partial profile update for `PUT /me`. Only fields that are set are sent. For the clearable fields the outer
/// optional means "do not send" and `.some(nil)` means "clear" (JSON `null`).
public struct CommunityProfileUpdate: Encodable, Equatable, Sendable {
    public var nickname: String?
    public var bio: String?
    public var avatarEmoji: String??
    public var level: CommunityLevel??
    public var genres: [String]?

    public init(nickname: String? = nil, bio: String? = nil, avatarEmoji: String?? = nil,
                level: CommunityLevel?? = nil, genres: [String]? = nil) {
        self.nickname = nickname
        self.bio = bio
        self.avatarEmoji = avatarEmoji
        self.level = level
        self.genres = genres
    }

    enum CodingKeys: String, CodingKey {
        case nickname, bio, level, genres
        case avatarEmoji = "avatar_emoji"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(bio, forKey: .bio)
        try c.encodeIfPresent(genres, forKey: .genres)
        if let emoji = avatarEmoji {
            if let value = emoji { try c.encode(value, forKey: .avatarEmoji) } else { try c.encodeNil(forKey: .avatarEmoji) }
        }
        if let lvl = level {
            if let value = lvl { try c.encode(value, forKey: .level) } else { try c.encodeNil(forKey: .level) }
        }
    }
}

public struct CommunityFavoriteState: Codable, Hashable, Sendable {
    public var favorited: Bool
    public var favorites: Int

    public init(favorited: Bool, favorites: Int) {
        self.favorited = favorited
        self.favorites = favorites
    }
}
