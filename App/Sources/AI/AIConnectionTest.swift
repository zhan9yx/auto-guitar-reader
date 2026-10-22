import Foundation
import AGRCore

/// Result of the 测试连接 button.
struct AIConnectionResult: Equatable {
    var latency: TimeInterval
    var model: String

    /// e.g. "连接成功 · 0.42 秒 · deepseek-chat"
    var summary: String { String(format: "连接成功 · %.2f 秒 · %@", latency, model) }
}

enum AIConnectionTester {
    /// Sends a tiny request (a few tokens) and reports latency + the model the server answered with.
    /// Errors are mapped to user-readable text and never contain the API key.
    static func test(config: AIProviderConfig, client: AIChatClient? = nil) async -> Result<AIConnectionResult, AIError> {
        var small = config
        small.timeout = min(config.timeout, 20)
        let client = client ?? OpenAICompatibleClient(config: small, retryPolicy: AIRetryPolicy(maxAttempts: 1))
        let request = AIChatRequest(
            messages: [AIChatMessage(role: .user, text: "Reply with the single word: OK")],
            jsonMode: false, temperature: 0, maxTokens: 8)
        let started = Date()
        do {
            let response = try await client.complete(request)
            let latency = response.latency > 0 ? response.latency : Date().timeIntervalSince(started)
            let model = (response.model?.isEmpty == false) ? response.model! : config.model
            return .success(AIConnectionResult(latency: latency, model: model))
        } catch let error as AIError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
