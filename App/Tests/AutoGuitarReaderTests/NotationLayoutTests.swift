import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

final class NotationLayoutTests: XCTestCase {
    private let metrics = NotationMetrics(fontSize: 16)

    private func arpeggio(_ beats: Double = 4) -> [TabEvent] {
        (0..<Int(beats * 2)).map { TabEvent(beat: Double($0) * 0.5, duration: 0.5, notes: [.chordTone(string: 3)]) }
    }

    private func measure(lyrics: [String] = [], tab: Bool = true) -> NotationMeasure {
        let melody = lyrics.enumerated().map {
            MelodyNote(beat: Double($0.offset), duration: 1, degree: 1 + $0.offset % 7, lyrics: [$0.element])
        }
        return NotationMeasure(chords: [ChordMark(name: "C")], tab: tab ? arpeggio() : [], melody: melody)
    }

    private func sizing(_ m: NotationMeasure, beats: Double = 4, options: NotationOptions = NotationOptions()) -> MeasureSizing {
        let verses = options.shownVerses(count: m.verseCount)
        return NotationLayout.sizing(measure: m, beats: beats, options: options, metrics: metrics, verses: verses,
                                     showDiagram: false, chordLabel: { $0.name })
    }

    // MARK: width allocation

    func testWidthGrowsWithContentAndKeepsMinimum() {
        let plain = sizing(measure())
        XCTAssertGreaterThanOrEqual(plain.naturalWidth, plain.minWidth)
        XCTAssertGreaterThanOrEqual(plain.naturalWidth, 4 * metrics.naturalBeatWidth)

        // Long lyrics on every beat need more room than the natural width.
        let heavy = measure(lyrics: ["abcdefgh", "abcdefgh", "abcdefgh", "abcdefgh"])
        XCTAssertGreaterThan(sizing(heavy).minWidth, plain.minWidth)
        XCTAssertGreaterThan(sizing(heavy).naturalWidth, plain.naturalWidth)

        // Hiding the lane that causes the constraint shrinks the measure.
        var noLyrics = NotationOptions(); noLyrics.verses = .verse(5)
        var noJianpu = noLyrics; noJianpu.showJianpu = false
        XCTAssertLessThan(sizing(heavy, options: noJianpu).minWidth, sizing(heavy).minWidth)
    }

    func testWidthProportionalToBeats() {
        let four = sizing(measure(), beats: 4).naturalWidth
        let two = sizing(NotationMeasure(chords: [ChordMark(name: "C")]), beats: 2).naturalWidth
        XCTAssertLessThan(two, four)
        let p = metrics.padding * 2
        XCTAssertEqual((four - p) / 4, (two - p) / 2 * (four - p) / 4 / ((two - p) / 2), accuracy: 0.01)
    }

    func testRepeatBarlineAddsPadding() {
        var m = measure()
        let base = sizing(m).padLeft
        m.leftBarline = .startRepeat
        XCTAssertGreaterThan(sizing(m).padLeft, base)
    }

    func testCJKLyricWidth() {
        XCTAssertEqual(NotationText.width(of: "我听见", fontSize: 10), 30, accuracy: 0.001)
        XCTAssertEqual(NotationText.width(of: "，", fontSize: 10), 10, accuracy: 0.001)
        XCTAssertLessThan(NotationText.width(of: "ab", fontSize: 10), 20)
    }

    // MARK: wrapping

    func testWrapGreedyAndBalanced() {
        XCTAssertEqual(NotationLayout.wrap(widths: [100, 100, 100, 100], usable: 350), [[0, 1], [2, 3]])
        XCTAssertEqual(NotationLayout.wrap(widths: [100, 100, 100, 100], usable: 1000), [[0, 1, 2, 3]])
        XCTAssertEqual(NotationLayout.wrap(widths: [100, 100, 100, 100, 100], usable: 320), [[0, 1, 2], [3, 4]])
        XCTAssertEqual(NotationLayout.wrap(widths: [500, 100], usable: 300), [[0], [1]])
        XCTAssertEqual(NotationLayout.wrap(widths: [], usable: 300), [])
    }

    func testRewrapByWidth() {
        let system = NotationSystem(measures: Array(repeating: measure(), count: 4))
        func rows(_ width: CGFloat) -> [Int] {
            NotationLayout.make(system: system, defaultBeats: 4, options: NotationOptions(), metrics: metrics, width: width)
                .rows.map { $0.measures.count }
        }
        XCTAssertEqual(rows(390 - 32), [2, 2])      // iPhone portrait
        XCTAssertEqual(rows(820), [4])              // iPad
        XCTAssertEqual(rows(200).reduce(0, +), 4)   // very narrow: still all measures
    }

    func testRowsFillWidthWithinStretchLimit() {
        let system = NotationSystem(measures: Array(repeating: measure(), count: 4))
        let layout = NotationLayout.make(system: system, defaultBeats: 4, options: NotationOptions(), metrics: metrics, width: 358)
        for row in layout.rows {
            XCTAssertEqual(row.maxX, 358 - 1, accuracy: 0.5)
            var x = row.x
            for m in row.measures {
                XCTAssertEqual(m.x, x, accuracy: 0.001)
                x += m.width
            }
        }
        // rows are stacked without overlap
        XCTAssertGreaterThan(layout.rows[1].y, layout.rows[0].y + layout.rows[0].height)
        XCTAssertEqual(layout.size.height, layout.rows[1].y + layout.rows[1].height, accuracy: 0.001)
    }

    // MARK: beams / underlines

    func testTabBeamGrouping() {
        // 8 eighths in 4/4 → four beamed pairs.
        let marks = RhythmLayout.marks(for: arpeggio())
        let groups = RhythmLayout.beamGroups(for: marks)
        XCTAssertEqual(groups.map(\.indices), [[0, 1], [2, 3], [4, 5], [6, 7]])
        XCTAssertTrue(groups.allSatisfy { $0.segments == [BeamSegment(level: 1, from: $0.indices[0], to: $0.indices[1])] })
    }

    func testSixteenthsAndMixedGrouping() {
        // 16th ×4 in one beat: level-1 over all, level-2 over all.
        let sixteenths = (0..<4).map { TabEvent(beat: Double($0) * 0.25, duration: 0.25, notes: [.chordTone(string: 1)]) }
        var g = RhythmLayout.beamGroups(for: RhythmLayout.marks(for: sixteenths))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(Set(g[0].segments), [BeamSegment(level: 1, from: 0, to: 3), BeamSegment(level: 2, from: 0, to: 3)])

        // dotted 8th + 16th: level 2 is a stub on the 16th only.
        let dotted = [TabEvent(beat: 0, duration: 0.75, notes: [.chordTone(string: 1)]),
                      TabEvent(beat: 0.75, duration: 0.25, notes: [.chordTone(string: 1)])]
        let marks = RhythmLayout.marks(for: dotted)
        XCTAssertTrue(marks[0].value.dotted)
        XCTAssertEqual(marks[0].value.beams, 1)
        g = RhythmLayout.beamGroups(for: marks)
        XCTAssertTrue(g[0].segments.contains(BeamSegment(level: 1, from: 0, to: 1)))
        XCTAssertTrue(g[0].segments.contains(BeamSegment(level: 2, from: 1, to: 1)))

        // quarter notes: stems only, no groups; half: short stem
        let quarters = [TabEvent(beat: 0, duration: 1, notes: [.chordTone(string: 1)]),
                        TabEvent(beat: 1, duration: 2, notes: [.chordTone(string: 1)]),
                        TabEvent(beat: 3, duration: 4, notes: [.chordTone(string: 1)])]
        let qm = RhythmLayout.marks(for: quarters)
        XCTAssertEqual(qm.map(\.value.stem), [.full, .short, .none])
        XCTAssertTrue(RhythmLayout.beamGroups(for: qm).isEmpty)

        // eighths in different beats are not joined
        let split = [TabEvent(beat: 0.5, duration: 0.5, notes: [.chordTone(string: 1)]),
                     TabEvent(beat: 1, duration: 0.5, notes: [.chordTone(string: 1)])]
        XCTAssertEqual(RhythmLayout.beamGroups(for: RhythmLayout.marks(for: split)).map(\.indices), [[0], [1]])
    }

    func testJianpuUnderlineGrouping() {
        let notes = [
            MelodyNote(beat: 0, duration: 0.5, degree: 1), MelodyNote(beat: 0.5, duration: 0.5, degree: 2),
            MelodyNote(beat: 1, duration: 1, degree: 3),
            MelodyNote(beat: 2, duration: 0.5, degree: 4), MelodyNote(beat: 2.5, duration: 0.25, degree: 5),
            MelodyNote(beat: 2.75, duration: 0.25, degree: 6),
            MelodyNote(beat: 3, duration: 1, degree: 0)
        ]
        let groups = JianpuLayout.underlineGroups(for: notes)
        XCTAssertEqual(groups.map(\.indices), [[0, 1], [3, 4, 5]])
        XCTAssertEqual(Set(groups[1].segments), [BeamSegment(level: 1, from: 3, to: 5), BeamSegment(level: 2, from: 4, to: 5)])
    }

    func testJianpuValues() {
        XCTAssertEqual(JianpuValue.describe(duration: 1), JianpuValue(underlines: 0, dotted: false, extensions: 0))
        XCTAssertEqual(JianpuValue.describe(duration: 0.5), JianpuValue(underlines: 1, dotted: false, extensions: 0))
        XCTAssertEqual(JianpuValue.describe(duration: 0.25), JianpuValue(underlines: 2, dotted: false, extensions: 0))
        XCTAssertEqual(JianpuValue.describe(duration: 0.75), JianpuValue(underlines: 1, dotted: true, extensions: 0))
        XCTAssertEqual(JianpuValue.describe(duration: 1.5), JianpuValue(underlines: 0, dotted: true, extensions: 0))
        XCTAssertEqual(JianpuValue.describe(duration: 2), JianpuValue(underlines: 0, dotted: false, extensions: 1))
        XCTAssertEqual(JianpuValue.describe(duration: 4), JianpuValue(underlines: 0, dotted: false, extensions: 3))
    }

    // MARK: lyrics

    func testLyricPlacementAvoidsOverlap() {
        let lefts = LyricPlacement.place(centers: [10, 20, 100], widths: [16, 16, 16], minGap: 2)
        XCTAssertEqual(lefts[0], 2, accuracy: 0.001)        // centred: 10 - 8
        XCTAssertEqual(lefts[1], 20, accuracy: 0.001)       // pushed to 2 + 16 + 2
        XCTAssertEqual(lefts[2], 92, accuracy: 0.001)       // free: centred
        // empty lyric is skipped and does not push neighbours
        let withGap = LyricPlacement.place(centers: [10, 14, 30], widths: [16, 0, 16], minGap: 0)
        XCTAssertEqual(withGap[2], 22, accuracy: 0.001)
    }

    func testLyricsCentredOnNotesInLayout() {
        let m = measure(lyrics: ["我", "听", "见", "雨"])
        let layout = NotationLayout.make(system: NotationSystem(measures: [m]), defaultBeats: 4,
                                         options: NotationOptions(), metrics: metrics, width: 358)
        let row = layout.rows[0]
        XCTAssertEqual(layout.verses, [0])
        XCTAssertEqual(row.lanes.lyricTops.count, 1)
        let ml = row.measures[0]
        // lyric and note share the same x for a beat
        XCTAssertEqual(ml.x(forBeat: 1), ml.contentX + ml.contentWidth * 0.25, accuracy: 0.001)
    }

    func testVerseSelection() {
        var o = NotationOptions()
        XCTAssertEqual(o.shownVerses(count: 2), [0, 1])
        o.verses = .verse(1)
        XCTAssertEqual(o.shownVerses(count: 2), [1])
        XCTAssertEqual(o.shownVerses(count: 1), [])
        XCTAssertEqual(NotationOptions.VerseSelection(storage: -1), .all)
        XCTAssertEqual(NotationOptions.VerseSelection.verse(2).storage, 2)
        var m = measure(); m.melody = [MelodyNote(beat: 0, duration: 1, degree: 1, lyrics: ["a", "b"])]
        let sys = NotationSystem(measures: [m])
        let all = NotationLayout.make(system: sys, defaultBeats: 4, options: NotationOptions(), metrics: metrics, width: 358)
        o.verses = .verse(0)
        let one = NotationLayout.make(system: sys, defaultBeats: 4, options: o, metrics: metrics, width: 358)
        XCTAssertEqual(all.rows[0].lanes.lyricTops.count, 2)
        XCTAssertEqual(one.rows[0].lanes.lyricTops.count, 1)
        XCTAssertGreaterThan(all.size.height, one.size.height)
    }

    func testLaneToggles() {
        let sys = NotationSystem(measures: [measure(lyrics: ["a", "b", "c", "d"])])
        func height(_ o: NotationOptions) -> CGFloat {
            NotationLayout.make(system: sys, defaultBeats: 4, options: o, metrics: metrics, width: 358).size.height
        }
        let full = height(NotationOptions())
        XCTAssertLessThan(height(NotationOptions(showJianpu: false)), full)
        XCTAssertLessThan(height(NotationOptions(showTab: false)), full)
    }

    // MARK: hit-test / frames / highlight

    private func twoRowLayout() -> NotationLayout {
        let system = NotationSystem(measures: Array(repeating: measure(lyrics: ["a", "b", "c", "d"]), count: 4))
        return NotationLayout.make(system: system, defaultBeats: 4, options: NotationOptions(), metrics: metrics, width: 358)
    }

    func testMeasureFramesAndUnion() {
        let layout = twoRowLayout()
        XCTAssertEqual(layout.rows.count, 2)
        let frames = layout.measureFrames
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0]!.minY, 0, accuracy: 0.001)
        XCTAssertEqual(frames[2]!.minY, layout.rows[1].y, accuracy: 0.001)
        XCTAssertEqual(frames[0]!.maxX, frames[1]!.minX, accuracy: 0.001)
        XCTAssertEqual(layout.unionFrame.height, layout.size.height, accuracy: 0.001)
        XCTAssertEqual(layout.rowIndex(forMeasure: 3), 1)
    }

    func testHitTest() {
        let layout = twoRowLayout()
        let r0 = layout.rows[0]
        let m1 = r0.measures[1]
        let staffY = r0.y + r0.lanes.staffTop + 2
        let hit = layout.hitTest(CGPoint(x: m1.x(forBeat: 2), y: staffY))
        XCTAssertEqual(hit?.measureIndex, 1)
        XCTAssertEqual(hit?.rowIndex, 0)
        XCTAssertEqual(hit?.lane, .staff)
        XCTAssertEqual(hit?.beat ?? -1, 2, accuracy: 0.01)

        let r1 = layout.rows[1]
        XCTAssertEqual(layout.hitTest(CGPoint(x: r1.measures[0].x + 5, y: r1.y + r1.lanes.jianpuTop + 3))?.measureIndex, 2)
        XCTAssertEqual(layout.hitTest(CGPoint(x: r1.measures[0].x + 5, y: r1.y + r1.lanes.jianpuTop + 3))?.lane, .jianpu)
        XCTAssertEqual(layout.hitTest(CGPoint(x: r1.measures[0].x + 5, y: r1.y + r1.lanes.lyricTops[0] + 3))?.lane, .lyric(0))
        XCTAssertEqual(layout.hitTest(CGPoint(x: r1.measures[0].x + 5, y: r1.y + 2))?.lane, .chords)
        XCTAssertNil(layout.hitTest(CGPoint(x: 2, y: staffY)))                      // clef column
        XCTAssertNil(layout.hitTest(CGPoint(x: 100, y: layout.size.height + 100)))  // below
    }

    func testHighlightXFromBeat() {
        let layout = twoRowLayout()
        let m = layout.rows[0].measures[0]
        let band0 = layout.highlightBand(measureIndex: 0, beat: 0.0)!
        XCTAssertEqual(band0.rowIndex, 0)
        XCTAssertEqual(band0.minX, m.x, accuracy: 0.001)
        // Onsets of the test measure are every half beat; the band of beat 1 spans 0.75...1.25.
        let band1 = layout.highlightBand(measureIndex: 0, beat: 1.0)!
        XCTAssertEqual(band1.minX, m.x(forBeat: 0.75), accuracy: 0.001)
        XCTAssertEqual(band1.maxX, m.x(forBeat: 1.25), accuracy: 0.001)
        // Bands tile: the band of the last onset ends at the measure edge.
        XCTAssertEqual(layout.highlightBand(measureIndex: 0, beat: 3.5)!.maxX, m.maxX, accuracy: 0.001)
        // A beat between onsets falls in the earlier onset's band.
        XCTAssertEqual(layout.highlightBand(measureIndex: 0, beat: 1.2)!.minX, band1.minX, accuracy: 0.001)
        XCTAssertEqual(layout.highlightBand(measureIndex: 3, beat: 0)!.rowIndex, 1)
        XCTAssertNil(layout.highlightBand(measureIndex: 9, beat: 0))
    }

    func testBeatXRoundTrip() {
        let m = twoRowLayout().rows[0].measures[0]
        for beat in [0.0, 0.5, 1.75, 4.0] {
            XCTAssertEqual(m.beat(forX: m.x(forBeat: beat)), beat, accuracy: 0.001)
        }
        XCTAssertEqual(m.x(forBeat: -3), m.contentX, accuracy: 0.001)
    }

    // MARK: highlight mapping

    private func event(measure: Int?, tabEvent: Int?, progress: ClosedRange<Double> = 0...1) -> TimelineEvent {
        TimelineEvent(index: 0, kind: .notes, line: LineRef(sectionIndex: 0, lineIndex: 1), tabMeasureIndex: measure,
                      tabEventIndex: tabEvent, startBeat: 0, beats: 0.5, progressInLine: progress)
    }

    func testHighlightMapping() {
        let score = SampleScores.notationSample()
        let h = NotationHighlightMapper.highlight(for: event(measure: 2, tabEvent: 3), in: score)
        XCTAssertEqual(h, NotationHighlight(line: LineRef(sectionIndex: 0, lineIndex: 1), measureIndex: 2, beat: 2.5))
        // fallback: progress 0.625 of 16 beats = beat 10 → measure 2, beat 2
        let p = NotationHighlightMapper.highlight(for: event(measure: nil, tabEvent: nil, progress: 0.625...0.7), in: score)
        XCTAssertEqual(p?.measureIndex, 2)
        XCTAssertEqual(p?.beat ?? -1, 2, accuracy: 0.001)
        // non-system line → nil
        var other = event(measure: 0, tabEvent: 0)
        other.line = LineRef(sectionIndex: 5, lineIndex: 0)
        XCTAssertNil(NotationHighlightMapper.highlight(for: other, in: score))
    }

    // MARK: issues / editing / sample

    func testReviewIssuePath() {
        let ref = ReviewIssuePath.measureRef("sections[1].lines[2].system.measures[3].melody[0]")
        XCTAssertEqual(ref, NotationMeasureRef(line: LineRef(sectionIndex: 1, lineIndex: 2), measure: 3))
        XCTAssertNil(ReviewIssuePath.measureRef("sections[1].lines[2].segments[0]"))
        XCTAssertNil(ReviewIssuePath.measureRef("meta.title"))
        let issue = ReviewIssue(path: ReviewIssuePath.path(line: LineRef(sectionIndex: 0, lineIndex: 0), measure: 4), message: "x")
        XCTAssertEqual(issue.measureRef?.measure, 4)
    }

    func testSampleScoreIsConsistent() {
        let score = SampleScores.notationSample()
        let lines = score.sections.flatMap(\.lines)
        XCTAssertEqual(lines.compactMap(\.system).reduce(0) { $0 + $1.measures.count }, 8)
        XCTAssertTrue(NotationLint.issues(for: score).isEmpty, "\(NotationLint.issues(for: score))")
        XCTAssertEqual(NotationScore.verseCount(score), 2)
        XCTAssertTrue(NotationScore.hasSystemLines(score))
        XCTAssertNotNil(try? ScoreCoding.decode(ScoreCoding.encode(score)))
    }

    func testLintFindsProblems() {
        var score = SampleScores.notationSample()
        score.sections[0].lines[0].system?.measures[1].melody.removeLast()
        score.sections[0].lines[0].system?.measures[0].chords[0].name = "???"
        let issues = NotationLint.issues(for: score)
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(Set(issues.compactMap { $0.measureRef?.measure }), [0, 1])
    }

    func testMeasureEditing() {
        var event = TabEvent(beat: 0, duration: 0.5)
        MeasureEditing.setCell(.chordTone, in: &event, string: 3)
        MeasureEditing.setCell(.fret(2), in: &event, string: 1)
        XCTAssertEqual(event.notes.map(\.string), [1, 3])
        XCTAssertEqual(MeasureEditing.cell(in: event, string: 3), .chordTone)
        XCTAssertEqual(MeasureEditing.cell(in: event, string: 1), .fret(2))
        MeasureEditing.setCell(.none, in: &event, string: 3)
        XCTAssertEqual(MeasureEditing.cell(in: event, string: 3), .none)

        var m = NotationMeasure()
        MeasureEditing.setPrimaryChord("Am", in: &m)
        XCTAssertEqual(MeasureEditing.primaryChordName(m), "Am")
        MeasureEditing.setPrimaryChord("", in: &m)
        XCTAssertTrue(m.chords.isEmpty)

        MeasureEditing.appendMelodyNote(to: &m, defaultBeats: 4)
        MeasureEditing.setLyric("好", note: &m.melody[0], verse: 1)
        XCTAssertEqual(m.melody[0].lyrics, ["", "好"])
        MeasureEditing.appendTabEvent(to: &m, defaultBeats: 4)
        XCTAssertEqual(m.tab.count, 1)

        var score = SampleScores.notationSample()
        let ref = NotationMeasureRef(line: LineRef(sectionIndex: 0, lineIndex: 0), measure: 1)
        XCTAssertTrue(score.updateNotationMeasure(ref, m))
        XCTAssertEqual(score.notationMeasure(ref), m)
        XCTAssertFalse(score.updateNotationMeasure(NotationMeasureRef(line: ref.line, measure: 9), m))
    }

    func testChordDiagramModel() {
        let c = ChordDiagramModel(shape: ChordShape(frets: [-1, 3, 2, 0, 1, 0]))
        XCTAssertEqual(c.startFret, 1)
        XCTAssertEqual(c.markers[0], .muted)
        XCTAssertEqual(c.markers[3], .open)
        XCTAssertEqual(c.markers[1], .fretted(row: 2))
        let barre = ChordDiagramModel(shape: ChordShape(frets: [5, 7, 7, 6, 5, 5]))
        XCTAssertEqual(barre.startFret, 5)
        XCTAssertNotNil(barre.barre)
    }
}

final class NotationChordsTests: XCTestCase {
    func testShapesAndLabels() {
        let printed = ChordShape(frets: [-1, 3, 2, 0, 1, 0])
        XCTAssertEqual(NotationChords.shape(for: ChordMark(name: "C", shape: printed), definitions: [:], transpose: 0, preferFlats: nil), printed)
        XCTAssertNil(NotationChords.shape(for: ChordMark(name: "???"), definitions: [:], transpose: 0, preferFlats: nil))
        XCTAssertNotNil(NotationChords.shape(for: ChordMark(name: "G"), definitions: [:], transpose: 2, preferFlats: nil))
        XCTAssertNotEqual(NotationChords.shape(for: ChordMark(name: "C", shape: printed), definitions: [:], transpose: 2, preferFlats: nil), printed)
        XCTAssertEqual(NotationChords.label(ChordMark(name: "C"), transpose: 2, preferFlats: nil), "D")
        XCTAssertEqual(NotationChords.label(ChordMark(name: "N.C."), transpose: 2, preferFlats: nil), "N.C.")
    }
}
