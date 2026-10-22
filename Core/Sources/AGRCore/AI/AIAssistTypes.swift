import Foundation

// MARK: - Input contract (produced by the OMR engine / import review)

public enum AIIssueKind: String, Codable, CaseIterable, Sendable {
    case beatSumMismatch
    case lowConfidenceSymbol
    case unknownChord
    case lyricAlignment
    case suspectedWatermark
    case other
}

/// One flagged problem the deterministic engine could not settle on its own.
public struct AIIssue: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: AIIssueKind
    /// JSONPath-like location in the Score JSON, e.g. `sections[0].lines[2].system.measures[3].tab[1]`.
    public var path: String
    public var message: String
    /// Compact textual rendering of the surrounding measures (see `AICompactRenderer`).
    public var context: String
    public var ocrSnippets: [String]
    /// JPEG crop of the region on the page (only sent when the provider supports vision).
    public var imageCrop: Data?

    public init(id: String, kind: AIIssueKind, path: String, message: String, context: String = "",
                ocrSnippets: [String] = [], imageCrop: Data? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.message = message
        self.context = context
        self.ocrSnippets = ocrSnippets
        self.imageCrop = imageCrop
    }

    enum CodingKeys: String, CodingKey { case id, kind, path, message, context, ocrSnippets, imageCrop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(AIIssueKind.self, forKey: .kind) ?? .other
        path = try c.decode(String.self, forKey: .path)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        ocrSnippets = try c.decodeIfPresent([String].self, forKey: .ocrSnippets) ?? []
        imageCrop = try c.decodeIfPresent(Data.self, forKey: .imageCrop)
    }
}

// MARK: - Results

/// Before → after rendering of the part of the score one fix touches.
public struct AIChange: Codable, Hashable, Sendable {
    public var path: String
    public var before: String
    public var after: String
    public init(path: String, before: String, after: String) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// A validated set of patch operations that fixes (part of) one or more issues.
public struct AppliedFix: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var issueIDs: [String]
    public var ops: [PatchOp]
    public var changes: [AIChange]
    public var notes: String
    public init(id: String, issueIDs: [String], ops: [PatchOp], changes: [AIChange], notes: String = "") {
        self.id = id
        self.issueIDs = issueIDs
        self.ops = ops
        self.changes = changes
        self.notes = notes
    }
}

/// A suggestion (or a whole response) that was not applied, with the reason.
public struct RejectedFix: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var issueIDs: [String]
    public var ops: [PatchOp]
    public var reason: String
    public init(id: String, issueIDs: [String], ops: [PatchOp] = [], reason: String) {
        self.id = id
        self.issueIDs = issueIDs
        self.ops = ops
        self.reason = reason
    }
}

// MARK: - Errors

public enum AIError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured(String)
    case invalidURL
    /// 401 / 403: the key is missing, wrong or lacks permission. Never retried.
    case unauthorized(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case http(status: Int, message: String?)
    case timeout
    case network(String)
    case badResponse(String)
    case fixtureMissing(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return "AI 辅助未配置：\(why)"
        case .invalidURL: return "Base URL 无效"
        case .unauthorized(let m): return "API Key 无效或无权限" + (m.map { "：\($0)" } ?? "")
        case .rateLimited: return "请求过于频繁（429），请稍后再试"
        case .server(let s, let m): return "服务端错误（\(s)）" + (m.map { "：\($0)" } ?? "")
        case .http(let s, let m): return "请求失败（\(s)）" + (m.map { "：\($0)" } ?? "")
        case .timeout: return "请求超时"
        case .network(let m): return "网络错误：\(m)"
        case .badResponse(let m): return "响应格式异常：\(m)"
        case .fixtureMissing(let h): return "缺少录制的应答：\(h)"
        }
    }

    /// Errors after which further requests are pointless (the rest of the batches are skipped).
    public var isFatal: Bool {
        switch self {
        case .notConfigured, .invalidURL, .unauthorized, .network, .timeout: return true
        default: return false
        }
    }
}
