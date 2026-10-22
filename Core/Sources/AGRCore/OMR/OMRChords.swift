import Foundation

// MARK: - Chord names + chord diagrams
//
// Reads the band between the previous system and a tab staff: chord diagrams (6 strings x 3..6 frets, dots,
// x / o markers, base-fret digit) and chord names (OCR tokens above the diagrams), pairs them, assigns them to
// measures by x and quantizes the beat from the x position.
//
// Inputs the engine passes (see OMRChordReader.read):
//   bm        binarized (deskewed) page bitmap (the one used for staff detection, staff lines still in place)
//   staff     the TabStaff below the band
//   spans     one MeasureSpan per tab measure (x0/x1 from MeasureTab, optional event anchors)
//   ocr       OCR tokens of the same (deskewed) page, normalised coordinates, incl. the zoomed region pass tokens

struct OMRChordDiagram {
    var rect: IRect              // grid + markers + base digit
    var grid: IRect
    var xs: [Double]             // 6 string x positions, low E (left) -> high E (right)
    var lineYs: [Double]         // fret lines top -> bottom
    var rel: [Int]               // per string: -1 muted, 0 open, k = k-th fret row of the diagram
    var baseFret: Int = 1
    var baseDigitPresent = false
    var baseDigitRect: IRect?
    var confidence: Double = 1
    var frets: [Int] {           // absolute
        rel.map { $0 <= 0 ? $0 : $0 + baseFret - 1 }
    }
    var shape: ChordShape { ChordShape(frets: frets, baseFret: baseFret) }
    var left: Double { Double(grid.x0) }
    var cx: Double { (xs.first! + xs.last!) / 2 }
    var stringSpacing: Double { (xs.last! - xs.first!) / 5 }
    var width: Double { xs.last! - xs.first! + 2 * stringSpacing }
}

struct OMRChordName {
    var text: String
    var x0: Double, x1: Double, y0: Double, y1: Double
    var cx: Double { (x0 + x1) / 2 }
    var confidence: Double
}

struct MeasureSpan {
    var x0: Double
    var x1: Double
    var beats: Double
    /// Optional (x, beat) of the tab events of the measure; used to snap chord positions to real event beats.
    var anchors: [(x: Double, beat: Double)] = []
    init(x0: Double, x1: Double, beats: Double = 4, anchors: [(x: Double, beat: Double)] = []) {
        self.x0 = x0; self.x1 = x1; self.beats = beats; self.anchors = anchors
    }
}

/// Diagrams repeat on a page: remembers name <-> shape pairs read with a printed name, to fix and fill others.
struct ChordLibrary {
    var shapesByName: [String: [[Int]: Int]] = [:]       // ChordNameNormalizer.key -> frets -> count
    var namesByShape: [[Int]: [String: Int]] = [:]
    mutating func add(name: String, frets: [Int]) {
        shapesByName[ChordNameNormalizer.key(name), default: [:]][frets, default: 0] += 1
        namesByShape[frets, default: [:]][name, default: 0] += 1
    }
    mutating func merge(_ o: ChordLibrary) {
        for (k, v) in o.shapesByName { for (f, c) in v { shapesByName[k, default: [:]][f, default: 0] += c } }
        for (k, v) in o.namesByShape { for (n, c) in v { namesByShape[k, default: [:]][n, default: 0] += c } }
    }
    func bestShape(for name: String) -> [Int]? {
        shapesByName[ChordNameNormalizer.key(name)]?.max { $0.value < $1.value }?.key
    }
    func name(for frets: [Int]) -> String? { namesByShape[frets]?.max { $0.value < $1.value }?.key }
}

struct ChordSystemInput {
    var staff: TabStaff
    var bandTop: Double?
    var spans: [MeasureSpan]
}

struct ChordReadResult {
    var measures: [[ChordMark]]
    var issues: [OMRIssue]
    var diagrams: [OMRChordDiagram]
    var names: [OMRChordName]
    /// Placed chords with their pixel anchors (for debugging / evaluation).
    var placed: [(measure: Int, chord: ChordMark, x: Double, diagram: Int?)]
    var bandTop: Double
    var learned = ChordLibrary()
}

enum OMRChordReader {
    static let standardTuning = ScoreMeta.standardTuning

    // MARK: Entry point

    /// Reads chord names + diagrams above `staff`.
    /// - Parameters:
    ///   - bandTop: top of the search band in pixels (e.g. bottom of the previous system's lyrics); default staff.top - 10.5u.
    ///   - spans: tab measures of this system (x range, beats, optional event anchors).
    static func read(bm bmGlobal: Bitmap, gray: GrayImage? = nil, staff: TabStaff, bandTop: Double? = nil, spans: [MeasureSpan], ocr: [OCRToken],
                     library: ChordLibrary = ChordLibrary(), pageIndex: Int = 0, systemIndex: Int = 0) -> ChordReadResult {
        let u = staff.u
        let bottom = staff.top - 0.25 * u
        let top = max(0, bandTop ?? (staff.top - 10.5 * u))
        // thin / pale / coloured strokes need a more inclusive local threshold than the page-wide one
        let bm = gray.map { localBitmap($0, y0: Int(top), y1: Int(bottom) + 2) } ?? bmGlobal
        var diagrams = findDiagrams(bm, gray: gray, top: top, bottom: bottom, u: u, xMin: max(0, staff.x0 - 4 * Int(u)), xMax: min(bm.w, staff.x1 + 4 * Int(u)))
        let names = chordNames(ocr: ocr, W: bm.w, H: bm.h, top: top, bottom: bottom, u: u)
        for i in diagrams.indices { readBaseDigit(bm, &diagrams[i], ocr: ocr) }

        // pair names <-> diagrams (a name sits above its diagram, roughly centred)
        var nameOfDiagram = [Int?](repeating: nil, count: diagrams.count)
        var usedNames = Set<Int>()
        var cand: [(d: Int, n: Int, dist: Double)] = []
        for (di, d) in diagrams.enumerated() {
            for (ni, n) in names.enumerated() {
                let dx = abs(n.cx - d.cx)
                let limit = max(d.width * 0.75, 1.6 * u)
                if dx <= limit && n.y1 <= Double(d.grid.y0) + 1.6 * d.stringSpacing { cand.append((di, ni, dx)) }
            }
        }
        for c in cand.sorted(by: { $0.dist < $1.dist }) where nameOfDiagram[c.d] == nil && !usedNames.contains(c.n) {
            nameOfDiagram[c.d] = c.n; usedNames.insert(c.n)
        }
        for di in diagrams.indices {
            if let ni = nameOfDiagram[di] { resolveBaseFret(&diagrams[di], name: names[ni].text) }
            else if diagrams[di].baseDigitPresent, diagrams[di].baseFret < 2 { diagrams[di].baseFret = 2 }
        }

        if debugOn {
            for (di, d) in diagrams.enumerated() {
                FileHandle.standardError.write(Data("pair diag\(di) x \(Int(d.left)) name \(nameOfDiagram[di].map { names[$0].text } ?? "-") digit \(d.baseDigitPresent) base \(d.baseFret) frets \(d.frets)\n".utf8))
            }
            FileHandle.standardError.write(Data("names \(names.map { $0.text })\n".utf8))
        }
        var entries: [(x: Double, name: String, shape: ChordShape?, di: Int?, conf: Double, p0: Double)] = []
        var issues: [OMRIssue] = []
        var learned = ChordLibrary()
        for (di, d) in diagrams.enumerated() {
            if let ni = nameOfDiagram[di], let sym = ChordNameNormalizer.symbol(names[ni].text), shapeFit(sym, d.frets) < 0.62,
               let alt = library.name(for: d.frets) ?? identify(frets: d.frets), let altSym = ChordNameNormalizer.symbol(alt), shapeFit(altSym, d.frets) >= 0.95,
               names[ni].confidence < 0.995 {
                // OCR misread (G/D, C/E ...): the diagram identifies another chord exactly
                entries.append((d.left, alt, d.shape, di, 0.5 * d.confidence, 0.05))
                issues.append(OMRIssue(kind: .unknownChord, path: "sections[0].lines[{L}].system.measures[0].chords",
                                       message: "printed name \(names[ni].text) contradicts the diagram; used \(alt)", context: "\(systemIndex)", ocrSnippets: [names[ni].text], confidence: 0.5))
                continue
            }
            if let ni = nameOfDiagram[di] {
                var shape = d.shape
                if let sym = ChordNameNormalizer.symbol(names[ni].text), shapeFit(sym, shape.frets) < 0.95,
                   let lib = library.bestShape(for: names[ni].text), shapeFit(sym, lib) >= 0.95 {
                    shape = ChordShape(frets: lib, baseFret: shape.baseFret)      // repeated chord: trust the page's majority reading
                } else { learned.add(name: names[ni].text, frets: shape.frets) }
                entries.append((d.left, names[ni].text, shape, di, min(d.confidence, names[ni].confidence), 0.05))
            } else if let known = library.name(for: d.frets) {
                entries.append((d.left, known, d.shape, di, 0.6 * d.confidence, 0.05))
            } else if let guess = identify(frets: d.frets) {
                entries.append((d.left, guess, d.shape, di, 0.3 * d.confidence, 0.05))
                issues.append(OMRIssue(kind: .unknownChord, path: "sections[0].lines[{L}].system.measures[0]",
                                       message: "chord diagram without printed name; guessed \(guess)",
                                       context: "\(systemIndex)", confidence: 0.3))
            } else {
                issues.append(OMRIssue(kind: .chordShapeUnread, path: "sections[0].lines[{L}].system.measures[0]",
                                       message: "chord diagram without a recognisable name", context: "\(systemIndex)", confidence: 0.2))
            }
        }
        let halves = diagrams.map { $0.cx - $0.left }.sorted()
        let halfW = halves.isEmpty ? 1.7 * u : halves[halves.count / 2]
        for (ni, n) in names.enumerated() where !usedNames.contains(ni) {
            entries.append((n.x0, n.text, nil, nil, n.confidence, 0.12))
        }

        var measures = [[ChordMark]](repeating: [], count: spans.count)
        var placed: [(measure: Int, chord: ChordMark, x: Double, diagram: Int?)] = []
        for e in entries.sorted(by: { $0.x < $1.x }) {
            guard !spans.isEmpty else { break }
            let (mi, beat) = place(x: e.x, spans: spans, p0: e.p0)
            var mark = ChordMark(name: e.name, beat: beat, shape: e.shape)
            if let msg = crossCheck(name: e.name, shape: e.shape) {
                if let fixed = tryFix(name: e.name, shape: e.shape) { mark.shape = fixed }
                else {
                    issues.append(OMRIssue(kind: .unknownChord, path: "sections[0].lines[{L}].system.measures[\(mi)].chords",
                                           message: msg, context: "\(systemIndex)", ocrSnippets: [e.name], confidence: e.conf))
                }
            }
            measures[mi].append(mark)
            placed.append((mi, mark, e.x, e.di))
        }
        for i in measures.indices { measures[i].sort { $0.beat < $1.beat } }
        return ChordReadResult(measures: measures, issues: issues, diagrams: diagrams, names: names, placed: placed, bandTop: top, learned: learned)
    }

    /// Reads all systems of a page; chord diagrams repeat, so names/shapes learned on the page fix and fill the others.
    static func readPage(bm: Bitmap, gray: GrayImage?, systems: [ChordSystemInput], ocr: [OCRToken]) -> [ChordReadResult] {
        var results = systems.enumerated().map { (i, s) in read(bm: bm, gray: gray, staff: s.staff, bandTop: s.bandTop, spans: s.spans, ocr: ocr, systemIndex: i) }
        var lib = ChordLibrary()
        for r in results { lib.merge(r.learned) }
        guard !lib.namesByShape.isEmpty else { return results }
        for (i, s) in systems.enumerated() {
            results[i] = read(bm: bm, gray: gray, staff: s.staff, bandTop: s.bandTop, spans: s.spans, ocr: ocr, library: lib, systemIndex: i)
        }
        return results
    }

    /// Local binarization of a horizontal band (threshold between the band's background and its darkest content).
    static func localBitmap(_ g: GrayImage, y0: Int, y1: Int) -> Bitmap {
        var bm = Bitmap(w: g.width, h: g.height)
        let ya = max(0, y0), yb = min(g.height, y1)
        guard yb > ya else { return bm }
        var hist = [Int](repeating: 0, count: 256)
        for y in ya..<yb { for x in 0..<g.width { hist[Int(g.pixels[y * g.width + x])] += 1 } }
        let total = (yb - ya) * g.width
        func pct(_ p: Double) -> Int { var a = 0; for v in 0..<256 { a += hist[v]; if Double(a) >= p * Double(total) { return v } }; return 255 }
        let bg = Double(pct(0.7)), dk = Double(pct(0.004))
        var t = bg - 0.4 * (bg - dk)
        if bg - dk < 60 { t = bg - 0.5 * (bg - dk) }
        let thr = UInt8(max(0, min(255, t)))
        for y in ya..<yb { for x in 0..<g.width where g.pixels[y * g.width + x] < thr { bm.d[y * g.width + x] = 1 } }
        return bm
    }

    // MARK: Measure / beat placement

    static func place(x: Double, spans: [MeasureSpan], p0: Double = 0.05) -> (Int, Double) {
        var mi = 0
        for (i, s) in spans.enumerated() where x >= s.x0 - 0.02 * (s.x1 - s.x0) { mi = i }
        let s = spans[mi]
        let w = max(1, s.x1 - s.x0)
        if !s.anchors.isEmpty {
            let xa = x - 0.2 * w / max(1, s.beats)
            let best = s.anchors.min { abs($0.x - xa) < abs($1.x - xa) }!
            return (mi, best.beat)
        }
        let f = (x - s.x0) / w
        let raw = max(0, (f - p0) / (1 - p0 - 0.03) * s.beats)
        // chords sit on the downbeat, the half measure or a whole beat
        if let c = [0.0, s.beats / 2].min(by: { abs($0 - raw) < abs($1 - raw) }), abs(c - raw) <= 0.8 { return (mi, c) }
        return (mi, min(raw.rounded(), max(0, s.beats - 1)))
    }

    /// Measure spans from detected barlines (standalone use / tests). First measure starts after the clef.
    static func spans(bars: [BarlineStructure], staff: TabStaff, beats: Double) -> [MeasureSpan] {
        // drop frame borders / margins (structures far wider than a barline) before pairing
        let bars = bars.filter { Double($0.x1 - $0.x0) <= 2.2 * staff.u }
        guard bars.count >= 2 else { return [MeasureSpan(x0: Double(staff.x0), x1: Double(staff.x1), beats: beats)] }
        var xs: [(Double, Double)] = []
        for i in 0..<(bars.count - 1) { xs.append((bars[i].xAfter, bars[i + 1].xBefore)) }
        if xs.count >= 2 {
            let others = xs.dropFirst().map { $0.1 - $0.0 }.sorted()
            let med = others[others.count / 2]
            xs[0].0 = max(xs[0].0 + 1.5 * staff.u, xs[0].1 - med)
        } else {
            xs[0].0 = xs[0].0 + 2.5 * staff.u
        }
        return xs.map { MeasureSpan(x0: $0.0, x1: $0.1, beats: beats) }
    }

    // MARK: Diagram detection

    static func findDiagrams(_ bm: Bitmap, gray: GrayImage? = nil, top: Double, bottom: Double, u: Double, xMin: Int, xMax: Int) -> [OMRChordDiagram] {
        let y0 = max(0, Int(top)), y1 = min(bm.h, Int(bottom))
        guard y1 - y0 > 8, xMax > xMin else { return [] }
        let band = OMRVision.crop(bm, IRect(x0: xMin, y0: y0, x1: xMax, y1: y1))
        let lab = OMRVision.label(band)
        var out: [OMRChordDiagram] = []
        for c in lab.comps {
            let w = Double(c.rect.w), h = Double(c.rect.h)
            guard w >= 1.6 * u, w <= 7 * u, h >= 1.3 * u, h <= 7.5 * u, w / h >= 0.5, w / h <= 2.2 else { continue }
            guard Double(c.area) >= 0.18 * w * h else { continue }
            let r = IRect(x0: c.rect.x0 + xMin, y0: c.rect.y0 + y0, x1: c.rect.x1 + xMin, y1: c.rect.y1 + y0)
            if let d = analyze(bm, gray: gray, rect: r, u: u) { out.append(d) }
        }
        return out.sorted { $0.left < $1.left }
    }

    /// Fits the lattice inside the grid component and reads dots / markers.
    static func analyze(_ bm: Bitmap, gray: GrayImage? = nil, rect r: IRect, u: Double) -> OMRChordDiagram? {
        let rw = r.w, rh = r.h
        var v = [Double](repeating: 0, count: rw + 6)
        for x in 0..<rw {
            var n = 0
            for y in r.y0..<r.y1 where bm.d[y * bm.w + r.x0 + x] != 0 { n += 1 }
            v[x + 3] = Double(n) / Double(rh)
        }
        func vat(_ x: Double) -> Double {
            let i = Int(x.rounded()) - r.x0 + 3
            var m = 0.0
            for k in (i - 1)...(i + 1) where k >= 0 && k < v.count { m = max(m, v[k]) }
            return m
        }
        var best = (score: -1.0, x0: 0.0, s: 0.0)
        let sGuess = Double(rw) / 5
        var s = sGuess * 0.78
        while s <= sGuess * 1.04 {
            var x0 = Double(r.x0) - 0.1 * s
            while x0 <= Double(r.x0) + 0.45 * s {
                var sc = 0.0
                for i in 0..<6 { sc += vat(x0 + Double(i) * s) }
                if sc > best.score { best = (sc, x0, s) }
                x0 += 0.5
            }
            s += 0.25
        }
        guard best.score >= 3.6 else { return nil }
        var xs: [Double] = []
        var strong = 0
        for i in 0..<6 {
            let ex = best.x0 + Double(i) * best.s
            var sw = 0.0, sx = 0.0
            for k in Int(ex.rounded()) - 2...Int(ex.rounded()) + 2 {
                let j = k - r.x0 + 3
                guard j >= 0, j < v.count else { continue }
                if v[j] >= 0.5 { sw += v[j]; sx += v[j] * Double(k) }
            }
            if sw > 0 { xs.append(sx / sw + 0.5); strong += 1 } else { xs.append(ex + 0.5) }
        }
        guard strong >= 5 else { return nil }
        let s0 = (xs[5] - xs[0]) / 5
        guard s0 >= 0.25 * u, s0 <= 1.6 * u else { return nil }
        for i in 0..<6 { let e = xs[0] + Double(i) * s0; if abs(xs[i] - e) > 0.25 * s0 { xs[i] = e } }
        let sp = s0

        // horizontal lines: ink at the 5 midpoints between strings
        let yTopScan = max(0, r.y0 - 1), yBotScan = min(bm.h, r.y1 + 1)
        var hrow = [Int](repeating: 0, count: yBotScan - yTopScan)
        for y in yTopScan..<yBotScan {
            var n = 0
            for i in 0..<5 {
                let mx = Int(((xs[i] + xs[i + 1]) / 2).rounded(.down))
                if bm.d[y * bm.w + mx] != 0 { n += 1 }
            }
            hrow[y - yTopScan] = n
        }
        var runs: [(c: Double, t: Int, a: Int)] = []
        var y = 0
        while y < hrow.count {
            if hrow[y] >= 4 {
                var e = y
                while e < hrow.count && hrow[e] >= 4 { e += 1 }
                runs.append((Double(yTopScan) + Double(y + e - 1) / 2 + 0.5, e - y, yTopScan + y))
                y = e
            } else { y += 1 }
        }
        guard runs.count >= 3 else { return nil }
        let thick = runs.map { $0.t }.sorted()
        let medT = Double(thick[thick.count / 2])
        var diffs: [Double] = []
        for i in 1..<runs.count { diffs.append(runs[i].c - runs[i - 1].c) }
        let ds = diffs.sorted()
        let f = ds[(ds.count - 1) / 2]
        guard f >= 0.6 * sp, f <= 2.2 * sp else { return nil }
        let yBot = runs.last!.c
        var yFirst = runs.first!.c
        let firstThick = Double(runs.first!.t) >= max(2.0 * medT, 3.5) && runs.count >= 2
        if firstThick { yFirst = Double(runs.first!.a) + 0.5 }
        let n = max(2, Int(((yBot - yFirst) / f).rounded()))
        guard n >= 3 && n <= 7 else { return nil }
        let fAdj = (yBot - yFirst) / Double(n)
        let yTop = yBot - Double(n) * fAdj
        var lineYs: [Double] = []
        for k in 0...n { lineYs.append(yTop + Double(k) * fAdj) }

        var rel = [Int](repeating: 0, count: 6)
        var conf = 1.0
        for i in 0..<6 {
            var found = 0
            let base = stringWidth(bm, x: xs[i], lineYs: lineYs, sp: sp)
            for j in 0..<n {
                let yc = (lineYs[j] + lineYs[j + 1]) / 2
                let sc = dotScore(bm, x: xs[i], y: yc, sp: sp, f: fAdj, base: base)
                if debugOn && sc >= 0.9 && ProcessInfo.processInfo.environment["OMR_CH_DOTS"] != nil {
                    var d = ""
                    for yy in Int(yc.rounded()) - 2...Int(yc.rounded()) + 2 { d += " \(rowSpan(bm, x: xs[i], y: yy, sp: sp))" }
                    FileHandle.standardError.write(Data("  dot s\(i) row\(j + 1) y \(yc) base \(base) spans\(d)\n".utf8))
                }
                if sc >= 0.9 { found = j + 1 }      // lowest flagged row: a barre bar sits above the finger dots of the same string
                else if sc >= 0.3 && sc < 0.9 { conf = min(conf, 0.5) }
            }
            rel[i] = found
        }
        let topEdge = min(yTop, Double(runs.first!.a)) - 1
        let markerBox = (a: topEdge - 1.45 * sp, b: topEdge - 1.5)
        for i in 0..<6 where rel[i] == 0 {
            if markerKind(bm, gray: gray, x: xs[i], yA: markerBox.a, yB: markerBox.b, sp: sp) == .muted { rel[i] = -1 }
        }
        let grid = IRect(x0: Int(xs[0] - 0.3 * sp), y0: Int(yTop), x1: Int(xs[5] + 0.3 * sp) + 1, y1: Int(yBot) + 1)
        var d = OMRChordDiagram(rect: IRect(x0: grid.x0, y0: Int(markerBox.a), x1: grid.x1, y1: grid.y1),
                                grid: grid, xs: xs, lineYs: lineYs, rel: rel)
        d.confidence = conf
        if OMRChordReader.debugOn {
            if ProcessInfo.processInfo.environment["OMR_CH_ASCII"] != nil {
                var txt = ""
                for yy in max(0, r.y0 - 10)..<min(bm.h, r.y1 + 2) {
                    for xx in max(0, r.x0 - 8)..<min(bm.w, r.x1 + 3) { txt += bm.d[yy * bm.w + xx] != 0 ? "#" : "." }
                    txt += "\n"
                }
                FileHandle.standardError.write(Data(txt.utf8))
            }
            FileHandle.standardError.write(Data("diag x \(r.x0)-\(r.x1) y \(r.y0)-\(r.y1) xs \(xs.map { String(format: "%.1f", $0) }) lines \(lineYs.map { String(format: "%.1f", $0) }) runs \(runs.map { "\(String(format: "%.1f", $0.c))/\($0.t)" }) rel \(rel)\n".utf8))
        }
        return d
    }

    static let debugOn = ProcessInfo.processInfo.environment["OMR_CH_DEBUG"] != nil

    static func rowSpan(_ bm: Bitmap, x: Double, y: Int, sp: Double) -> Double {
        guard y >= 0, y < bm.h else { return 0 }
        var lo = Int.max, hi = Int.min
        let xa = Int((x - 0.46 * sp).rounded()), xb = Int((x + 0.46 * sp).rounded())
        for xx in xa...xb where bm.ink(xx, y) { lo = min(lo, xx); hi = max(hi, xx) }
        return hi >= lo ? Double(hi - lo + 1) : 0
    }

    /// Typical ink width of the plain string line (median over rows away from fret lines).
    static func stringWidth(_ bm: Bitmap, x: Double, lineYs: [Double], sp: Double) -> Double {
        var spans: [Double] = []
        let lo = Int(lineYs[0]), hi = Int(lineYs[lineYs.count - 1])
        for y in lo...hi {
            if lineYs.contains(where: { abs(Double(y) + 0.5 - $0) < 2.2 }) { continue }
            spans.append(rowSpan(bm, x: x, y: y, sp: sp))
        }
        guard !spans.isEmpty else { return 1 }
        spans.sort()
        return max(1, spans[spans.count / 3])
    }

    /// 1 when a filled dot is centred near (x, y): ink span clearly wider than the string line in >= 2 of 3 rows.
    static func dotScore(_ bm: Bitmap, x: Double, y: Double, sp: Double, f: Double, base: Double) -> Double {
        let need = max(2.5, base + max(1.5, 0.22 * sp))
        var best = 0.0
        let y0 = Int(y.rounded(.down))
        for c in (y0 - 1)...(y0 + 1) {
            let n = (c - 1...c + 1).filter { rowSpan(bm, x: x, y: $0, sp: sp) >= need }.count
            best = max(best, c == y0 ? Double(n) / 3 : (n == 3 ? 1 : Double(n) / 3 * 0.6))
        }
        return best >= 0.66 ? 1.0 : (best > 0 ? 0.35 : 0)
    }

    enum Marker { case muted, open, none }

    static func markerKind(_ bm: Bitmap, gray: GrayImage? = nil, x: Double, yA: Double, yB: Double, sp: Double) -> Marker {
        let xa = Int((x - 0.62 * sp).rounded()), xb = Int((x + 0.62 * sp).rounded())
        let ya = max(0, Int(yA.rounded())), yb = min(bm.h - 1, Int(yB.rounded()))
        guard yb > ya, xb > xa else { return .none }
        let ww = xb - xa + 1, hh = yb - ya + 1
        // 8-connected components inside the window; take the largest one near the string
        var seen = [Bool](repeating: false, count: ww * hh)
        var best: (area: Int, x0: Int, x1: Int, y0: Int, y1: Int, pts: [(Int, Int)])?
        for yy in ya...yb {
            for xx in xa...xb where bm.ink(xx, yy) && !seen[(yy - ya) * ww + (xx - xa)] {
                var stack = [(xx, yy)]
                seen[(yy - ya) * ww + (xx - xa)] = true
                var pts: [(Int, Int)] = []
                var x0 = xx, x1 = xx, y0 = yy, y1 = yy
                while let (cx, cy) = stack.popLast() {
                    pts.append((cx, cy))
                    x0 = min(x0, cx); x1 = max(x1, cx); y0 = min(y0, cy); y1 = max(y1, cy)
                    for dy in -1...1 { for dx in -1...1 {
                        let nx = cx + dx, ny = cy + dy
                        if nx >= xa, nx <= xb, ny >= ya, ny <= yb, bm.ink(nx, ny), !seen[(ny - ya) * ww + (nx - xa)] {
                            seen[(ny - ya) * ww + (nx - xa)] = true; stack.append((nx, ny))
                        }
                    } }
                }
                // ignore components cut by the top of the window (descenders of the chord name above)
                if y0 == ya && yy == ya && pts.count < 40 && ya > 0 { continue }
                let cxm = Double(x0 + x1) / 2
                let score = Double(pts.count) - 3.0 * abs(cxm - x)
                if best == nil || score > Double(best!.area) - 3.0 * abs(Double(best!.x0 + best!.x1) / 2 - x) { best = (pts.count, x0, x1, y0, y1, pts) }
            }
        }
        guard let c = best, c.area >= 3 else { return .none }
        let w = c.x1 - c.x0 + 1, h = c.y1 - c.y0 + 1
        guard Double(w) >= 0.25 * sp, Double(h) >= 0.25 * sp else { return .none }
        // hole test at the exact centre of the bounding box (ring = hollow, cross = ink at the crossing)
        var set = Set<Int>()
        for (px, py) in c.pts { set.insert(py * 100_000 + px) }
        let cxs = Set([c.x0 + (w - 1) / 2, c.x0 + w / 2]), cys = Set([c.y0 + (h - 1) / 2, c.y0 + h / 2])
        var filled = 0, tot = 0
        for cx in cxs { for cy in cys { tot += 1; if set.contains(cy * 100_000 + cx) { filled += 1 } } }
        let fill = Double(c.area) / Double(w * h)
        // gray evidence (blurred / JPEG rings are rarely clean holes): the centre of an 'o' is lighter than its ring, an 'x' is darkest at the crossing
        if let g = gray, w >= 3, h >= 3 {
            var cSum = 0.0, cN = 0.0, rSum = 0.0, rN = 0.0
            let ccx = Double(c.x0) + Double(w - 1) / 2, ccy = Double(c.y0) + Double(h - 1) / 2
            for (px, py) in c.pts {
                let v = Double(g.pixels[py * g.width + px])
                if abs(Double(px) - ccx) <= 0.75 && abs(Double(py) - ccy) <= 0.75 { cSum += v; cN += 1 } else { rSum += v; rN += 1 }
            }
            // centre pixels that are not ink (holes) are part of the ring's inside: sample them directly
            for cy in cys { for cx in cxs where !set.contains(cy * 100_000 + cx) { cSum += Double(g.pixels[cy * g.width + cx]); cN += 1 } }
            if cN > 0 && rN > 0 {
                let cm = cSum / cN, rm = rSum / rN
                let paper = 255.0
                if debugOn { FileHandle.standardError.write(Data("  marker x \(Int(x)) bbox \(w)x\(h) area \(c.area) filled \(filled)/\(tot) cm \(Int(cm)) rm \(Int(rm))\n".utf8)) }
                let diff = cm - rm
                if diff >= 30 { return .open }                         // clean ring: bright hole inside a dark ring
                if diff <= -25 { return .muted }                       // cross: darkest at the crossing, blurred arms around
                if cm >= 135 && filled > 0 { return .open }            // blurred ring: centre filled in but only mid-gray
                if filled > 0 { return .muted }
            }
        }
        if filled == 0 && fill < 0.9 { return .open }
        if filled == tot { return .muted }
        return fill < 0.62 ? .muted : .open
    }

    // MARK: Base fret

    static func readBaseDigit(_ bm: Bitmap, _ d: inout OMRChordDiagram, ocr: [OCRToken]) {
        let sp = d.stringSpacing
        let xr = d.xs[0] - 0.6 * sp
        let xl = d.xs[0] - 2.8 * sp
        let ya = d.lineYs[0] - 0.9 * sp, yb = d.lineYs[1] + 0.6 * sp
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min, n = 0
        for yy in max(0, Int(ya))..<max(max(0, Int(ya)), min(bm.h, Int(yb))) {
            for xx in max(0, Int(xl))..<max(max(0, Int(xl)), min(bm.w, Int(xr))) where bm.d[yy * bm.w + xx] != 0 {
                x0 = min(x0, xx); x1 = max(x1, xx); y0 = min(y0, yy); y1 = max(y1, yy); n += 1
            }
        }
        var digit: Int?
        let W = Double(bm.w), H = Double(bm.h)
        for t in ocr {
            let cx = (t.x + t.width / 2) * W, cy = (t.y + t.height / 2) * H
            guard cx >= xl - sp, cx <= d.xs[0] + 0.2 * sp, cy >= ya - sp, cy <= yb + sp else { continue }
            let s = ChordNameNormalizer.foldWidth(t.text).lowercased().filter { !$0.isWhitespace }
            let digits = s.prefix { $0.isNumber }
            if let v = Int(digits), v >= 1, v <= 24, s.dropFirst(digits.count).allSatisfy({ "frthp品格".contains($0) }) { digit = v }
        }
        if n >= 4, Double(x1 - x0 + 1) >= 0.2 * sp, Double(y1 - y0 + 1) >= 0.35 * sp, Double(x1 - x0 + 1) <= 2.4 * sp {
            d.baseDigitPresent = true
            d.baseDigitRect = IRect(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1)
            if digit == nil {
                let crop = OMRVision.crop(bm, IRect(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1))
                if let (lab, c) = OMRGlyphClassifier.shared.classify(crop, role: .other, allowed: Set((1...9).map(String.init))), c >= 0.55, let v = Int(lab) {
                    digit = v
                    d.confidence = min(d.confidence, 0.4 + 0.6 * c)
                }
            }
        }
        if let digit { d.baseDigitPresent = true; d.baseFret = max(1, digit) }
    }

    /// With the printed name known, picks the base fret that makes the shape consistent with the name.
    static func resolveBaseFret(_ d: inout OMRChordDiagram, name: String) {
        guard let sym = ChordNameNormalizer.symbol(name) else { return }
        func fit(_ base: Int) -> Double {
            var dd = d; dd.baseFret = base
            return shapeFit(sym, dd.frets)
        }
        if !d.baseDigitPresent { return }
        let current = max(1, d.baseFret)
        let fc = fit(current)
        if fc >= 0.95 && current >= 2 { return }
        var best = (current, fc)
        for b in 2...12 { let s = fit(b) - 0.001 * Double(abs(b - current)); if s > best.1 + 1e-9 { best = (b, s) } }
        if best.0 != current, best.1 >= 0.85, best.1 > fc + 0.2 { d.baseFret = best.0 }
        else if current < 2 { d.baseFret = 2 }
    }

    // MARK: Names

    static let chordRx = #"^[#b♯♭]?[A-G][#b♯♭]?(?:maj|min|dim|aug|add|sus|m|M|\+|°|ø|-)?(?:[+-]?(?:5|6|7|9|11|13|69)|[#b][59]|sus[24]?|add\d{1,2}|maj\d{0,2}|\([^)]{1,6}\))*(?:/[#b♯♭]?[A-G][#b♯♭]?)?(?:变形|变化|指法)?$"#

    static func cleanName(_ raw: String) -> String? {
        var t = ChordNameNormalizer.foldWidth(raw).filter { !$0.isWhitespace }
        t = t.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        guard !t.isEmpty, t.count <= 14 else { return nil }
        if ChordNames.isNoChord(t) { return t }
        // OCR often lower-cases a lone chord letter ("c7", "am")
        if let f = t.first, "abcdefg".contains(f), t.count <= 8, !Rx.test("^[a-g][a-z]{3,}", t) { t = f.uppercased() + t.dropFirst() }
        guard Rx.test(chordRx, t) else { return nil }
        return t
    }

    static func chordNames(ocr: [OCRToken], W: Int, H: Int, top: Double, bottom: Double, u: Double) -> [OMRChordName] {
        struct Piece { var text: String; var x0: Double, x1: Double, y0: Double, y1: Double; var conf: Double }
        var pieces: [Piece] = []
        let Wd = Double(W), Hd = Double(H)
        let headerRx = #"(?i)(key|1\s*=|capo|速度|原调|选调|bpm|tempo|[♩♪]|j\s*=|变调|调)"#
        let headerRows = ocr.filter { Rx.test(headerRx, $0.text) }.map { (($0.y + $0.height / 2) * Hd, $0.height * Hd) }
        for t in ocr {
            let y0 = t.y * Hd, y1 = (t.y + t.height) * Hd
            let cy = (y0 + y1) / 2
            guard cy >= top, cy <= bottom + 0.4 * u, !t.text.isEmpty else { continue }
            guard y1 - y0 <= 4.2 * u else { continue }
            if headerRows.contains(where: { abs($0.0 - cy) < 0.6 * max($0.1, y1 - y0) }) { continue }
            let chars = Array(t.text)
            var segs: [(String, Int, Int)] = []
            var cur = "", s = 0
            for (i, ch) in chars.enumerated() {
                if ch.isWhitespace { if !cur.isEmpty { segs.append((cur, s, i)); cur = "" } }
                else { if cur.isEmpty { s = i }; cur.append(ch) }
            }
            if !cur.isEmpty { segs.append((cur, s, chars.count)) }
            let n = Double(max(1, chars.count))
            let X0 = t.x * Wd, X1 = (t.x + t.width) * Wd
            for sg in segs {
                pieces.append(Piece(text: sg.0, x0: X0 + (X1 - X0) * Double(sg.1) / n, x1: X0 + (X1 - X0) * Double(sg.2) / n, y0: y0, y1: y1, conf: t.confidence))
            }
        }
        pieces.sort { $0.x0 < $1.x0 }
        var merged: [Piece] = []
        for p in pieces {
            if let li = merged.indices.last {
                let l = merged[li]
                let h = max(l.y1 - l.y0, p.y1 - p.y0)
                let sameRow = abs((l.y0 + l.y1) / 2 - (p.y0 + p.y1) / 2) < 0.6 * h
                if sameRow && p.x0 - l.x1 < 0.8 * h && cleanName(l.text + p.text) != nil {
                    merged[li] = Piece(text: l.text + p.text, x0: l.x0, x1: max(l.x1, p.x1), y0: min(l.y0, p.y0), y1: max(l.y1, p.y1), conf: min(l.conf, p.conf))
                    continue
                }
            }
            merged.append(p)
        }
        var out: [OMRChordName] = []
        for p in merged {
            guard let c = cleanName(p.text) else { continue }
            out.append(OMRChordName(text: c, x0: p.x0, x1: p.x1, y0: p.y0, y1: p.y1, confidence: p.conf))
        }
        return out
    }

    // MARK: Cross-check / identification

    static func pitchClasses(_ frets: [Int]) -> [Int] {
        var pcs: [Int] = []
        for (i, f) in frets.enumerated() where f >= 0 && i < 6 { pcs.append((standardTuning[i] + f) % 12) }
        return pcs
    }

    static func bassPC(_ frets: [Int]) -> Int? {
        for (i, f) in frets.enumerated() where f >= 0 && i < 6 { return (standardTuning[i] + f) % 12 }
        return nil
    }

    /// 0...1: share of sounding pitch classes that belong to the chord, with root / coverage / bass bonuses.
    static func shapeFit(_ sym: ChordSymbol, _ frets: [Int]) -> Double {
        let pcs = pitchClasses(frets)
        guard !pcs.isEmpty else { return 0 }
        let chordPCs = sym.pitchClasses
        let inChord = Double(pcs.filter { chordPCs.contains($0) }.count) / Double(pcs.count)
        let rootPresent = pcs.contains(sym.root) ? 1.0 : 0.0
        let covered = Double(chordPCs.intersection(Set(pcs)).count) / Double(max(1, chordPCs.count))
        let bassOK = (bassPC(frets) == sym.bassPitchClass) ? 1.0 : 0.0
        return 0.5 * inChord + 0.2 * rootPresent + 0.2 * covered + 0.1 * bassOK
    }

    /// Mismatch message or nil when consistent / not checkable.
    static func crossCheck(name: String, shape: ChordShape?) -> String? {
        guard let shape else { return nil }
        guard let sym = ChordNameNormalizer.symbol(name) else {
            return ChordNames.isNoChord(name) ? nil : "unparseable chord name \(name)"
        }
        if pitchClasses(shape.frets).isEmpty { return "chord diagram for \(name) has no sounding strings" }
        let fit = shapeFit(sym, shape.frets)
        return fit >= 0.75 ? nil : "diagram does not match name \(name) (fit \(String(format: "%.2f", fit)))"
    }

    /// Try other base frets when the name disagrees with the diagram.
    static func tryFix(name: String, shape: ChordShape?) -> ChordShape? {
        guard let shape, let sym = ChordNameNormalizer.symbol(name) else { return nil }
        let rel = shape.frets.map { $0 > 0 ? $0 - shape.baseFret + 1 : $0 }
        var best: (ChordShape, Double)?
        for b in 1...12 where b != shape.baseFret {
            let fr = rel.map { $0 > 0 ? $0 + b - 1 : $0 }
            let s = shapeFit(sym, fr)
            if s >= 0.95, s > (best?.1 ?? 0) { best = (ChordShape(frets: fr, baseFret: b), s) }
        }
        return best?.0
    }

    static let identifyQualities: [ChordSymbol.Quality] = [.major, .minor, .dom7, .min7, .maj7, .sus4, .sus2, .add9, .six, .dim, .aug, .dom9]

    /// Names a shape when the printed name was missed: exact pitch-class match, bass == root preferred.
    static func identify(frets: [Int]) -> String? {
        let pcs = Set(pitchClasses(frets))
        guard pcs.count >= 3, let bass = bassPC(frets) else { return nil }
        var best: (String, Int)?
        for root in 0..<12 {
            for q in identifyQualities {
                let s = ChordSymbol(root: root, quality: q)
                guard s.pitchClasses == pcs else { continue }
                let score = (root == bass ? 10 : 0) - identifyQualities.firstIndex(of: q)!
                if best == nil || score > best!.1 { best = (s.description, score) }
            }
        }
        return best?.0
    }
}
