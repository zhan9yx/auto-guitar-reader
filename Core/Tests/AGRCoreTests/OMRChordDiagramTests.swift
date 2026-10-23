import XCTest
@testable import AGRCore

/// Chord grids drawn on a small canvas and read back with `OMRChordReader.findDiagrams`.
final class OMRChordDiagramTests: XCTestCase {
    enum Marker { case x, o }
    struct Spec {
        var nut = true
        var dots: [(string: Int, row: Int)] = []          // string 0 = low E (left), row 1 = first fret row
        var barre: (row: Int, from: Int, to: Int)?
        var markers: [(string: Int, kind: Marker)] = []
        var smears: [(string: Int, row: Int)] = []         // 2 px marker bleed in a fret row
    }
    let sp = 10, f = 12, rows = 4, left = 40, top = 40

    func read(_ spec: Spec) -> OMRChordDiagram? {
        var c = OMRCanvas(width: 160, height: 140)
        let right = left + 5 * sp
        for i in 0..<6 { c.vline(x: left + i * sp, y0: top, y1: top + rows * f + 1, t: 2) }
        for k in 0...rows {
            let y = top + k * f
            c.hline(x0: left, x1: right + 1, y: y, t: (k == 0 && spec.nut) ? 5 : 2)
        }
        func cy(_ row: Int) -> Int { top + (row - 1) * f + f / 2 + 1 }
        if let b = spec.barre {
            c.rect(x0: left + b.from * sp - 3, y0: cy(b.row) - 4, x1: left + b.to * sp + 4, y1: cy(b.row) + 5)
        }
        for d in spec.dots { c.disc(cx: left + d.string * sp, cy: cy(d.row), r: 4) }
        for s in spec.smears { c.rect(x0: left + s.string * sp - 4, y0: cy(s.row) - 1, x1: left + s.string * sp + 5, y1: cy(s.row) + 1) }
        for m in spec.markers {
            let x = left + m.string * sp, y = top - 9
            switch m.kind {
            case .x: c.cross(cx: x, cy: y, size: 7, t: 2)
            case .o: c.ring(cx: x, cy: y, r: 3)
            }
        }
        let (bm, _, _, _) = OMRVision.binarize(c.img)
        return OMRChordReader.findDiagrams(bm, top: 0, bottom: Double(c.height), u: 14, xMin: 0, xMax: c.width).first
    }

    /// Jianpu digits on an underline have six aligned columns and horizontal rules but no continuous strings.
    func testDigitRowIsNotADiagram() {
        var c = OMRCanvas(width: 160, height: 140)
        for k in 0...3 { c.hline(x0: 40, x1: 91, y: 40 + k * 12, t: 2) }
        for i in 0..<6 { c.rect(x0: 40 + i * 10 - 3, y0: 46, x1: 40 + i * 10 + 3, y1: 52) }   // glyph blobs between rules
        let (bm, _, _, _) = OMRVision.binarize(c.img)
        XCTAssertTrue(OMRChordReader.findDiagrams(bm, top: 0, bottom: Double(c.height), u: 14, xMin: 0, xMax: c.width).isEmpty)
    }

    /// C major, open: x32010.
    func testOpenC() throws {
        var s = Spec()
        s.dots = [(1, 3), (2, 2), (4, 1)]
        s.markers = [(0, .x), (3, .o), (5, .o)]
        let d = try XCTUnwrap(read(s))
        XCTAssertEqual(d.rel, [-1, 3, 2, 0, 1, 0])
    }

    /// F major barre at the first fret: the fingers on strings 4 and 5 sit on top of the bar and win.
    func testFBarreFingersBeatTheBar() throws {
        var s = Spec()
        s.barre = (1, 0, 5)
        s.dots = [(1, 3), (2, 3), (3, 2)]
        let d = try XCTUnwrap(read(s))
        XCTAssertEqual(d.rel, [1, 3, 3, 2, 1, 1])
        XCTAssertEqual(d.frets, [1, 3, 3, 2, 1, 1])
    }

    /// Bm at base fret 2: a bar over strings 2-6, X over the low E.
    func testBmBarreAtBaseFret() throws {
        var s = Spec()
        s.nut = false
        s.barre = (1, 1, 5)
        s.dots = [(2, 3), (3, 3), (4, 2)]
        s.markers = [(0, .x)]
        var d = try XCTUnwrap(read(s))
        XCTAssertEqual(d.rel, [-1, 1, 3, 3, 2, 1])
        d.baseFret = 2
        XCTAssertEqual(d.frets, [-1, 2, 4, 4, 3, 2])
    }

    /// A smear of the O marker over the nut is not a finger.
    func testMarkerBleedIsNotAFret() throws {
        var s = Spec()
        s.dots = [(1, 3)]
        s.markers = [(0, .x), (2, .o)]
        s.smears = [(2, 1)]
        let d = try XCTUnwrap(read(s))
        XCTAssertEqual(d.rel[0], -1)
        XCTAssertEqual(d.rel[2], 0)
    }

    /// A full dot in the first fret row stays a finger even if the marker row above it holds an O.
    func testClearDotBeatsMarker() throws {
        var s = Spec()
        s.dots = [(2, 1)]
        s.markers = [(2, .o)]
        let d = try XCTUnwrap(read(s))
        XCTAssertEqual(d.rel[2], 1)
    }
}

/// Chord placement: the diagram is left-aligned with the first event it governs, so its centre sits half a diagram
/// to the right of that event; beats are interpolated between the events and rounded to whole beats.
final class OMRChordPlacementTests: XCTestCase {
    func testCentreMinusHalfDiagramSnapsToWholeBeat() {
        let anchors: [(x: Double, beat: Double)] = [(100, 0), (130, 0.5), (160, 1), (190, 1.5), (250, 3), (280, 3.5)]
        let span = MeasureSpan(x0: 80, x1: 300, beats: 4, anchors: anchors)
        // chord on the downbeat: centre 28 px right of the first event, half diagram 28
        XCTAssertEqual(OMRChordReader.place(x: 128, spans: [span], shift: 28).1, 0)
        // no event at beat 2 (rest): the position between the events at 1.5 and 3 still rounds to 2
        XCTAssertEqual(OMRChordReader.place(x: 218 + 0, spans: [span], shift: 28).1, 2)
        XCTAssertEqual(OMRChordReader.place(x: 278, spans: [span], shift: 28).1, 3)
    }

    func testPrefixAccidentalAndDiagramBass() {
        XCTAssertEqual(ChordNameNormalizer.key("D/#F"), ChordNameNormalizer.key("D/F#"))
        XCTAssertEqual(ChordNameNormalizer.key("#Fm"), ChordNameNormalizer.key("F#m"))
        // D major over F# (fretted bass on string 6): the OCR lost the "/#F"
        XCTAssertEqual(OMRChordReader.withBass("D", frets: [2, -1, 0, 2, 3, 2]), "D/#F")
        // open sixth string stays a plain C; a root bass stays plain
        XCTAssertEqual(OMRChordReader.withBass("C", frets: [0, 3, 2, 0, 1, 0]), "C")
        XCTAssertEqual(OMRChordReader.withBass("F", frets: [1, 3, 3, 2, 1, 1]), "F")
        // accidental dropped by OCR: A9/G with a G# bass on fret 4
        XCTAssertEqual(OMRChordReader.withBass("A9/G", frets: [4, 0, 2, 4, 2, 0]), "A9/#G")
    }
}
