import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AGRCore

final class AIClientTests: XCTestCase {
    func config(vision: Bool = false, json: Bool = true, base: String = "https://api.deepseek.com") -> AIProviderConfig {
        AIProviderConfig(baseURL: URL(string: base)!, model: "deepseek-chat", apiKey: "test-key-123", supportsVision: vision, supportsJSONMode: json)
    }

    func client(_ cfg: AIProviderConfig, _ transport: AIHTTPTransport, sleeps: SleepLog = SleepLog()) -> OpenAICompatibleClient {
        OpenAICompatibleClient(config: cfg, transport: transport, sleeper: { sleeps.add($0) })
    }

    func req(images: [Data] = []) -> AIChatRequest {
        AIChatRequest(messages: [AIChatMessage(role: .system, text: "sys"),
                                 AIChatMessage(role: .user, parts: [.text("hello")] + images.map { .imageJPEG($0) })])
    }

    // MARK: Request building

    func testEndpointURLVariants() throws {
        let c = { (b: String) in try self.client(self.config(base: b), MockTransport([])).endpointURL().absoluteString }
        XCTAssertEqual(try c("https://api.deepseek.com"), "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try c("https://api.deepseek.com/"), "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try c("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try c("https://x.org/v1/chat/completions"), "https://x.org/v1/chat/completions")
        XCTAssertThrowsError(try c("ftp://x.org"))
    }

    func testRequestHeadersAndJSONMode() throws {
        let c = client(config(), MockTransport([]))
        let r = try c.makeURLRequest(req())
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(r.timeoutInterval, 60)
        let body = try AIJSONValue.parse(r.httpBody!)
        XCTAssertEqual(body["model"]?.stringValue, "deepseek-chat")
        XCTAssertEqual(body["response_format"]?["type"]?.stringValue, "json_object")
        XCTAssertEqual(body["messages"]?.arrayValue?.count, 2)
        XCTAssertEqual(body["messages"]?.arrayValue?[1]["content"]?.stringValue, "hello")
        XCTAssertEqual(body["temperature"]?.doubleValue, 0)
    }

    func testNoJSONModeWhenUnsupportedOrNotRequested() throws {
        let c = client(config(json: false), MockTransport([]))
        XCTAssertNil(try AIJSONValue.parse(try c.makeURLRequest(req()).httpBody!)["response_format"])
        var plain = req(); plain.jsonMode = false
        let c2 = client(config(), MockTransport([]))
        XCTAssertNil(try AIJSONValue.parse(try c2.makeURLRequest(plain).httpBody!)["response_format"])
    }

    func testVisionPartsOnlyWhenSupported() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let on = try AIJSONValue.parse(try client(config(vision: true), MockTransport([])).makeURLRequest(req(images: [jpeg])).httpBody!)
        let content = on["messages"]!.arrayValue![1]["content"]!.arrayValue!
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text")
        XCTAssertEqual(content[1]["type"]?.stringValue, "image_url")
        XCTAssertEqual(content[1]["image_url"]?["url"]?.stringValue, "data:image/jpeg;base64," + jpeg.base64EncodedString())
        let off = try AIJSONValue.parse(try client(config(vision: false), MockTransport([])).makeURLRequest(req(images: [jpeg])).httpBody!)
        XCTAssertEqual(off["messages"]!.arrayValue![1]["content"]?.stringValue, "hello")
    }

    func testConfigDescriptionRedactsKey() {
        XCTAssertFalse(config().description.contains("test-key-123"))
        XCTAssertFalse("\(config())".contains("test-key-123"))
    }

    // MARK: Responses / errors / retry

    func testSuccessParsesContent() async throws {
        let t = MockTransport([.init(status: 200, body: completionBody("{\"ops\":[]}"))])
        let r = try await client(config(), t).complete(req())
        XCTAssertEqual(r.content, "{\"ops\":[]}")
        XCTAssertEqual(r.model, "m-x")
        XCTAssertEqual(t.requests.count, 1)
    }

    func testUnauthorizedIsNotRetried() async {
        for status in [401, 403] {
            let t = MockTransport([.init(status: status, body: #"{"error":{"message":"Authentication Fails"}}"#),
                                   .init(status: 200, body: completionBody("x"))])
            do {
                _ = try await client(config(), t).complete(req())
                XCTFail("expected error")
            } catch let e as AIError {
                XCTAssertEqual(e, .unauthorized("Authentication Fails"))
                XCTAssertTrue(e.isFatal)
            } catch { XCTFail("\(error)") }
            XCTAssertEqual(t.requests.count, 1)
        }
    }

    func testRetries429HonoringRetryAfterThenSucceeds() async throws {
        let sleeps = SleepLog()
        let t = MockTransport([.init(status: 429, headers: ["Retry-After": "3"], body: "{}"),
                               .init(status: 200, body: completionBody("ok"))])
        let r = try await client(config(), t, sleeps: sleeps).complete(req())
        XCTAssertEqual(r.content, "ok")
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(sleeps.values, [3])
    }

    func testMaxTwoAttemptsOn5xx() async {
        let sleeps = SleepLog()
        let t = MockTransport([.init(status: 503, body: #"{"error":{"message":"busy"}}"#),
                               .init(status: 502, body: "{}"), .init(status: 200, body: completionBody("late"))])
        do {
            _ = try await client(config(), t, sleeps: sleeps).complete(req())
            XCTFail("expected error")
        } catch let e as AIError {
            XCTAssertEqual(e, .server(status: 502, message: nil))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(sleeps.values, [1], "default backoff 1s")
    }

    func testNoRetryOn400And404() async {
        for status in [400, 404] {
            let t = MockTransport([.init(status: status, body: #"{"error":{"message":"bad model"}}"#)])
            do { _ = try await client(config(), t).complete(req()); XCTFail() }
            catch let e as AIError { XCTAssertEqual(e, .http(status: status, message: "bad model")) }
            catch { XCTFail("\(error)") }
            XCTAssertEqual(t.requests.count, 1)
        }
    }

    func testRateLimitedErrorCarriesRetryAfterAfterExhaustion() async {
        let t = MockTransport([.init(status: 429, headers: ["retry-after": "2"], body: "{}"),
                               .init(status: 429, headers: ["retry-after": "2"], body: "{}")])
        do { _ = try await client(config(), t).complete(req()); XCTFail() }
        catch let e as AIError { XCTAssertEqual(e, .rateLimited(retryAfter: 2)) }
        catch { XCTFail("\(error)") }
    }

    func testBadResponseShapes() async {
        for body in ["not json", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":null}}]}"#] {
            let t = MockTransport([.init(status: 200, body: body)])
            do { _ = try await client(config(), t).complete(req()); XCTFail() }
            catch let e as AIError { if case .badResponse = e {} else { XCTFail("\(e)") } }
            catch { XCTFail("\(error)") }
        }
    }

    func testMissingKeyIsNotConfiguredAndSendsNothing() async {
        var cfg = config(); cfg.apiKey = "  "
        let t = MockTransport([])
        do { _ = try await client(cfg, t).complete(req()); XCTFail() }
        catch let e as AIError { if case .notConfigured = e {} else { XCTFail("\(e)") } }
        catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 0)
    }

    func testRetryPolicyMath() {
        let p = AIRetryPolicy()
        XCTAssertTrue(p.shouldRetry(status: 429, attempt: 1))
        XCTAssertTrue(p.shouldRetry(status: 500, attempt: 1))
        XCTAssertFalse(p.shouldRetry(status: 500, attempt: 2))
        XCTAssertFalse(p.shouldRetry(status: 401, attempt: 1))
        XCTAssertFalse(p.shouldRetry(status: 404, attempt: 1))
        XCTAssertEqual(p.delay(afterAttempt: 1, retryAfter: nil), 1)
        XCTAssertEqual(p.delay(afterAttempt: 2, retryAfter: nil), 2)
        XCTAssertEqual(p.delay(afterAttempt: 1, retryAfter: 999), 30)
    }

    // MARK: Recorded client

    func testRecordedClientReplaysByKeyAndReportsMissing() async throws {
        let dir = AITestSupport.tempDir()
        let r = req()
        let rec = RecordedAIClient(directory: dir)
        do { _ = try await rec.complete(r); XCTFail() }
        catch let e as AIError { XCTAssertEqual(e, .fixtureMissing(r.fixtureKey)) }
        try Data("{\"ops\":[]}".utf8).write(to: RecordedAIClient.responseURL(directory: dir, key: r.fixtureKey))
        let out = try await rec.complete(r)
        XCTAssertEqual(out.content, "{\"ops\":[]}")
        var other = r; other.messages[1] = AIChatMessage(role: .user, text: "different")
        XCTAssertNotEqual(other.fixtureKey, r.fixtureKey)
        XCTAssertEqual(r.fixtureKey.count, 16)
    }

    func testRecordingClientWritesFixtures() async throws {
        let dir = AITestSupport.tempDir()
        let t = MockTransport([.init(status: 200, body: completionBody("hello-fixture"))])
        let recording = RecordingAIClient(base: client(config(), t), directory: dir)
        _ = try await recording.complete(req())
        let replay = try await RecordedAIClient(directory: dir).complete(req())
        XCTAssertEqual(replay.content, "hello-fixture")
    }
}
