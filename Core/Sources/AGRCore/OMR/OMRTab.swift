import Foundation

struct TabGlyph {
    enum Kind: Equatable { case cross, digit(Int), rest, arc, unknown }
    var rect: IRect
    var kind: Kind
    var confidence: Double
    var string: Int          // 1...6
    var stringOffset: Double // |offset from line| / u
}

struct Stem {
    var x: Double
    var width: Int
    var y0: Int, y1: Int
    var beams = 0
    var dotted = false
}

struct MeasureTab {
    var x0: Double, x1: Double
    var events: [TabEvent]
    var eventX: [Double]
    var lowConfidence: [Int]    // event indices with doubtful glyphs
    var beatSum: Double
    var glyphs: [TabGlyph]
    var timeSig: (beats: Int, unit: Int)? = nil
}

enum OMRTabAnalyzer {
    // MARK: Glyph classification helpers

    /// × test on a glyph bitmap.
    static func crossScore(_ b: Bitmap) -> Double {
        guard b.w >= 4, b.h >= 4 else { return 0 }
        func frac(_ fx0: Double, _ fy0: Double, _ fx1: Double, _ fy1: Double) -> Double {
            let x0 = Int(Double(b.w) * fx0), x1 = max(x0 + 1, Int((Double(b.w) * fx1).rounded(.up)))
            let y0 = Int(Double(b.h) * fy0), y1 = max(y0 + 1, Int((Double(b.h) * fy1).rounded(.up)))
            var n = 0, t = 0
            for y in y0..<min(b.h, y1) { for x in x0..<min(b.w, x1) { t += 1; if b[x, y] != 0 { n += 1 } } }
            return t == 0 ? 0 : Double(n) / Double(t)
        }
        let corners = [frac(0, 0, 0.3, 0.3), frac(0.7, 0, 1, 0.3), frac(0, 0.7, 0.3, 1), frac(0.7, 0.7, 1, 1)]
        let mids = [frac(0.35, 0, 0.65, 0.22), frac(0.35, 0.78, 0.65, 1), frac(0, 0.35, 0.22, 0.65), frac(0.78, 0.35, 1, 0.65)]
        let center = frac(0.35, 0.35, 0.65, 0.65)
        let cMin = corners.min() ?? 0
        let mMax = mids.max() ?? 1
        if cMin < 0.12 || center < 0.2 { return 0 }
        let ratio = Double(b.w) / Double(b.h)
        if ratio < 0.55 || ratio > 1.8 { return 0 }
        return max(0, min(1, (cMin * 1.5 - mMax + 0.35)))
    }

    // MARK: Stems

    static func findStems(clean: Bitmap, staff st: TabStaff, bars: [BarlineStructure]) -> [Stem] {
        let u = st.u
        let yFrom = Int(st.top - 0.5 * u)
        let yTo = min(clean.h, Int(st.bottom + 9 * u))
        let minLen = Int(1.0 * u)
        var cols: [(x: Int, y0: Int, y1: Int)] = []
        for x in max(0, st.x0 + 2)..<min(clean.w, st.x1 - 1) {
            if bars.contains(where: { x >= $0.x0 - 1 && x <= $0.x1 }) { continue }
            var best: (Int, Int)? = nil
            var y = max(0, yFrom)
            while y < yTo {
                if clean.d[y * clean.w + x] != 0 {
                    var e = y
                    while e < yTo && clean.d[e * clean.w + x] != 0 { e += 1 }
                    if e - y >= minLen && e - y <= Int(7 * u) && Double(y) <= st.bottom + 1.8 * u && Double(e) >= st.bottom + 0.7 * u { if best == nil || e - y > best!.1 - best!.0 { best = (y, e) } }
                    y = e
                } else { y += 1 }
            }
            if let b = best { cols.append((x, b.0, b.1)) }
        }
        if ProcessInfo.processInfo.environment["OMR_DEBUG_COLS"] != nil { FileHandle.standardError.write(Data("cols \(cols.filter { $0.x > 385 && $0.x < 430 }.map { "\($0.x):\($0.y0)-\($0.y1)" })  bottom \(st.bottom)\n".utf8)) }
        var stems: [Stem] = []
        var i = 0
        while i < cols.count {
            var j = i
            while j + 1 < cols.count && cols[j + 1].x <= cols[j].x + 1 { j += 1 }
            let w = cols[j].x - cols[i].x + 1
            if Double(w) <= max(3.0, 0.35 * u) {
                let x = (Double(cols[i].x) + Double(cols[j].x)) / 2 + 0.5
                stems.append(Stem(x: x, width: w, y0: cols[i...j].map { $0.y0 }.min()!, y1: cols[i...j].map { $0.y1 }.max()!))
            }
            i = j + 1
        }
        return stems
    }

    /// Number of beams at the stem (distinct stacked bars touching the stem sides in its lower part).
    static func beamCount(clean: Bitmap, stem: Stem, staff st: TabStaff) -> Int {
        let u = st.u
        let left = Int(stem.x - Double(stem.width) / 2 - 2.0), right = Int(stem.x + Double(stem.width) / 2 + 1.5)
        let yFrom = max(stem.y0, Int(st.bottom + 0.6 * u))
        var bands = 0
        var inBand = false
        var lastBandEnd = -10
        for y in yFrom..<min(clean.h, stem.y1 + 2) {
            let hit = clean.ink(left, y) || clean.ink(right, y) || clean.ink(left - 1, y) || clean.ink(right + 1, y)
            if hit && !inBand { if y - lastBandEnd >= 1 { bands += 1 }; inBand = true }
            if !hit && inBand { inBand = false; lastBandEnd = y }
        }
        return bands
    }

    // MARK: Main

    static func analyze(bm: Bitmap, clean: Bitmap, staff st: TabStaff, bars: [BarlineStructure],
                        beats: Double, classifier: OMRGlyphClassifier, trace: OMRTrace? = nil) -> [MeasureTab] {
        let u = st.u
        var stems = findStems(clean: clean, staff: st, bars: bars)
        for i in stems.indices { stems[i].beams = beamCount(clean: clean, stem: stems[i], staff: st) }

        // glyph bitmap: staff-free, stems erased so that glyphs touching stems separate
        var gb = clean
        for s in stems {
            for x in Int(s.x - Double(s.width) / 2)..<Int(s.x + Double(s.width) / 2 + 1) where x >= 0 && x < gb.w {
                for y in max(0, s.y0)..<min(gb.h, s.y1) { gb.d[y * gb.w + x] = 0 }
            }
        }
        for b in bars { for x in max(0, b.x0 - 1)..<min(gb.w, b.x1 + 1) { for y in max(0, Int(st.top - u * 0.4))..<min(gb.h, Int(st.bottom + u * 0.4)) { gb.d[y * gb.w + x] = 0 } } }
        // restrict to the tab band
        let yLo = Int(st.top - 0.9 * u), yHi = Int(st.bottom + 1.2 * u)
        var band = Bitmap(w: gb.w, h: gb.h)
        for y in max(0, yLo)..<min(gb.h, yHi) { for x in st.x0..<min(gb.w, st.x1) { band.d[y * gb.w + x] = gb.d[y * gb.w + x] } }
        let lab = OMRVision.label(band)

        var glyphs: [TabGlyph] = []
        for c in lab.comps {
            let r = c.rect
            let w = Double(r.w), h = Double(r.h)
            if c.area < 4 { continue }
            if h > 1.6 * u || w > 1.6 * u && h > 0.5 * u { continue }
            let bmp = OMRVision.extract(lab, c)
            let cy = r.cy
            let off = (cy - st.top) / u
            let sIdx = min(5, max(0, Int(off.rounded())))
            let so = abs(off - Double(sIdx))
            // dash = rest
            let fracOff = abs(off - off.rounded())
            if w >= 0.5 * u && h <= 0.4 * u && w / max(h, 1) >= 2.2 && fracOff > 0.2 && cy > st.top && cy < st.bottom {
                glyphs.append(TabGlyph(rect: r, kind: .rest, confidence: 0.9, string: sIdx + 1, stringOffset: so)); continue
            }
            if h < 0.3 * u && w < 0.4 * u { continue }  // dots / specks
            let cs = crossScore(bmp)
            let cl = classifier.classify(bmp, role: .tabDigit)
            if let (label, conf) = cl, conf >= 0.25 {
                if label == "x" { glyphs.append(TabGlyph(rect: r, kind: .cross, confidence: conf, string: sIdx + 1, stringOffset: so)); continue }
                if let d = Int(label) { glyphs.append(TabGlyph(rect: r, kind: .digit(d), confidence: conf, string: sIdx + 1, stringOffset: so)); continue }
                if label == "clef" || label == "cjk" || label == "H" || label == "P" || label == "S" { glyphs.append(TabGlyph(rect: r, kind: .unknown, confidence: conf, string: sIdx + 1, stringOffset: so)); continue }
            }
            if cs > 0.5 && w >= 0.3 * u && h >= 0.3 * u {
                glyphs.append(TabGlyph(rect: r, kind: .cross, confidence: cs * 0.8, string: sIdx + 1, stringOffset: so)); continue
            }
            if w >= 0.6 * u && h <= 0.9 * u && Double(c.area) / (w * h) < 0.5 { glyphs.append(TabGlyph(rect: r, kind: .arc, confidence: 0.5, string: sIdx + 1, stringOffset: so)); continue }
            glyphs.append(TabGlyph(rect: r, kind: .unknown, confidence: 0.2, string: sIdx + 1, stringOffset: so))
        }

        // measure ranges from barlines
        var ranges: [(Double, Double)] = []
        let sorted = bars.sorted { $0.x0 < $1.x0 }
        if sorted.count >= 2 {
            for i in 0..<(sorted.count - 1) { ranges.append((sorted[i].xAfter, sorted[i + 1].xBefore)) }
        }
        for g in glyphs { trace?.add(g.rect, g.kind == .cross ? (0, 0, 255) : (g.kind == .rest ? (255, 128, 0) : (200, 0, 200))) }
        for s in stems { trace?.add(IRect(x0: Int(s.x) - 1, y0: s.y0, x1: Int(s.x) + 2, y1: s.y1), (0, 200, 200), "b\(s.beams)") }
        var out: [MeasureTab] = []
        for (mi, rg) in ranges.enumerated() {
            let mg = glyphs.filter { $0.rect.cx >= rg.0 && $0.rect.cx < rg.1 }
            let ms = stems.filter { $0.x >= rg.0 && $0.x < rg.1 }
            var timeSig: (Int, Int)? = nil
            var mgNotes = mg
            if mi == 0, stems.count >= 3, let fs = ms.first?.x {
                let left = mg.filter { $0.rect.cx < fs - 0.5 * u }
                var up = [Int](), lo = [Int]()
                for g in left { if case .digit(let d) = g.kind, g.rect.h > Int(0.95 * u) { if g.rect.cy < st.top + 2.5 * u { up.append(d) } else { lo.append(d) } } }
                if up.count == 1 && lo.count == 1 { timeSig = (up[0], lo[0]) }
                mgNotes = mg.filter { $0.rect.cx >= fs - 0.5 * u }
            }
            let note = mgNotes.filter { if case .rest = $0.kind { return false }; if case .arc = $0.kind { return false }; if case .unknown = $0.kind { return false }; return true }
            let rests = mg.filter { $0.kind == .rest }
            // cluster note glyphs to events: nearest stem within 0.7u, else own cluster by x
            struct Ev { var x: Double; var glyphs: [TabGlyph]; var stem: Stem? }
            var evs: [Ev] = []
            for g in note.sorted(by: { $0.rect.cx < $1.rect.cx }) {
                var bestStem: Stem? = nil
                var bd = 0.7 * u
                for s in ms { let d = abs(s.x - g.rect.cx); if d < bd { bd = d; bestStem = s } }
                if let s = bestStem {
                    if let k = evs.firstIndex(where: { $0.stem?.x == s.x }) { evs[k].glyphs.append(g) } else { evs.append(Ev(x: s.x, glyphs: [g], stem: s)) }
                } else if let k = evs.lastIndex(where: { $0.stem == nil && abs($0.x - g.rect.cx) < 0.45 * u }) {
                    evs[k].glyphs.append(g)
                } else { evs.append(Ev(x: g.rect.cx, glyphs: [g], stem: nil)) }
            }
            // stems without glyphs are ignored (could be ties etc.)
            evs.sort { $0.x < $1.x }
            struct Item { var x: Double; var dur: Double; var ev: Ev? }
            var items: [Item] = []
            for e in evs {
                let dur: Double
                if let s = e.stem { dur = [1.0, 0.5, 0.25, 0.125, 0.0625][min(4, s.beams)] } else { dur = 1.0 }
                items.append(Item(x: e.x, dur: dur, ev: e))
            }
            for r in rests { items.append(Item(x: r.rect.cx, dur: 1.0, ev: nil)) }
            items.sort { $0.x < $1.x }
            if ProcessInfo.processInfo.environment["OMR_DEBUG"] != nil { FileHandle.standardError.write(Data("m\(mi) glyphs \(mg.map { "\($0.kind)@\(Int($0.rect.cx)),\(Int($0.rect.cy)) \($0.rect.w)x\($0.rect.h)" })\n stems \(ms.map { "\(Int($0.x)):b\($0.beams)" })\n items \(items.map { "\(Int($0.x)):\($0.dur)\($0.ev == nil ? "R" : "")" })\n".utf8)) }
            let restIdx = items.indices.filter { items[$0].ev == nil }
            let evSum = items.filter { $0.ev != nil }.reduce(0) { $0 + $1.dur }
            if !restIdx.isEmpty {
                let remain = beats - evSum
                if remain > 0 && abs(remain - Double(restIdx.count)) > 1e-6 {
                    for k in restIdx { items[k].dur = remain / Double(restIdx.count) }
                }
            }
            var t = 0.0
            var events: [TabEvent] = []
            var xs: [Double] = []
            var low: [Int] = []
            for it in items {
                if let e = it.ev {
                    var notes: [TabNote] = []
                    var bad = false
                    for g in e.glyphs.sorted(by: { $0.string > $1.string }) {
                        if g.stringOffset > 0.4 || g.confidence < 0.45 { bad = true }
                        switch g.kind {
                        case .cross: notes.append(TabNote.chordTone(string: g.string))
                        case .digit(let d): notes.append(TabNote(string: g.string, fret: d))
                        default: break
                        }
                    }
                    // merge multi-digit frets (e.g. "1","0" side by side on one string)
                    notes = mergeDigits(e.glyphs, notes: notes, u: u)
                    if bad { low.append(events.count) }
                    events.append(TabEvent(beat: t, duration: it.dur, notes: notes))
                    xs.append(it.x)
                }
                t += it.dur
            }
            out.append(MeasureTab(x0: rg.0, x1: rg.1, events: events, eventX: xs, lowConfidence: low, beatSum: t, glyphs: mg, timeSig: timeSig.map { (beats: $0.0, unit: $0.1) }))
            _ = mi
        }
        return out
    }

    /// Two digits on the same string in the same event cluster (x gap < 0.9u) form one two-digit fret.
    static func mergeDigits(_ gl: [TabGlyph], notes: [TabNote], u: Double) -> [TabNote] {
        var res: [TabNote] = []
        let digits = gl.filter { if case .digit = $0.kind { return true }; return false }
        var used = Set<Int>()
        for (i, a) in digits.enumerated() where !used.contains(i) {
            for (j, b) in digits.enumerated() where j > i && !used.contains(j) && a.string == b.string && abs(a.rect.cx - b.rect.cx) < 1.2 * u {
                if case .digit(let da) = a.kind, case .digit(let db) = b.kind {
                    let (l, r) = a.rect.cx < b.rect.cx ? (da, db) : (db, da)
                    res.append(TabNote(string: a.string, fret: l * 10 + r)); used.insert(i); used.insert(j)
                }
            }
        }
        if used.isEmpty { return notes }
        var rest = notes.filter { n in !(res.contains { $0.string == n.string } ) }
        rest.append(contentsOf: res)
        return rest.sorted { $0.string > $1.string }
    }
}
