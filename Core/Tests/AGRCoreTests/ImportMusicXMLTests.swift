import XCTest
@testable import AGRCore

final class ImportMusicXMLTests: XCTestCase {
    typealias S = ImportTestSupport

    /// Lead sheet: chords + Chinese lyrics, 4/4, two measures per phrase.
    private let leadSheet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="3.1">
      <work><work-title>七里香</work-title></work>
      <identification>
        <creator type="composer">周杰伦</creator>
        <creator type="lyricist">方文山</creator>
      </identification>
      <part-list><score-part id="P1"><part-name>Voice</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>2</divisions>
            <key><fifths>1</fifths><mode>major</mode></key>
            <time><beats>4</beats><beat-type>4</beat-type></time>
          </attributes>
          <direction><sound tempo="88"/></direction>
          <harmony><root><root-step>G</root-step></root><kind text="">major</kind></harmony>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration>
            <lyric number="1"><syllabic>single</syllabic><text>窗</text></lyric></note>
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>2</duration>
            <lyric number="1"><syllabic>single</syllabic><text>外</text></lyric></note>
          <harmony><root><root-step>D</root-step></root><kind>major</kind><bass><bass-step>F</bass-step><bass-alter>1</bass-alter></bass></harmony>
          <note><pitch><step>B</step><octave>4</octave></pitch><duration>2</duration>
            <lyric number="1"><syllabic>single</syllabic><text>的</text></lyric></note>
          <note><pitch><step>B</step><octave>4</octave></pitch><duration>2</duration>
            <lyric number="1"><syllabic>single</syllabic><text>麻</text></lyric></note>
        </measure>
        <measure number="2">
          <harmony><root><root-step>E</root-step></root><kind text="m7">minor-seventh</kind></harmony>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration>
            <lyric number="1"><syllabic>single</syllabic><text>雀</text></lyric></note>
          <note><rest/><duration>4</duration></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// Fingerstyle tab with technical notes, a chord symbol and a tied/hammered note.
    private let tabXML = """
    <?xml version="1.0"?>
    <score-partwise version="3.1">
      <movement-title>Etude</movement-title>
      <part-list><score-part id="P1"><part-name>Guitar</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes><divisions>1</divisions><time><beats>3</beats><beat-type>4</beat-type></time></attributes>
          <direction><sound tempo="100"/></direction>
          <harmony><root><root-step>A</root-step></root><kind>minor</kind></harmony>
          <note><pitch><step>E</step><octave>2</octave></pitch><duration>1</duration>
            <notations><technical><string>6</string><fret>0</fret></technical></notations></note>
          <note><chord/><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration>
            <notations><technical><string>2</string><fret>1</fret></technical></notations></note>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration>
            <notations><technical><string>1</string><fret>0</fret></technical></notations></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration>
            <notations><technical><string>1</string><fret>3</fret><hammer-on type="stop" number="1">H</hammer-on></technical></notations></note>
        </measure>
        <measure number="2">
          <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration>
            <notations><technical><string>1</string><fret>5</fret><bend><bend-alter>1</bend-alter></bend></technical></notations></note>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration>
            <notations><technical><string>2</string><fret>1</fret><pull-off type="stop">P</pull-off></technical></notations></note>
          <note><rest/><duration>1</duration></note>
        </measure>
      </part>
    </score-partwise>
    """

    func testLeadSheetMetadata() throws {
        let score = try MusicXMLParser.parse(Data(leadSheet.utf8))
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.meta.composer, "周杰伦")
        XCTAssertEqual(score.meta.lyricist, "方文山")
        XCTAssertEqual(score.meta.tempo, 88)
        XCTAssertEqual(score.meta.timeSignature, TimeSignature(beats: 4, unit: 4))
        XCTAssertEqual(score.meta.key, "G")
        XCTAssertEqual(score.meta.mode, .strumSing)
        XCTAssertEqual(score.meta.source?.kind, .musicXML)
    }

    func testHarmonyAndLyricsBecomeLyricLines() throws {
        let score = try MusicXMLParser.parse(Data(leadSheet.utf8))
        let lines = S.allLines(score)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .lyrics)
        XCTAssertEqual(S.render(lines[0]), "[G]窗外[D/F#]的麻[Em7]雀")
    }

    func testTabTechnicalNotes() throws {
        let score = try MusicXMLParser.parse(Data(tabXML.utf8))
        XCTAssertEqual(score.meta.title, "Etude")
        XCTAssertEqual(score.meta.mode, .fingerstyle)
        XCTAssertEqual(score.meta.timeSignature, TimeSignature(beats: 3, unit: 4))
        XCTAssertEqual(score.meta.tempo, 100)
        let lines = S.allLines(score)
        XCTAssertEqual(lines.count, 1)
        let tab = try XCTUnwrap(lines[0].tab)
        XCTAssertEqual(tab.measures.count, 2)
        let m1 = tab.measures[0]
        XCTAssertEqual(m1.events.map(\.beat), [0, 1, 2])
        XCTAssertEqual(m1.events[0].notes, [TabNote(string: 2, fret: 1), TabNote(string: 6, fret: 0)])
        XCTAssertEqual(m1.events[0].chord, "Am")
        XCTAssertEqual(m1.events[2].notes, [TabNote(string: 1, fret: 3, technique: .hammerOn)])
        XCTAssertEqual(m1.events[1].duration, 1)
        let m2 = tab.measures[1]
        XCTAssertEqual(m2.events[0].notes, [TabNote(string: 1, fret: 5, technique: .bend)])
        XCTAssertEqual(m2.events[1].notes, [TabNote(string: 2, fret: 1, technique: .pullOff)])
    }

    func testTabLinesChunkFourMeasures() throws {
        let measures = (1...9).map { i in
            let attrs = i == 1 ? "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>" : ""
            return "<measure number=\"\(i)\">\(attrs)<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><notations><technical><string>1</string><fret>\(i)</fret></technical></notations></note></measure>"
        }.joined()
        let xml = "<score-partwise><part-list/><part id=\"P1\">\(measures)</part></score-partwise>"
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        let lines = S.allLines(score)
        XCTAssertEqual(lines.map { $0.tab?.measures.count }, [4, 4, 1])
        XCTAssertEqual(lines[2].tab?.measures[0].events[0].notes.first?.fret, 9)
    }

    func testRehearsalMarksCreateSections() throws {
        let xml = """
        <score-partwise><part-list/><part id="P1">
        <measure number="1"><attributes><divisions>1</divisions></attributes>
          <direction><direction-type><rehearsal>Intro</rehearsal></direction-type></direction>
          <harmony><root><root-step>C</root-step></root><kind>major</kind></harmony>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><lyric><text>la</text></lyric></note></measure>
        <measure number="2">
          <direction><direction-type><rehearsal>Chorus</rehearsal></direction-type></direction>
          <harmony><root><root-step>F</root-step></root><kind>major</kind></harmony>
          <note><pitch><step>F</step><octave>4</octave></pitch><duration>4</duration><lyric><text>na</text></lyric></note></measure>
        </part></score-partwise>
        """
        let score = try MusicXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(score.sections.map(\.name), ["Intro", "Chorus"])
        XCTAssertEqual(score.sections.map(\.kind), [.intro, .chorus])
    }

    func testChordKindsMapToSymbols() {
        XCTAssertEqual(MusicXMLReader.kindSuffix("dominant", text: ""), "7")
        XCTAssertEqual(MusicXMLReader.kindSuffix("half-diminished", text: ""), "m7b5")
        XCTAssertEqual(MusicXMLReader.kindSuffix("suspended-fourth", text: ""), "sus4")
        XCTAssertEqual(MusicXMLReader.kindSuffix("other", text: "add9"), "add9")
        XCTAssertNotNil(ChordSymbol("C" + MusicXMLReader.kindSuffix("major-seventh", text: "")))
    }

    func testMXLZipIsUnsupported() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try MusicXMLParser.parse(zip)) {
            XCTAssertEqual($0 as? ImportError, .unsupportedFormat("mxl"))
        }
    }

    func testMalformedAndNonMusicXMLThrow() {
        XCTAssertThrowsError(try MusicXMLParser.parse(Data("<score-partwise><part".utf8))) {
            guard case .malformed? = $0 as? ImportError else { return XCTFail("expected malformed") }
        }
        XCTAssertThrowsError(try MusicXMLParser.parse(Data("<html><body/></html>".utf8))) {
            guard case .malformed? = $0 as? ImportError else { return XCTFail("expected malformed") }
        }
        XCTAssertThrowsError(try MusicXMLParser.parse(Data())) { XCTAssertEqual($0 as? ImportError, .empty) }
    }

    func testScoreWithoutUsableContentIsEmpty() {
        let xml = "<score-partwise><part-list/><part id=\"P1\"><measure number=\"1\"><note><rest/><duration>4</duration></note></measure></part></score-partwise>"
        XCTAssertThrowsError(try MusicXMLParser.parse(Data(xml.utf8))) { XCTAssertEqual($0 as? ImportError, .empty) }
    }

    func testImportDataDetectsMusicXMLByContent() throws {
        let data = Data(leadSheet.utf8)
        XCTAssertEqual(ScoreImporter.detectFormat(data: data, fileName: "x.xml"), .musicXML)
        XCTAssertEqual(ScoreImporter.detectFormat(data: data, fileName: nil), .musicXML)
        let score = try ScoreImporter.importData(data, fileName: "song.musicxml")
        XCTAssertEqual(score.meta.source?.fileName, "song.musicxml")
    }
}
