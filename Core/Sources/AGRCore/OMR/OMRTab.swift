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
                    // A full-height strum shaft continues into the stem and is longer than 7u.
                    // Keep only the part that starts at the staff bottom and hangs below it.
                    let stemTop = max(y, Int((st.bottom + 0.12 * u).rounded()))
                    let len = e - stemTop
                    if len >= minLen && len <= Int(4.8 * u) && Double(stemTop) <= st.bottom + 1.8 * u && Double(e) >= st.bottom + 0.7 * u {
                        if best == nil || len > best!.1 - best!.0 { best = (stemTop, e) }
                    }
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
        let close = min(clean.h, stem.y1 + 2)
        let bands = sideBands(clean: clean, left: left, right: right, y0: yFrom, y1: close, minRun: 1)
        if bands > 0 { return bands }
        // The shaft often ends a few pixels above the beam (the bar is lighter off the stem).
        // Only a horizontal run counts, so a quarter with nothing beside it stays unbeamed.
        let yHi = min(clean.h, stem.y1 + max(6, Int((0.62 * u).rounded())))
        let minRun = max(5, Int((0.45 * u).rounded()))
        return sideBands(clean: clean, left: left, right: right, y0: close, y1: yHi, minRun: minRun)
    }

    /// Stacked side-ink bars between y0 and y1. `minRun` is the shortest horizontal run that counts.
    private static func sideBands(clean: Bitmap, left: Int, right: Int, y0: Int, y1: Int, minRun: Int) -> Int {
        guard y1 > y0 else { return 0 }
        var bands = 0
        var inBand = false
        var lastBandEnd = -10
        let xs = [left, right, left - 1, right + 1]
        for y in y0..<y1 {
            let hit = xs.contains { clean.ink($0, y) && (minRun <= 1 || horizontalRun(clean, x: $0, y: y) >= minRun) }
            if hit && !inBand { if y - lastBandEnd >= 1 { bands += 1 }; inBand = true }
            if !hit && inBand { inBand = false; lastBandEnd = y }
        }
        return bands
    }

    private static func horizontalRun(_ bm: Bitmap, x: Int, y: Int) -> Int {
        guard bm.ink(x, y) else { return 0 }
        var x0 = x, x1 = x
        while bm.ink(x0 - 1, y) { x0 -= 1 }
        while bm.ink(x1 + 1, y) { x1 += 1 }
        return x1 - x0 + 1
    }

    /// A column of ink running most of the component's height (strum shaft, not a fret).
    private static func verticalShaft(_ b: Bitmap) -> Bool {
        guard b.h >= 6, b.w >= 1 else { return false }
        let need = max(4, Int((0.62 * Double(b.h)).rounded()))
        for x in 0..<b.w {
            var n = 0
            for y in 0..<b.h where b.d[y * b.w + x] != 0 { n += 1 }
            if n >= need { return true }
        }
        return false
    }

    /// One-pixel bridge between a slur (or H/P) and the fret under it.
    /// Returns tight pieces, or empty when the glyph should stay whole.
    /// A hollow digit has two walls, not one short run, so it is not cut.
    /// A strum shaft is taller than a fret, so the long side is left intact.
    private static func glyphParts(_ b: Bitmap, rect r: IRect, u: Double) -> [(Bitmap, IRect)] {
        guard b.h >= 8, b.w >= 2 else { return [] }
        let rows = inkRows(b)
        func runs(_ y: Int) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            var x = 0
            while x < b.w {
                if b.d[y * b.w + x] != 0 {
                    var e = x
                    while e < b.w && b.d[y * b.w + e] != 0 { e += 1 }
                    out.append((x, e - 1)); x = e
                } else { x += 1 }
            }
            return out
        }
        func maxWidth(_ y0: Int, _ y1: Int) -> Int {
            var m = 0
            for y in y0..<y1 where y >= 0 && y < rows.count { m = max(m, rows[y]) }
            return m
        }
        var cut = -1
        for y in 1..<(b.h - 1) {
            let rs = runs(y)
            let bridge = rows[y] == 0 || (rs.count == 1 && rs[0].1 - rs[0].0 <= 1)
            guard bridge else { continue }
            guard let yA = (0..<y).last(where: { rows[$0] > 0 }),
                  let yB = ((y + 1)..<b.h).first(where: { rows[$0] > 0 }) else { continue }
            let topH = yA + 1, botH = b.h - yB
            let short = min(topH, botH), tall = max(topH, botH)
            guard short >= 3, tall >= 5,
                  Double(short) <= 0.70 * u,
                  Double(tall) >= 0.50 * u,
                  Double(tall) <= 1.45 * u else { continue }
            // The bridge is thinner than both the cap and the body. A stem that
            // simply continues a letter is not thinner than the side below it.
            let neck = max(rows[y], 1)
            guard neck + 2 <= min(maxWidth(0, y), maxWidth(y + 1, b.h)) else { continue }
            cut = y
            break
        }
        guard cut > 0 else { return [] }
        func piece(_ y0: Int, _ y1: Int) -> (Bitmap, IRect)? {
            guard y1 > y0 else { return nil }
            var x0 = b.w, x1 = -1
            for y in y0..<y1 { for x in 0..<b.w where b.d[y * b.w + x] != 0 { x0 = min(x0, x); x1 = max(x1, x) } }
            guard x1 >= x0 else { return nil }
            var nb = Bitmap(w: x1 - x0 + 1, h: y1 - y0)
            for y in y0..<y1 { for x in x0...x1 where b.d[y * b.w + x] != 0 { nb.d[(y - y0) * nb.w + (x - x0)] = 1 } }
            let nr = IRect(x0: r.x0 + x0, y0: r.y0 + y0, x1: r.x0 + x1 + 1, y1: r.y0 + y1)
            return (nb, nr)
        }
        guard let a = piece(0, cut), let c = piece(cut + 1, b.h) else { return [] }
        return [a, c]
    }

    /// Augmentation dot just right of the stem end (a dotted quarter / eighth). 0 or 1.
    static func augmentationDots(clean: Bitmap, stem: Stem, staff st: TabStaff) -> Int {
        let u = st.u
        // Start just right of the stem. A flag is connected to the stem; a dot is not.
        let stemRight = Int(stem.x + Double(stem.width) / 2) + 1
        let x0 = max(0, stemRight)
        let x1 = min(clean.w, Int((stem.x + 0.90 * u).rounded()))
        let y0 = max(0, Int((Double(stem.y1) - 0.70 * u).rounded()))
        let y1 = min(clean.h, Int((Double(stem.y1) - 0.02 * u).rounded()))
        guard x1 > x0, y1 > y0 else { return 0 }
        let ww = x1 - x0, hh = y1 - y0
        var seen = [Bool](repeating: false, count: ww * hh)
        func at(_ x: Int, _ y: Int) -> Int { (y - y0) * ww + (x - x0) }
        var dots = 0
        for y in y0..<y1 {
            for x in x0..<x1 where clean.ink(x, y) && !seen[at(x, y)] {
                var stack = [(x, y)]
                seen[at(x, y)] = true
                var n = 0, minx = x, maxx = x, miny = y, maxy = y, beam = false
                while let p = stack.popLast() {
                    n += 1
                    minx = min(minx, p.0); maxx = max(maxx, p.0); miny = min(miny, p.1); maxy = max(maxy, p.1)
                    if p.0 >= x1 - 2 {
                        var xx = x1, run = 0
                        while xx < clean.w && clean.ink(xx, p.1) {
                            run += 1; xx += 1
                            if run > Int(0.55 * u) { beam = true; break }
                        }
                    }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = p.0 + dx, ny = p.1 + dy
                        if nx >= x0, nx < x1, ny >= y0, ny < y1, clean.ink(nx, ny), !seen[at(nx, ny)] {
                            seen[at(nx, ny)] = true
                            stack.append((nx, ny))
                        }
                    }
                }
                if beam || minx <= stemRight { continue }
                let bw = maxx - minx + 1, bh = maxy - miny + 1
                if n >= max(3, Int(u * u * 0.035)), n <= Int(u * u * 0.30),
                   bw >= 2, bh >= 2, bw <= Int(0.50 * u) + 1, bh <= Int(0.50 * u) + 1,
                   abs(bw - bh) <= max(2, Int(0.25 * u)) { dots += 1 }
            }
        }
        return min(dots, 1)
    }

    // MARK: Main

    struct Item {
        var x: Double
        var kind: TabGlyph.Kind
        var string: Int
        var conf: Double
        var strumDir: Stroke? = nil
        var strumStrings: [Int] = []
        var isShaft = false
        var rect: IRect
    }

    /// Row-wise ink count of a component bitmap.
    static func inkRows(_ b: Bitmap) -> [Int] {
        (0..<b.h).map { y in var n = 0; for x in 0..<b.w where b.d[y * b.w + x] != 0 { n += 1 }; return n }
    }

    static func analyze(bm: Bitmap, clean: Bitmap, staff st: TabStaff, bars: [BarlineStructure],
                        beats: Double, unit: Int = 4, classifier: OMRGlyphClassifier, trace: OMRTrace? = nil) -> [MeasureTab] {
        let u = st.u
        let unitScale = Double(unit) / 4.0
        var stems = findStems(clean: clean, staff: st, bars: bars)
        for i in stems.indices {
            stems[i].beams = beamCount(clean: clean, stem: stems[i], staff: st)
            stems[i].dotted = augmentationDots(clean: clean, stem: stems[i], staff: st) > 0
        }

        // glyph bitmap: staff-free, stems erased so that glyphs touching stems separate
        var gb = clean
        for s in stems {
            for x in Int(s.x - Double(s.width) / 2)..<Int(s.x + Double(s.width) / 2 + 1) where x >= 0 && x < gb.w {
                for y in max(0, s.y0)..<min(gb.h, s.y1) { gb.d[y * gb.w + x] = 0 }
            }
        }
        for b in bars { for x in max(0, b.x0 - 1)..<min(gb.w, b.x1 + 1) { for y in max(0, Int(st.top - u * 0.4))..<min(gb.h, Int(st.bottom + u * 0.4)) { gb.d[y * gb.w + x] = 0 } } }
        // restrict to the tab band
        let yLo = Int(st.top - 0.9 * u), yHi = Int(st.bottom + 1.3 * u)
        var band = Bitmap(w: gb.w, h: gb.h)
        for y in max(0, yLo)..<min(gb.h, yHi) { for x in st.x0..<min(gb.w, st.x1) { band.d[y * gb.w + x] = gb.d[y * gb.w + x] } }
        let lab = OMRVision.label(band)

        var items: [Item] = []
        var rests: [IRect] = []
        var others: [TabGlyph] = []
        func stringIndex(_ cy: Double) -> (Int, Double) {
            let off = (cy - st.top) / u
            let i = min(5, max(0, Int(off.rounded())))
            return (i, abs(off - Double(i)))
        }
        var techs: [(x: Double, y: Double, tech: Technique)] = []
        var glyphs: [(Bitmap, IRect, Int)] = []
        for c in lab.comps where c.area >= 4 {
            let bmp = OMRVision.extract(lab, c)
            let parts = glyphParts(bmp, rect: c.rect, u: u)
            if parts.isEmpty { glyphs.append((bmp, c.rect, c.area)) }
            else {
                for p in parts {
                    let ink = p.0.d.reduce(0) { $0 + Int($1) }
                    if ink >= 4 { glyphs.append((p.0, p.1, ink)) }
                }
            }
        }
        for (bmp, r, area) in glyphs {
            let w = Double(r.w), h = Double(r.h)
            // ---- tall comps: strum shafts / x columns / x with arrow head
            if h >= 1.25 * u {
                // string windows containing a cross
                var wins: [(Int, Double)] = []   // (string index, score)
                for i in 0..<6 {
                    let ly = st.lines[i]
                    let wy0 = Int((ly - 0.5 * u).rounded()) - r.y0, wy1 = Int((ly + 0.5 * u).rounded()) - r.y0
                    if wy0 < -Int(0.2 * u) || wy1 > r.h + Int(0.2 * u) { continue }
                    let sub = OMRVision.crop(bmp, IRect(x0: 0, y0: max(0, wy0), x1: r.w, y1: min(r.h, wy1)))
                    if sub.w < 4 || sub.h < 4 { continue }
                    let sc = crossScore(OMRGlyphFeatures.tight(sub))
                    if sc > 0.35 && w >= 0.55 * u { wins.append((i, sc)) }
                }
                if !wins.isEmpty && w <= 1.7 * u {
                    var dir: Stroke? = nil
                    let first = wins.first!.0, last = wins.last!.0
                    let topEdge = Int((st.lines[first] - 0.55 * u).rounded()) - r.y0
                    let botEdge = Int((st.lines[last] + 0.55 * u).rounded()) - r.y0
                    var topInk = 0, botInk = 0
                    let rows = inkRows(bmp)
                    for y in 0..<r.h { if y < topEdge - 1 { topInk += rows[y] }; if y > botEdge + 1 { botInk += rows[y] } }
                    let thr = max(8, Int(0.08 * u * u))
                    // A slur sitting on the string above a fret also leaves ink outside the
                    // crosses. A stacked-x strum is a shaft at least two strings tall.
                    if verticalShaft(bmp) && h >= 2.0 * u {
                        if topInk >= thr && topInk > botInk { dir = .up } else if botInk >= thr { dir = .down }
                    }
                    let strs = wins.map { $0.0 + 1 }
                    for (k, wn) in wins.enumerated() {
                        var it = Item(x: r.cx, kind: .cross, string: wn.0 + 1, conf: min(1, wn.1 + 0.3), rect: r)
                        if k == 0 { it.strumDir = dir }
                        items.append(it)
                    }
                    _ = strs
                    continue
                }
                // thin shaft with arrow head (vertical or slanted)
                if h >= 1.4 * u && w <= 1.3 * u {
                    let rows = inkRows(bmp)
                    func offBand(_ i: Int) -> Bool { let y = r.y0 + i; return !st.bands.contains { y >= $0.0 - 1 && y <= $0.1 + 1 } }
                    let k = max(3, Int(0.8 * u))
                    var top = 0, bot = 0
                    for i in 0..<min(k, rows.count) where offBand(i) { top = max(top, rows[i]) }
                    for i in max(0, rows.count - k)..<rows.count where offBand(i) { bot = max(bot, rows[i]) }
                    var dir: Stroke = bot >= top ? .down : .up
                    if abs(bot - top) < 2 { dir = .down }
                    var strs: [Int] = []
                    for i in 0..<6 where st.lines[i] >= Double(r.y0) - 0.3 * u && st.lines[i] <= Double(r.y1) + 0.3 * u { strs.append(i + 1) }
                    if !strs.isEmpty {
                        var it = Item(x: r.cx, kind: .cross, string: strs[0], conf: 0.8, rect: r)
                        it.strumDir = dir; it.strumStrings = strs; it.isShaft = true
                        items.append(it)
                    }
                    continue
                }
                continue
            }
            if w > 1.6 * u && h > 0.5 * u { continue }
            let (sIdx, so) = stringIndex(r.cy)
            // dash = rest
            let fracOff = abs((r.cy - st.top) / u - ((r.cy - st.top) / u).rounded())
            _ = fracOff
            if w >= 0.5 * u && w <= 1.5 * u && h <= 0.45 * u && Double(r.h) >= Double(st.thickness) + 1 && w / max(h, 1) >= 2.0 && r.cy > st.top + 0.3 * u && r.cy < st.bottom - 0.3 * u {
                rests.append(r); continue
            }
            if h < 0.3 * u && w < 0.4 * u { continue }
            // A slur fragment left after the neck split: flat, not a fret or an ×.
            if h <= 0.50 * u && w >= 1.25 * h { continue }
            if w < 0.3 * u || Double(area) < 0.1 * u * u { continue }
            // H/P sits between the strings, or just above the staff on the top string.
            let offString = so > 0.30 || r.cy < st.top - 0.12 * u
            if offString, let (lab, tc) = classifier.classify(bmp, role: .tabDigit, allowed: ["H", "P"]), tc >= 0.18 {
                techs.append((r.cx, r.cy, lab == "H" ? .hammerOn : .pullOff))
                continue
            }
            if r.cy < st.top - 0.12 * u { continue }
            let cs = crossScore(bmp)
            let cl = classifier.classify(bmp, role: .tabDigit)
            if let (label, conf) = cl, conf >= 0.25 {
                if label == "x" {
                    if so <= 0.24 { items.append(Item(x: r.cx, kind: .cross, string: sIdx + 1, conf: conf, rect: r)); items[items.count - 1].strumStrings = [] }
                    else if so > 0.4 { others.append(TabGlyph(rect: r, kind: .unknown, confidence: 0.1, string: sIdx + 1, stringOffset: so)) }
                    continue
                }
                if ProcessInfo.processInfo.environment["OMR_DEBUG_GLYPH"] != nil, Int(label) != nil { FileHandle.standardError.write(Data("digit \(label) conf \(conf) rect \(r.x0),\(r.y0) \(r.w)x\(r.h) area \(area)\n".utf8)) }
                if let d = Int(label) {
                    // A fret is centred on its string. An H/P or a slur tail sits between strings
                    // and is an "8" only by accident.
                    if so <= 0.24 { items.append(Item(x: r.cx, kind: .digit(d), string: sIdx + 1, conf: conf, rect: r)) }
                    continue
                }
                if label == "H" || label == "P" {
                    techs.append((r.cx, r.cy, label == "H" ? .hammerOn : .pullOff))
                    continue
                }
                if label == "clef" || label == "cjk" || label == "S" || label == "(" || label == ")" { others.append(TabGlyph(rect: r, kind: .unknown, confidence: conf, string: sIdx + 1, stringOffset: so)); continue }
            }
            if cs > 0.5 && w >= 0.3 * u && h >= 0.3 * u && so <= 0.24 {
                items.append(Item(x: r.cx, kind: .cross, string: sIdx + 1, conf: cs * 0.8, rect: r)); continue
            }
            others.append(TabGlyph(rect: r, kind: w >= 0.6 * u && h <= 0.9 * u && Double(area) / (w * h) < 0.5 ? .arc : .unknown, confidence: 0.2, string: sIdx + 1, stringOffset: so))
        }
        for it in items { trace?.add(it.rect, it.isShaft ? (255, 0, 255) : (it.kind == .cross ? (0, 0, 255) : (200, 0, 200))) }
        for r in rests { trace?.add(r, (255, 128, 0)) }
        for s in stems { trace?.add(IRect(x0: Int(s.x) - 1, y0: s.y0, x1: Int(s.x) + 2, y1: s.y1), (0, 200, 200), "b\(s.beams)") }

        // measure ranges from barlines
        var ranges: [(Double, Double)] = []
        let sorted = bars.sorted { $0.x0 < $1.x0 }
        if sorted.count >= 2 { for i in 0..<(sorted.count - 1) { ranges.append((sorted[i].xAfter, sorted[i + 1].xBefore)) } }

        var out: [MeasureTab] = []
        for (mi, rg) in ranges.enumerated() {
            var mItems = items.filter { $0.x >= rg.0 && $0.x < rg.1 }
            let ms = stems.filter { $0.x >= rg.0 && $0.x < rg.1 }
            let mRests = rests.filter { $0.cx >= rg.0 && $0.cx < rg.1 }
            var timeSig: (Int, Int)? = nil
            if mi == 0, stems.count >= 3, let fs = ms.first?.x {
                var up = [Int](), lo = [Int]()
                for it in mItems where it.x < fs - 0.5 * u {
                    if case .digit(let d) = it.kind, it.rect.h > Int(0.95 * u) { if it.rect.cy < st.top + 2.5 * u { up.append(d) } else { lo.append(d) } }
                }
                if up.count == 1 && lo.count == 1 { timeSig = (up[0], lo[0]) }
                mItems = mItems.filter { $0.x >= fs - 0.5 * u }
            }
            // cluster to events
            struct Ev { var x: Double; var items: [Item]; var stem: Stem? }
            var evs: [Ev] = []
            for g in mItems.sorted(by: { $0.x < $1.x }) {
                var bestStem: Stem? = nil
                var bd = (g.isShaft ? 0.9 : 0.65) * u
                for s in ms { let d = abs(s.x - g.x); if d < bd { bd = d; bestStem = s } }
                if let s = bestStem {
                    if let k = evs.firstIndex(where: { $0.stem?.x == s.x }) { evs[k].items.append(g) } else { evs.append(Ev(x: s.x, items: [g], stem: s)) }
                } else if let k = evs.lastIndex(where: { $0.stem == nil && abs($0.x - g.x) < 0.45 * u }) {
                    evs[k].items.append(g)
                } else { evs.append(Ev(x: g.x, items: [g], stem: nil)) }
            }
            evs.sort { $0.x < $1.x }
            struct Slot { var x: Double; var dur: Double; var ev: Ev? }
            var slots: [Slot] = []
            for e in evs {
                var dur: Double
                if let s = e.stem {
                    dur = [1.0, 0.5, 0.25, 0.125, 0.0625][min(4, s.beams)] * unitScale
                    if s.dotted { dur *= 1.5 }
                } else { dur = unitScale }
                slots.append(Slot(x: e.x, dur: dur, ev: e))
            }
            for r in mRests { slots.append(Slot(x: r.cx, dur: unitScale, ev: nil)) }
            slots.sort { $0.x < $1.x }
            // Two unbeamed notes and nothing else, sitting on either half of the bar, are half notes.
            // A quarter and a half look the same (stem, no beam); the pair is what distinguishes them.
            let mW = max(1, rg.1 - rg.0)
            let evSlots = slots.indices.filter { slots[$0].ev != nil }
            if evSlots.count == 2,
               abs((slots[evSlots[0]].dur + slots[evSlots[1]].dur) - beats / 2) < 0.2,
               evSlots.allSatisfy({ slots[$0].ev?.stem.map { $0.beams == 0 } ?? true }) {
                let gap = (slots[evSlots[1]].x - slots[evSlots[0]].x) / mW
                if gap > 0.28, gap < 0.72 {
                    for i in evSlots { slots[i].dur = beats / 2 }
                }
            }
            if ProcessInfo.processInfo.environment["OMR_DEBUG"] != nil { FileHandle.standardError.write(Data("m\(mi) stems \(ms.map { "\(Int($0.x)):b\($0.beams)" }) slots \(slots.map { "\(Int($0.x)):\($0.dur)\($0.ev == nil ? "R" : "")" })\n".utf8)) }
            let restIdx = slots.indices.filter { slots[$0].ev == nil }
            let evSum = slots.filter { $0.ev != nil }.reduce(0) { $0 + $1.dur }
            if !restIdx.isEmpty {
                let remain = beats - evSum
                if remain > 0 && abs(remain - Double(restIdx.count) * unitScale) > 1e-6 {
                    for k in restIdx { slots[k].dur = remain / Double(restIdx.count) }
                }
            }
            var t = 0.0
            var events: [TabEvent] = []
            var xs: [Double] = []
            var low: [Int] = []
            for sl in slots {
                if let e = sl.ev {
                    var notes: [TabNote] = []
                    var stroke: Stroke? = nil
                    var bad = false
                    var digitGlyphs: [TabGlyph] = []
                    var seen = Set<Int>()
                    for g in e.items {
                        if g.conf < 0.45 { bad = true }
                        if let d = g.strumDir { stroke = d }
                        if g.isShaft { for s in g.strumStrings where !seen.contains(s) { seen.insert(s); notes.append(TabNote.chordTone(string: s)) }; continue }
                        switch g.kind {
                        case .cross: if !seen.contains(g.string) { seen.insert(g.string); notes.append(TabNote.chordTone(string: g.string)) }
                        case .digit: digitGlyphs.append(TabGlyph(rect: g.rect, kind: g.kind, confidence: g.conf, string: g.string, stringOffset: 0))
                        default: break
                        }
                    }
                    if !digitGlyphs.isEmpty {
                        let dn = mergeDigits(digitGlyphs, notes: digitGlyphs.map { g -> TabNote in if case .digit(let d) = g.kind { return TabNote(string: g.string, fret: d) }; return TabNote(string: g.string, fret: 0) }, u: u)
                        for n in dn where !seen.contains(n.string) { seen.insert(n.string); notes.append(n) }
                    }
                    notes.sort { $0.string > $1.string }
                    if bad { low.append(events.count) }
                    events.append(TabEvent(beat: t, duration: sl.dur, notes: notes, stroke: stroke))
                    xs.append(sl.x)
                } else {
                    events.append(TabEvent(beat: t, duration: sl.dur, notes: []))
                    xs.append(sl.x)
                }
                t += sl.dur
            }
            // H/P is printed between the two frets, above the string. It belongs on the right-hand note.
            for tech in techs where tech.x >= rg.0 && tech.x < rg.1 {
                guard let ri = xs.indices.filter({ xs[$0] >= tech.x - 0.2 * u }).min(by: { xs[$0] < xs[$1] }),
                      xs[ri] - tech.x < 1.5 * u,
                      let li = xs.indices.filter({ xs[$0] < tech.x - 0.05 * u }).max(by: { xs[$0] < xs[$1] }),
                      tech.x - xs[li] < 1.5 * u,
                      !events[ri].notes.isEmpty else { continue }
                let targetY = tech.y + 1.15 * u
                let k = events[ri].notes.indices.min {
                    abs(st.lines[events[ri].notes[$0].string - 1] - targetY) < abs(st.lines[events[ri].notes[$1].string - 1] - targetY)
                } ?? events[ri].notes.startIndex
                guard !events[ri].notes[k].chordTone else { continue }
                events[ri].notes[k].technique = tech.tech
            }
            // The H/P often melts into the slur. The arc still joins two frets on one string;
            // a lower destination is a pull-off, a higher one a hammer-on.
            if events.count >= 2 {
                for i in 0..<(events.count - 1) {
                    guard events[i].notes.count == 1, events[i + 1].notes.count == 1 else { continue }
                    let a = events[i].notes[0], b = events[i + 1].notes[0]
                    guard !a.chordTone, !b.chordTone, a.string == b.string, a.fret != b.fret else { continue }
                    guard events[i + 1].notes[0].technique == nil else { continue }
                    let gap = xs[i + 1] - xs[i]
                    guard gap > 0.55 * u, gap < 2.6 * u else { continue }
                    let yLine = st.lines[a.string - 1]
                    let y0 = Int((yLine - 1.20 * u).rounded()), y1 = Int((yLine - 0.38 * u).rounded())
                    let xa = Int((xs[i] + 0.22 * u).rounded()), xb = Int((xs[i + 1] - 0.22 * u).rounded())
                    guard xb - xa >= 3, y1 > y0 else { continue }
                    var hit = 0
                    for x in xa...xb {
                        var col = false
                        for y in y0...y1 where clean.ink(x, y) { col = true; break }
                        if col { hit += 1 }
                    }
                    guard Double(hit) >= 0.38 * Double(xb - xa + 1) else { continue }
                    events[i + 1].notes[0].technique = b.fret < a.fret ? .pullOff : .hammerOn
                }
            }
            let mg = others.filter { $0.rect.cx >= rg.0 && $0.rect.cx < rg.1 }
            out.append(MeasureTab(x0: rg.0, x1: rg.1, events: events, eventX: xs, lowConfidence: low, beatSum: t, glyphs: mg, timeSig: timeSig.map { (beats: $0.0, unit: $0.1) }))
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
