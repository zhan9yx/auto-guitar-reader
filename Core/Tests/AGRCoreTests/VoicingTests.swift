import XCTest
@testable import AGRCore

final class VoicingTests: XCTestCase {
    let std = ScoreMeta.standardTuning

    func v(_ name: String, definitions: [String: ChordShape] = [:], written: String? = nil) -> Voicing {
        VoicingLibrary.voicing(for: ChordSymbol(name)!, definitions: definitions, written: written)
    }

    func testOpenChordShapes() {
        XCTAssertEqual(v("C").description, "x32010")
        XCTAssertEqual(v("G").description, "320003")
        XCTAssertEqual(v("D").description, "xx0232")
        XCTAssertEqual(v("Am").description, "x02210")
        XCTAssertEqual(v("Em").description, "022000")
        XCTAssertEqual(v("E7").description, "020100")
        XCTAssertEqual(v("Cmaj7").description, "x32000")
        XCTAssertEqual(v("Dsus4").description, "xx0233")
        XCTAssertEqual(v("Cadd9").description, "x32030")
    }

    func testBarreShapes() {
        XCTAssertEqual(v("F").description, "133211")
        XCTAssertEqual(v("Bm").description, "x24432")
        XCTAssertEqual(v("F#m").description, "244222")
        // Movable: Ab major E-form at fret 4, C#m7 A-form at fret 4.
        XCTAssertEqual(v("Ab").description, "466544")
        XCTAssertEqual(v("C#m7").description, "x46454")
        XCTAssertEqual(v("Bb7").frets.first(where: { $0 >= 0 }), 1)
    }

    func testMidiNotesCapoAndTuning() {
        XCTAssertEqual(v("C").midiNotes(tuning: std, capo: 0), [48, 52, 55, 60, 64])
        XCTAssertEqual(v("C").midiNotes(tuning: std, capo: 2), [50, 54, 57, 62, 66])
        XCTAssertEqual(v("G").midiNotes(tuning: std, capo: 0), [43, 47, 50, 55, 59, 67])
        let dropD = [38, 45, 50, 55, 59, 64]
        XCTAssertEqual(v("G").midiNotes(tuning: dropD, capo: 0).first, 41)
        let sn = v("C").stringNotes(tuning: std, capo: 0)
        XCTAssertEqual(sn.map(\.string), [1, 2, 3, 4, 5])
    }

    func testSlashChordBassOnLowestPlayedString() {
        for (name, bassPC) in [("C/G", 7), ("G/B", 11), ("D/F#", 6), ("Am/G", 7), ("Em/G", 7),
                               ("F/A", 9), ("Am/C", 0), ("Bm/A", 9), ("C/E", 4), ("D/A", 9)] {
            let notes = v(name).midiNotes(tuning: std, capo: 0)
            XCTAssertEqual(notes.first.map { $0 % 12 }, bassPC, name)
            // All other notes belong to the chord.
            let pcs = ChordSymbol(name)!.pitchClasses
            for n in notes { XCTAssertTrue(pcs.contains(n % 12), "\(name) has stray note \(n)") }
        }
        XCTAssertEqual(v("C/G").description, "332010")
        XCTAssertEqual(v("G/B").description, "x20003")
        XCTAssertEqual(v("F/A").description, "x03211")
    }

    func testAllRootsAndQualitiesAreChordTonesWithRootBass() {
        let exact: [ChordSymbol.Quality] = [.major, .minor, .dom7, .maj7, .min7, .sus4, .sus2, .six, .min6,
                                            .dom7sus4, .add9, .minAdd9, .dom9, .aug, .power, .dim, .dim7,
                                            .halfDim7, .minMaj7, .maj9]
        for root in 0..<12 {
            for q in exact {
                let c = ChordSymbol(root: root, quality: q)
                let notes = VoicingLibrary.voicing(for: c).midiNotes(tuning: std, capo: 0)
                XCTAssertFalse(notes.isEmpty, "\(c)")
                let pcs = c.pitchClasses
                for n in notes {
                    XCTAssertTrue(pcs.contains(n % 12), "\(c): note \(n % 12) not in chord")
                }
                XCTAssertEqual(notes.first.map { $0 % 12 }, root, "\(c) bass")
            }
        }
    }

    func testFallbackForExoticQualities() {
        for q in [ChordSymbol.Quality.dom11, .dom13, .min9] {
            let c = ChordSymbol(root: 2, quality: q)
            let notes = VoicingLibrary.voicing(for: c).midiNotes(tuning: std, capo: 0)
            XCTAssertGreaterThanOrEqual(notes.count, 3)
            XCTAssertEqual(notes.first.map { $0 % 12 }, 2)
        }
        XCTAssertEqual(v("Bdim").description, "x2343x")
    }

    func testDefinitionsOverride() {
        let shape = ChordShape(frets: [-1, 3, 5, 5, 5, 3], baseFret: 3)
        XCTAssertEqual(v("C", definitions: ["C": shape], written: "C").frets, [-1, 3, 5, 5, 5, 3])
        // Not applied without a matching written name.
        XCTAssertEqual(v("C", definitions: ["C": shape], written: "D").description, "x32010")
        XCTAssertEqual(v("C", definitions: ["C": shape], written: nil).description, "x32010")
        // Invalid shape (wrong length) is ignored.
        XCTAssertEqual(v("C", definitions: ["C": ChordShape(frets: [0, 1])], written: "C").description, "x32010")
    }

    func testVoicingParsing() {
        XCTAssertEqual(Voicing("x32010")?.frets, [-1, 3, 2, 0, 1, 0])
        XCTAssertNil(Voicing("x3201"))
        XCTAssertNil(Voicing("x32z10"))
        XCTAssertEqual(Voicing(frets: [1, 3, 3, 2, 1, 1]).playedStrings, [0, 1, 2, 3, 4, 5])
    }
}
