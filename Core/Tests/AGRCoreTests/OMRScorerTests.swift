import XCTest
@testable import AGRCore

final class OMRScorerTests: XCTestCase {
    private func report(_ edit: (inout Score) -> Void) -> OMRScoreReport {
        let gt = V2.score()
        var p = gt
        edit(&p)
        return OMRScorer.compare(groundTruth: gt, predicted: p)
    }
    private func mutate(_ s: inout Score, _ f: (inout NotationMeasure) -> Void, measure: Int = 0) {
        f(&s.sections[0].lines[0].system!.measures[measure])
    }

    func testPerfectMatchIsOne() {
        let gt = V2.score()
        let r = OMRScorer.compare(groundTruth: gt, predicted: gt)
        XCTAssertEqual(r.overall, 1.0)
        for c in [r.header, r.chords, r.chordShapes, r.tab, r.strokes, r.rhythm, r.melody, r.barlines, r.measures] {
            XCTAssertEqual(c.fp, 0); XCTAssertEqual(c.fn, 0); XCTAssertEqual(c.accuracy, 1)
        }
        XCTAssertEqual(r.lyrics.cer, 0)
        XCTAssertGreaterThan(r.tab.tp, 0); XCTAssertGreaterThan(r.melody.tp, 0); XCTAssertEqual(r.chordShapes.tp, 1)
        XCTAssertEqual(r.measures.tp, 4)
    }

    func testReportIsJSONEncodable() throws {
        let r = OMRScorer.compare(groundTruth: V2.score(), predicted: V2.score())
        let data = try r.jsonData()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["overall"] as? Double, 1.0)
        XCTAssertNotNil((obj["tab"] as? [String: Any])?["accuracy"])
        let back = try JSONDecoder().decode(OMRScoreReport.self, from: data)
        XCTAssertEqual(back.tab, r.tab)
        XCTAssertFalse(r.summary.isEmpty)
    }

    func testWrongChordNameOnlyAffectsChords() {
        let r = report { mutate(&$0, { $0.chords[0].name = "D" }, measure: 1) }
        XCTAssertEqual(r.chords.tp, 3); XCTAssertEqual(r.chords.fp, 1); XCTAssertEqual(r.chords.fn, 1)
        XCTAssertEqual(r.tab.fp + r.tab.fn, 0); XCTAssertEqual(r.melody.fp + r.melody.fn, 0)
        XCTAssertEqual(r.lyrics.editDistance, 0)
        XCTAssertLessThan(r.overall, 1)
    }

    func testEquivalentChordWritingIsNotAnError() {
        let r = report { mutate(&$0, { $0.chords[0].name = "Ｇ７(3)" }, measure: 1) }
        XCTAssertEqual(r.chords.fp + r.chords.fn, 0)
        let r2 = report { mutate(&$0, { $0.chords[0].name = "G7" }, measure: 1) }
        XCTAssertEqual(r2.chords.fn, 1, "the printed (3) variant is part of the name")
    }

    func testChordBeatToleranceAndShift() {
        let near = report { mutate(&$0, { $0.chords[0].beat = 0.05 }) }
        XCTAssertEqual(near.chords.fp + near.chords.fn, 0)
        let far = report { mutate(&$0, { $0.chords[0].beat = 1 }) }
        XCTAssertEqual(far.chords.fn, 1); XCTAssertEqual(far.chords.fp, 1)
    }

    func testChordShapeError() {
        let r = report { mutate(&$0, { $0.chords[0].shape = ChordShape(frets: [-1, 3, 2, 0, 1, 1]) }) }
        XCTAssertEqual(r.chordShapes.fn, 1); XCTAssertEqual(r.chordShapes.fp, 1); XCTAssertEqual(r.chordShapes.tp, 0)
        XCTAssertEqual(r.chords.fp + r.chords.fn, 0)
        let missing = report { mutate(&$0, { $0.chords[0].shape = nil }) }
        XCTAssertEqual(missing.chordShapes.fn, 1); XCTAssertEqual(missing.chordShapes.fp, 0)
    }

    func testTabNoteErrorsAffectOnlyTab() {
        let gtTab = OMRScorer.compare(groundTruth: V2.score(), predicted: V2.score()).tab.tp
        let wrongString = report { mutate(&$0, { $0.tab[1].notes[0].string = 3 }) }
        XCTAssertEqual(wrongString.tab.fn, 1); XCTAssertEqual(wrongString.tab.fp, 1); XCTAssertEqual(wrongString.tab.tp, gtTab - 1)
        XCTAssertEqual(wrongString.melody.fn + wrongString.chords.fn + wrongString.rhythm.fn, 0)

        let fretVsX = report { mutate(&$0, { $0.tab[0].notes[0] = TabNote(string: 5, fret: 3) }) }
        XCTAssertEqual(fretVsX.tab.fn, 1); XCTAssertEqual(fretVsX.tab.fp, 1)

        let tech = report { mutate(&$0, { $0.tab[0].notes[1].technique = .hammerOn }) }
        XCTAssertEqual(tech.tab.fn, 1); XCTAssertEqual(tech.tab.fp, 1)

        let missingEvent = report { mutate(&$0, { $0.tab.remove(at: 3) }) }
        XCTAssertEqual(missingEvent.tab.fn, 1); XCTAssertEqual(missingEvent.tab.fp, 0)
        XCTAssertEqual(missingEvent.tabEvents.fn, 1)
    }

    func testStrokeError() {
        var gt = V2.score()
        gt.sections[0].lines[0].system!.measures[0].tab[0].stroke = .down
        var p = gt
        p.sections[0].lines[0].system!.measures[0].tab[0].stroke = .up
        var r = OMRScorer.compare(groundTruth: gt, predicted: p)
        XCTAssertEqual(r.strokes.fn, 1); XCTAssertEqual(r.strokes.fp, 1); XCTAssertEqual(r.tab.fp + r.tab.fn, 0)
        p.sections[0].lines[0].system!.measures[0].tab[0].stroke = .down
        r = OMRScorer.compare(groundTruth: gt, predicted: p)
        XCTAssertEqual(r.strokes.tp, 1); XCTAssertEqual(r.strokes.accuracy, 1)
    }

    func testRhythmDurationError() {
        let r = report { mutate(&$0, { $0.tab[2].duration = 0.5 }) }
        XCTAssertEqual(r.rhythm.fn, 1); XCTAssertEqual(r.rhythm.fp, 1)
        XCTAssertEqual(r.tab.fp + r.tab.fn, 0)
        let m = report { mutate(&$0, { $0.melody[1].duration = 2 }) }
        XCTAssertEqual(m.rhythm.fn, 1); XCTAssertEqual(m.melody.fn, 0, "melody duration is scored in rhythm")
    }

    func testMelodyErrors() {
        let deg = report { mutate(&$0, { $0.melody[0].degree = 5 }) }
        XCTAssertEqual(deg.melody.fn, 1); XCTAssertEqual(deg.melody.fp, 1)
        let oct = report { mutate(&$0, { $0.melody[2].octave = 0 }) }
        XCTAssertEqual(oct.melody.fn, 1)
        let acc = report { mutate(&$0, { $0.melody[1].accidental = 1 }) }
        XCTAssertEqual(acc.melody.fn, 1)
        let tie = report { mutate(&$0, { $0.melody[1].tieToNext = true }) }
        XCTAssertEqual(tie.melody.fn, 1)
        XCTAssertEqual(tie.tab.fn + tie.chords.fn + tie.lyrics.editDistance, 0)
    }

    func testLyricsCER() {
        let r = report { mutate(&$0, { $0.melody[0].lyrics[0] = "晓" }) }
        XCTAssertEqual(r.lyrics.editDistance, 1)
        // GT: 4 measures * 4 notes * 2 verses = 32 chars.
        XCTAssertEqual(r.lyrics.groundTruthChars, 32)
        XCTAssertEqual(r.lyrics.cer, 1.0 / 32, accuracy: 1e-9)
        XCTAssertEqual(r.lyrics.accuracy, 1 - 1.0 / 32, accuracy: 1e-9)
        XCTAssertEqual(r.melody.fn + r.tab.fn, 0)

        let verse2Missing = report { s in for i in 0..<4 { mutate(&s, { m in for k in m.melody.indices { m.melody[k].lyrics = [m.melody[k].lyrics[0]] } }, measure: i) } }
        XCTAssertEqual(verse2Missing.lyrics.editDistance, 16)
        XCTAssertEqual(verse2Missing.lyrics.accuracy, 0.5, accuracy: 1e-9)
    }

    func testBarlinesAndRepeats() {
        let r = report { mutate(&$0, { $0.rightBarline = .single }, measure: 2) }
        XCTAssertEqual(r.barlines.fn, 1); XCTAssertEqual(r.barlines.fp, 0)
        let v = report { mutate(&$0, { $0.volta = [1] }, measure: 2) }
        XCTAssertEqual(v.barlines.fp, 1)
        XCTAssertEqual(v.chords.fp + v.tab.fp, 0)
    }

    func testHeaderFields() {
        let r = report { $0.meta.title = "别的歌"; $0.meta.capo = 2 }
        XCTAssertEqual(r.header.tp, 3)  // artist, key, tempo
        XCTAssertEqual(r.header.fn, 1); XCTAssertEqual(r.header.fp, 2)
        let same = report { $0.meta.title = " 小星云 " }
        XCTAssertEqual(same.header.fp + same.header.fn, 0)
    }

    func testDeletedMeasureIsHandledByAlignment() {
        let r = report { $0.sections[0].lines[0].system!.measures.remove(at: 1) }
        XCTAssertEqual(r.measures.tp, 3); XCTAssertEqual(r.measures.fn, 1); XCTAssertEqual(r.measures.fp, 0)
        XCTAssertEqual(r.alignment.missing, [1])
        XCTAssertEqual(r.chords.tp, 3); XCTAssertEqual(r.chords.fn, 1); XCTAssertEqual(r.chords.fp, 0)
        XCTAssertEqual(r.lyrics.editDistance, 8)
        XCTAssertGreaterThan(r.overall, 0.7)
        XCTAssertLessThan(r.overall, 1)
    }

    func testInsertedMeasureIsHandledByAlignment() {
        let extra = V2.measure(chord: "Dm", syllables: [["多"], ["余"], [], []])
        let r = report { $0.sections[0].lines[0].system!.measures.insert(extra, at: 2) }
        XCTAssertEqual(r.measures.tp, 4); XCTAssertEqual(r.measures.fp, 1); XCTAssertEqual(r.measures.fn, 0)
        XCTAssertEqual(r.alignment.extra, [2])
        XCTAssertEqual(r.chords.tp, 4); XCTAssertEqual(r.chords.fp, 1); XCTAssertEqual(r.chords.fn, 0)
        XCTAssertEqual(r.melody.fn, 0)
        XCTAssertGreaterThan(r.overall, 0.7)
    }

    func testEmptyPredictionScoresLow() {
        let r = OMRScorer.compare(groundTruth: V2.score(), predicted: Score())
        XCTAssertEqual(r.measures.fn, 4)
        XCTAssertLessThan(r.overall, 0.2)
        XCTAssertEqual(r.lyrics.accuracy, 0)
    }

    func testWeightsSumToOne() {
        XCTAssertEqual(OMRScorer.weights.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testRoundTripThroughJSONScores() throws {
        let gt = V2.score()
        let data = try ScoreCoding.encode(gt)
        let back = try ScoreCoding.decode(data)
        XCTAssertEqual(OMRScorer.compare(groundTruth: gt, predicted: back).overall, 1.0)
    }
}
