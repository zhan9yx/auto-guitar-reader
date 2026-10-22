import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request; injectable so tests never touch the network.
public protocol AIHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAITransport: AIHTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                else { continuation.resume(throwing: URLError(.badServerResponse)) }
            }
            task.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse("non-HTTP response") }
        return (data, http)
    }
}

/// OpenAI-compatible `POST {baseURL}/chat/completions` client (OpenAI, DeepSeek, …).
public struct OpenAICompatibleClient: AIChatClient {
    public let config: AIProviderConfig
    public let retryPolicy: AIRetryPolicy
    private let transport: AIHTTPTransport
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(config: AIProviderConfig,
                retryPolicy: AIRetryPolicy = AIRetryPolicy(),
                transport: AIHTTPTransport = URLSessionAITransport(),
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                }) {
        self.config = config
        self.retryPolicy = retryPolicy
        self.transport = transport
        self.sleeper = sleeper
    }

    // MARK: Request building (pure)

    /// `{baseURL}/chat/completions` (a base URL that already ends with it is kept as is).
    public func endpointURL() throws -> URL {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme, scheme.hasPrefix("http"), comps.host != nil else { throw AIError.invalidURL }
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        comps.percentEncodedPath = path
        guard let url = comps.url else { throw AIError.invalidURL }
        return url
    }

    public func makeBody(_ request: AIChatRequest) -> AIJSONValue {
        var messages: [AIJSONValue] = []
        for m in request.messages {
            let images = config.supportsVision ? m.images : []
            if images.isEmpty {
                messages.append(.object(["role": .string(m.role.rawValue), "content": .string(m.text)]))
            } else {
                var parts: [AIJSONValue] = []
                for p in m.parts {
                    switch p {
                    case .text(let t):
                        parts.append(.object(["type": .string("text"), "text": .string(t)]))
                    case .imageJPEG(let d):
                        parts.append(.object([
                            "type": .string("image_url"),
                            "image_url": .object(["url": .string("data:image/jpeg;base64," + d.base64EncodedString())]),
                        ]))
                    }
                }
                messages.append(.object(["role": .string(m.role.rawValue), "content": .array(parts)]))
            }
        }
        var body: [String: AIJSONValue] = [
            "model": .string(config.model),
            "messages": .array(messages),
            "temperature": .double(request.temperature),
        ]
        if let maxTokens = request.maxTokens { body["max_tokens"] = .int(maxTokens) }
        if request.jsonMode && config.supportsJSONMode {
            body["response_format"] = .object(["type": .string("json_object")])
        }
        return .object(body)
    }

    public func makeURLRequest(_ request: AIChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: try endpointURL())
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = config.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try makeBody(request).data()
        return urlRequest
    }

    // MARK: Response handling (pure)

    /// Extracts `error.message` (OpenAI/DeepSeek style) or a plain `message`, truncated.
    static func errorMessage(_ data: Data) -> String? {
        guard let json = try? AIJSONValue.parse(data) else { return nil }
        var text: String?
        if let err = json["error"] {
            text = err["message"]?.stringValue ?? err.stringValue
        }
        text = text ?? json["message"]?.stringValue
        guard let t = text, !t.isEmpty else { return nil }
        return String(t.prefix(300))
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        var raw: String?
        for (k, v) in response.allHeaderFields {
            if "\(k)".lowercased() == "retry-after" { raw = "\(v)"; break }
        }
        guard let raw, let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return seconds
    }

    public static func mapError(status: Int, data: Data, retryAfter: TimeInterval?) -> AIError {
        let message = errorMessage(data)
        switch status {
        case 401, 403: return .unauthorized(message)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500..<600: return .server(status: status, message: message)
        default: return .http(status: status, message: message)
        }
    }

    public static func parseCompletion(_ data: Data) throws -> (content: String, model: String?) {
        guard let json = try? AIJSONValue.parse(data) else { throw AIError.badResponse("not JSON") }
        guard let choice = json["choices"]?.arrayValue?.first, let message = choice["message"] else {
            throw AIError.badResponse("no choices")
        }
        let model = json["model"]?.stringValue
        if let s = message["content"]?.stringValue { return (s, model) }
        if let parts = message["content"]?.arrayValue {
            let text = parts.compactMap { $0["text"]?.stringValue }.joined()
            if !text.isEmpty { return (text, model) }
        }
        throw AIError.badResponse("empty content")
    }

    // MARK: AIChatClient

    public func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIError.notConfigured("缺少 API Key")
        }
        let urlRequest = try makeURLRequest(request)
        var attempt = 0
        while true {
            attempt += 1
            let started = Date()
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await transport.send(urlRequest)
            } catch let error as AIError {
                throw error
            } catch let error as URLError {
                if error.code == .timedOut { throw AIError.timeout }
                throw AIError.network(error.localizedDescription)
            } catch {
                throw AIError.network(error.localizedDescription)
            }
            if (200..<300).contains(http.statusCode) {
                let parsed = try Self.parseCompletion(data)
                return AIChatResponse(content: parsed.content, model: parsed.model,
                                      latency: Date().timeIntervalSince(started))
            }
            let wait = Self.retryAfter(http)
            if retryPolicy.shouldRetry(status: http.statusCode, attempt: attempt) {
                await sleeper(retryPolicy.delay(afterAttempt: attempt, retryAfter: wait))
                continue
            }
            throw Self.mapError(status: http.statusCode, data: data, retryAfter: wait)
        }
    }
}
