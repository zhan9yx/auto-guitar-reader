import XCTest
@testable import AGRCore

final class ImportAsciiTabTests: XCTestCase {
    typealias S = ImportTestSupport

    private let basic = [
        "e|-----0-----|-----3-----|",
        "B|---1---1---|---0---0---|",
        "G|-2-------2-|-0-------0-|",
        "D|-----------|-----------|",
        "A|0----------|-----------|",
        "E|-----------|3----------|",
    ]

    func testBasicBlockMeasuresStringsAndBeats() throws {
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(basic))
        XCTAssertEqual(block.measures.count, 2)
        let m0 = block.measures[0]
        // 11 columns per measure: events at columns 0,1,3,5,7,9 → beat = col/11*4 quantized to 1/8
        XCTAssertEqual(m0.events.map(\.beat), [0, 0.375, 1.125, 1.875, 2.5, 3.25])
        XCTAssertEqual(m0.events.map(\.notes), [
            [TabNote(string: 5, fret: 0)], [TabNote(string: 3, fret: 2)], [TabNote(string: 2, fret: 1)],
            [TabNote(string: 1, fret: 0)], [TabNote(string: 2, fret: 1)], [TabNote(string: 3, fret: 2)],
        ])
        XCTAssertEqual(block.measures[1].events.first?.notes.contains(TabNote(string: 6, fret: 3)), true)
    }

    func testBeatsAreMonotonicAndInsideMeasure() throws {
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(basic))
        for m in block.measures {
            var last = -1.0
            for e in m.events {
                XCTAssertGreaterThan(e.beat, last)
                XCTAssertLessThan(e.beat, 4)
                XCTAssertGreaterThan(e.duration, 0)
                XCTAssertLessThanOrEqual(e.beat + e.duration, 4.0001)
                XCTAssertEqual((e.beat * 8).rounded(), e.beat * 8, accuracy: 1e-9)
                last = e.beat
            }
        }
    }

    func testEvenlySpacedColumnsGiveEvenBeats() throws {
        let lines = [
            "e|0---3---0---3---|",
            "B|----------------|",
            "G|----------------|",
            "D|----------------|",
            "A|----------------|",
            "E|----------------|",
        ]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines))
        XCTAssertEqual(block.measures[0].events.map(\.beat), [0, 1, 2, 3])
        XCTAssertEqual(block.measures[0].events.map(\.duration), [1, 1, 1, 1])
    }

    func testThreeFourTimeUsesBeatsPerMeasure() throws {
        let lines = [
            "e|0-----3-----|",
            "B|------------|",
            "G|------------|",
            "D|------------|",
            "A|------------|",
            "E|------------|",
        ]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines, beatsPerMeasure: 3))
        XCTAssertEqual(block.measures[0].events.map(\.beat), [0, 1.5])
    }

    func testMultiDigitFrets() throws {
        let lines = [
            "e|-12-15-|",
            "B|-------|",
            "G|-------|",
            "D|-------|",
            "A|-------|",
            "E|-10----|",
        ]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines))
        let events = block.measures[0].events
        XCTAssertEqual(events[0].notes, [TabNote(string: 1, fret: 12), TabNote(string: 6, fret: 10)])
        XCTAssertEqual(events[1].notes, [TabNote(string: 1, fret: 15)])
    }

    func testTechniques() throws {
        let lines = [
            "e|--5h7--7p5--5/7--7\\5--7b9r7--x--<12>--|",
            "B|--------------------------------------|",
            "G|--------------------------------------|",
            "D|--------------------------------------|",
            "A|--------------------------------------|",
            "E|--------------------------------------|",
        ]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines))
        let notes = block.measures[0].events.flatMap(\.notes)
        XCTAssertEqual(notes, [
            TabNote(string: 1, fret: 5), TabNote(string: 1, fret: 7, technique: .hammerOn),
            TabNote(string: 1, fret: 7), TabNote(string: 1, fret: 5, technique: .pullOff),
            TabNote(string: 1, fret: 5), TabNote(string: 1, fret: 7, technique: .slideUp),
            TabNote(string: 1, fret: 7), TabNote(string: 1, fret: 5, technique: .slideDown),
            TabNote(string: 1, fret: 7, technique: .bend),
            TabNote(string: 1, fret: 0, technique: .mute),
            TabNote(string: 1, fret: 12, technique: .harmonic),
        ])
    }

    func testChordNamesAboveTabAttachToNearestEvent() throws {
        let lines = [
            "e|0---3---0---3---|",
            "B|----------------|",
            "G|----------------|",
            "D|----------------|",
            "A|----------------|",
            "E|----------------|",
        ]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines, beatsPerMeasure: 4, chordLine: "  Am      G"))
        let events = block.measures[0].events
        XCTAssertEqual(events[0].chord, "Am")
        XCTAssertEqual(events[2].chord, "G")
        XCTAssertNil(events[1].chord)
    }

    func testLowercaseLabelsWithoutNamesAndNumericLabels() throws {
        let bare = ["|--0--|", "|--1--|", "|--2--|", "|--2--|", "|--3--|", "|--x--|"]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(bare))
        XCTAssertEqual(block.measures[0].events[0].notes.map(\.string), [1, 2, 3, 4, 5, 6])
        let numeric = ["1|--0--|", "2|--1--|", "3|--2--|", "4|--2--|", "5|--3--|", "6|--0--|"]
        let nb = try XCTUnwrap(AsciiTabParser.parseBlock(numeric))
        XCTAssertEqual(nb.measures[0].events[0].notes.first, TabNote(string: 1, fret: 0))
        XCTAssertEqual(nb.measures[0].events[0].notes.last, TabNote(string: 6, fret: 0))
    }

    func testReversedLabelOrderBassFirst() throws {
        let lines = ["E|--0--|", "A|--1--|", "D|--2--|", "G|--2--|", "B|--3--|", "e|--4--|"]
        let block = try XCTUnwrap(AsciiTabParser.parseBlock(lines))
        let notes = block.measures[0].events[0].notes
        XCTAssertEqual(notes.first(where: { $0.string == 6 })?.fret, 0)
        XCTAssertEqual(notes.first(where: { $0.string == 1 })?.fret, 4)
    }

    func testParseBlockRejectsWrongLineCountAndNonTab() {
        XCTAssertNil(AsciiTabParser.parseBlock(Array(basic.prefix(5))))
        XCTAssertNil(AsciiTabParser.parseBlock(["hello", "world", "a", "b", "c", "d"]))
    }

    func testRenderThenParseRoundTrip() throws {
        let measure = TabMeasure(beats: nil, events: [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 5, fret: 3), TabNote(string: 2, fret: 1)], chord: "C"),
            TabEvent(beat: 1, duration: 0.5, notes: [TabNote(string: 3, fret: 12)]),
            TabEvent(beat: 1.5, duration: 0.5, notes: [TabNote(string: 3, fret: 14, technique: .hammerOn)]),
            TabEvent(beat: 2, duration: 2, notes: [TabNote(string: 1, fret: 0)], chord: "G"),
        ])
        let block = TabBlock(measures: [measure, measure])
        let rendered = AsciiTabParser.render(block, defaultBeats: 4)
        XCTAssertEqual(rendered.count, 7)
        let back = try XCTUnwrap(AsciiTabParser.parseBlock(Array(rendered.dropFirst()), beatsPerMeasure: 4, chordLine: rendered[0]))
        XCTAssertEqual(back.measures.count, 2)
        for (a, b) in zip(block.measures, back.measures) {
            XCTAssertEqual(a.events.map(\.beat), b.events.map(\.beat))
            XCTAssertEqual(a.events.map { $0.notes.sorted { $0.string < $1.string } }, b.events.map(\.notes))
            XCTAssertEqual(a.events.map(\.chord), b.events.map(\.chord))
        }
    }

    func testParseDocumentWithMetadataAndSections() throws {
        let text = """
        Romance - Traditional
        Tempo: 90
        Time: 3/4

        [Intro]
          Am
        e|0---3---|
        B|--------|
        G|--------|
        D|--------|
        A|--------|
        E|--------|

        Play slowly
        """
        let score = try AsciiTabParser.parse(text)
        XCTAssertEqual(score.meta.title, "Romance")
        XCTAssertEqual(score.meta.artist, "Traditional")
        XCTAssertEqual(score.meta.tempo, 90)
        XCTAssertEqual(score.meta.mode, .fingerstyle)
        XCTAssertEqual(score.meta.source?.kind, .asciiTab)
        XCTAssertEqual(score.sections.map(\.name), ["Intro"])
        let lines = score.sections[0].lines
        XCTAssertEqual(lines.map(\.kind), [.tab, .comment])
        XCTAssertEqual(lines[0].tab?.measures[0].events.map(\.beat), [0, 1.5])
        XCTAssertEqual(lines[0].tab?.measures[0].events[0].chord, "Am")
    }

    func testTabParseThrowsWithoutBlocks() {
        XCTAssertThrowsError(try AsciiTabParser.parse("just words")) {
            guard case .malformed? = $0 as? ImportError else { return XCTFail("expected malformed") }
        }
        XCTAssertThrowsError(try AsciiTabParser.parse("")) { XCTAssertEqual($0 as? ImportError, .empty) }
    }

    func testTwelveLineRunSplitsIntoTwoSystems() throws {
        let text = (basic + basic).joined(separator: "\n")
        let score = try AsciiTabParser.parse(text)
        XCTAssertEqual(score.sections.flatMap(\.lines).filter { $0.kind == .tab }.count, 2)
    }
}
