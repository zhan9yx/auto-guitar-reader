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

    public init(id: String, title: String, artist: String? = nil, key: String? = nil,
                mode: PlayMode = .strumSing, uploader: String = "匿名", downloads: Int = 0,
                createdAt: Date = Date(), pageCount: Int = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.key = key
        self.mode = mode
        self.uploader = uploader
        self.downloads = downloads
        self.createdAt = createdAt
        self.pageCount = pageCount
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, key, mode, uploader, downloads
        case createdAt = "created_at"
        case pageCount = "page_count"
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
