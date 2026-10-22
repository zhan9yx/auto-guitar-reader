import Foundation

// MARK: - Pixel-level watermark removal + QR detection

extension OMRWatermark {
    public struct CleanReport: Sendable {
        public var overlayPixels = 0
        public var colorPixels = 0
        public var qrBoxes: [[Int]] = []         // x0, y0, x1, y1
        public var background = 255
        public var ink = 0
    }

    /// Removes pale / semi-transparent overlays, tiled logos and QR codes, keeping dark and thin (<= 4 px) notation.
    ///
    /// - A pixel is notation when it is dark (`<= ink + 0.45 (bg - ink)`) or belongs to a thin stroke: pixels noticeably darker
    ///   than the paper are grouped into horizontal / vertical runs, and a pixel whose shorter run is <= 4 px is part of a thin
    ///   line, glyph stroke or anti-aliasing fringe (staff lines, barlines, stems, beams, digits, text).
    /// - Every other non-paper pixel (wide, not dark = watermark stroke / logo body) is set to the paper level.
    /// - With `rgb`, pale coloured pixels (saturation > 0.12, not dark) are removed as well.
    public static func clean(_ img: GrayImage, rgb: OMRRGBImage? = nil, removeQR: Bool = true, thinLimit: Int = 4) -> (image: GrayImage, report: CleanReport) {
        let w = img.width, h = img.height
        var rep = CleanReport()
        guard w > 8, h > 8 else { return (img, rep) }
        let (bg, ink) = OMRVision.levels(img)
        rep.background = Int(bg); rep.ink = Int(ink)
        let darkThr = ink + 0.56 * (bg - ink)
        let paleThr = bg - max(7.0, 0.04 * (bg - ink))
        let px = img.pixels
        var nonBg = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where Double(px[i]) < paleThr { nonBg[i] = true }
        var hrun = [Int16](repeating: 0, count: w * h)
        var vrun = [Int16](repeating: 0, count: w * h)
        for y in 0..<h {
            var x = 0
            while x < w {
                if nonBg[y * w + x] {
                    var e = x
                    while e < w && nonBg[y * w + e] { e += 1 }
                    let l = Int16(min(e - x, 30000))
                    for xx in x..<e { hrun[y * w + xx] = l }
                    x = e
                } else { x += 1 }
            }
        }
        for x in 0..<w {
            var y = 0
            while y < h {
                if nonBg[y * w + x] {
                    var e = y
                    while e < h && nonBg[e * w + x] { e += 1 }
                    let l = Int16(min(e - y, 30000))
                    for yy in y..<e { vrun[yy * w + x] = l }
                    y = e
                } else { y += 1 }
            }
        }
        var out = img
        let paper = UInt8(max(0, min(255, bg)))
        var overlay = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where nonBg[i] && Double(px[i]) > darkThr && min(hrun[i], vrun[i]) > Int16(thinLimit) {
            overlay[i] = true
        }
        // anti-aliasing fringe of dark strokes stays
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where overlay[y * w + x] {
                var nearDark = false
                for dy in -1...1 { for dx in -1...1 where Double(px[(y + dy) * w + x + dx]) <= darkThr { nearDark = true } }
                if nearDark { overlay[y * w + x] = false }
            }
        }
        // close one-pixel gaps around removed regions (anti-aliased edges of wide strokes)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where nonBg[y * w + x] && !overlay[y * w + x] && Double(px[y * w + x]) > darkThr {
                if overlay[y * w + x - 1] && overlay[y * w + x + 1] || overlay[(y - 1) * w + x] && overlay[(y + 1) * w + x] { overlay[y * w + x] = true }
            }
        }
        for i in 0..<(w * h) where overlay[i] { out.pixels[i] = paper; rep.overlayPixels += 1 }

        // coloured pale overlays
        if let c = rgb, c.width == w, c.height == h {
            for i in 0..<(w * h) where out.pixels[i] != paper {
                let r = Int(c.pixels[3 * i]), g = Int(c.pixels[3 * i + 1]), b = Int(c.pixels[3 * i + 2])
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let sat = mx == 0 ? 0 : Double(mx - mn) / Double(mx)
                if sat > 0.12 && Double(out.pixels[i]) > darkThr { out.pixels[i] = paper; rep.colorPixels += 1 }
            }
        }
        if removeQR {
            let bm = OMRVision.binarize(out, threshold: Int(ink + 0.55 * (bg - ink))).bm
            for r in detectQR(bm) {
                rep.qrBoxes.append([r.x0, r.y0, r.x1, r.y1])
                for y in max(0, r.y0)..<min(h, r.y1) { for x in max(0, r.x0)..<min(w, r.x1) { out.pixels[y * w + x] = paper } }
            }
        }
        return (out, rep)
    }

    // MARK: QR finder patterns

    struct Finder { var x: Double, y: Double, m: Double }

    /// 1:1:3:1:1 finder patterns -> QR code bounding boxes.
    static func detectQR(_ bm: Bitmap) -> [IRect] {
        var cands: [Finder] = []
        let w = bm.w, h = bm.h
        func ratioOK(_ r: [Int]) -> Double? {
            let tot = r.reduce(0, +)
            guard tot >= 7, tot <= 120 else { return nil }
            let m = Double(tot) / 7
            let tol = max(0.6, m * 0.55)
            if abs(Double(r[0]) - m) <= tol, abs(Double(r[1]) - m) <= tol, abs(Double(r[2]) - 3 * m) <= 3 * tol, abs(Double(r[3]) - m) <= tol, abs(Double(r[4]) - m) <= tol { return m }
            return nil
        }
        for y in stride(from: 0, to: h, by: 1) {
            // runs along the row
            var runs: [(start: Int, len: Int, ink: Bool)] = []
            var x = 0
            while x < w {
                let v = bm.d[y * w + x] != 0
                var e = x
                while e < w && (bm.d[y * w + e] != 0) == v { e += 1 }
                runs.append((x, e - x, v)); x = e
            }
            guard runs.count >= 5 else { continue }
            for i in 0...(runs.count - 5) where runs[i].ink {
                let r = (0..<5).map { runs[i + $0].len }
                guard let m = ratioOK(r) else { continue }
                let cx = Double(runs[i + 2].start) + Double(runs[i + 2].len) / 2
                // vertical check through the centre
                let col = Int(cx)
                let y0 = max(0, y - Int(8 * m)), y1 = min(h - 1, y + Int(8 * m))
                var cur = bm.d[y0 * w + col] != 0, len = 0
                var vruns: [(start: Int, len: Int, ink: Bool)] = []
                var start = y0
                for k in y0...y1 {
                    let v = bm.d[k * w + col] != 0
                    if v == cur { len += 1 } else { vruns.append((start, len, cur)); start = k; cur = v; len = 1 }
                }
                vruns.append((start, len, cur))
                guard vruns.count >= 5 else { continue }
                for j in 0...(vruns.count - 5) where vruns[j].ink {
                    let rr = (0..<5).map { vruns[j + $0].len }
                    if let m2 = ratioOK(rr), abs(m2 - m) <= 0.6 * m + 1, vruns[j + 2].start <= y, vruns[j + 2].start + vruns[j + 2].len >= y {
                        cands.append(Finder(x: cx, y: Double(vruns[j + 2].start) + Double(vruns[j + 2].len) / 2, m: (m + m2) / 2))
                    }
                }
            }
        }
        // merge candidates
        var merged: [Finder] = []
        for c in cands {
            if let i = merged.firstIndex(where: { hypot($0.x - c.x, $0.y - c.y) < 2.5 * max($0.m, c.m) }) {
                let n = merged[i]; merged[i] = Finder(x: (n.x + c.x) / 2, y: (n.y + c.y) / 2, m: (n.m + c.m) / 2)
            } else { merged.append(c) }
        }
        // triplets forming an L
        var boxes: [IRect] = []
        for a in merged.indices {
            for b in merged.indices where b > a {
                for c in merged.indices where c > b {
                    let p = [merged[a], merged[b], merged[c]]
                    let m = p.map { $0.m }.sorted()
                    guard m[2] <= 1.6 * m[0] + 1 else { continue }
                    // find the corner (right angle)
                    for k in 0..<3 {
                        let o = p[k], q = p[(k + 1) % 3], r = p[(k + 2) % 3]
                        let d1 = hypot(q.x - o.x, q.y - o.y), d2 = hypot(r.x - o.x, r.y - o.y)
                        guard d1 > 14 * m[0], abs(d1 - d2) <= 0.2 * max(d1, d2) else { continue }
                        let dot = (q.x - o.x) * (r.x - o.x) + (q.y - o.y) * (r.y - o.y)
                        guard abs(dot) <= 0.25 * d1 * d2 else { continue }
                        let fx = q.x + r.x - o.x, fy = q.y + r.y - o.y
                        let xs = [o.x, q.x, r.x, fx], ys = [o.y, q.y, r.y, fy]
                        let pad = 4.5 * m[1]
                        let box = IRect(x0: max(0, Int(xs.min()! - pad)), y0: max(0, Int(ys.min()! - pad)), x1: min(bm.w, Int(xs.max()! + pad)), y1: min(bm.h, Int(ys.max()! + pad)))
                        // plausibility: size, module count and the dense, balanced ink of a QR matrix
                        let side = Double(max(box.w, box.h))
                        guard side <= 0.34 * Double(min(bm.w, bm.h)), side / m[1] >= 21, side / m[1] <= 150 else { break }
                        let area = box.w * box.h
                        guard area > 0 else { break }
                        let dens = Double(bm.count(x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1)) / Double(area)
                        guard dens >= 0.28, dens <= 0.72 else { break }
                        // horizontal transitions per row ~ modules / 2
                        var trans = 0, rowsChecked = 0
                        for yy in stride(from: box.y0 + box.h / 4, to: box.y1 - box.h / 4, by: max(1, box.h / 12)) {
                            rowsChecked += 1
                            var prev = bm.ink(box.x0, yy)
                            for xx in box.x0..<box.x1 { let v = bm.ink(xx, yy); if v != prev { trans += 1; prev = v } }
                        }
                        let perRow = rowsChecked == 0 ? 0 : Double(trans) / Double(rowsChecked)
                        guard perRow >= 0.25 * (Double(box.w) / m[1]) else { break }
                        boxes.append(box)
                        break
                    }
                }
            }
        }
        // drop duplicates (keep the largest of overlapping boxes)
        var out: [IRect] = []
        for b in boxes.sorted(by: { $0.w * $0.h > $1.w * $1.h }) where !out.contains(where: { o in
            max(o.x0, b.x0) < min(o.x1, b.x1) && max(o.y0, b.y0) < min(o.y1, b.y1) }) { out.append(b) }
        return out
    }
}
