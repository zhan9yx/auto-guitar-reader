import Foundation

/// Binary image: 1 = ink.
struct Bitmap {
    var w: Int
    var h: Int
    var d: [UInt8]
    init(w: Int, h: Int) { self.w = w; self.h = h; d = [UInt8](repeating: 0, count: w * h) }
    @inline(__always) subscript(x: Int, y: Int) -> UInt8 {
        get { d[y * w + x] }
        set { d[y * w + x] = newValue }
    }
    @inline(__always) func ink(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && d[y * w + x] != 0 }

    /// Ink fraction etc. helpers over a rectangle.
    func count(x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        var n = 0
        for y in max(0, y0)..<max(max(0, y0), min(h, y1)) {
            for x in max(0, x0)..<max(max(0, x0), min(w, x1)) where d[y * w + x] != 0 { n += 1 }
        }
        return n
    }
}

struct IRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int   // x1,y1 exclusive
    var w: Int { x1 - x0 }
    var h: Int { y1 - y0 }
    var cx: Double { Double(x0 + x1) / 2 }
    var cy: Double { Double(y0 + y1) / 2 }
}

struct Component {
    var id: Int
    var rect: IRect
    var area: Int
}

struct Labeling {
    var labels: [Int32]     // 0 = background, otherwise component index + 1
    var comps: [Component]
    var w: Int
}

enum OMRVision {
    /// Gray level statistics: (background, ink) levels.
    static func levels(_ img: GrayImage) -> (bg: Double, ink: Double) {
        var hist = [Int](repeating: 0, count: 256)
        for p in img.pixels { hist[Int(p)] += 1 }
        let total = img.pixels.count
        var acc = 0, bg = 255
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc * 100 >= total * 30 { bg = v; break } } // robust bg: 70th pct from top
        // background = brightest mode region: use 90th percentile
        acc = 0
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc * 100 >= total * 50 { bg = v; break } }
        // ink = median of pixels darker than 0.5*bg
        let cut = Int(Double(bg) * 0.5)
        var n = 0
        for v in 0...cut { n += hist[v] }
        var ink = 0.0
        if n > 0 {
            var a = 0
            for v in 0...cut { a += hist[v]; if a * 2 >= n { ink = Double(v); break } }
        } else { ink = Double(cut) }
        return (Double(max(bg, 128)), ink)
    }

    /// Threshold between ink and background (pixels darker than this are ink).
    static func binarize(_ img: GrayImage, threshold: Int? = nil) -> (bm: Bitmap, threshold: Int, bg: Double, ink: Double) {
        let (bg, ink) = levels(img)
        let t = threshold ?? Int(ink + (bg - ink) * 0.55)
        var bm = Bitmap(w: img.width, h: img.height)
        for i in 0..<img.pixels.count where Int(img.pixels[i]) < t { bm.d[i] = 1 }
        return (bm, t, bg, ink)
    }

    static func label(_ bm: Bitmap) -> Labeling {
        let w = bm.w, h = bm.h
        var labels = [Int32](repeating: 0, count: w * h)
        var parent = [Int32](repeating: 0, count: 1)
        func find(_ a: Int32) -> Int32 {
            var r = a
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = a
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }
        parent[0] = 0
        for y in 0..<h {
            for x in 0..<w where bm.d[y * w + x] != 0 {
                var best: Int32 = 0
                func consider(_ xx: Int, _ yy: Int) {
                    guard xx >= 0, xx < w, yy >= 0 else { return }
                    let l = labels[yy * w + xx]
                    if l == 0 { return }
                    if best == 0 { best = l } else {
                        let a = find(best), b = find(l)
                        if a != b { if a < b { parent[Int(b)] = a } else { parent[Int(a)] = b }; best = min(a, b) }
                    }
                }
                consider(x - 1, y); consider(x - 1, y - 1); consider(x, y - 1); consider(x + 1, y - 1)
                if best == 0 {
                    parent.append(Int32(parent.count))
                    labels[y * w + x] = Int32(parent.count - 1)
                } else { labels[y * w + x] = find(best) }
            }
        }
        var remap = [Int32](repeating: -1, count: parent.count)
        var comps: [Component] = []
        for y in 0..<h {
            for x in 0..<w {
                let l = labels[y * w + x]
                if l == 0 { continue }
                let r = find(l)
                var m = remap[Int(r)]
                if m < 0 {
                    m = Int32(comps.count)
                    remap[Int(r)] = m
                    comps.append(Component(id: Int(m), rect: IRect(x0: x, y0: y, x1: x + 1, y1: y + 1), area: 0))
                }
                labels[y * w + x] = m + 1
                var c = comps[Int(m)]
                c.area += 1
                if x < c.rect.x0 { c.rect.x0 = x }
                if x + 1 > c.rect.x1 { c.rect.x1 = x + 1 }
                if y + 1 > c.rect.y1 { c.rect.y1 = y + 1 }
                comps[Int(m)] = c
            }
        }
        return Labeling(labels: labels, comps: comps, w: w)
    }

    /// Extract a component's bitmap (rect-sized, 1 = ink of that component).
    static func extract(_ lab: Labeling, _ c: Component) -> Bitmap {
        var b = Bitmap(w: c.rect.w, h: c.rect.h)
        for y in c.rect.y0..<c.rect.y1 {
            for x in c.rect.x0..<c.rect.x1 where lab.labels[y * lab.w + x] == Int32(c.id + 1) {
                b[x - c.rect.x0, y - c.rect.y0] = 1
            }
        }
        return b
    }

    /// Extract an arbitrary rect of a bitmap.
    static func crop(_ bm: Bitmap, _ r: IRect) -> Bitmap {
        let x0 = max(0, r.x0), y0 = max(0, r.y0), x1 = min(bm.w, r.x1), y1 = min(bm.h, r.y1)
        var b = Bitmap(w: max(0, x1 - x0), h: max(0, y1 - y0))
        if b.w == 0 || b.h == 0 { return b }
        for y in y0..<y1 { for x in x0..<x1 { b[x - x0, y - y0] = bm[x, y] } }
        return b
    }
}
