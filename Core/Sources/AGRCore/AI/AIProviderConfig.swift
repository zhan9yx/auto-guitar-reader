import Foundation

/// Connection settings of an OpenAI-compatible chat-completions endpoint.
public struct AIProviderConfig: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var baseURL: URL
    public var model: String
    /// Secret. Never logged, never serialized (this type is intentionally not `Codable`).
    public var apiKey: String
    public var supportsVision: Bool
    /// Ask for `response_format: {"type":"json_object"}`.
    public var supportsJSONMode: Bool
    public var timeout: TimeInterval
    public var maxIssuesPerRequest: Int

    public init(baseURL: URL, model: String, apiKey: String, supportsVision: Bool = false,
                supportsJSONMode: Bool = true, timeout: TimeInterval = 60, maxIssuesPerRequest: Int = 8) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsVision = supportsVision
        self.supportsJSONMode = supportsJSONMode
        self.timeout = timeout
        self.maxIssuesPerRequest = max(1, maxIssuesPerRequest)
    }

    public static let deepSeekBaseURL = URL(string: "https://api.deepseek.com")!
    public static let deepSeekModel = "deepseek-chat"

    public static func deepSeek(apiKey: String) -> AIProviderConfig {
        AIProviderConfig(baseURL: deepSeekBaseURL, model: deepSeekModel, apiKey: apiKey)
    }

    public var description: String {
        "AIProviderConfig(baseURL: \(baseURL.absoluteString), model: \(model), apiKey: <redacted>, vision: \(supportsVision))"
    }
    public var debugDescription: String { description }
}

/// Retry policy: at most `maxAttempts` tries in total, only for 429 and 5xx.
public struct AIRetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 2, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func shouldRetry(status: Int, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        return status == 429 || (500..<600).contains(status)
    }

    /// Wait before attempt `attempt + 1`; honours `Retry-After` (seconds), clamped to `maxDelay`.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 { return min(retryAfter, maxDelay) }
        return min(baseDelay * pow(2, Double(max(0, attempt - 1))), maxDelay)
    }
}
