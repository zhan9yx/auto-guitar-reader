import Foundation

enum OMRDeskew {
    /// Estimates the slope `a = tan(phi)` of horizontal structures (y grows with x when a > 0), |phi| <= 3.5 degrees.
    static func estimateSlope(_ bm: Bitmap) -> Double {
        // sample ink pixels that belong to horizontal runs >= 12 px (staff lines, beams, underlines)
        var xs: [Float] = [], ys: [Float] = []
        let w = bm.w, h = bm.h
        for y in 0..<h {
            var x = 0
            while x < w {
                if bm.d[y * w + x] != 0 {
                    var e = x
                    while e < w && bm.d[y * w + e] != 0 { e += 1 }
                    if e - x >= 12 {
                        var k = x
                        while k < e { xs.append(Float(k)); ys.append(Float(y)); k += 3 }
                    }
                    x = e
                } else { x += 1 }
            }
        }
        guard xs.count > 200 else { return 0 }
        let cx = Float(w) / 2
        func score(_ a: Float) -> Double {
            var hist = [Int32](repeating: 0, count: h * 2 + 64)
            let off = Float(h / 2 + 32)
            for i in 0..<xs.count {
                let yy = Int(ys[i] - a * (xs[i] - cx) + off)
                if yy >= 0 && yy < hist.count { hist[yy] += 1 }
            }
            var s = 0.0
            for v in hist where v > 0 { s += Double(v) * Double(v) }
            return s
        }
        var best: Float = 0, bestS = score(0)
        var a: Float = -0.062
        while a <= 0.0625 { let s = score(a); if s > bestS { bestS = s; best = a }; a += 0.002 }
        var fine = best - 0.002
        let end = best + 0.002
        while fine <= end { let s = score(fine); if s > bestS { bestS = s; best = fine }; fine += 0.0004 }
        return abs(Double(best)) < 0.0008 ? 0 : Double(best)
    }

    static func rotate(_ img: GrayImage, slope a: Double, fill: UInt8) -> GrayImage {
        let phi = atan(a)
        let c = cos(phi), s = sin(phi)
        let cx = Double(img.width) / 2, cy = Double(img.height) / 2
        var out = GrayImage(width: img.width, height: img.height, fill: fill)
        let w = img.width, h = img.height
        img.pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                let dy = Double(y) - cy
                for x in 0..<w {
                    let dx = Double(x) - cx
                    let sx = cx + dx * c - dy * s, sy = cy + dx * s + dy * c
                    if sx < 0 || sy < 0 || sx >= Double(w - 1) || sy >= Double(h - 1) { continue }
                    let x0 = Int(sx), y0 = Int(sy)
                    let fx = sx - Double(x0), fy = sy - Double(y0)
                    let p00 = Double(src[y0 * w + x0]), p10 = Double(src[y0 * w + x0 + 1])
                    let p01 = Double(src[(y0 + 1) * w + x0]), p11 = Double(src[(y0 + 1) * w + x0 + 1])
                    let v = p00 * (1 - fx) * (1 - fy) + p10 * fx * (1 - fy) + p01 * (1 - fx) * fy + p11 * fx * fy
                    out.pixels[y * w + x] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }
        return out
    }

    /// Nearest-neighbour warp of a binary page. Bilinear resampling of the gray image turns
    /// one-pixel staff lines gray, and a second threshold then drops them.
    static func rotate(_ bm: Bitmap, slope a: Double) -> Bitmap {
        let phi = atan(a)
        let c = cos(phi), s = sin(phi)
        let cx = Double(bm.w) / 2, cy = Double(bm.h) / 2
        var out = Bitmap(w: bm.w, h: bm.h)
        let w = bm.w, h = bm.h
        for y in 0..<h {
            let dy = Double(y) - cy
            for x in 0..<w {
                let dx = Double(x) - cx
                let sx = cx + dx * c - dy * s
                let sy = cy + dx * s + dy * c
                let ix = Int(sx.rounded()), iy = Int(sy.rounded())
                if ix >= 0, iy >= 0, ix < w, iy < h, bm.d[iy * w + ix] != 0 { out.d[y * w + x] = 1 }
            }
        }
        return out
    }

    /// Maps a point from the original image frame to the deskewed frame.
    static func forward(x: Double, y: Double, slope a: Double, width: Int, height: Int) -> (Double, Double) {
        let phi = atan(a)
        let c = cos(phi), s = sin(phi)
        let cx = Double(width) / 2, cy = Double(height) / 2
        let sx = x - cx, sy = y - cy
        // inverse of: src = cx + dx c - dy s, cy + dx s + dy c  =>  dst = rotate by -phi
        return (cx + sx * c + sy * s, cy - sx * s + sy * c)
    }
}
