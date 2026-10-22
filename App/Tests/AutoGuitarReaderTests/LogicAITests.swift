import XCTest
import Foundation
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

/// Scripted chat client for the coordinator tests.
private final class FakeChatClient: AIChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, AIError>]
    private var count = 0
    init(_ replies: [Result<String, AIError>]) { self.replies = replies }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func next() -> Result<String, AIError> {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return replies.isEmpty ? .success("{\"ops\":[]}") : replies.removeFirst()
    }
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        switch next() {
        case .success(let s): return AIChatResponse(content: s, model: "fake-model", latency: 0.25)
        case .failure(let e): throw e
        }
    }
}

final class LogicAITests: XCTestCase {
    @MainActor
    private func makeDefaults() -> UserDefaults {
        let suite = "AGRTests.ai.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func sampleScore() -> Score {
        func note(_ i: Int, _ d: Double) -> MelodyNote { MelodyNote(beat: Double(i), duration: d, degree: i + 1) }
        let m = NotationMeasure(chords: [ChordMark(name: "G")], melody: [note(0, 1), note(1, 1), note(2, 1)])
        return Score(meta: ScoreMeta(title: "T", key: "G"),
                     sections: [ScoreSection(id: "s", name: "主歌", kind: .verse,
                                             lines: [Line(id: "l", kind: .system, system: NotationSystem(measures: [m]))])])
    }

    private let issue = AIIssue(id: "i1", kind: .beatSumMismatch, path: "sections[0].lines[0].system.measures[0]",
                                message: "3 beats", context: "m0: G | mel 1(0+1) 2(1+1) 3(2+1)")
    private let goodPatch = #"{"ops":[{"op":"insert","path":"sections[0].lines[0].system.measures[0].melody[-]","value":{"beat":3,"duration":1,"degree":4},"issue":"i1"}],"notes":"n"}"#

    // MARK: Settings persistence

    func testDefaultsAreOffAndSafe() {
        MainActor.assumeIsolated {
            let s = SettingsStore(defaults: makeDefaults(), secrets: InMemorySecretStore())
            XCTAssertFalse(s.ai.isEnabled)
            XCTAssertEqual(s.ai.preset, .deepSeek)
            XCTAssertEqual(s.ai.baseURLString, "https://api.deepseek.com")
            XCTAssertEqual(s.ai.model, "deepseek-chat")
            XCTAssertTrue(s.ai.confirmBeforeSend)
            XCTAssertFalse(s.ai.supportsVision)
            XCTAssertNil(s.ai.providerConfig)
            XCTAssertNotNil(s.ai.unavailableReason)
        }
    }

    func testApiKeyGoesToSecretStoreNeverDefaults() {
        MainActor.assumeIsolated {
            let defaults = makeDefaults()
            let secrets = InMemorySecretStore()
            let s = SettingsStore(defaults: defaults, secrets: secrets)
            s.ai.apiKey = "  sk-test-secret  "
            XCTAssertEqual(secrets.string(for: AISettings.keychainAccount), "sk-test-secret")
            for (key, value) in defaults.dictionaryRepresentation() {
                XCTAssertFalse("\(value)".contains("sk-test-secret"), "key leaked into defaults under \(key)")
            }
            let again = SettingsStore(defaults: defaults, secrets: secrets)
            XCTAssertEqual(again.ai.apiKey, "sk-test-secret")
            again.ai.apiKey = ""
            XCTAssertNil(secrets.string(for: AISettings.keychainAccount))
        }
    }

    func testPresetsAndConfigMapping() {
        MainActor.assumeIsolated {
            let defaults = makeDefaults()
            let s = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            s.ai.isEnabled = true
            s.ai.apiKey = "k"
            XCTAssertEqual(s.ai.providerConfig?.baseURL.absoluteString, "https://api.deepseek.com")
            XCTAssertEqual(s.ai.providerConfig?.model, "deepseek-chat")
            s.ai.selectPreset(.custom)
            s.ai.baseURLString = " https://api.openai.com/v1 "
            s.ai.model = "gpt-4o-mini"
            s.ai.supportsVision = true
            let c = s.ai.providerConfig
            XCTAssertEqual(c?.baseURL.absoluteString, "https://api.openai.com/v1")
            XCTAssertEqual(c?.model, "gpt-4o-mini")
            XCTAssertEqual(c?.supportsVision, true)
            XCTAssertEqual(c?.apiKey, "k")
            s.ai.selectPreset(.deepSeek)
            XCTAssertEqual(s.ai.baseURLString, "https://api.deepseek.com")
            // persisted
            let again = SettingsStore(defaults: defaults, secrets: InMemorySecretStore(["api-key": "k"]))
            XCTAssertTrue(again.ai.isEnabled)
            XCTAssertEqual(again.ai.preset, .deepSeek)
            XCTAssertTrue(again.ai.supportsVision)
        }
    }

    func testConfigRejectsBadURLAndMissingPieces() {
        MainActor.assumeIsolated {
            let s = SettingsStore(defaults: makeDefaults(), secrets: InMemorySecretStore(["api-key": "k"]))
            s.ai.isEnabled = true
            s.ai.baseURLString = "not a url"
            XCTAssertNil(s.ai.providerConfig)
            XCTAssertEqual(s.ai.unavailableReason, "Base URL 无效")
            s.ai.baseURLString = "ftp://x.org"
            XCTAssertNil(s.ai.providerConfig)
            s.ai.baseURLString = "https://x.org"
            s.ai.model = "  "
            XCTAssertEqual(s.ai.unavailableReason, "请先填写模型名")
            s.ai.model = "m"
            XCTAssertNotNil(s.ai.providerConfig)
            s.ai.isEnabled = false
            XCTAssertNil(s.ai.providerConfig)
            XCTAssertNotNil(s.ai.connectionConfig, "测试连接 works while disabled")
        }
    }

    // MARK: Connection test

    func testConnectionTestSuccessAndErrors() async {
        let config = AIProviderConfig(baseURL: URL(string: "https://x.org")!, model: "m", apiKey: "k")
        let ok = await AIConnectionTester.test(config: config, client: FakeChatClient([.success("OK")]))
        XCTAssertEqual(try? ok.get(), AIConnectionResult(latency: 0.25, model: "fake-model"))
        XCTAssertEqual(try? ok.get().summary, "连接成功 · 0.25 秒 · fake-model")
        let bad = await AIConnectionTester.test(config: config, client: FakeChatClient([.failure(.unauthorized(nil))]))
        if case .failure(let e) = bad { XCTAssertEqual(e, .unauthorized(nil)); XCTAssertFalse((e.errorDescription ?? "").contains("k\u{0}")) } else { XCTFail() }
    }

    // MARK: Coordinator + proposal

    @MainActor
    private func coordinator(_ client: FakeChatClient, enabled: Bool = true, confirm: Bool = true) -> AIAssistCoordinator {
        let s = SettingsStore(defaults: makeDefaults(), secrets: InMemorySecretStore(["api-key": "k"]))
        s.ai.isEnabled = enabled
        s.ai.confirmBeforeSend = confirm
        let c = AIAssistCoordinator(clientFactory: { _ in client })
        c.attach(settings: s)
        retained.append(s)
        return c
    }
    // `attach` keeps only a weak reference, like the views do with the environment object.
    @MainActor private var retained: [SettingsStore] = []

    func testCoordinatorProposesFixesWithoutTouchingScore() async {
        let client = FakeChatClient([.success(goodPatch)])
        let score = sampleScore()
        let (proposal, available, confirm, summary): (AIFixProposal?, Bool, Bool, AIPreSendSummary?) = await MainActor.run {
            let c = coordinator(client)
            return (nil, c.isAvailable, c.requiresConfirmation, c.preSendSummary(score: score, issues: [issue]))
        }
        XCTAssertNil(proposal)
        XCTAssertTrue(available)
        XCTAssertTrue(confirm)
        XCTAssertEqual(summary?.requestCount, 1)
        XCTAssertEqual(summary?.imageCount, 0)
        XCTAssertEqual(summary?.host, "api.deepseek.com")
        XCTAssertTrue(summary?.text.contains("不发送图片") ?? false)

        let result: AIFixProposal? = await MainActor.run { () -> AIAssistCoordinator in coordinator(client) }.proposeFixes(score: score, issues: [issue])
        XCTAssertEqual(client.requestCount, 1)
        guard let p = result else { return XCTFail("no proposal") }
        XCTAssertEqual(p.original, score)
        XCTAssertEqual(p.fixes.count, 1)
        XCTAssertEqual(p.issues(for: p.fixes[0]).map(\.id), ["i1"])
        let accepted = p.result(accepting: Set(p.fixes.map(\.id)))
        XCTAssertTrue(accepted.failed.isEmpty)
        XCTAssertEqual(AIScoreMetrics(accepted.score).invalidBeatMeasures, 0)
        let none = p.result(accepting: [])
        XCTAssertEqual(none.score, score)
    }

    func testCoordinatorUnavailableAndErrors() async {
        let score = sampleScore()
        let off = await MainActor.run { coordinator(FakeChatClient([]), enabled: false) }
        let r1 = await off.proposeFixes(score: score, issues: [issue])
        XCTAssertNil(r1)
        let m1 = await MainActor.run { off.errorMessage }
        XCTAssertEqual(m1, "未启用 AI 辅助识别（设置 → AI 辅助识别）")

        let client = FakeChatClient([.failure(.unauthorized(nil))])
        let on = await MainActor.run { coordinator(client) }
        let r2 = await on.proposeFixes(score: score, issues: [issue])
        XCTAssertNil(r2)
        let m2 = await MainActor.run { on.errorMessage }
        XCTAssertEqual(m2, AIError.unauthorized(nil).localizedDescription)
        let running = await MainActor.run { on.isRunning }
        XCTAssertFalse(running)

        let r3 = await on.proposeFixes(score: score, issues: [])
        XCTAssertNil(r3)
        let m3 = await MainActor.run { on.errorMessage }
        XCTAssertEqual(m3, "没有需要 AI 校对的问题")
        XCTAssertEqual(client.requestCount, 1, "no request without issues")
    }

    func testRejectedOnlyProposalStillReturned() async {
        let bad = #"{"ops":[{"op":"set","path":"meta.title","value":"x","issue":"i1"}]}"#
        let c = await MainActor.run { coordinator(FakeChatClient([.success(bad)])) }
        let p = await c.proposeFixes(score: sampleScore(), issues: [issue])
        XCTAssertEqual(p?.fixes.count, 0)
        XCTAssertEqual(p?.rejected.count, 1)
        XCTAssertEqual(p?.isEmpty, true)
    }
}
