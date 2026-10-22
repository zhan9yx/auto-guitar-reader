import Foundation

/// Optional debug recorder: rectangles / labels drawn over the (deskewed) page.
final class OMRTrace {
    struct Box { var r: IRect; var color: (UInt8, UInt8, UInt8); var text: String }
    var boxes: [Box] = []
    func add(_ r: IRect, _ c: (UInt8, UInt8, UInt8), _ t: String = "") { boxes.append(Box(r: r, color: c, text: t)) }
    var image: GrayImage?

    func ppm() -> Data? {
        guard let img = image else { return nil }
        var rgb = [UInt8](repeating: 0, count: img.width * img.height * 3)
        for i in 0..<img.pixels.count { rgb[3 * i] = img.pixels[i]; rgb[3 * i + 1] = img.pixels[i]; rgb[3 * i + 2] = img.pixels[i] }
        func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            guard x >= 0, y >= 0, x < img.width, y < img.height else { return }
            let o = 3 * (y * img.width + x); rgb[o] = c.0; rgb[o + 1] = c.1; rgb[o + 2] = c.2
        }
        for b in boxes {
            for x in b.r.x0...max(b.r.x0, b.r.x1 - 1) { put(x, b.r.y0, b.color); put(x, b.r.y1 - 1, b.color) }
            for y in b.r.y0...max(b.r.y0, b.r.y1 - 1) { put(b.r.x0, y, b.color); put(b.r.x1 - 1, y, b.color) }
        }
        var d = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
        d.append(contentsOf: rgb)
        return d
    }
}
