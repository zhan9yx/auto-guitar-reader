import XCTest
import Foundation
@testable import AGRCore

/// Returns scripted answers in order (or throws) and records requests.
final class ScriptedClient: AIChatClient, @unchecked Sendable {
    enum Step { case reply(String), fail(AIError) }
    private let lock = NSLock()
    private var steps: [Step]
    private var seen: [AIChatRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    var requests: [AIChatRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    private func next(_ r: AIChatRequest) -> Step {
        lock.lock(); defer { lock.unlock() }
        seen.append(r)
        return steps.isEmpty ? .reply("{\"ops\":[]}") : steps.removeFirst()
    }
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        switch next(request) {
        case .reply(let s): return AIChatResponse(content: s)
        case .fail(let e): throw e
        }
    }
}

final class AIAssistServiceTests: XCTestCase {
    let score = AITestSupport.score()
    func cfg(batch: Int = 8, vision: Bool = false) -> AIProviderConfig {
        AIProviderConfig(baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-chat", apiKey: "k", supportsVision: vision, maxIssuesPerRequest: batch)
    }

    // MARK: Prompt builder

    func testSystemPromptCoversRequiredSemantics() {
        let p = AIAssistPromptBuilder.systemPrompt
        for needle in ["chordTone", "×", "简谱", "octave", "下划线", "lyrics", "\"ops\"", "\"set\"", "insert", "delete",
                       "绝不编造歌词", "Never invent lyrics", "最小", "Prefer minimal", "空补丁", "If unsure", "chordDefinitions", "tieToNext"] {
            XCTAssertTrue(p.contains(needle), "system prompt lacks \(needle)")
        }
    }

    func testUserTextSnapshot() {
        let text = AIAssistPromptBuilder.userText(header: AIAssistPromptBuilder.header(for: score), issues: [AITestSupport.issue()], vision: false)
        XCTAssertEqual(text, """
        score: title=T key=G capo=0 timeSignature=4/4 tempo=80
        issues: 1

        ### Issue 1  id=i1  kind=beatSumMismatch
        path: sections[0].lines[0].system.measures[1]
        message: melody sums to 3 beats, expected 4
        context:
          m1: Cx | mel 1(0+1) 2(1+1) 3(2+1)
        ocr:
          - 过山和

        请只输出补丁 JSON。Reply with the patch JSON only.
        """)
    }

    func testVisionImagesAttachedOnlyWithVision() {
        let jpeg = Data([1, 2, 3])
        let issues = [AITestSupport.issue("a", crop: jpeg), AITestSupport.issue("b")]
        let h = AIAssistPromptBuilder.header(for: score)
        let on = AIAssistPromptBuilder.request(header: h, issues: issues, vision: true)
        XCTAssertEqual(on.messages[1].images, [jpeg])
        XCTAssertTrue(on.messages[1].text.contains("image: attached crop #1"))
        let off = AIAssistPromptBuilder.request(header: h, issues: issues, vision: false)
        XCTAssertTrue(off.messages[1].images.isEmpty)
        XCTAssertFalse(off.messages[1].text.contains("attached crop"))
        XCTAssertTrue(on.jsonMode)
    }

    func testBatchingAndDeterministicKeys() {
        let issues = (1...5).map { AITestSupport.issue("i\($0)") }
        let a = AIAssistPromptBuilder.requests(score: score, issues: issues, batchSize: 2, vision: false)
        let b = AIAssistPromptBuilder.requests(score: score, issues: issues, batchSize: 2, vision: false)
        XCTAssertEqual(a.map { $0.issues.count }, [2, 2, 1])
        XCTAssertEqual(a.map { $0.request.fixtureKey }, b.map { $0.request.fixtureKey })
        XCTAssertEqual(Set(a.map { $0.request.fixtureKey }).count, 3)
        XCTAssertEqual(AIAssistPromptBuilder.batches([], size: 3).count, 0)
        XCTAssertEqual(AIAssistPromptBuilder.batches(issues, size: 0).count, 5, "size clamps to 1")
    }

    func testIssueJSONRoundTripIncludingCrop() throws {
        let i = AITestSupport.issue(crop: Data([0xFF, 0xD8]))
        let back = try JSONDecoder().decode(AIIssue.self, from: try JSONEncoder().encode(i))
        XCTAssertEqual(i, back)
        let minimal = try JSONDecoder().decode(AIIssue.self, from: Data(#"{"id":"x","path":"meta.key"}"#.utf8))
        XCTAssertEqual(minimal.kind, .other)
    }

    // MARK: Service

    func testAppliesValidFixAndReportsChanges() async {
        let client = ScriptedClient([.reply(AITestSupport.fixPatch)])
        let (out, applied, rejected) = await AIAssistService(client: client).correct(score: score, issues: [AITestSupport.issue()], config: cfg())
        XCTAssertEqual(rejected.count, 0)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].issueIDs, ["i1"])
        XCTAssertEqual(applied[0].notes, "add missing note")
        XCTAssertEqual(AIScoreMetrics(out).invalidBeatMeasures, 0)
        XCTAssertEqual(applied[0].changes.count, 1)
        XCTAssertEqual(applied[0].changes[0].before, "Cx | mel 1(0+1) 2(1+1) 3(2+1) | v1 过 山 和")
        XCTAssertEqual(applied[0].changes[0].after, "Cx | mel 1(0+1) 2(1+1) 3(2+1) 4(3+1) | v1 过 山 和 海")
    }

    func testSameLineEditsAreInScope() async {
        // i1 points at measures[1] but scope is the whole flagged line, so measure 0 edits are allowed.
        let patch = #"{"ops":[{"op":"set","path":"sections[0].lines[0].system.measures[0].chords[0].name","value":"Am","issue":"i1"}]}"#
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: [AITestSupport.issue()], config: cfg())
        XCTAssertEqual(r.applied.count, 1)
        XCTAssertEqual(r.score.sections[0].lines[0].system!.measures[0].chords[0].name, "Am")
    }

    func testOutOfScopeAndMissingIssueRejected() async {
        let issues = [AITestSupport.issue("i1"), AITestSupport.issue("i2", path: "meta.credits", kind: .suspectedWatermark)]
        let patch = """
        {"ops":[
         {"op":"set","path":"meta.title","value":"Hacked","issue":"i2"},
         {"op":"set","path":"sections[0].lines[0].system.measures[0].beats","value":4,"issue":"nope"},
         {"op":"set","path":"sections[0].lines[0].system.measures[0].beats","value":4}
        ]}
        """
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: issues, config: cfg())
        XCTAssertEqual(r.applied.count, 0)
        XCTAssertEqual(r.rejected.count, 3)
        XCTAssertTrue(r.rejected[0].reason.contains("超出问题范围"))
        XCTAssertTrue(r.rejected[1].reason.contains("未知的问题"))
        XCTAssertTrue(r.rejected[2].reason.contains("缺少 issue"))
        XCTAssertEqual(r.score, score)
    }

    func testUnknownChordMayEditChordDefinitions() async {
        let issue = AITestSupport.issue("c1", path: "sections[0].lines[0].system.measures[1].chords[0]", kind: .unknownChord)
        let patch = """
        {"ops":[{"op":"set","path":"sections[0].lines[0].system.measures[1].chords[0].name","value":"C","issue":"c1"},
                {"op":"set","path":"chordDefinitions['C']","value":{"frets":[-1,3,2,0,1,0]},"issue":"c1"}]}
        """
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: [issue], config: cfg())
        XCTAssertEqual(r.applied.count, 1, "\(r.rejected)")
        XCTAssertEqual(r.score.chordDefinitions["C"]?.frets, [-1, 3, 2, 0, 1, 0])
    }

    func testGroupsAreAtomicAndIndependent() async {
        let issues = [AITestSupport.issue("i1"), AITestSupport.issue("i2")]
        let patch = """
        {"ops":[
         {"op":"insert","path":"sections[0].lines[0].system.measures[1].melody[-]","value":{"beat":3,"duration":1,"degree":4},"issue":"i1"},
         {"op":"set","path":"sections[0].lines[0].system.measures[0].melody[0].duration","value":3,"issue":"i2"},
         {"op":"set","path":"sections[0].lines[0].system.measures[0].chords[0].name","value":"D","issue":"i2"}
        ]}
        """
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: issues, config: cfg())
        XCTAssertEqual(r.applied.map(\.issueIDs), [["i1"]])
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertTrue(r.rejected[0].reason.contains("校验未通过"))
        XCTAssertEqual(r.score.sections[0].lines[0].system!.measures[0].chords[0].name, "G", "rejected group left no partial edit")
    }

    func testBadModelOutputAndEmptyOps() async {
        let issues = [AITestSupport.issue("i1"), AITestSupport.issue("i2")]
        let r = await AIAssistService(client: ScriptedClient([.reply("I think it is fine."), .reply(#"{"ops":[],"notes":"unsure"}"#)]))
            .correctDetailed(score: score, issues: issues, config: cfg(batch: 1))
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected[0].issueIDs, ["i1"])
        XCTAssertEqual(r.unresolvedIssueIDs, ["i2"])
        XCTAssertEqual(r.requestCount, 2)
    }

    func testNoOpPatchIsRejected() async {
        let patch = #"{"ops":[{"op":"set","path":"sections[0].lines[0].system.measures[1].chords[0].name","value":"Cx","issue":"i1"}]}"#
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: [AITestSupport.issue()], config: cfg())
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertTrue(r.rejected[0].reason.contains("没有产生任何变化"))
    }

    func testUnauthorizedStopsRemainingBatches() async {
        let issues = (1...3).map { AITestSupport.issue("i\($0)") }
        let client = ScriptedClient([.fail(.unauthorized("bad key")), .reply(AITestSupport.fixPatch)])
        let r = await AIAssistService(client: client).correctDetailed(score: score, issues: issues, config: cfg(batch: 1))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(r.fatalError, .unauthorized("bad key"))
        XCTAssertEqual(r.rejected.count, 3)
        XCTAssertTrue(r.rejected[0].reason.contains("API Key"))
        XCTAssertTrue(r.rejected[2].reason.contains("已跳过"))
    }

    func testNonFatalErrorContinuesWithNextBatch() async {
        let issues = [AITestSupport.issue("i1"), AITestSupport.issue("i2")]
        let client = ScriptedClient([.fail(.server(status: 503, message: nil)), .reply(AITestSupport.fixPatch.replacingOccurrences(of: "\"i1\"", with: "\"i2\""))])
        let r = await AIAssistService(client: client).correctDetailed(score: score, issues: issues, config: cfg(batch: 1))
        XCTAssertNil(r.fatalError)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.applied.count, 1)
    }

    func testSingleIssueBatchDefaultsMissingIssueField() async {
        let patch = #"{"ops":[{"op":"insert","path":"sections[0].lines[0].system.measures[1].melody[-]","value":{"beat":3,"duration":1,"degree":4}}]}"#
        let r = await AIAssistService(client: ScriptedClient([.reply(patch)])).correctDetailed(score: score, issues: [AITestSupport.issue()], config: cfg())
        XCTAssertEqual(r.applied.count, 1)
        XCTAssertEqual(r.applied[0].ops[0].issue, "i1")
    }

    func testDryRunKeepsOriginalAndFixesCanBeAppliedSelectively() async {
        let r = await AIAssistService(client: ScriptedClient([.reply(AITestSupport.fixPatch)]))
            .correctDetailed(score: score, issues: [AITestSupport.issue()], config: cfg(), dryRun: true)
        XCTAssertEqual(r.score, score)
        XCTAssertEqual(r.applied.count, 1)
        let (none, f0) = AIAssistService.apply(fixes: [], to: score)
        XCTAssertEqual(none, score); XCTAssertTrue(f0.isEmpty)
        let (fixed, failed) = AIAssistService.apply(fixes: r.applied, to: score)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(AIScoreMetrics(fixed).invalidBeatMeasures, 0)
        // applying twice: second no longer valid (beat sum would exceed)
        let (_, failed2) = AIAssistService.apply(fixes: r.applied + r.applied, to: score)
        XCTAssertEqual(failed2.count, 1)
    }

    func testProgressCallbackFires() async {
        final class Log: @unchecked Sendable { var v: [Int] = []; let l = NSLock(); func add(_ x: Int) { l.lock(); v.append(x); l.unlock() } }
        let log = Log()
        let issues = [AITestSupport.issue("i1"), AITestSupport.issue("i2")]
        _ = await AIAssistService(client: ScriptedClient([])).correctDetailed(score: score, issues: issues, config: cfg(batch: 1),
                                                                              progress: { log.add($0.completedBatches) })
        XCTAssertEqual(log.v, [0, 1, 2])
    }

    func testRecordedFixtureLoopEndToEnd() async throws {
        let dir = AITestSupport.tempDir()
        let issues = [AITestSupport.issue()]
        let planned = AIAssistPromptBuilder.requests(score: score, issues: issues, batchSize: 8, vision: false)
        try Data(AITestSupport.fixPatch.utf8).write(to: RecordedAIClient.responseURL(directory: dir, key: planned[0].request.fixtureKey))
        let r = await AIAssistService(client: RecordedAIClient(directory: dir)).correctDetailed(score: score, issues: issues, config: cfg())
        XCTAssertEqual(r.applied.count, 1)
        // missing fixture for a changed config (vision=true changes nothing without crops, but batch size does)
        let two = [AITestSupport.issue("i1"), AITestSupport.issue("i2")]
        let r2 = await AIAssistService(client: RecordedAIClient(directory: dir)).correctDetailed(score: score, issues: two, config: cfg())
        XCTAssertEqual(r2.applied.count, 0)
        XCTAssertTrue(r2.rejected[0].reason.contains("缺少录制"))
    }
}
