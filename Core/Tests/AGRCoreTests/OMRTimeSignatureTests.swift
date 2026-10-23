import XCTest
@testable import AGRCore

/// Time-signature reading and duration repair at bitmap / slot level. Test glyphs are the tab classifier's own centroids.
final class OMRTimeSignatureTests: XCTestCase {
    private func draw(_ c: inout OMRCanvas, _ label: String, x: Int, top: Int, h: Int) -> Int {
        let ts = OMRGlyphClassifier.shared.templates.filter { $0.label == label }.sorted { $0.aspect < $1.aspect }
        guard let p = ts.isEmpty ? nil : ts[ts.count / 2] else { return x }
        let w = max(3, Int((Double(h) * Double(p.aspect) / 100).rounded()))
        for yy in 0..<h { for xx in 0..<w {
            let cx = min(OMRGlyphFeatures.fw - 1, xx * OMRGlyphFeatures.fw / w), cy = min(OMRGlyphFeatures.fh - 1, yy * OMRGlyphFeatures.fh / h)
            if p.v[cy * OMRGlyphFeatures.fw + cx] >= 128 { c.set(x + xx, top + yy) }
        } }
        return x + w
    }

    private func read(upper: String, lower: String, gap: Int) -> (beats: Int, unit: Int)? {
        let f = OMRTabFixture()
        var canvas = OMRCanvas(width: f.canvas.width, height: f.canvas.height)   // glyphs on an already staff-free page
        let h = Int(1.6 * Double(f.u))
        let top = f.top + Int(2.5 * Double(f.u)) - gap / 2 - h
        _ = draw(&canvas, upper, x: 60, top: top, h: h)
        _ = draw(&canvas, lower, x: 60, top: top + h + gap, h: h)
        let bm = OMRVision.binarize(canvas.img).bm
        let st = TabStaff(lines: (0..<6).map { Double(f.lineY($0 + 1)) }, thickness: 2, x0: f.x0, x1: f.x1)
        return OMRTimeSignatureReader.read(clean: bm, staff: st, limitX: 140)
    }

    func testSeparateNumbersRead() {
        let r = read(upper: "3", lower: "4", gap: 6)
        XCTAssertEqual(r?.beats, 3); XCTAssertEqual(r?.unit, 4)
    }

    /// Bold fonts: the two numbers touch and are one component; it is cut between them.
    func testTouchingNumbersAreCut() {
        let r = read(upper: "6", lower: "8", gap: 0)
        XCTAssertEqual(r?.beats, 6); XCTAssertEqual(r?.unit, 8)
    }

    private func slot(_ x: Double, _ dur: Double, beams: Int, dotted: Bool = false) -> OMRTabAnalyzer.Slot {
        let s = Stem(x: x, width: 2, y0: 0, y1: 10, beams: beams, dotted: dotted)
        return OMRTabAnalyzer.Slot(x: x, dur: dur, ev: OMRTabAnalyzer.Ev(x: x, items: [], stem: s))
    }

    /// A first stem read with three beams (a tie arc beside it) in a bar of otherwise plain eighths becomes an eighth.
    func testExtraBeamsFixedWhenBarDoesNotAddUp() {
        var slots = [slot(0, 0.125, beams: 3)] + (1..<8).map { slot(Double($0), 0.5, beams: 1) }
        var rep: [String] = []
        OMRTabAnalyzer.repairBeamCounts(&slots, beats: 4, unitScale: 1, repairs: &rep)
        XCTAssertEqual(slots.map(\.dur), Array(repeating: 0.5, count: 8))
        XCTAssertEqual(rep.count, 1)
    }

    /// A bar that already adds up keeps its sixteenths.
    func testCorrectSixteenthsKept() {
        var slots = (0..<4).map { slot(Double($0), 0.25, beams: 2) } + (4..<10).map { slot(Double($0), 0.5, beams: 1) }
        var rep: [String] = []
        OMRTabAnalyzer.repairBeamCounts(&slots, beats: 4, unitScale: 1, repairs: &rep)
        XCTAssertEqual(slots.prefix(4).map(\.dur), [0.25, 0.25, 0.25, 0.25])
        XCTAssertTrue(rep.isEmpty)
    }

    private func bar(_ durs: [Double], gapAfter: Int? = nil) -> OMRTimeSignatureReader.BarEvidence {
        var x = 100.0
        var xs: [Double] = []
        var evs: [TabEvent] = []
        var t = 0.0
        for (i, d) in durs.enumerated() {
            xs.append(x); evs.append(TabEvent(beat: t, duration: d, notes: [TabNote.chordTone(string: 3)]))
            x += d * 100 + (i == gapAfter ? 100 : 0); t += d
        }
        return OMRTimeSignatureReader.BarEvidence(events: evs, x: xs, x0: 70, x1: xs.last! + durs.last! * 100 + 20)
    }

    func testSixEighthBarsInferSixEight() {
        let bars = (0..<4).map { _ in bar(Array(repeating: 0.5, count: 6)) }
        XCTAssertEqual(OMRTimeSignatureReader.inferFromStems(bars: bars)?.beats, 6)
        XCTAssertEqual(OMRTimeSignatureReader.inferFromStems(bars: bars)?.unit, 8)
    }

    /// Four eighths and a quarter with a silent last beat is 4/4 with an unprinted rest, not 3/4.
    func testShortBarsAreNotReinterpreted() {
        let bars = (0..<4).map { _ in bar([0.5, 0.5, 0.5, 0.5, 1]) }
        XCTAssertNil(OMRTimeSignatureReader.inferFromStems(bars: bars))
    }

    /// A one-beat gap between quarters is an unprinted rest: the later event moves one beat later.
    func testPositionPlacesEventsAfterUnprintedRest() {
        var slots = [slot(100, 1, beams: 0), slot(200, 1, beams: 0), slot(300, 1, beams: 0), slot(500, 1, beams: 0)]
        var rep: [String] = []
        OMRTabAnalyzer.placeByPosition(&slots, beats: 5, repairs: &rep)
        XCTAssertEqual(slots.map(\.lead), [0, 0, 0, 1])
        XCTAssertEqual(rep.count, 1)
    }

    /// If honouring the positions would overflow the bar, the duration sum is kept.
    func testPositionIgnoredWhenBarWouldOverflow() {
        var slots = [slot(100, 1, beams: 0), slot(200, 1, beams: 0), slot(300, 1, beams: 0), slot(500, 1, beams: 0)]
        var rep: [String] = []
        OMRTabAnalyzer.placeByPosition(&slots, beats: 4, repairs: &rep)
        XCTAssertEqual(slots.map(\.lead), [0, 0, 0, 0])
    }
}
