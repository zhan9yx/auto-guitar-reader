import Foundation
@testable import AGRCore

/// Tiny page painter for bitmap-level OMR tests: black ink on white, no antialiasing.
struct OMRCanvas {
    var img: GrayImage
    /// Gray level of everything drawn without an explicit value.
    var ink: UInt8 = 0
    init(width: Int, height: Int, paper: UInt8 = 255, ink: UInt8 = 0) {
        img = GrayImage(width: width, height: height, fill: paper)
        self.ink = ink
    }
    var width: Int { img.width }
    var height: Int { img.height }

    mutating func set(_ x: Int, _ y: Int, _ v: UInt8? = nil) {
        if x >= 0, y >= 0, x < img.width, y < img.height { img[x, y] = v ?? ink }
    }
    mutating func rect(x0: Int, y0: Int, x1: Int, y1: Int, _ v: UInt8? = nil) {
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 { for x in x0..<x1 { set(x, y, v) } }
    }
    /// Horizontal line, `t` pixels thick, centred on `y`.
    mutating func hline(x0: Int, x1: Int, y: Int, t: Int = 2) { rect(x0: x0, y0: y - t / 2, x1: x1, y1: y - t / 2 + t) }
    /// Vertical line, `t` pixels wide, centred on `x`.
    mutating func vline(x: Int, y0: Int, y1: Int, t: Int = 2) { rect(x0: x - t / 2, y0: y0, x1: x - t / 2 + t, y1: y1) }
    /// Thick straight stroke.
    mutating func stroke(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, t: Double = 2) {
        let n = Int(max(abs(bx - ax), abs(by - ay)) * 2) + 1
        for i in 0...n {
            let f = Double(i) / Double(n)
            let x = ax + (bx - ax) * f, y = ay + (by - ay) * f
            for dy in 0..<Int(t.rounded(.up)) { for dx in 0..<Int(t.rounded(.up)) { set(Int(x) + dx - Int(t) / 2, Int(y) + dy - Int(t) / 2) } }
        }
    }
    /// An × centred on (cx, cy), `size` pixels square.
    mutating func cross(cx: Int, cy: Int, size: Int, t: Double = 2) {
        let h = Double(size) / 2
        stroke(Double(cx) - h, Double(cy) - h, Double(cx) + h, Double(cy) + h, t: t)
        stroke(Double(cx) - h, Double(cy) + h, Double(cx) + h, Double(cy) - h, t: t)
    }
    /// Filled disc.
    mutating func disc(cx: Int, cy: Int, r: Int) {
        for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { set(x, y) } }
    }
    /// Ring (stroke width 2) centred on (cx, cy).
    mutating func ring(cx: Int, cy: Int, r: Int) {
        for y in (cy - r - 1)...(cy + r + 1) { for x in (cx - r - 1)...(cx + r + 1) {
            let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
            if d2 <= (r + 1) * (r + 1) && d2 >= (r - 1) * (r - 1) { set(x, y) }
        } }
    }
}

/// A six-line tab staff drawn on a canvas, with measures separated by barlines.
struct OMRTabFixture {
    var canvas: OMRCanvas
    let u = 14
    let top = 60
    let x0 = 20
    let x1: Int
    var bottom: Int { top + 5 * u }
    func lineY(_ string: Int) -> Int { top + (string - 1) * u }

    init(width: Int = 520, height: Int = 220, paper: UInt8 = 255, ink: UInt8 = 0) {
        canvas = OMRCanvas(width: width, height: height, paper: paper, ink: ink)
        x1 = width - 20
        for s in 1...6 { canvas.hline(x0: x0, x1: x1, y: lineY(s)) }
    }
    mutating func bar(x: Int, t: Int = 2) { canvas.vline(x: x, y0: top - 1, y1: bottom + 2, t: t) }
    /// An × on `string` with a plain stem under the staff (a quarter strum).
    mutating func crossWithStem(x: Int, string: Int) {
        canvas.cross(cx: x, cy: lineY(string), size: 10)
        canvas.vline(x: x, y0: bottom + 3, y1: bottom + 3 + Int(1.7 * Double(u)))
    }
    /// A short dash between two strings: a printed rest.
    mutating func rest(x: Int, betweenStrings s: Int) {
        let y = (lineY(s) + lineY(s + 1)) / 2
        canvas.rect(x0: x - 5, y0: y - 2, x1: x + 5, y1: y + 2)
    }
    func page() -> PageResult {
        OMRPage.process(page: 0, image: canvas.img, ocr: [], options: OMROptions())
    }
}

extension OMRCanvas {
    /// Draws a jianpu digit by rendering the classifier's own prototype (12x16 cells, thresholded) at `h` pixels tall.
    /// Returns the drawn box (x0, x1 exclusive). Test glyphs are the classifier's centroids, not real print.
    @discardableResult
    mutating func digit(_ label: String, x: Int, top: Int, h: Int) -> (x0: Int, x1: Int) {
        let protos = JianpuClassifier.shared.protos.filter { $0.label == label }.sorted { $0.aspect < $1.aspect }
        guard let p = protos.isEmpty ? nil : protos[protos.count / 2] else { return (x, x) }
        let w = max(3, Int((Double(h) * Double(p.aspect) / 100).rounded()))
        for yy in 0..<h {
            for xx in 0..<w {
                let cx = min(OMRGlyphFeatures.fw - 1, xx * OMRGlyphFeatures.fw / w), cy = min(OMRGlyphFeatures.fh - 1, yy * OMRGlyphFeatures.fh / h)
                if p.v[cy * OMRGlyphFeatures.fw + cx] >= 128 { set(x + xx, top + yy) }
            }
        }
        return (x, x + w)
    }
}

/// Tab fixture with a numbered-notation row under the staff.
struct OMRJianpuFixture {
    var tab: OMRTabFixture
    let digitTop: Int
    let digitH = 22
    init(width: Int = 520, height: Int = 300, paper: UInt8 = 255, ink: UInt8 = 0) {
        tab = OMRTabFixture(width: width, height: height, paper: paper, ink: ink)
        digitTop = tab.bottom + 34
    }
    /// A digit at x (left edge). Returns its box.
    @discardableResult
    mutating func note(_ label: String, x: Int) -> (x0: Int, x1: Int) { tab.canvas.digit(label, x: x, top: digitTop, h: digitH) }
    mutating func underline(x0: Int, x1: Int, level: Int = 1) {
        for l in 0..<level { tab.canvas.hline(x0: x0, x1: x1, y: digitTop + digitH + 4 + 4 * l, t: 2) }
    }
    func page() -> PageResult { tab.page() }
}
