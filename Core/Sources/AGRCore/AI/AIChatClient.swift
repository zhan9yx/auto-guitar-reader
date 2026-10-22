import Foundation

// MARK: - Provider-independent chat types

public enum AIContentPart: Hashable, Sendable {
    case text(String)
    /// JPEG bytes; sent as a `data:image/jpeg;base64,` URL part (vision providers only).
    case imageJPEG(Data)
}

public struct AIChatMessage: Hashable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var parts: [AIContentPart]
    public init(role: Role, parts: [AIContentPart]) {
        self.role = role
        self.parts = parts
    }
    public init(role: Role, text: String) {
        self.role = role
        self.parts = [.text(text)]
    }
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
    public var images: [Data] {
        parts.compactMap { if case .imageJPEG(let d) = $0 { return d } else { return nil } }
    }
}

public struct AIChatRequest: Hashable, Sendable {
    public var messages: [AIChatMessage]
    /// Ask for a JSON object (honoured when the provider supports it).
    public var jsonMode: Bool
    public var temperature: Double
    public var maxTokens: Int?
    public init(messages: [AIChatMessage], jsonMode: Bool = true, temperature: Double = 0, maxTokens: Int? = nil) {
        self.messages = messages
        self.jsonMode = jsonMode
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Stable key of the request *messages* (FNV-1a 64 over roles, texts and image digests).
    /// Used to name recorded fixtures; independent of model / temperature.
    public var fixtureKey: String { AIFixtureHash.key(for: messages) }
}

public struct AIChatResponse: Hashable, Sendable {
    public var content: String
    public var model: String?
    public var latency: TimeInterval
    public init(content: String, model: String? = nil, latency: TimeInterval = 0) {
        self.content = content
        self.model = model
        self.latency = latency
    }
}

public protocol AIChatClient: Sendable {
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse
}

// MARK: - Hashing

public enum AIFixtureHash {
    public static func fnv1a64<S: Sequence>(_ bytes: S, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 where S.Element == UInt8 {
        var h = seed
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    public static func hex(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }

    public static func key(for messages: [AIChatMessage]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func feed(_ s: String) { h = fnv1a64(Array(s.utf8), seed: h) }
        for m in messages {
            feed("\u{1}" + m.role.rawValue + "\u{2}")
            for p in m.parts {
                switch p {
                case .text(let t): feed("T" + t + "\u{3}")
                case .imageJPEG(let d): feed("I" + hex(fnv1a64(d)) + "\u{3}")
                }
            }
        }
        return hex(h)
    }
}

// MARK: - Recorded / recording clients (offline tests and evaluation)

/// Replays model answers from `<directory>/<fixtureKey>.response.json`. The file content is the
/// raw model output (the patch JSON, optionally inside a ```json fence).
public struct RecordedAIClient: AIChatClient {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func responseURL(directory: URL, key: String) -> URL {
        directory.appendingPathComponent("\(key).response.json")
    }

    public func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        let key = request.fixtureKey
        let url = Self.responseURL(directory: directory, key: key)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw AIError.fixtureMissing(key)
        }
        return AIChatResponse(content: text, model: "recorded")
    }
}

/// Wraps a real client and records every answer as a fixture (for later replay).
public struct RecordingAIClient: AIChatClient {
    public let base: AIChatClient
    public let directory: URL
    public init(base: AIChatClient, directory: URL) {
        self.base = base
        self.directory = directory
    }

    public func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        let response = try await base.complete(request)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(response.content.utf8).write(to: RecordedAIClient.responseURL(directory: directory, key: request.fixtureKey))
        return response
    }
}
