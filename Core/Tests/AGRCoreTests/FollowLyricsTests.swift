import XCTest
@testable import AGRCore

final class FollowLyricsTests: XCTestCase {
    private func timeline(arrangement: [Int]? = [0, 1, 1]) -> Timeline {
        let cho = """
        {title: t}
        {tempo: 100}
        {start_of_verse}
        [C]我曾经跨过山和大海[G]也穿过人山人海
        [Am]我曾经问遍整个世界[F]从来没得到答案
        {end_of_verse}
        {start_of_chorus}
        [C]不要问我从哪里来[G]我的故乡在远方
        {end_of_chorus}
        """
        var score = try! ChordProParser.parse(cho)
        if let a = arrangement { score.arrangement = a.map { score.sections[$0].id } }
        return Timeline.build(from: score)
    }

    private func argmax(_ v: [Double]) -> Int { v.enumerated().max { $0.element < $1.element }!.offset }

    func testFindsPositionOfExactTranscript() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        let r = try XCTUnwrap(al.update(transcript: "我曾经问遍整个世"))
        XCTAssertEqual(r.evidence.count, tl.events.count)
        XCTAssertEqual(argmax(r.evidence), 2, "verse line 2 is in event 2 (Am)")
        XCTAssertGreaterThan(r.weight, 0.5)
        XCTAssertTrue(r.evidence.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testEvidenceIsExtendedOneEventForward() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        let r = try XCTUnwrap(al.update(transcript: "我曾经问遍整个世"))
        XCTAssertEqual(r.evidence[2], 1)
        XCTAssertEqual(r.evidence[3], 1, "ASR latency: the next event is as plausible as the matched one")
        XCTAssertLessThan(r.evidence[0], 0.5)
    }

    func testToleratesSubstitutionErrors() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        // 2 of 9 characters wrong.
        let r = try XCTUnwrap(al.update(transcript: "我曾径问边整个世界"))
        XCTAssertEqual(argmax(r.evidence), 2)
    }

    func testWeakOrUnrelatedMatchReturnsNil() {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        XCTAssertNil(al.update(transcript: "今天天气真不错啊"))
        XCTAssertNil(al.update(transcript: "短"))
        XCTAssertNil(al.update(transcript: ""))
    }

    func testRepeatedChorusGivesMultiModalEvidenceWithLowerWeight() throws {
        let tl = timeline(arrangement: [0, 1, 1])
        let al = LyricsAligner(timeline: tl)
        let single = try XCTUnwrap(al.update(transcript: "我曾经问遍整个世界"))
        let al2 = LyricsAligner(timeline: tl)
        let amb = try XCTUnwrap(al2.update(transcript: "不要问我从哪里来"))
        let chorusEvents = tl.events.filter { $0.line.sectionIndex == 1 && $0.segmentIndex == 0 }.map(\.index)
        XCTAssertEqual(chorusEvents.count, 2)
        for e in chorusEvents { XCTAssertEqual(amb.evidence[e], 1, "both passes of the chorus line are plausible") }
        XCTAssertLessThan(amb.weight, single.weight)
    }

    func testNoNewTextReturnsNilAndGrowingTextReturnsEvidence() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        XCTAssertNotNil(al.update(transcript: "我曾经问遍整个世"))
        XCTAssertNil(al.update(transcript: "我曾经问遍整个世"), "nothing new")
        let r = try XCTUnwrap(al.update(transcript: "我曾经问遍整个世界从来没"))
        XCTAssertEqual(argmax(r.evidence), 3, "'从来没' is in the last event (F)")
    }

    func testRevisedEarlierTextIsHandled() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        _ = al.update(transcript: "我曾经问边整个世")                    // partial result with a wrong character
        let r = try XCTUnwrap(al.update(transcript: "我曾经问遍整个世界"))    // revised + extended
        XCTAssertEqual(argmax(r.evidence), 2)
        // Revision with the same length (only the middle changed) is also processed.
        let al2 = LyricsAligner(timeline: tl)
        _ = al2.update(transcript: "我曾经问边整个世界")
        XCTAssertNotNil(al2.update(transcript: "我曾经问遍整个世界"))
    }

    func testNewUtteranceAfterReset() throws {
        let tl = timeline(arrangement: nil)
        let al = LyricsAligner(timeline: tl)
        _ = al.update(transcript: "我曾经问遍整个世界")
        // The recognizer restarted: a shorter, unrelated-prefix transcript.
        let r = try XCTUnwrap(al.update(transcript: "从来没得到答案"))
        XCTAssertEqual(argmax(r.evidence), 3)
    }

    func testNormalisationStripsPunctuationSpacesAndCase() throws {
        let cho = "{title: t}\n{tempo: 100}\n[Am]Hello, darkness[F] my old friend\n[C]I've come to talk[G] with you again"
        let tl = Timeline.build(from: try ChordProParser.parse(cho))
        let al = LyricsAligner(timeline: tl)
        let r = try XCTUnwrap(al.update(transcript: "HELLO  darkness, my old"))
        XCTAssertLessThanOrEqual(argmax(r.evidence), 1)
        let r2 = try XCTUnwrap(al.update(transcript: "hello darkness my old friend i've come to talk"))
        XCTAssertGreaterThanOrEqual(argmax(r2.evidence), 2)
    }

    func testNoLyricsTimelineIsHarmless() throws {
        let tl = Timeline.build(from: try ChordProParser.parse("{title: t}\n[C] [G] [Am] [F]"))
        let al = LyricsAligner(timeline: tl)
        XCTAssertEqual(al.corpusLength, 0)
        XCTAssertNil(al.update(transcript: "我曾经问遍整个世界"))
    }
}
