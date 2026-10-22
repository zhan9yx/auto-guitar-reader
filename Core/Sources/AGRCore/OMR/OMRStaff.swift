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
                lines.append(L(y: wy / wsum, t: last - y + 1, x0: x0, x1: x1, ya: y, yb: last))
                y = e
            } else { y += 1 }
        }
        if ProcessInfo.processInfo.environment["OMR_DEBUG_STAFF"] != nil { FileHandle.standardError.write(Data("lines \(lines.map { String(format: "%.1f/%d", $0.y, $0.t) }) thr \(thr) maxSum \(maxSum) minRun \(minRun)\n".utf8)) }
        var staves: [TabStaff] = []
        var i = 0
        while i + 5 < lines.count {
            let s = lines[i + 1].y - lines[i].y
            var ok = s >= 4 && s <= Double(h) / 6
            var chain = [i]
            if ok {
                for k in 1..<6 {
                    let sm = (lines[chain.last!].y - lines[i].y) / Double(k - 1 > 0 ? k - 1 : 1)
                    let expect = lines[chain.last!].y + (k == 1 ? s : sm)
                    guard let j = (chain.last! + 1..<lines.count).first(where: { abs(lines[$0].y - expect) <= max(2.0, 0.17 * s) }) else { ok = false; break }
                    chain.append(j)
                }
            }
            if ProcessInfo.processInfo.environment["OMR_DEBUG_STAFF"] != nil { FileHandle.standardError.write(Data("i \(i) s \(s) ok \(ok) chain \(chain)\n".utf8)) }
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
    static func barlines(_ bm: Bitmap, dark: Bitmap? = nil, staff st: TabStaff) -> [BarlineStructure] {
        let u = st.u
        let y0 = Int(st.top.rounded()), y1 = Int(st.bottom.rounded())
        var cols: [Int] = []
        for x in max(0, st.x0 - 3)..<min(bm.w, st.x1 + 3) {
            var gap = 0, maxGap = 0, n = 0
            for y in (y0 + 2)...(y1 - 2) where y >= 0 && y < bm.h {
                if bm.d[y * bm.w + x] != 0 { n += 1; maxGap = max(maxGap, gap); gap = 0 } else { gap += 1 }
            }
            maxGap = max(maxGap, gap)
            let total = y1 - y0 - 3
            var edgeGaps = 0
            for y in [y0, y0 + 1, y1 - 1, y1] where y >= 0 && y < bm.h && bm.d[y * bm.w + x] == 0 { edgeGaps += 1 }
            if Double(n) >= 0.98 * Double(total) && maxGap <= 1 && edgeGaps <= 2 { cols.append(x) }
        }
        // group columns into runs
        var runs: [(Int, Int)] = []
        for c in cols {
            if let l = runs.last, c <= l.1 + 1 { runs[runs.count - 1].1 = c } else { runs.append((c, c)) }
        }
        if ProcessInfo.processInfo.environment["OMR_DEBUG_BAR"] != nil { FileHandle.standardError.write(Data("cols \(cols.suffix(8)) runs \(runs.suffix(5)) range \(max(0, st.x0 - 3))..<\(min(bm.w, st.x1 + 3)) y \(y0)-\(y1)\n".utf8)) }
        // strum arrows: a vertical shaft with a wider arrow head at one end is not a barline
        runs = runs.filter { r in
            if r.1 - r.0 > 5 { return true }
            let cx = (r.0 + r.1) / 2
            func width(atY y: Int) -> Int {
                var l = cx, rr = cx
                while l > cx - Int(2 * u) && dkInk(bm, dark, l - 1, y) { l -= 1 }
                while rr < cx + Int(2 * u) && dkInk(bm, dark, rr + 1, y) { rr += 1 }
                return rr - l + 1
            }
            var headW = 0
            func inBand(_ y: Int) -> Bool { st.bands.contains { y >= $0.0 && y <= $0.1 } }
            for dy in Int(-0.45 * u)...Int(0.3 * u) {
                if !inBand(y0 + dy) { headW = max(headW, width(atY: y0 + dy)) }
                if !inBand(y1 - dy) { headW = max(headW, width(atY: y1 - dy)) }
            }
            var midY = (y0 + y1) / 2 + Int(0.5 * u)
            while inBand(midY) { midY += 1 }
            let midW = width(atY: midY)
            return Double(headW) < Double(midW) + max(2.5, 0.17 * u)
        }
        // merge runs into structures when gap <= 0.9u
        var groups: [[(Int, Int)]] = []
        for r in runs {
            if var g = groups.last, Double(r.0 - g.last!.1) <= max(3, 0.9 * u) { g.append(r); groups[groups.count - 1] = g } else { groups.append([r]) }
        }
        let thickPx = max(3, Int((u * 0.22).rounded()))
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
        var out: [BarlineStructure] = []
        for g in groups {
            let x0 = g.first!.0, x1 = g.last!.1 + 1
            var bs = BarlineStructure(x0: x0, x1: x1, kind: .single, xAfter: Double(x1), xBefore: Double(x0))
            var lastThick = false
            for r in g { if darkWidth(r) >= thickPx { bs.thickCount += 1; lastThick = true } else { bs.thinCount += 1; lastThick = false } }
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
            else if g.count >= 2 { bs.kind = (bs.thickCount > 0 && bs.thinCount > 0 && lastThick) ? .final : .double }
            else if bs.thickCount > 0 { bs.kind = .double }
            if bs.hasDotsRight { bs.xAfter = Double(x1 + dr) }
            if bs.hasDotsLeft { bs.xBefore = Double(x0 - dr) }
            out.append(bs)
        }
        return out
    }
}

@inline(__always) private func dkInk(_ a: Bitmap, _ b: Bitmap?, _ x: Int, _ y: Int) -> Bool { (b ?? a).ink(x, y) }
