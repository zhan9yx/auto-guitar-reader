import XCTest
@testable import AGRCore

final class AIPatcherTests: XCTestCase {
    let base = "sections[0].lines[0].system.measures"
    let score = AITestSupport.score()

    func op(_ kind: PatchOp.Kind, _ path: String, _ value: String? = nil) -> PatchOp {
        PatchOp(op: kind, path: path, value: value.map { try! AIJSONValue.parse($0) })
    }

    func apply(_ ops: PatchOp...) throws -> Score { try ScorePatcher.apply(ScorePatch(ops: ops), to: score) }

    // MARK: path forms

    func testPathParsing() throws {
        let expected: [PathToken] = [.key("sections"), .index(0), .key("lines"), .index(2)]
        for p in ["sections[0].lines[2]", "$.sections[0].lines[2]", "$sections[0].lines[2]", "sections.0.lines.2",
                  "sections[0][\"lines\"][2]", "sections['0'.lines".replacingOccurrences(of: "['0'.lines", with: "[0]['lines'][2]"),
                  "/sections/0/lines/2", " sections[0].lines[2] "] {
            XCTAssertEqual(try ScorePath.parse(p), expected, p)
        }
        XCTAssertEqual(try ScorePath.parse("a.b[-]"), [.key("a"), .key("b"), .append])
        XCTAssertEqual(try ScorePath.parse("/a~1b/~0c"), [.key("a/b"), .key("~c")])
        XCTAssertEqual(ScorePath.render(try ScorePath.parse("sections[0].lines[-]")), "sections[0].lines[-]")
    }

    func testInvalidPathsThrow() {
        for p in ["", "  ", "$", "sections[", "sections[x]", "sections[-1]", "sections..lines", "sections.", ".sections",
                  "sections[0]lines", "sections[0]]", "[\"\"]", "/", "/a//b", "sections[0.lines"] {
            XCTAssertThrowsError(try ScorePath.parse(p), p) { XCTAssertTrue("\($0)".contains("路径无效"), p) }
        }
    }

    // MARK: set

    func testSetScalarAndWholeObject() throws {
        let r = try apply(op(.set, "\(base)[1].melody[2].duration", "2"))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody[2].duration, 2)
        // beat sum now 4? 1+1+2 = 4
        XCTAssertEqual(AIScoreMetrics(r).invalidBeatMeasures, 0)
        let r2 = try apply(op(.set, "\(base)[0].chords[0]", #"{"name":"Am","beat":0}"#))
        XCTAssertEqual(r2.sections[0].lines[0].system!.measures[0].chords[0].name, "Am")
        let r3 = try apply(op(.set, "$.\(base)[0].melody[0].lyrics[0]", "\"你\""))
        XCTAssertEqual(r3.sections[0].lines[0].system!.measures[0].melody[0].lyrics, ["你"])
    }

    func testSetOptionalFieldAddAndNullRemove() throws {
        let r = try apply(op(.set, "\(base)[0].beats", "4"))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[0].beats, 4)
        let r2 = try ScorePatcher.apply(ScorePatch(ops: [op(.set, "\(base)[0].tab[1].notes[0].technique", "\"hammerOn\"")]), to: score)
        XCTAssertEqual(r2.sections[0].lines[0].system!.measures[0].tab[1].notes[0].technique, .hammerOn)
        let r3 = try ScorePatcher.apply(ScorePatch(ops: [op(.set, "meta.artist", "null")]), to: r2)
        XCTAssertNil(r3.meta.artist)
    }

    func testPointerAndQuotedFormsApply() throws {
        let r = try apply(op(.set, "/sections/0/lines/0/system/measures/1/melody/2/duration", "2"))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody[2].duration, 2)
        let r2 = try apply(op(.set, "sections[0][\"lines\"][0].system.measures[1].melody[2].duration", "2.0"))
        XCTAssertEqual(r2.sections[0].lines[0].system!.measures[1].melody[2].duration, 2)
    }

    // MARK: insert / delete

    func testInsertAtIndexAppendAndLengthIndex() throws {
        let note = #"{"beat":3,"duration":1,"degree":4}"#
        for tail in ["[-]", "[3]"] {
            let r = try apply(op(.insert, "\(base)[1].melody\(tail)", note))
            XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody.count, 4)
            XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody[3].degree, 4)
            XCTAssertEqual(AIScoreMetrics(r).invalidBeatMeasures, 0)
        }
        let mid = try apply(op(.insert, "\(base)[0].chords[0]", #"{"name":"D","beat":0}"#))
        XCTAssertEqual(mid.sections[0].lines[0].system!.measures[0].chords.map(\.name), ["D", "G"])
    }

    func testDeleteArrayElementAndObjectKey() throws {
        let r = try apply(op(.delete, "\(base)[0].tab[1]"))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[0].tab.count, 1)
        let r2 = try apply(op(.delete, "\(base)[0].melody[3].lyrics"))
        XCTAssertEqual(r2.sections[0].lines[0].system!.measures[0].melody[3].lyrics, [])
        var s = score; s.meta.artist = "x"
        XCTAssertNil(try ScorePatcher.apply(ScorePatch(ops: [op(.delete, "meta.artist")]), to: s).meta.artist)
    }

    func testOpsApplyInSequence() throws {
        let r = try apply(op(.insert, "\(base)[1].melody[-]", #"{"beat":3,"duration":1,"degree":4}"#),
                          op(.set, "\(base)[1].melody[3].degree", "5"))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody[3].degree, 5)
    }

    func testEmptyPatchReturnsSameScore() throws {
        XCTAssertEqual(try ScorePatcher.apply(ScorePatch(), to: score), score)
    }

    // MARK: failures

    func assertPatchError(_ ops: [PatchOp], _ match: (PatchError) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ScorePatcher.apply(ScorePatch(ops: ops), to: score), file: file, line: line) { e in
            guard let pe = e as? PatchError else { return XCTFail("not PatchError: \(e)", file: file, line: line) }
            XCTAssertTrue(match(pe), "unexpected \(pe)", file: file, line: line)
        }
    }

    func testNotFoundAndOutOfRange() {
        assertPatchError([op(.set, "\(base)[1].nope.x", "1")]) { if case .notFound = $0 { return true } else { return false } }
        assertPatchError([op(.delete, "\(base)[1].nope")]) { if case .notFound = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[9].beats", "1")]) { if case .indexOutOfRange = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody[3]", "{}")]) { if case .indexOutOfRange = $0 { return true } else { return false } }
        assertPatchError([op(.insert, "\(base)[1].melody[5]", "{}")]) { if case .indexOutOfRange = $0 { return true } else { return false } }
        assertPatchError([op(.delete, "\(base)[1].melody[3]")]) { if case .indexOutOfRange = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody[-]", "{}")]) { if case .invalidPath = $0 { return true } else { return false } }
    }

    func testTypeMismatches() {
        assertPatchError([op(.set, "\(base).beats", "1")]) { if case .typeMismatch = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody.duration", "1")]) { if case .typeMismatch = $0 { return true } else { return false } }
        assertPatchError([op(.set, "meta.title.x", "1")]) { if case .typeMismatch = $0 { return true } else { return false } }
        assertPatchError([op(.insert, "\(base)[1].beats", "4"), op(.insert, "\(base)[1].beats", "5")]) { if case .typeMismatch = $0 { return true } else { return false } }
        // wrong value type -> decode failure
        assertPatchError([op(.set, "\(base)[1].melody[0].degree", "\"three\"")]) { if case .decodeFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody[0].degree", "2.5")]) { if case .decodeFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody", "{}")]) { if case .decodeFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[1].melody[0].degree", "null")]) { if case .decodeFailed = $0 { return true } else { return false } }
    }

    func testMissingValueAndForbiddenPaths() {
        assertPatchError([op(.set, "\(base)[1].beats")]) { if case .missingValue = $0 { return true } else { return false } }
        for p in ["format", "version", "id", "pages", "pages[0].fileName", "$.id"] {
            assertPatchError([op(.set, p, "1")]) { if case .forbiddenPath = $0 { return true } else { return false } }
        }
        assertPatchError([op(.delete, "pages")]) { if case .forbiddenPath = $0 { return true } else { return false } }
    }

    func testUnknownFieldIsRejected() {
        assertPatchError([op(.set, "\(base)[0].chords[0].chrod", "\"Am\"")]) { if case .unknownField = $0 { return true } else { return false } }
    }

    func testFailureIsAtomic() throws {
        let s = score
        XCTAssertThrowsError(try ScorePatcher.apply(ScorePatch(ops: [op(.set, "\(base)[1].melody[2].duration", "2"), op(.set, "\(base)[7].beats", "1")]), to: s))
        XCTAssertEqual(s, score)
    }

    // MARK: structural validation

    func testRejectsBreakingBeatSumOfValidMeasure() {
        assertPatchError([op(.set, "\(base)[0].melody[0].duration", "2")]) { if case .validationFailed = $0 { return true } else { return false } }
    }

    func testRejectsMakingBeatErrorWorse() {
        assertPatchError([op(.set, "\(base)[1].melody[0].duration", "0.5")]) { if case .validationFailed = $0 { return true } else { return false } }
    }

    func testAllowsPartialImprovementOfBrokenMeasure() throws {
        var s = score
        s.sections[0].lines[0].system!.measures[1].melody[2].duration = 0.5
        let r = try ScorePatcher.apply(ScorePatch(ops: [op(.set, "\(base)[1].melody[2].duration", "0.75")]), to: s)
        XCTAssertEqual(r.sections[0].lines[0].system!.measures[1].melody[2].duration, 0.75)
    }

    func testRejectsOutOfRangeValues() {
        assertPatchError([op(.set, "\(base)[0].tab[1].notes[0].string", "7")]) { if case .validationFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[0].melody[0].degree", "9")]) { if case .validationFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[0].tab[1].notes[0].fret", "40")]) { if case .validationFailed = $0 { return true } else { return false } }
        assertPatchError([op(.set, "\(base)[0].tab[1].beat", "3.5")]) { if case .validationFailed = $0 { return true } else { return false } }
    }

    func testPickupMeasureWithBeatsAttributeIsRespected() throws {
        let r = try apply(op(.insert, "sections[0].lines[0].system.measures[-]",
                             #"{"beats":1,"melody":[{"beat":0,"duration":1,"degree":5}]}"#))
        XCTAssertEqual(r.sections[0].lines[0].system!.measures.count, 3)
    }

    // MARK: parsing model output

    func testParseModelOutputForms() throws {
        let json = AITestSupport.fixPatch
        XCTAssertEqual(try ScorePatch.parse(modelOutput: json).ops.count, 1)
        XCTAssertEqual(try ScorePatch.parse(modelOutput: "```json\n\(json)\n```").ops.count, 1)
        XCTAssertEqual(try ScorePatch.parse(modelOutput: "Here you go: \(json) Hope it helps").ops.count, 1)
        XCTAssertEqual(try ScorePatch.parse(modelOutput: #"{"ops":[],"notes":"unsure"}"#).notes, "unsure")
        XCTAssertEqual(try ScorePatch.parse(modelOutput: "{}").ops.count, 0)
        XCTAssertThrowsError(try ScorePatch.parse(modelOutput: "sorry I cannot"))
        XCTAssertThrowsError(try ScorePatch.parse(modelOutput: #"{"ops":[{"op":"rename","path":"x"}]}"#))
        XCTAssertThrowsError(try ScorePatch.parse(modelOutput: #"{"ops":[{"op":"set"}]}"#))
    }

    func testExplicitNullValueDistinguishedFromMissing() throws {
        let p = try ScorePatch.parse(modelOutput: #"{"ops":[{"op":"set","path":"meta.artist","value":null}]}"#)
        XCTAssertEqual(p.ops[0].value, .null)
        let p2 = try ScorePatch.parse(modelOutput: #"{"ops":[{"op":"delete","path":"meta.artist"}]}"#)
        XCTAssertNil(p2.ops[0].value)
    }

    func testRendererSnapshot() {
        let m = AITestSupport.score().sections[0].lines[0].system!.measures[0]
        XCTAssertEqual(AICompactRenderer.render(measure: m),
                       "G | tab 0:×6×3 2:2:3 | mel 1(0+1) 2(1+1) 3(2+1) 4(3+1) | v1 我 曾 经 跨")
    }
}
