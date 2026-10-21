import XCTest
@testable import AGRCore

final class ImportChordProTests: XCTestCase {
    typealias S = ImportTestSupport

    private let sample = """
    {title: 七里香}
    {t: ignored by later title}
    {artist: 周杰伦}
    {composer: 周杰伦}
    {lyricist: 方文山}
    {key: G}
    {capo: 2}
    {tempo: 86}
    {time: 4/4}

    {start_of_part: Intro}
    [G] [D] [Em] [C]
    {end_of_part}

    {start_of_verse: 主歌 1}
    [G]窗外的[D]麻雀 在电线杆上[Em]多嘴
    {comment: 轻轻弹唱}
    你说这一句 很有[C]夏天的感觉
    {end_of_verse}

    {soc}
    [C]雨下整夜 我的爱溢出就像雨[G]水
    {eoc}
    """

    func testMetaDirectives() throws {
        let score = try ChordProParser.parse(sample)
        XCTAssertEqual(score.meta.title, "ignored by later title")
        XCTAssertEqual(score.meta.artist, "周杰伦")
        XCTAssertEqual(score.meta.composer, "周杰伦")
        XCTAssertEqual(score.meta.lyricist, "方文山")
        XCTAssertEqual(score.meta.key, "G")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(score.meta.tempo, 86)
        XCTAssertEqual(score.meta.timeSignature, TimeSignature(beats: 4, unit: 4))
        XCTAssertEqual(score.meta.source?.kind, .chordpro)
        XCTAssertEqual(score.meta.mode, .strumSing)
    }

    func testSectionsKindsAndLabels() throws {
        let score = try ChordProParser.parse(sample)
        XCTAssertEqual(score.sections.map(\.name), ["Intro", "主歌 1", "Chorus"])
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse, .chorus])
        XCTAssertEqual(score.sections.map(\.id), ["s0", "s1", "s2"])
    }

    func testInlineChordsAndChordOnlyLines() throws {
        let score = try ChordProParser.parse(sample)
        let intro = score.sections[0].lines[0]
        XCTAssertEqual(intro.kind, .chords)
        XCTAssertEqual(intro.segments.compactMap(\.chord), ["G", "D", "Em", "C"])
        XCTAssertTrue(intro.segments.allSatisfy { $0.text.isEmpty })
        let verse = score.sections[1].lines
        XCTAssertEqual(verse[0].segments, [
            ChordSegment(chord: "G", text: "窗外的"),
            ChordSegment(chord: "D", text: "麻雀 在电线杆上"),
            ChordSegment(chord: "Em", text: "多嘴"),
        ])
        XCTAssertEqual(verse[1].kind, .comment)
        XCTAssertEqual(verse[1].text, "轻轻弹唱")
        XCTAssertEqual(S.render(verse[2]), "你说这一句 很有[C]夏天的感觉")
        XCTAssertEqual(verse[2].segments.first?.chord, nil)
        XCTAssertEqual(verse[2].id, "s1l2")
    }

    func testShortDirectivesAndLabelAttribute() throws {
        let text = """
        {t: Song}
        {st: Someone}
        {sov: Verse A}
        [C]one
        {eov}
        {sob}
        [G]two
        {eob}
        {start_of_chorus: label="Refrain 1"}
        [F]three
        {end_of_chorus}
        {ci: note}
        """
        let score = try ChordProParser.parse(text)
        XCTAssertEqual(score.meta.artist, "Someone")
        XCTAssertEqual(score.sections.map(\.name), ["Verse A", "Bridge", "Refrain 1", ""])
        XCTAssertEqual(score.sections.map(\.kind), [.verse, .bridge, .chorus, .other])
        XCTAssertEqual(score.sections[3].lines.first?.kind, .comment)
    }

    func testBracketedNonChordTextStaysLiteral() throws {
        let score = try ChordProParser.parse("{t: x}\n[C]hello [laughs] there[G]")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.segments, [ChordSegment(chord: "C", text: "hello [laughs] there"), ChordSegment(chord: "G", text: "")])
    }

    func testDefineDirective() throws {
        let text = """
        {title: x}
        {define: Am base-fret 1 frets x 0 2 2 1 0}
        {define: F base-fret 1 frets 1 3 3 2 1 1 fingers 1 3 4 2 1 1}
        {define: Bm base-fret 2 frets x 1 3 3 2 1}
        [Am]la
        """
        let score = try ChordProParser.parse(text)
        XCTAssertEqual(score.chordDefinitions["Am"]?.frets, [-1, 0, 2, 2, 1, 0])
        XCTAssertEqual(score.chordDefinitions["F"]?.fingers, [1, 3, 4, 2, 1, 1])
        // relative frets are converted to absolute frets
        XCTAssertEqual(score.chordDefinitions["Bm"]?.frets, [-1, 2, 4, 4, 3, 2])
        XCTAssertEqual(score.chordDefinitions["Bm"]?.baseFret, 2)
    }

    func testStartOfTabParsesAsciiTab() throws {
        let text = """
        {title: Tab}
        {time: 3/4}
        {sot}
        e|0-----3-----|
        B|------------|
        G|------------|
        D|------------|
        A|------------|
        E|------------|
        {eot}
        """
        let score = try ChordProParser.parse(text)
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.kind, .tab)
        XCTAssertEqual(line.tab?.measures[0].events.map(\.beat), [0, 1.5])
        XCTAssertEqual(score.meta.mode, .fingerstyle)
    }

    func testUnknownDirectivesAndCommentsIgnored() throws {
        let score = try ChordProParser.parse("# comment\n{textsize: 12}\n{new_page}\n[C]hi")
        XCTAssertEqual(S.allLines(score).count, 1)
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try ChordProParser.parse("   \n")) { XCTAssertEqual($0 as? ImportError, .empty) }
    }

    // MARK: Exporter round trip

    private func sampleScore() throws -> Score {
        var score = try ChordProParser.parse(sample)
        score.chordDefinitions["Am"] = ChordShape(frets: [-1, 0, 2, 2, 1, 0], fingers: nil, baseFret: 1)
        score.chordDefinitions["Bm"] = ChordShape(frets: [-1, 2, 4, 4, 3, 2], fingers: nil, baseFret: 2)
        return score
    }

    func testExportRoundTripPreservesMetaSectionsAndSegments() throws {
        let score = try sampleScore()
        let text = ChordProExporter.export(score)
        let back = try ChordProParser.parse(text)
        XCTAssertEqual(back.meta.title, score.meta.title)
        XCTAssertEqual(back.meta.artist, score.meta.artist)
        XCTAssertEqual(back.meta.composer, score.meta.composer)
        XCTAssertEqual(back.meta.lyricist, score.meta.lyricist)
        XCTAssertEqual(back.meta.key, score.meta.key)
        XCTAssertEqual(back.meta.capo, score.meta.capo)
        XCTAssertEqual(back.meta.tempo, score.meta.tempo)
        XCTAssertEqual(back.meta.timeSignature, score.meta.timeSignature)
        XCTAssertEqual(back.sections.map(\.name), score.sections.map(\.name))
        XCTAssertEqual(back.sections.map(\.kind), score.sections.map(\.kind))
        XCTAssertEqual(back.sections, score.sections)
        XCTAssertEqual(back.chordDefinitions, score.chordDefinitions)
    }

    func testExportIsStableAfterSecondRoundTrip() throws {
        let first = ChordProExporter.export(try sampleScore())
        let second = ChordProExporter.export(try ChordProParser.parse(first))
        XCTAssertEqual(first, second)
    }

    func testExportRoundTripNonDefaultMeta() throws {
        var meta = ScoreMeta(title: "Waltz", artist: "A", key: "Em", capo: 3, tempo: 92.5,
                             timeSignature: TimeSignature(beats: 3, unit: 4), tuning: [38, 45, 50, 55, 59, 64])
        meta.mode = .fingerstyle
        let score = Score(meta: meta, sections: [
            Section(id: "s0", name: "Verse", kind: .verse, lines: [Line(id: "s0l0", kind: .lyrics, segments: [ChordSegment(chord: "Em", text: "la")])])
        ])
        let back = try ChordProParser.parse(ChordProExporter.export(score))
        XCTAssertEqual(back.meta.tempo, 92.5)
        XCTAssertEqual(back.meta.timeSignature, TimeSignature(beats: 3, unit: 4))
        XCTAssertEqual(back.meta.tuning, [38, 45, 50, 55, 59, 64])
        XCTAssertEqual(back.meta.mode, .fingerstyle)
        XCTAssertEqual(back.meta.capo, 3)
    }

    func testExportRoundTripKeepsSectionKindsWithCustomNames() throws {
        let kinds: [SectionKind] = [.intro, .verse, .preChorus, .chorus, .bridge, .interlude, .solo, .outro, .other]
        let sections = kinds.enumerated().map { i, k in
            Section(id: "s\(i)", name: "名称 \(i)", kind: k,
                    lines: [Line(id: "s\(i)l0", kind: .lyrics, segments: [ChordSegment(chord: "C", text: "x")])])
        }
        let score = Score(meta: ScoreMeta(title: "k"), sections: sections)
        let back = try ChordProParser.parse(ChordProExporter.export(score))
        XCTAssertEqual(back.sections.map(\.kind), kinds)
        XCTAssertEqual(back.sections.map(\.name), sections.map(\.name))
    }

    func testExportRoundTripTabEvents() throws {
        let events1 = [
            TabEvent(beat: 0, duration: 1, notes: [TabNote(string: 5, fret: 3), TabNote(string: 2, fret: 1)], chord: "C"),
            TabEvent(beat: 1, duration: 1, notes: [TabNote(string: 3, fret: 0)]),
            TabEvent(beat: 2, duration: 0.5, notes: [TabNote(string: 2, fret: 1)]),
            TabEvent(beat: 2.5, duration: 1.5, notes: [TabNote(string: 1, fret: 0, technique: .slideUp)]),
        ]
        let events2 = [
            TabEvent(beat: 0, duration: 2, notes: [TabNote(string: 6, fret: 3), TabNote(string: 4, fret: 12)], chord: "G"),
            TabEvent(beat: 2, duration: 2, notes: [TabNote(string: 1, fret: 3, technique: .hammerOn)]),
        ]
        let tab = TabBlock(measures: [TabMeasure(events: events1), TabMeasure(events: events2)])
        let score = Score(meta: ScoreMeta(title: "fs", mode: .fingerstyle), sections: [
            Section(id: "s0", name: "", kind: .other, lines: [Line(id: "s0l0", kind: .tab, tab: tab)])
        ])
        let text = ChordProExporter.export(score)
        XCTAssertTrue(text.contains("{sot}"))
        let back = try ChordProParser.parse(text)
        let backTab = try XCTUnwrap(S.allLines(back).first?.tab)
        XCTAssertEqual(backTab.measures.count, 2)
        for (a, b) in zip(tab.measures, backTab.measures) {
            XCTAssertEqual(a.events.count, b.events.count)
            for (ea, eb) in zip(a.events, b.events) {
                XCTAssertEqual(ea.beat, eb.beat, accuracy: 0.125)
                XCTAssertEqual(ea.duration, eb.duration, accuracy: 0.125)
                XCTAssertEqual(ea.notes.sorted { $0.string < $1.string }, eb.notes)
                XCTAssertEqual(ea.chord, eb.chord)
            }
        }
        XCTAssertEqual(back.meta.mode, .fingerstyle)
    }

    func testExportRoundTripCommentsAndChordsLines() throws {
        let score = Score(meta: ScoreMeta(title: "c"), sections: [
            Section(id: "s0", name: "Intro", kind: .intro, lines: [
                Line(id: "s0l0", kind: .chords, segments: [ChordSegment(chord: "Am", text: ""), ChordSegment(chord: "F", text: "")]),
                Line(id: "s0l1", kind: .comment, text: "慢速 rubato"),
                Line(id: "s0l2", kind: .lyrics, segments: [ChordSegment(chord: nil, text: "前奏 "), ChordSegment(chord: "G", text: "词")]),
            ])
        ])
        let back = try ChordProParser.parse(ChordProExporter.export(score))
        XCTAssertEqual(back.sections, score.sections)
    }

    func testChordTextScoreRoundTripsThroughChordPro() throws {
        let text = """
        原调：G
        变调夹：2
        [主歌]
        C         G     Am
        我曾经跨过山和大海
        F       G
        也穿过人山人海
        """
        let score = try ChordTextParser.parse(text)
        let back = try ChordProParser.parse(ChordProExporter.export(score))
        XCTAssertEqual(back.sections, score.sections)
        XCTAssertEqual(back.meta.key, "G")
        XCTAssertEqual(back.meta.capo, 2)
    }
}
