import XCTest
@testable import AGRCore

final class ImportChordTextTests: XCTestCase {
    typealias S = ImportTestSupport

    // MARK: Chord-over-lyrics alignment

    func testChineseChordOverLyricsAlignsByDisplayColumns() throws {
        // 我0 曾2 经4 跨6 过8 山10 和12 大14 海16
        let text = """
        C         G     Am
        我曾经跨过山和大海
        """
        let score = try ChordTextParser.parse(text)
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.kind, .lyrics)
        XCTAssertEqual(line.segments, [
            ChordSegment(chord: "C", text: "我曾经跨过"),
            ChordSegment(chord: "G", text: "山和大"),
            ChordSegment(chord: "Am", text: "海"),
        ])
    }

    func testChordInsideSecondColumnOfWideCharAttachesToThatChar() throws {
        // chord at column 3 is inside 曾 (columns 2-3)
        let score = try ChordTextParser.parse("   C\n我曾经")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.segments, [ChordSegment(chord: nil, text: "我"), ChordSegment(chord: "C", text: "曾经")])
    }

    func testMixedWidthLyricAlignment() throws {
        // "Hi 我们" → H0 i1 space2 我3-4 们5-6
        let score = try ChordTextParser.parse("C  G\nHi 我们")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(S.render(line), "[C]Hi [G]我们")
    }

    func testChordBeyondLyricEndGetsEmptyText() throws {
        let score = try ChordTextParser.parse("C   G          Am\nHello")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.segments.map(\.chord), ["C", "G", "Am"])
        XCTAssertEqual(line.segments.last?.text, "")
        XCTAssertEqual(line.lyricText, "Hello")
    }

    func testChordLineFollowedByBlankBecomesChordsLine() throws {
        let score = try ChordTextParser.parse("[Intro]\nC  G  Am  F\n\nC\nlyric line")
        let lines = S.allLines(score)
        XCTAssertEqual(lines.map(\.kind), [.chords, .lyrics])
        XCTAssertEqual(lines[0].segments.map(\.chord), ["C", "G", "Am", "F"])
        XCTAssertTrue(lines[0].segments.allSatisfy { $0.text.isEmpty })
        XCTAssertEqual(S.render(lines[1]), "[C]lyric line")
    }

    func testTwoConsecutiveChordLines() throws {
        let score = try ChordTextParser.parse("Am  G\nC   F\nlyrics here")
        let lines = S.allLines(score)
        XCTAssertEqual(lines.map(\.kind), [.chords, .lyrics])
        XCTAssertEqual(S.render(lines[1]), "[C]lyri[F]cs here")
    }

    func testBarLinesAndFillersInChordRows() throws {
        let text = """
        | G | D | Em | C |
        | Am7 | % | N.C. | x2 |
        """
        let score = try ChordTextParser.parse(text)
        let lines = S.allLines(score)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].segments.map(\.chord), ["G", "D", "Em", "C"])
        XCTAssertEqual(lines[1].segments.map(\.chord), ["Am7", "N.C."])
    }

    func testSlashAndExtendedChordsAreChordLines() throws {
        let score = try ChordTextParser.parse("C/G  D/F#  Cmaj7  E7#9  Gsus4  C6/9\nsing along now")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(line.kind, .lyrics)
        XCTAssertEqual(line.segments.compactMap(\.chord), ["C/G", "D/F#", "Cmaj7", "E7#9", "Gsus4", "C6/9"])
    }

    func testRepeatMarkerBecomesComment() throws {
        let score = try ChordTextParser.parse("[Chorus]\nC  G\nla la\n(x2)")
        let lines = S.allLines(score)
        XCTAssertEqual(lines.last?.kind, .comment)
        XCTAssertEqual(lines.last?.text, "(x2)")
    }

    func testIndentedLyricsStayAligned() throws {
        let score = try ChordTextParser.parse("    C   G\n    我曾经跨过")
        let line = try XCTUnwrap(S.allLines(score).first)
        XCTAssertEqual(S.render(line), "[C]我曾[G]经跨过")
    }

    // MARK: Sections

    func testSectionHeaderVariants() throws {
        let headers: [(String, SectionKind)] = [
            ("[Verse]", .verse), ("[Chorus 2]", .chorus), ("[Intro]", .intro), ("Verse:", .verse),
            ("主歌", .verse), ("主歌1", .verse), ("副歌", .chorus), ("前奏", .intro), ("间奏", .interlude),
            ("尾奏", .outro), ("桥段", .bridge), ("Bridge", .bridge), ("Pre-Chorus", .preChorus),
            ("Outro", .outro), ("Solo", .solo), ("【副歌】", .chorus), ("[Pre-Chorus]", .preChorus),
        ]
        for (header, kind) in headers {
            let score = try ChordTextParser.parse("\(header)\nC\nla la")
            XCTAssertEqual(score.sections.count, 1, header)
            XCTAssertEqual(score.sections[0].kind, kind, header)
            XCTAssertFalse(score.sections[0].name.isEmpty, header)
        }
    }

    func testSectionNamesKeepLabelAndIds() throws {
        let text = """
        【副歌】
        C  G
        啦啦啦啦

        [Chorus 2]
        Am  F
        la la la
        """
        let score = try ChordTextParser.parse(text)
        XCTAssertEqual(score.sections.map(\.name), ["副歌", "Chorus 2"])
        XCTAssertEqual(score.sections.map(\.id), ["s0", "s1"])
        XCTAssertEqual(score.sections[0].lines.map(\.id), ["s0l0"])
        XCTAssertEqual(score.sections[1].lines[0].id, "s1l0")
    }

    func testIntroWithTrailingChordsOnSameLine() throws {
        let score = try ChordTextParser.parse("Intro: C G Am F\nVerse 1:\nC  G\nhello world")
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse])
        XCTAssertEqual(score.sections[0].lines.first?.kind, .chords)
        XCTAssertEqual(score.sections[0].lines.first?.segments.count, 4)
    }

    func testLyricsWithoutHeadersGoToImplicitSection() throws {
        let score = try ChordTextParser.parse("C  G\nhello world\njust text")
        XCTAssertEqual(score.sections.count, 1)
        XCTAssertEqual(score.sections[0].name, "")
        XCTAssertEqual(score.sections[0].lines.count, 2)
        XCTAssertEqual(score.sections[0].lines[1].segments, [ChordSegment(chord: nil, text: "just text")])
    }

    // MARK: Metadata

    func testChineseMetadataLines() throws {
        let text = """
        原调：G 选调：C
        变调夹：2
        速度: 76
        1=C 4/4
        [主歌]
        C
        啦啦
        """
        let score = try ChordTextParser.parse(text)
        XCTAssertEqual(score.meta.key, "G")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(score.meta.tempo, 76)
        XCTAssertEqual(score.sections.first?.lines.count, 1)
    }

    func testChineseCapoVariants() {
        XCTAssertEqual(MetaLineParser.parse("变调夹2品"), [.capo(2)])
        XCTAssertEqual(MetaLineParser.parse("变调夹: 三"), [.capo(3)])
        XCTAssertEqual(MetaLineParser.parse("Capo 2nd fret"), [.capo(2)])
        XCTAssertEqual(MetaLineParser.parse("Capo: 4"), [.capo(4)])
        XCTAssertEqual(MetaLineParser.parse("capo on 5"), [.capo(5)])
        XCTAssertEqual(MetaLineParser.parse("Capo: none"), [.capo(0)])
    }

    func testSelectedKeyDoesNotOverrideOriginalKey() throws {
        let score = try ChordTextParser.parse("选调：C\n原调：A\nC\nla")
        XCTAssertEqual(score.meta.key, "A")
        let score2 = try ChordTextParser.parse("选调：C\nC\nla")
        XCTAssertEqual(score2.meta.key, "C")
    }

    func testEnglishMetadataLines() throws {
        let text = """
        Key: Em
        Capo 2nd fret
        Tuning: Drop D
        BPM: 92
        Time: 3/4
        ♩=100
        [Verse]
        Em
        la la
        """
        let score = try ChordTextParser.parse(text)
        XCTAssertEqual(score.meta.key, "Em")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(score.meta.tuning, [38, 45, 50, 55, 59, 64])
        XCTAssertEqual(score.meta.tempo, 100)
        XCTAssertEqual(score.meta.timeSignature, TimeSignature(beats: 3, unit: 4))
        XCTAssertEqual(S.allLines(score).count, 1)
    }

    func testStandardTuningLineIsConsumed() throws {
        let score = try ChordTextParser.parse("Tuning: standard\nC\nla")
        XCTAssertEqual(score.meta.tuning, ScoreMeta.standardTuning)
        XCTAssertEqual(S.allLines(score).count, 1)
    }

    func testLyricsContainingKeyAreNotMetadata() throws {
        let score = try ChordTextParser.parse("C  G\nThe key to my heart\n")
        XCTAssertEqual(score.meta.key, nil)
        XCTAssertEqual(S.allLines(score).count, 1)
    }

    func testTitleDashArtistOnFirstLine() throws {
        let score = try ChordTextParser.parse("七里香 - 周杰伦\n\n[主歌]\nC  G\n窗外的麻雀")
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.artist, "周杰伦")
        XCTAssertEqual(S.allLines(score).count, 1)
    }

    func testTitleLineWithoutArtistWhenFollowedByBlank() throws {
        let score = try ChordTextParser.parse("《晴天》\n\nC  G\n故事的小黄花")
        XCTAssertEqual(score.meta.title, "晴天")
        XCTAssertNil(score.meta.artist)
    }

    func testBookTitleMarksWithTrailingArtist() throws {
        let score = try ChordTextParser.parse("《七里香》 周杰伦\n原调:G\nC  G\n窗外的麻雀")
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.artist, "周杰伦")
        XCTAssertEqual(score.meta.key, "G")
    }

    func testFirstLyricLineIsNotTitle() throws {
        let score = try ChordTextParser.parse("C  G\n我曾经跨过山和大海\n他们说你不该如此\n")
        XCTAssertEqual(score.meta.title, "")
        XCTAssertEqual(S.allLines(score).count, 2)
    }

    func testTitleArtistComposerMarkers() {
        XCTAssertEqual(MetaLineParser.parse("歌手：周杰伦"), [.artist("周杰伦")])
        XCTAssertEqual(MetaLineParser.parse("演唱：周杰伦 词：方文山 曲：周杰伦"),
                       [.artist("周杰伦"), .lyricist("方文山"), .composer("周杰伦")])
        XCTAssertEqual(MetaLineParser.parse("Title: Yesterday"), [.title("Yesterday")])
    }

    // MARK: Ultimate-Guitar style

    func testUltimateGuitarStyleSheet() throws {
        let text = """
        Wonderwall - Oasis
        Capo: 2

        [Intro]
        [ch]Em7[/ch]  [ch]G[/ch]  [ch]Dsus4[/ch]  [ch]A7sus4[/ch]

        [Verse 1]
        [ch]Em7[/ch]                  [ch]G[/ch]
        Today is gonna be the day that they're gonna throw it back to you
        [ch]Dsus4[/ch]                [ch]A7sus4[/ch]
        By now you should've somehow realized what you gotta do

        [Chorus]
        [ch]C[/ch]       [ch]D[/ch]        [ch]Em7[/ch]
        And all the roads we have to walk are winding
        """
        let score = try ChordTextParser.parse(text)
        XCTAssertEqual(score.meta.title, "Wonderwall")
        XCTAssertEqual(score.meta.artist, "Oasis")
        XCTAssertEqual(score.meta.capo, 2)
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse, .chorus])
        XCTAssertEqual(score.sections[0].lines.first?.segments.compactMap(\.chord), ["Em7", "G", "Dsus4", "A7sus4"])
        let verse = score.sections[1].lines
        XCTAssertEqual(verse.count, 2)
        XCTAssertEqual(verse[0].segments.first?.chord, "Em7")
        XCTAssertEqual(verse[0].segments[1].chord, "G")
        XCTAssertTrue(verse[0].lyricText.hasPrefix("Today is gonna be"))
        let chorus = score.sections[2].lines[0]
        XCTAssertEqual(chorus.segments.compactMap(\.chord), ["C", "D", "Em7"])
        XCTAssertEqual(chorus.segments[0].text, "And all ")
    }

    func testInlineBracketChordsInChordText() throws {
        let score = try ChordTextParser.parse("[主歌]\n[C]我曾经跨过[G]山和大[Am]海\n[F]他们说你不该[G]如此\n")
        let lines = S.allLines(score)
        XCTAssertEqual(S.render(lines[0]), "[C]我曾经跨过[G]山和大[Am]海")
        XCTAssertEqual(S.render(lines[1]), "[F]他们说你不该[G]如此")
    }

    // MARK: Mixed with tab

    func testChordSheetWithEmbeddedTabBlock() throws {
        let text = """
        [Intro]
        Am    G
        e|-----0-----|-----3-----|
        B|---1---1---|---0---0---|
        G|-2-------2-|-0-------0-|
        D|-----------|-----------|
        A|0----------|-----------|
        E|-----------|3----------|

        [Verse]
        C         G
        我曾经跨过山和大海
        """
        let score = try ChordTextParser.parse(text)
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .verse])
        let intro = score.sections[0].lines
        XCTAssertEqual(intro.count, 1)
        XCTAssertEqual(intro[0].kind, .tab)
        let tab = try XCTUnwrap(intro[0].tab)
        XCTAssertEqual(tab.measures.count, 2)
        XCTAssertEqual(tab.measures.flatMap(\.events).compactMap(\.chord), ["Am", "G"])
        XCTAssertEqual(score.sections[1].lines[0].kind, .lyrics)
        XCTAssertEqual(score.meta.mode, .strumSing)
    }

    func testTabOnlyTextIsFingerstyle() throws {
        let tab = """
        e|-----0-----|
        B|---1---1---|
        G|-2-------2-|
        D|-----------|
        A|0----------|
        E|-----------|
        """
        let score = try ChordTextParser.parse(tab)
        XCTAssertEqual(score.meta.mode, .fingerstyle)
        XCTAssertEqual(S.allLines(score).first?.kind, .tab)
    }

    // MARK: Errors

    func testEmptyTextThrows() {
        XCTAssertThrowsError(try ChordTextParser.parse("  \n \n")) { XCTAssertEqual($0 as? ImportError, .empty) }
    }
}
