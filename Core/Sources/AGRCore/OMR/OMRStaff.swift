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
        let minRun = max(24, w / 30)
        var rowSum = [Int](repeating: 0, count: h)
        var rowMin = [Int](repeating: Int.max, count: h)
        var rowMax = [Int](repeating: Int.min, count: h)
        for y in 0..<h {
            var x = 0
            var sum = 0
            while x < w {
                if bm.d[y * w + x] != 0 {
                    var e = x
                    while e < w && bm.d[y * w + e] != 0 { e += 1 }
                    // bridge tiny gaps (glyph halos)
                    while e < w - 3 && (bm.d[y * w + e + 1] != 0 || bm.d[y * w + e + 2] != 0) && e - x >= 6 {
                        var f = e
                        while f < w && bm.d[y * w + f] == 0 && f - e < 3 { f += 1 }
                        if f < w && bm.d[y * w + f] != 0 && f - e < 3 {
                            while f < w && bm.d[y * w + f] != 0 { f += 1 }
                            e = f
                        } else { break }
                    }
                    if e - x >= minRun {
                        sum += e - x
                        rowMin[y] = min(rowMin[y], x)
                        rowMax[y] = max(rowMax[y], e)
                    }
                    x = e
                } else { x += 1 }
            }
            rowSum[y] = sum
        }
        // candidate rows: at least 30% of the widest horizontal extent
        let maxSum = rowSum.max() ?? 0
        guard maxSum > 0 else { return [] }
        let thr = max(Double(maxSum) * 0.45, Double(minRun))
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
                lines.append(L(y: wy / wsum, t: last - y + 1, x0: x0, x1: x1, ya: y, yb: last))
                y = e
            } else { y += 1 }
        }
        var staves: [TabStaff] = []
        var i = 0
        while i + 5 < lines.count {
            let s = lines[i + 1].y - lines[i].y
            var ok = s >= 4 && s <= Double(h) / 6
            var chain = [i]
            if ok {
                for k in 1..<6 {
                    let expect = lines[i].y + Double(k) * s
                    guard let j = (chain.last! + 1..<lines.count).first(where: { abs(lines[$0].y - expect) <= max(2.0, 0.15 * s) }) else { ok = false; break }
                    chain.append(j)
                }
            }
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
        }
        return out
    }

    /// Full-height vertical lines across the staff -> barline structures (including edges).
    static func barlines(_ bm: Bitmap, staff st: TabStaff) -> [BarlineStructure] {
        let u = st.u
        let y0 = Int(st.top.rounded()), y1 = Int(st.bottom.rounded())
        var cols: [Int] = []
        for x in max(0, st.x0 - 3)..<min(bm.w, st.x1 + 3) {
            var gap = 0, maxGap = 0, n = 0
            for y in (y0 - 1)...(y1 + 1) where y >= 0 && y < bm.h {
                if bm.d[y * bm.w + x] != 0 { n += 1; maxGap = max(maxGap, gap); gap = 0 } else { gap += 1 }
            }
            maxGap = max(maxGap, gap)
            let total = y1 - y0 + 3
            if Double(n) >= 0.96 * Double(total) && maxGap <= 1 { cols.append(x) }
        }
        // group columns into runs
        var runs: [(Int, Int)] = []
        for c in cols {
            if let l = runs.last, c <= l.1 + 1 { runs[runs.count - 1].1 = c } else { runs.append((c, c)) }
        }
        // merge runs into structures when gap <= 0.9u
        var groups: [[(Int, Int)]] = []
        for r in runs {
            if var g = groups.last, Double(r.0 - g.last!.1) <= max(3, 0.9 * u) { g.append(r); groups[groups.count - 1] = g } else { groups.append([r]) }
        }
        let thickPx = max(3, Int((u * 0.22).rounded()))
        var out: [BarlineStructure] = []
        for g in groups {
            let x0 = g.first!.0, x1 = g.last!.1 + 1
            var bs = BarlineStructure(x0: x0, x1: x1, kind: .single, xAfter: Double(x1), xBefore: Double(x0))
            for r in g { if r.1 - r.0 + 1 >= thickPx { bs.thickCount += 1 } else { bs.thinCount += 1 } }
            // repeat dots: small blobs between lines 2-3 and 3-4 adjacent to the group
            func dotsNear(_ xa: Int, _ xb: Int) -> Bool {
                let ya = Int((st.lines[1] + st.lines[2]) / 2), yb = Int((st.lines[2] + st.lines[3]) / 2)
                // dots may straddle the gap between lines; count ink in boxes
                let n1 = bm.count(x0: xa, y0: ya - Int(u * 0.25), x1: xb, y1: ya + Int(u * 0.25) + 1)
                let n2 = bm.count(x0: xa, y0: yb - Int(u * 0.25), x1: xb, y1: yb + Int(u * 0.25) + 1)
                let minInk = max(3, Int(u * u * 0.04))
                return n1 >= minInk && n2 >= minInk
            }
            let dr = Int(u * 1.3)
            bs.hasDotsRight = dotsNear(x1 + 1, x1 + dr)
            bs.hasDotsLeft = dotsNear(x0 - dr, x0 - 1)
            if bs.hasDotsRight && bs.hasDotsLeft { bs.kind = .startEndRepeat }
            else if bs.hasDotsRight { bs.kind = .startRepeat }
            else if bs.hasDotsLeft { bs.kind = .endRepeat }
            else if g.count >= 2 { bs.kind = (bs.thickCount > 0 && bs.thinCount > 0 && g.last!.1 - g.last!.0 + 1 >= thickPx) ? .final : .double }
            else if bs.thickCount > 0 { bs.kind = .double }
            if bs.hasDotsRight { bs.xAfter = Double(x1 + dr) }
            if bs.hasDotsLeft { bs.xBefore = Double(x0 - dr) }
            out.append(bs)
        }
        return out
    }
}
