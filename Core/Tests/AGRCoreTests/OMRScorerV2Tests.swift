import XCTest
@testable import AGRCore

/// Scorer v2 (honest metric): one test per known v1 flaw, each also showing what v1 reports.
final class OMRScorerV2Tests: XCTestCase {
    private func cmp(_ metric: OMRMetric, watermarks: [String] = [], gt: Score = V2.score(), _ edit: (inout Score) -> Void) -> OMRScoreReport {
        var p = gt
        edit(&p)
        return OMRScorer.compare(groundTruth: gt, predicted: p, metric: metric, watermarks: watermarks)
    }
    private func mutate(_ s: inout Score, _ f: (inout NotationMeasure) -> Void, measure: Int) {
        f(&s.sections[0].lines[0].system!.measures[measure])
    }
    /// A measure sharing nothing but the melody degrees with GT measure 1.
    private var alien: NotationMeasure {
        V2.measure(chord: "Dm", syllables: [["乐"], ["曲"], ["风"], ["雨"]], tab: [V2.ct([6], 0, 1), V2.ct([6], 1, 1), V2.ct([6], 2, 1), V2.ct([6], 3, 1)])
    }

    func testPerfectIsOneInBothMetrics() {
        for m in [OMRMetric.v1, .v2] {
            let r = OMRScorer.compare(groundTruth: V2.score(), predicted: V2.score(), metric: m)
            XCTAssertEqual(r.overall, 1.0)
            XCTAssertEqual(r.rhythm.fn + r.rhythm.fp, 0)
        }
        XCTAssertEqual(OMRScorer.weightsV2.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    // Flaw 1: dissimilar measures were paired.
    func testDissimilarMeasureIsGappedInV2() {
        let v1 = cmp(.v1) { mutate(&$0, { $0 = self.alien }, measure: 1) }
        XCTAssertEqual(v1.measures.tp, 4, "v1 pairs even a totally different measure")
        let v2 = cmp(.v2) { mutate(&$0, { $0 = self.alien }, measure: 1) }
        XCTAssertEqual(v2.measures.tp, 3); XCTAssertEqual(v2.measures.fn, 1); XCTAssertEqual(v2.measures.fp, 1)
        XCTAssertEqual(v2.alignment.missing, [1]); XCTAssertEqual(v2.alignment.extra, [1])
        XCTAssertEqual(v2.chords.tp, 3); XCTAssertEqual(v2.chords.fn, 1); XCTAssertEqual(v2.chords.fp, 1)
        XCTAssertLessThan(v2.measures.accuracy, v1.measures.accuracy)
        XCTAssertLessThan(v2.overall, v1.overall)
        // the whole measure content is wrong: all 7 GT tab notes missed, 4 alien ones extra, no melody credit for matches
        XCTAssertEqual(v2.tab.fn, 7); XCTAssertEqual(v2.tab.fp, 4)
        XCTAssertEqual(v2.melody.fn, 4); XCTAssertEqual(v2.melody.fp, 4)
    }

    func testSimilarMeasureStillPairs() {
        let r = cmp(.v2) { mutate(&$0, { $0.tab[1].notes[0].string = 3 }, measure: 1) }
        XCTAssertEqual(r.measures.tp, 4)
    }

    // Flaw 2: rhythm was only scored on matched events.
    func testMissedAndExtraEventsCostRhythm() {
        let drop = { (s: inout Score) in self.mutate(&s, { $0.tab.removeLast(2) }, measure: 0) }
        let v1 = cmp(.v1, drop), v2 = cmp(.v2, drop)
        XCTAssertEqual(v1.rhythm.fn + v1.rhythm.fp, 0, "v1: missed events are free in rhythm")
        XCTAssertEqual(v2.rhythm.fn, 2); XCTAssertEqual(v2.rhythm.fp, 0)
        XCTAssertLessThan(v2.rhythm.accuracy, 1)
        XCTAssertLessThan(v2.rhythm.recall, 1); XCTAssertEqual(v2.rhythm.precision, 1)

        let extra = cmp(.v2) { self.mutate(&$0, { $0.tab.append(V2.ct([1], 3.5, 0.5)); $0.melody.append(MelodyNote(beat: 3.5, duration: 0.5, degree: 1)) }, measure: 0) }
        XCTAssertEqual(extra.rhythm.fp, 2); XCTAssertEqual(extra.rhythm.fn, 0)
        XCTAssertLessThan(extra.rhythm.precision, 1); XCTAssertEqual(extra.rhythm.recall, 1)

        let noMelody = cmp(.v2) { self.mutate(&$0, { $0.melody = [] }, measure: 2) }
        XCTAssertEqual(noMelody.rhythm.fn, 4)
        // an unpaired GT measure contributes all its events and its length
        let gone = cmp(.v2) { $0.sections[0].lines[0].system!.measures.remove(at: 1) }
        XCTAssertEqual(gone.rhythm.fn, 4 + 4 + 1)
    }

    // Time signature: wrong TS hurts rhythm (measure length) and header.
    func testWrongTimeSignatureHurts() {
        let ts = { (s: inout Score) in s.meta.timeSignature = TimeSignature(beats: 3, unit: 4) }
        let v1 = cmp(.v1, ts), v2 = cmp(.v2, ts)
        XCTAssertEqual(v1.rhythm.fn, 0, "v1 compares measure lengths only when stated")
        XCTAssertEqual(v2.rhythm.fn, 4); XCTAssertEqual(v2.rhythm.fp, 4)
        XCTAssertEqual(v2.header.fn, 1); XCTAssertEqual(v2.header.fp, 1)
        XCTAssertLessThan(v2.overall, 1)
        // an event beyond the predicted measure end is still matched by beat, so tab stays right: the TS cost is explicit
        XCTAssertEqual(v2.tab.fn + v2.tab.fp, 0)
    }

    // Flaw 3: default barlines were not counted.
    func testSingleBarlinesAreCounted() {
        let all = cmp(.v2) { _ in }
        XCTAssertEqual(all.barlines.tp, 4 /*measure rights*/ + 1 /*start repeat*/)
        let r = cmp(.v2) { s in for i in 0..<2 { self.mutate(&s, { $0.rightBarline = .double }, measure: i) } }
        XCTAssertEqual(r.barlines.fp, 2); XCTAssertEqual(r.barlines.fn, 2)
        let v1 = cmp(.v1) { s in for i in 0..<2 { self.mutate(&s, { $0.rightBarline = .double }, measure: i) } }
        XCTAssertEqual(v1.barlines.fn, 0); XCTAssertEqual(v1.barlines.fp, 2)
    }

    // Flaw 4: credits ignored; watermark leakage.
    func testCreditsAreScored() {
        var gt = V2.score(); gt.meta.credits = ["编配：甲乙"]
        let v2 = cmp(.v2, gt: gt) { $0.meta.credits = [] }
        XCTAssertEqual(v2.header.fn, 1)
        let v1 = cmp(.v1, gt: gt) { $0.meta.credits = [] }
        XCTAssertEqual(v1.header.fn, 0)
        let same = cmp(.v2, gt: gt) { $0.meta.credits = ["编配: 甲乙"] }
        XCTAssertEqual(same.header.fn + same.header.fp, 0, "width / punctuation / spacing are normalized")
    }

    func testWatermarkNeedleExtraction() {
        let n = OMRScorer.watermarkNeedles(["微信公众号：吉他专家 (footer)", "QR code (top-left)", "微信：18673066106", "page number 1"])
        XCTAssertEqual(Set(n), ["微信公众号", "吉他专家", "18673066106"])
        XCTAssertEqual(OMRScorer.watermarkNeedles(["微信公众号：吉他专家"], gtText: "微信公众号：吉他专家"), [])
    }

    func testLeakedWatermarkIsPenalized() {
        let marks = ["微信公众号：吉他专家", "QR code (top-left)"]
        let clean = cmp(.v2, watermarks: marks) { _ in }
        XCTAssertEqual(clean.cleanliness.tp, 2); XCTAssertEqual(clean.cleanliness.fp, 0)
        let credit = cmp(.v2, watermarks: marks) { $0.meta.credits = ["微信公众号：吉他专家"] }
        XCTAssertEqual(credit.cleanliness.fp, 2); XCTAssertEqual(credit.cleanliness.tp, 0)
        XCTAssertEqual(credit.groups["cleanliness"]?.accuracy, 0)
        XCTAssertLessThan(credit.overall, clean.overall)
        let title = cmp(.v2, watermarks: marks) { $0.meta.title = "小星云 吉他专家" }
        XCTAssertEqual(title.cleanliness.fp, 1); XCTAssertEqual(title.cleanliness.tp, 1)
        // leaked into lyrics (split over notes)
        let lyr = cmp(.v2, watermarks: marks) { s in
            self.mutate(&s, { m in for (i, c) in ["吉", "他", "专", "家"].enumerated() { m.melody[i].lyrics = [c] } }, measure: 0)
        }
        XCTAssertEqual(lyr.cleanliness.fp, 1)
        // v1 has no such category
        let v1 = cmp(.v1, watermarks: marks) { $0.meta.credits = ["微信公众号：吉他专家"] }
        XCTAssertTrue(v1.cleanliness.isEmpty); XCTAssertNil(v1.groups["cleanliness"])
        // no watermarks in GT: category skipped and weights renormalized
        let none = cmp(.v2) { _ in }
        XCTAssertEqual(none.groups["cleanliness"]?.included, false); XCTAssertEqual(none.overall, 1)
    }

    // Flaw 5: a category empty in the prediction but not in GT scores 0 (and is not skipped).
    func testEmptyPredictionCategoryIsZero() {
        let r = cmp(.v2) { s in for i in 0..<4 { self.mutate(&s, { $0.melody = []; $0.chords = [] }, measure: i) } }
        XCTAssertEqual(r.melody.accuracy, 0); XCTAssertEqual(r.melody.recall, 0); XCTAssertEqual(r.melody.precision, 0)
        XCTAssertEqual(r.chords.accuracy, 0)
        XCTAssertEqual(r.groups["melody"]?.included, true); XCTAssertEqual(r.groups["melody"]?.accuracy, 0)
        XCTAssertEqual(r.groups["chords"]?.accuracy, 0)
        XCTAssertEqual(r.groups["lyrics"]?.accuracy, 0)
        // empty in both: skipped, weights renormalized
        var gt = V2.score()
        for i in 0..<4 { mutate(&gt, { $0.chords = [] }, measure: i) }
        let both = OMRScorer.compare(groundTruth: gt, predicted: gt, metric: .v2)
        XCTAssertEqual(both.groups["chords"]?.included, false); XCTAssertEqual(both.overall, 1)
    }

    // Per-category precision and recall.
    func testPrecisionRecall() {
        let r = cmp(.v2) { self.mutate(&$0, { $0.tab.remove(at: 3) }, measure: 0) }
        XCTAssertEqual(r.tab.precision, 1); XCTAssertLessThan(r.tab.recall, 1)
        let json = try! r.jsonData()
        let o = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertNotNil((o["tab"] as? [String: Any])?["precision"]); XCTAssertNotNil((o["tab"] as? [String: Any])?["recall"])
        XCTAssertEqual(o["metric"] as? String, "v2")
    }

    func testDeterministic() {
        let a = cmp(.v2) { mutate(&$0, { $0 = self.alien }, measure: 2) }
        let b = cmp(.v2) { mutate(&$0, { $0 = self.alien }, measure: 2) }
        XCTAssertEqual(a, b)
    }
}
