import XCTest
@testable import AGRCore

final class TimelineTests: XCTestCase {
    func lyr(_ pairs: [(String?, String)], beats: [Double?] = []) -> Line {
        Line(kind: .lyrics, segments: pairs.enumerated().map { i, p in
            ChordSegment(chord: p.0, text: p.1, beats: i < beats.count ? beats[i] : nil)
        })
    }
    func chordsLine(_ names: [String], beats: [Double?] = []) -> Line {
        Line(kind: .chords, segments: names.enumerated().map { i, n in
            ChordSegment(chord: n, text: "", beats: i < beats.count ? beats[i] : nil)
        })
    }
    func score(_ sections: [Section], capo: Int = 0, tempo: Double = 120, ts: TimeSignature = TimeSignature(),
               arrangement: [String]? = nil, defs: [String: ChordShape] = [:]) -> Score {
        Score(meta: ScoreMeta(title: "t", capo: capo, tempo: tempo, timeSignature: ts),
              chordDefinitions: defs, sections: sections, arrangement: arrangement)
    }

    func testDefaultChordDurationIsOneMeasure() {
        let s = score([Section(id: "a", lines: [chordsLine(["C", "G", "Am", "F"])])])
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.map(\.startBeat), [0, 4, 8, 12])
        XCTAssertEqual(t.events.map(\.beats), [4, 4, 4, 4])
        XCTAssertEqual(t.totalBeats, 16)
        XCTAssertEqual(t.events.map(\.kind), [.chord, .chord, .chord, .chord])
        XCTAssertEqual(t.events.map { $0.chord?.description }, ["C", "G", "Am", "F"])
        // 3/4 time → 3 beats per measure.
        let t3 = Timeline.build(from: score([Section(id: "a", lines: [chordsLine(["C", "G"])])], ts: TimeSignature(beats: 3)))
        XCTAssertEqual(t3.events.map(\.beats), [3, 3])
    }

    func testExplicitBeatsAndLyrics() {
        let line = lyr([("C", "我曾经"), ("G", "跨过")], beats: [2, 6])
        let t = Timeline.build(from: score([Section(id: "a", lines: [line])]))
        XCTAssertEqual(t.events.map(\.beats), [2, 6])
        XCTAssertEqual(t.events.map(\.lyric), ["我曾经", "跨过"])
        XCTAssertEqual(t.events.map(\.segmentIndex), [0, 1])
        XCTAssertEqual(t.events[1].startBeat, 2)
    }

    func testChordlessLyricLineContinuesPreviousChord() {
        let s = score([Section(id: "a", lines: [
            lyr([("C", "我曾经跨过山和大海")]),              // 1 measure
            lyr([(nil, "也穿过人山人海")]),                    // 7 chars → 1 measure
            lyr([(nil, "每当我走过这座城市的街头巷尾")]),       // 14 chars → 2 measures
            lyr([(nil, "   "), (nil, "")]),                    // blank → skipped
        ])])
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.count, 3)
        XCTAssertEqual(t.events.map(\.beats), [4, 4, 8])
        XCTAssertEqual(t.events[1].chord?.description, "C")
        XCTAssertEqual(t.events[1].midiNotes, t.events[0].midiNotes)
        XCTAssertEqual(t.events[1].line.lineIndex, 1)
        XCTAssertEqual(t.events[2].lyric, "每当我走过这座城市的街头巷尾")
    }

    func testChordlessLineWithoutPreviousChordIsRest() {
        let t = Timeline.build(from: score([Section(id: "a", lines: [lyr([(nil, "前奏之前的话")])])]))
        XCTAssertEqual(t.events.count, 1)
        XCTAssertEqual(t.events[0].kind, .rest)
        XCTAssertNil(t.events[0].chord)
        XCTAssertEqual(t.events[0].beats, 4)
    }

    func testLeadingTextJoinsPreviousChordEvent() {
        let s = score([Section(id: "a", lines: [
            lyr([("C", "我曾经跨"), ("G", "过山")]),
            lyr([(nil, "和大海"), ("Am", "也穿过")]),
        ])])
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.count, 3)
        XCTAssertEqual(t.events[1].lyric, "过山和大海")
        XCTAssertEqual(t.events[2].lyric, "也穿过")
        XCTAssertEqual(t.events[1].startBeat, 4)
        XCTAssertEqual(t.events[1].beats, 4)   // no extra duration for unbeated text
        // Progress of the second line starts at 0 for its first event.
        XCTAssertEqual(t.events[2].progressInLine.lowerBound, 0)
        XCTAssertEqual(t.events[2].progressInLine.upperBound, 1)
    }

    func testLeadingTextWithoutPreviousChord() {
        // No duration: merged into the next event's lyric.
        let t = Timeline.build(from: score([Section(id: "a", lines: [lyr([(nil, "啊"), ("C", "我曾经")])])]))
        XCTAssertEqual(t.events.count, 1)
        XCTAssertEqual(t.events[0].lyric, "啊我曾经")
        // With explicit duration: a rest event of that duration.
        let t2 = Timeline.build(from: score([Section(id: "a", lines: [lyr([(nil, "啊"), ("C", "我曾经")], beats: [2, nil])])]))
        XCTAssertEqual(t2.events.map(\.kind), [.rest, .chord])
        XCTAssertEqual(t2.events[0].beats, 2)
        XCTAssertEqual(t2.events[0].lyric, "啊")
        XCTAssertEqual(t2.events[1].startBeat, 2)
        XCTAssertEqual(t2.totalBeats, 6)
    }

    func testCommentLinesAndUnparseableChords() {
        let s = score([Section(id: "a", lines: [
            Line(kind: .comment, text: "(x2)"),
            lyr([("N.C.", "停"), ("G", "走")]),
        ])])
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.map(\.kind), [.rest, .chord])
        XCTAssertEqual(t.events[0].lyric, "停")
        XCTAssertEqual(t.events[1].startBeat, 4)
    }

    func testArrangementRepeatsAndPassIndex() {
        let verse = Section(id: "v", name: "V", kind: .verse, lines: [chordsLine(["C", "G"])])
        let chorus = Section(id: "c", name: "C", kind: .chorus, lines: [chordsLine(["F"])])
        let s = score([verse, chorus], arrangement: ["v", "c", "v", "missing", "c"])
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.count, 2 + 1 + 2 + 1)
        XCTAssertEqual(t.events.map(\.passIndex), [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(t.events.map(\.line.sectionIndex), [0, 0, 1, 0, 0, 1])
        XCTAssertEqual(t.sectionStartIndices, [0, 2, 3, 5])
        XCTAssertEqual(t.sectionPasses.map(\.passIndex), [0, 0, 1, 1])
        XCTAssertEqual(t.events.map(\.index), Array(0..<6))
        // Without arrangement: sections in order.
        XCTAssertEqual(Timeline.build(from: score([verse, chorus])).sectionStartIndices, [0, 2])
    }

    func testTabBeatPositionsAndRests() {
        let m1 = TabMeasure(beats: 4, events: [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 6, fret: 3)]),
            TabEvent(beat: 1, duration: 1.5, notes: [TabNote(string: 1, fret: 0), TabNote(string: 2, fret: 1)]),
            TabEvent(beat: 2.5, duration: 1.5, notes: [TabNote(string: 3, fret: 2)]),
        ])
        let m2 = TabMeasure(beats: 4, events: [])
        let line = Line(kind: .tab, tab: TabBlock(measures: [m1, m2]))
        let t = Timeline.build(from: score([Section(id: "a", lines: [line])], capo: 0, tempo: 60))
        XCTAssertEqual(t.events.map(\.kind), [.notes, .notes, .notes, .rest])
        XCTAssertEqual(t.events.map(\.startBeat), [0, 1, 2.5, 4])
        XCTAssertEqual(t.events.map(\.beats), [1, 1.5, 1.5, 4])
        XCTAssertEqual(t.events.map(\.tabMeasureIndex), [0, 0, 0, 1])
        XCTAssertEqual(t.events.map(\.tabEventIndex), [0, 1, 2, nil])
        XCTAssertEqual(t.events[0].midiNotes, [43])            // string 6 fret 3 = G2
        XCTAssertEqual(t.events[1].midiNotes, [64, 60])        // index-aligned with TabEvent.notes
        XCTAssertEqual(t.totalBeats, 8)
        XCTAssertEqual(t.events[1].progressInLine.lowerBound, 1.0 / 8, accuracy: 1e-12)
        XCTAssertEqual(t.events[3].progressInLine.upperBound, 1, accuracy: 1e-12)
    }

    func testTabCapoAndTransposeAndLeadingGap() {
        let m = TabMeasure(beats: 4, events: [TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 1, fret: 0)], chord: "Am")])
        let line = Line(kind: .tab, tab: TabBlock(measures: [m]))
        let s = score([Section(id: "a", lines: [line])], capo: 2)
        let t = Timeline.build(from: s, options: TimelineOptions(transpose: 3))
        XCTAssertEqual(t.events.map(\.kind), [.rest, .notes])   // leading gap becomes a rest
        XCTAssertEqual(t.events[1].midiNotes, [64 + 2 + 3])
        XCTAssertEqual(t.events[1].chord?.description, "Cm")
        XCTAssertEqual(t.events[1].beats, 3)
    }

    func testTransposeChangesNameAndMidiButCapoDoesNot() {
        let base = score([Section(id: "a", lines: [chordsLine(["G", "C"])])])
        let t0 = Timeline.build(from: base)
        XCTAssertEqual(t0.events[0].midiNotes, [43, 47, 50, 55, 59, 67])

        // Capo 2: shapes (names) unchanged, sound two semitones up.
        var capoed = base
        capoed.meta.capo = 2
        let tc = Timeline.build(from: capoed)
        XCTAssertEqual(tc.events.map { $0.chord?.description }, ["G", "C"])
        XCTAssertEqual(tc.events[0].midiNotes, t0.events[0].midiNotes.map { $0 + 2 })

        // Transpose +2: names change, voicing is re-derived for the new name.
        let tt = Timeline.build(from: base, options: TimelineOptions(transpose: 2))
        XCTAssertEqual(tt.events.map { $0.chord?.description }, ["A", "D"])
        XCTAssertEqual(tt.events[0].voicing?.description, "x02220")
        XCTAssertEqual(Set(tt.events[0].midiNotes.map { $0 % 12 }), [9, 1, 4])

        // Capo + transpose both apply to the sound; only transpose changes the name.
        let both = Timeline.build(from: capoed, options: TimelineOptions(transpose: 2))
        XCTAssertEqual(both.events[0].chord?.description, "A")
        XCTAssertEqual(both.events[0].midiNotes, tt.events[0].midiNotes.map { $0 + 2 })
    }

    func testTransposeSpelling() {
        let s = score([Section(id: "a", lines: [chordsLine(["C", "Bb", "F#m", "Am/G"])])])
        let t = Timeline.build(from: s, options: TimelineOptions(transpose: 3))
        XCTAssertEqual(t.events.map { $0.chord?.description }, ["Eb", "Db", "Am", "Cm/Bb"])
        let down = Timeline.build(from: s, options: TimelineOptions(transpose: -12))
        XCTAssertEqual(down.events.map { $0.chord?.description }, ["C", "Bb", "F#m", "Am/G"])
    }

    func testChordDefinitionsOverrideOnlyWhenNotTransposed() {
        let shape = ChordShape(frets: [-1, 3, 5, 5, 5, 3], baseFret: 3)
        let s = score([Section(id: "a", lines: [chordsLine(["C"])])], defs: ["C": shape])
        XCTAssertEqual(Timeline.build(from: s).events[0].voicing?.frets, [-1, 3, 5, 5, 5, 3])
        XCTAssertEqual(Timeline.build(from: s, options: TimelineOptions(transpose: 2)).events[0].voicing?.description, "xx0232")
    }

    func testProgressInLineMonotonicAndCoversLine() {
        let s = score([Section(id: "a", lines: [
            lyr([("C", "我曾经跨过山和大海"), ("G", "也穿过"), ("Am", "人山人海"), ("F", "")]),
            chordsLine(["C", "G", "Am"], beats: [2, 4, 2]),
            lyr([(nil, "继续唱")]),
            Line(kind: .tab, tab: TabBlock(measures: [
                TabMeasure(beats: 4, events: [TabEvent(beat: 0, duration: 2, notes: [TabNote(string: 1, fret: 0)]),
                                              TabEvent(beat: 2, duration: 2, notes: [TabNote(string: 2, fret: 0)])]),
            ])),
        ])])
        let t = Timeline.build(from: s)
        let byLine = Dictionary(grouping: t.events, by: { $0.line.lineIndex })
        XCTAssertEqual(byLine.count, 4)
        for (li, evs) in byLine {
            let sorted = evs.sorted { $0.index < $1.index }
            XCTAssertEqual(sorted.first!.progressInLine.lowerBound, 0, accuracy: 1e-12, "line \(li)")
            XCTAssertEqual(sorted.last!.progressInLine.upperBound, 1, accuracy: 1e-12, "line \(li)")
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                XCTAssertLessThanOrEqual(a.progressInLine.lowerBound, a.progressInLine.upperBound)
                XCTAssertEqual(a.progressInLine.upperBound, b.progressInLine.lowerBound, accuracy: 1e-12)
            }
        }
        // Display columns: 9 full-width chars (18) vs 3 (6) vs 4 (8) vs empty (min 1).
        let first = byLine[0]!.sorted { $0.index < $1.index }
        XCTAssertEqual(first[0].progressInLine.upperBound, 18.0 / 33.0, accuracy: 1e-9)
        // Chord line by beats: 2/8, 4/8, 2/8.
        let cl = byLine[1]!.sorted { $0.index < $1.index }
        XCTAssertEqual(cl[1].progressInLine.lowerBound, 0.25, accuracy: 1e-12)
        XCTAssertEqual(cl[1].progressInLine.upperBound, 0.75, accuracy: 1e-12)
    }

    func testSecondsAndEventLookup() {
        let s = score([Section(id: "a", lines: [chordsLine(["C", "G", "Am"], beats: [2, 4, 2])])], tempo: 120)
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.tempo, 120)
        XCTAssertEqual(t.seconds(forBeat: 2), 1.0, accuracy: 1e-12)
        XCTAssertEqual(t.eventIndex(atBeat: 0), 0)
        XCTAssertEqual(t.eventIndex(atBeat: 1.99), 0)
        XCTAssertEqual(t.eventIndex(atBeat: 2), 1)
        XCTAssertEqual(t.eventIndex(atBeat: 7.9), 2)
        XCTAssertNil(t.eventIndex(atBeat: 8))
        XCTAssertNil(t.eventIndex(atBeat: -0.1))
        let fast = Timeline.build(from: s, options: TimelineOptions(tempo: 60))
        XCTAssertEqual(fast.tempo, 60)
        XCTAssertEqual(fast.seconds(forBeat: 2), 2.0, accuracy: 1e-12)
        XCTAssertNil(Timeline.build(from: Score()).eventIndex(atBeat: 0))
    }

    func testDemoScoreBuilds() {
        let s = DemoScore.make()
        let t = Timeline.build(from: s)
        XCTAssertEqual(t.events.filter { $0.kind == .chord }.count, 4)
        XCTAssertGreaterThan(t.events.filter { $0.kind == .notes }.count, 10)
    }
}
