import Foundation

/// One detected six-line tab staff.
struct TabStaff {
    var lines: [Double]       // y centers, top (string 1) -> bottom (string 6)
    var thickness: Int
    var bands: [(Int, Int)] = []   // pixel row ranges (inclusive) of each line
    var x0: Int
    var x1: Int               // exclusive
    var u: Double { (lines[5] - lines[0]) / 5 }
    var top: Double { lines[0] }
    var bottom: Double { lines[5] }
}

struct BarlineStructure {
    var x0: Int, x1: Int          // pixel columns covered
    var kind: BarlineKind
    var cx: Double { Double(x0 + x1) / 2 }
    /// x where music starts after this structure / ends before it
    var xAfter: Double
    var xBefore: Double
    var hasDotsRight = false
    var hasDotsLeft = false
    var thickCount = 0
    var thinCount = 0
}

enum OMRStaffDetector {
    /// Finds six-line staves. Returns staves sorted top to bottom.
    static func detect(_ bm: Bitmap) -> [TabStaff] {
        let w = bm.w, h = bm.h
        // The absolute pixel limits below (line thickness, plausible string spacing) are for a page about 1000 px wide.
        let pageScale = Double(w) / 1000
        let minRun = max(24, w / 30)
        var rowSum = [Int](repeating: 0, count: h)
        var rowMin = [Int](repeating: Int.max, count: h)
        var rowMax = [Int](repeating: Int.min, count: h)
        var rowLongest = [Int](repeating: 0, count: h)
        let gapMax = max(3, Int(Double(w) * 0.011))
        for y in 0..<h {
            // raw ink runs
            var runs: [(Int, Int)] = []
            var x = 0
            while x < w {
                if bm.d[y * w + x] != 0 {
                    var e = x
                    while e < w && bm.d[y * w + e] != 0 { e += 1 }
                    runs.append((x, e)); x = e
                } else { x += 1 }
            }
            // merge across small gaps, keep groups that are dense and long
            var sum = 0
            var gi = 0
            while gi < runs.count {
                var gs = runs[gi].0, ge = runs[gi].1, ink = ge - gs
                var gj = gi + 1
                while gj < runs.count && runs[gj].0 - ge <= gapMax { ink += runs[gj].1 - runs[gj].0; ge = runs[gj].1; gj += 1 }
                let ext = ge - gs
                if ext >= minRun && Double(ext) >= 0.12 * Double(w) && Double(ink) >= 0.6 * Double(ext) {
                    sum += ink
                    rowLongest[y] = max(rowLongest[y], ext)
                    rowMin[y] = min(rowMin[y], gs)
                    rowMax[y] = max(rowMax[y], ge)
                }
                gs = 0; gi = gj
            }
            rowSum[y] = sum
        }
        // candidate rows: at least 30% of the widest horizontal extent
        let maxSum = rowSum.max() ?? 0
        guard maxSum > 0 else { return [] }
        let thr = max(Double(maxSum) * 0.22, Double(minRun) * 2)
        struct L { var y: Double; var t: Int; var x0: Int; var x1: Int; var ya: Int; var yb: Int }
        var lines: [L] = []
        var y = 0
        while y < h {
            if Double(rowSum[y]) >= thr {
                var e = y
                var wsum = 0.0, wy = 0.0
                var x0 = Int.max, x1 = Int.min
                var last = y
                while e < h && (Double(rowSum[e]) >= thr || (e - last <= 1 && e + 1 < h && Double(rowSum[e + 1]) >= thr)) {
                    if Double(rowSum[e]) >= thr { last = e; wsum += Double(rowSum[e]); wy += Double(rowSum[e]) * Double(e); x0 = min(x0, rowMin[e]); x1 = max(x1, rowMax[e]) }
                    e += 1
                }
                let thick = last - y + 1
                if thick <= Int((8 * max(1, pageScale)).rounded()) {
                    lines.append(L(y: wy / wsum, t: thick, x0: x0, x1: x1, ya: y, yb: last))
                } else {
                    // A gray watermark keeps the gaps between strings above `thr`, so one staff
                    // becomes a single ~200px band. The strings are still the thin spikes.
                    for p in thinStaffRows(y0: y, y1: last, rowSum: rowSum, rowMin: rowMin, rowMax: rowMax, maxSum: maxSum) {
                        lines.append(L(y: p.y, t: p.t, x0: p.x0, x1: p.x1, ya: p.ya, yb: p.yb))
                    }
                }
                y = e
            } else { y += 1 }
        }
        if OMRTrace.flag("OMR_DEBUG_STAFF") { FileHandle.standardError.write(Data("lines \(lines.map { String(format: "%.1f/%d", $0.y, $0.t) }) thr \(thr) maxSum \(maxSum) minRun \(minRun)\n".utf8)) }
        // String spacing is the common small gap (typically 8–40 px on a 1000 px wide page, scaled with the width). An equally spaced chain
        // several times that gap is text and staff lines mixed together, not a tab staff.
        let gaps = (0..<max(0, lines.count - 1)).map { lines[$0 + 1].y - lines[$0].y }
        let smallGaps = gaps.filter { $0 >= max(4, 8 * pageScale) && $0 <= 40 * pageScale }
        var pitch: Double?
        if smallGaps.count >= 4 {
            var bestN = 0
            var bestG = smallGaps[0]
            for g in smallGaps {
                let tol = max(1.5, 0.12 * g)
                let n = smallGaps.reduce(0) { $0 + (abs($1 - g) <= tol ? 1 : 0) }
                if n > bestN || (n == bestN && g < bestG) { bestN = n; bestG = g }
            }
            let tol = max(1.5, 0.12 * bestG)
            let cluster = smallGaps.filter { abs($0 - bestG) <= tol }.sorted()
            if cluster.count >= 4 { pitch = cluster[cluster.count / 2] }
        }
        var staves: [TabStaff] = []
        var i = 0
        while i + 5 < lines.count {
            let s = lines[i + 1].y - lines[i].y
            var ok = s >= 4 && s <= Double(h) / 6
            if let pitch, s > pitch * 2.5 || abs(s - pitch) > max(2.0, 0.25 * pitch) { ok = false }
            var chain = [i]
            if ok {
                for k in 1..<6 {
                    let sm = (lines[chain.last!].y - lines[i].y) / Double(k - 1 > 0 ? k - 1 : 1)
                    let expect = lines[chain.last!].y + (k == 1 ? s : sm)
                    guard let j = (chain.last! + 1..<lines.count).first(where: { abs(lines[$0].y - expect) <= max(2.0, 0.17 * s) }) else { ok = false; break }
                    chain.append(j)
                }
            }
            if OMRTrace.flag("OMR_DEBUG_STAFF") { FileHandle.standardError.write(Data("i \(i) s \(s) ok \(ok) chain \(chain)\n".utf8)) }
            if ok {
                let ls = chain.map { lines[$0] }
                let ys = ls.map { $0.y }
                let x0 = ls.map { $0.x0 }.sorted()[2], x1 = ls.map { $0.x1 }.sorted()[3]
                staves.append(TabStaff(lines: ys, thickness: max(1, ls.map { $0.t }.max() ?? 1), bands: ls.map { ($0.ya, $0.yb) }, x0: x0, x1: x1))
                i = chain.last! + 1
            } else { i += 1 }
        }
        return staves
    }

    /// Thin full-width spikes inside a band that the row threshold fused together.
    /// Each spike is a staff line; a solid block (watermark fill, diagram) is not.
    private static func thinStaffRows(y0: Int, y1: Int, rowSum: [Int], rowMin: [Int], rowMax: [Int], maxSum: Int) -> [(y: Double, t: Int, x0: Int, x1: Int, ya: Int, yb: Int)] {
        let floor = Double(maxSum) * 0.62
        var out: [(y: Double, t: Int, x0: Int, x1: Int, ya: Int, yb: Int)] = []
        var i = y0
        while i <= y1 {
            if Double(rowSum[i]) < floor { i += 1; continue }
            var e = i
            var best = i
            while e <= y1 && Double(rowSum[e]) >= floor {
                if rowSum[e] > rowSum[best] { best = e }
                e += 1
            }
            let peak = Double(rowSum[best])
            let left = (y0..<best).last(where: { Double(rowSum[$0]) < peak * 0.55 })
            let right = best < y1 ? ((best + 1)...y1).first(where: { Double(rowSum[$0]) < peak * 0.55 }) : nil
            let thinLeft = left.map { best - $0 <= 4 } ?? true
            let thinRight = right.map { $0 - best <= 4 } ?? (best == y1)
            if e - i <= 3, thinLeft, thinRight {
                var x0 = Int.max, x1 = Int.min
                for r in i..<e where rowMin[r] != Int.max {
                    x0 = min(x0, rowMin[r]); x1 = max(x1, rowMax[r])
                }
                if x1 > x0 { out.append((y: Double(best), t: e - i, x0: x0, x1: x1, ya: i, yb: e - 1)) }
            }
            i = e
        }
        return out
    }

    /// A blurred staff line keeps a row of ink just outside the detected band. Two strum
    /// heads on that shoulder join into one component wider than a shaft and the strum is
    /// dropped. A shoulder pixel with no stroke three rows further out is the line, not a glyph.
    private static func clearLineShoulders(_ bm: inout Bitmap, _ st: TabStaff) {
        let minRun = max(8, Int(0.7 * st.u))
        let xLo = max(0, st.x0), xHi = min(bm.w, st.x1)
        guard xHi > xLo else { return }
        for band in st.bands {
            let ya = band.0, yb = band.1
            for (y, dir) in [(ya - 1, -1), (ya - 2, -1), (yb + 1, 1), (yb + 2, 1)] {
                if y < 0 || y >= bm.h { continue }
                if st.bands.contains(where: { y >= $0.0 && y <= $0.1 }) { continue }
                var x = xLo
                while x < xHi {
                    if !bm.ink(x, y) { x += 1; continue }
                    var e = x + 1
                    var gap = 0
                    while e < xHi {
                        if bm.ink(e, y) { gap = 0; e += 1 }
                        else if gap == 0 && e + 1 < xHi && bm.ink(e + 1, y) { gap = 1; e += 1 }
                        else { break }
                    }
                    if e - x >= minRun {
                        // Only a one-pixel shoulder. A fret or an × continues away from the line.
                        let next = y + dir
                        for xx in x..<e where bm.ink(xx, y) {
                            if next < 0 || next >= bm.h || !bm.ink(xx, next) { bm[xx, y] = 0 }
                        }
                    }
                    x = e
                }
            }
        }
    }

    /// Removes staff lines from a copy of the bitmap (keeps glyph pixels that cross a line, heals thin crossings).
    static func removeLines(_ bm: Bitmap, staves: [TabStaff]) -> Bitmap {
        var out = bm
        for st in staves {
            for band in st.bands {
                let ya = band.0, yb = band.1
                let lo = max(0, ya - 1), hi = min(bm.h - 1, yb + 1)
                for x in max(0, st.x0)..<min(bm.w, st.x1) {
                    // vertical extent of ink attached above/below the band
                    var up = 0
                    var yy = lo
                    while yy >= 0 && bm.d[yy * bm.w + x] != 0 && up < 4 { up += 1; yy -= 1 }
                    var dn = 0
                    yy = hi
                    while yy < bm.h && bm.d[yy * bm.w + x] != 0 && dn < 4 { dn += 1; yy += 1 }
                    // note: lo/hi are band rows themselves when thickness is padded; recompute using true band
                    _ = up; _ = dn
                    var a = 0
                    yy = ya - 1
                    while yy >= 0 && bm.d[yy * bm.w + x] != 0 && a < 4 { a += 1; yy -= 1 }
                    var b = 0
                    yy = yb + 1
                    while yy < bm.h && bm.d[yy * bm.w + x] != 0 && b < 4 { b += 1; yy += 1 }
                    if a + b <= 2 {
                        for r in max(0, ya)...min(bm.h - 1, yb) { out.d[r * bm.w + x] = 0 }
                    }
                }
                // heal: restore band pixels bridging ink above and below
                for x in max(2, st.x0)..<min(bm.w - 2, st.x1) {
                    var above = false, below = false
                    for dx in -2...2 {
                        if out.ink(x + dx, ya - 1) || out.ink(x + dx, ya - 2) { above = true }
                        if out.ink(x + dx, yb + 1) || out.ink(x + dx, yb + 2) { below = true }
                    }
                    if above && below && bm.ink(x, ya) {
                        for r in max(0, ya)...min(bm.h - 1, yb) where bm.d[r * bm.w + x] != 0 { out.d[r * bm.w + x] = 1 }
                    }
                }
            }
            clearLineShoulders(&out, st)
        }
        return out
    }

    /// Rows of ink below the bottom staff line, walking the column. A barline ends on the
    /// line. A full-staff strum shaft continues into its stem for about 2u and then stops.
    /// The walk is capped so a system connector, which keeps going, is not a stem.
    static func tailBelow(_ bm: Bitmap, run r: (Int, Int), staff st: TabStaff) -> Int {
        let lim = Int(3.6 * st.u)
        var y = (st.bands.last?.1 ?? Int(st.bottom.rounded())) + 1
        var n = 0, gap = 0
        while n < lim {
            y += 1
            if y >= bm.h { break }
            var hit = false
            for x in (r.0 - 1)...(r.1 + 1) where bm.ink(x, y) { hit = true; break }
            if hit { n += 1; gap = 0 } else { gap += 1; if gap > 1 { break } }
        }
        return n
    }

    /// Stem-length continuation below the staff: a strum shaft, not a barline.
    static func isStrumShaft(_ bm: Bitmap, run r: (Int, Int), staff st: TabStaff) -> Bool {
        let n = tailBelow(bm, run: r, staff: st)
        return n >= Int(0.75 * st.u) && n < Int(3.6 * st.u)
    }

    /// Full-height vertical lines across the staff -> barline structures (including edges).
    /// `gray`, when it matches `bm`, closes holes of at most 3 rows where the barline is still
    /// darker than both neighbors but lighter than the line threshold. A stem gap is white, not a ridge.
    /// `contrast` is the page's background minus ink gray level; gray-level steps are fractions of it (nil: measured from `gray`).
    static func barlines(_ bm: Bitmap, dark: Bitmap? = nil, clean: Bitmap? = nil, staff st: TabStaff, gray: GrayImage? = nil,
                         contrast: Double? = nil) -> [BarlineStructure] {
        let u = st.u
        let y0 = Int(st.top.rounded()), y1 = Int(st.bottom.rounded())
        var cols: [Int] = []
        var weakCols = Set<Int>()
        let g = (gray != nil && gray!.width == bm.w && gray!.height == bm.h) ? gray : nil
        let ys = ((y0 + 2)...(y1 - 2)).filter { $0 >= 0 && $0 < bm.h }
        for x in max(0, st.x0 - 3)..<min(bm.w, st.x1 + 3) {
            var hits: [Bool] = []
            hits.reserveCapacity(ys.count)
            for y in ys {
                let hit = bm.d[y * bm.w + x] != 0 || (x > 0 && bm.d[y * bm.w + x - 1] != 0 && x + 1 < bm.w && bm.d[y * bm.w + x + 1] != 0)
                hits.append(hit)
            }
            if let g, x > 0, x + 1 < bm.w {
                var i = 0
                while i < hits.count {
                    if hits[i] { i += 1; continue }
                    var j = i
                    while j < hits.count && !hits[j] { j += 1 }
                    let sided = (i > 0 ? 1 : 0) + (j < hits.count ? 1 : 0)
                    if sided >= 1 && j - i > 0 && j - i <= 3 {
                        var ridge = true
                        for k in i..<j {
                            let y = ys[k]
                            let c = Int(g.pixels[y * g.width + x])
                            let l = Int(g.pixels[y * g.width + x - 1])
                            let r = Int(g.pixels[y * g.width + x + 1])
                            if c + 16 > l || c + 16 > r { ridge = false; break }
                        }
                        if ridge { for k in i..<j { hits[k] = true } }
                    }
                    i = j
                }
            }
            var gap = 0, maxGap = 0, n = 0
            for hit in hits {
                if hit { n += 1; maxGap = max(maxGap, gap); gap = 0 } else { gap += 1 }
            }
            maxGap = max(maxGap, gap)
            let total = y1 - y0 - 3
            var edgeGaps = 0
            for y in [y0, y0 + 1, y1 - 1, y1] where y >= 0 && y < bm.h && bm.d[y * bm.w + x] == 0 { edgeGaps += 1 }
            if OMRTrace.flag("OMR_DEBUG_COL"), let t = Int(OMRTrace.value("OMR_DEBUG_COL") ?? ""), abs(t - x) <= 1 { FileHandle.standardError.write(Data("col \(x) n \(n) total \(total) maxGap \(maxGap) edge \(edgeGaps) y \(y0)-\(y1)\n".utf8)) }
            if Double(n) >= 0.98 * Double(total) && maxGap <= 1 && edgeGaps <= 2 { cols.append(x) }
            // Antialiased hairlines of low-resolution scans lose a few rows. Such a column is accepted only if it is
            // clearly a full-height line, and (below, per run) it does not continue under the staff like a note stem.
            else if Double(n) >= 0.88 * Double(total) && maxGap <= 2 && edgeGaps <= 1 { cols.append(x); weakCols.insert(x) }
        }
        // group columns into runs
        var runs: [(Int, Int)] = []
        for c in cols {
            if let l = runs.last, c <= l.1 + 1 { runs[runs.count - 1].1 = c } else { runs.append((c, c)) }
        }
        if OMRTrace.flag("OMR_DEBUG_BAR") { FileHandle.standardError.write(Data("cols \(cols.count) runs \(runs) range \(max(0, st.x0 - 3))..<\(min(bm.w, st.x1 + 3)) y \(y0)-\(y1) bands \(st.bands)\n".utf8)) }
        // strum arrows: a vertical shaft with a wider arrow head at one end is not a barline
        runs = runs.filter { r in
            if (r.0...r.1).allSatisfy({ weakCols.contains($0) }) && tailBelow(bm, run: r, staff: st) > 1 { return false }
            if r.1 - r.0 > 5 { return true }
            let cx = (r.0 + r.1) / 2
            func width(atY y: Int) -> Int {
                var l = cx, rr = cx
                while l > cx - Int(2 * u) && dkInk(bm, dark, l - 1, y) { l -= 1 }
                while rr < cx + Int(2 * u) && dkInk(bm, dark, rr + 1, y) { rr += 1 }
                return rr - l + 1
            }
            var headW = 0
            // One row above the projection band is still the heavy line, not an arrow head.
            func inBand(_ y: Int) -> Bool { st.bands.contains { y >= $0.0 - 1 && y <= $0.1 } }
            for dy in Int(-0.45 * u)...Int(0.3 * u) {
                if !inBand(y0 + dy) { headW = max(headW, width(atY: y0 + dy)) }
                if !inBand(y1 - dy) { headW = max(headW, width(atY: y1 - dy)) }
            }
            var midY = (y0 + y1) / 2 + Int(0.5 * u)
            while inBand(midY) { midY += 1 }
            let midW = width(atY: midY)
            let keep = Double(headW) < Double(midW) + max(2.5, 0.17 * u)
            let shaft = isStrumShaft(bm, run: r, staff: st)
            if OMRTrace.flag("OMR_DEBUG_BAR") {
                FileHandle.standardError.write(Data(" run \(r.0)-\(r.1) head \(headW) mid \(midW) keep \(keep) shaft \(shaft) tailB \(tailBelow(bm, run: r, staff: st))\n".utf8))
            }
            return keep && !shaft
        }
        // merge runs into structures when gap <= 0.9u
        var groups: [[(Int, Int)]] = []
        for r in runs {
            if var g = groups.last, Double(r.0 - g.last!.1) <= max(3, 0.9 * u) { g.append(r); groups[groups.count - 1] = g } else { groups.append([r]) }
        }
        func darkWidth(_ r: (Int, Int)) -> Int {
            guard let dk = dark else { return r.1 - r.0 + 1 }
            var n = 0
            for x in r.0...r.1 {
                var c = 0
                for y in y0...y1 where dk.ink(x, y) { c += 1 }
                if Double(c) >= 0.9 * Double(y1 - y0 + 1) { n += 1 }
            }
            return n
        }
        // Mid-staff gray of a stroke. Lower is darker. -1 when gray is unavailable.
        func midGray(_ r: (Int, Int)) -> Int {
            guard let gimg = gray, gimg.width == bm.w, gimg.height == bm.h else { return -1 }
            let yA = max(0, (y0 + y1) / 2 - 2), yB = min(gimg.height - 1, (y0 + y1) / 2 + 2)
            var sum = 0, n = 0
            for x in r.0...r.1 {
                for y in yA...yB { sum += Int(gimg.pixels[y * gimg.width + x]); n += 1 }
            }
            return n > 0 ? sum / n : -1
        }
        // "Clearly darker" = 40 gray levels on a full-contrast (255) page, scaled to this page's contrast.
        let darkerStep: Double = {
            let c = contrast ?? gray.map { let l = OMRVision.levels($0); return l.bg - l.ink } ?? 255
            return max(4, 40.0 / 255.0 * c)
        }()
        var out: [BarlineStructure] = []
        for g in groups {
            let x0 = g.first!.0, x1 = g.last!.1 + 1
            var bs = BarlineStructure(x0: x0, x1: x1, kind: .single, xAfter: Double(x1), xBefore: Double(x0))
            // A blurred twin is only one column wider. A heavy stroke is two columns
            // wider than the narrowest in the group, or clearly darker than a thinner one.
            let stats = g.map { (w: darkWidth($0), g: midGray($0)) }
            let minW = stats.map(\.w).min() ?? 1
            var lastThick = false
            for s in stats {
                let wider = s.w >= minW + 2
                let darker = s.g >= 0 && stats.contains { $0.g >= 0 && $0.w < s.w && Double($0.g) >= Double(s.g) + darkerStep }
                if wider || darker { bs.thickCount += 1; lastThick = true } else { bs.thinCount += 1; lastThick = false }
            }
            // repeat dots: small blobs between lines 2-3 and 3-4 adjacent to the group
            func dotsNear(_ xa: Int, _ xb: Int) -> Bool {
                let cb = clean ?? bm
                let c1 = ((st.lines[1] + st.lines[2]) / 2), c2 = ((st.lines[3] + st.lines[4]) / 2)
                let r = Int((0.34 * u).rounded())
                // The clef letters sit in the same columns as the dots, so all ink in the window is not one blob.
                func dot(_ cy: Double) -> Bool {
                    let ya = Int(cy.rounded()) - r, yb = Int(cy.rounded()) + r
                    let xLo = max(0, xa), xHi = min(cb.w, xb)
                    guard xHi > xLo, yb > ya else { return false }
                    let ww = xHi - xLo, hh = yb - ya + 1
                    var seen = [Bool](repeating: false, count: ww * hh)
                    func at(_ x: Int, _ y: Int) -> Int { (y - ya) * ww + (x - xLo) }
                    for y in ya...yb {
                        for x in xLo..<xHi where cb.ink(x, y) && !seen[at(x, y)] {
                            var stack = [(x, y)]
                            seen[at(x, y)] = true
                            var n = 0, minx = x, maxx = x, miny = y, maxy = y
                            while let p = stack.popLast() {
                                n += 1
                                minx = min(minx, p.0); maxx = max(maxx, p.0); miny = min(miny, p.1); maxy = max(maxy, p.1)
                                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                                    let nx = p.0 + dx, ny = p.1 + dy
                                    if nx >= xLo, nx < xHi, ny >= ya, ny <= yb, cb.ink(nx, ny), !seen[at(nx, ny)] {
                                        seen[at(nx, ny)] = true
                                        stack.append((nx, ny))
                                    }
                                }
                            }
                            let bw = Double(maxx - minx + 1), bh = Double(maxy - miny + 1)
                            let cyb = Double(miny + maxy) / 2
                            // The 0.8u size limit was set on synthetic pages (blur + downscale spread a dot), and the
                            // clef beside a system-start repeat adds a column to the same component. Not calibrated on real images.
                            if n >= max(3, Int(u * u * 0.02)), bw <= 0.80 * u, bh <= 0.80 * u, bw >= 0.14 * u, bh >= 0.14 * u,
                               abs(cyb - cy) <= 0.28 * u, Double(n) >= 0.45 * bw * bh,
                               bw / bh >= 0.55, bw / bh <= 1.8 { return true }
                        }
                    }
                    return false
                }
                return dot(c1) && dot(c2)
            }
            let dr = Int(u * 1.15)
            bs.hasDotsRight = dotsNear(x1 + 1, x1 + dr)
            bs.hasDotsLeft = dotsNear(x0 - dr, x0 - 1)
            if bs.hasDotsRight && bs.hasDotsLeft { bs.kind = .startEndRepeat }
            else if bs.hasDotsRight { bs.kind = .startRepeat }
            else if bs.hasDotsLeft { bs.kind = .endRepeat }
            else if g.count >= 2 { bs.kind = (bs.thickCount > 0 && bs.thinCount > 0 && lastThick) ? .final : .double }
            if bs.hasDotsRight { bs.xAfter = Double(x1 + dr) }
            if bs.hasDotsLeft { bs.xBefore = Double(x0 - dr) }
            out.append(bs)
        }
        return out
    }
}

@inline(__always) private func dkInk(_ a: Bitmap, _ b: Bitmap?, _ x: Int, _ y: Int) -> Bool { (b ?? a).ink(x, y) }
