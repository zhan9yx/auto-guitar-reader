import Foundation

/// Glyph features: tight-bbox bitmap area-resampled to 12x16 (0...255) + aspect ratio.
enum OMRGlyphFeatures {
    static let fw = 12, fh = 16
    static var length: Int { fw * fh }

    /// Tight bounding box of ink inside the bitmap.
    static func tight(_ b: Bitmap) -> Bitmap {
        var x0 = b.w, y0 = b.h, x1 = -1, y1 = -1
        for y in 0..<b.h { for x in 0..<b.w where b.d[y * b.w + x] != 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        if x1 < 0 { return Bitmap(w: 0, h: 0) }
        return OMRVision.crop(b, IRect(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1))
    }

    /// (vector, aspect*100 clamped)
    static func vector(_ raw: Bitmap) -> (v: [UInt8], aspect: Int)? {
        let b = tight(raw)
        guard b.w > 0, b.h > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: fw * fh)
        for oy in 0..<fh {
            let ya = Double(oy) * Double(b.h) / Double(fh), yb = Double(oy + 1) * Double(b.h) / Double(fh)
            for ox in 0..<fw {
                let xa = Double(ox) * Double(b.w) / Double(fw), xb = Double(ox + 1) * Double(b.w) / Double(fw)
                var sum = 0.0, area = 0.0
                var y = Int(ya.rounded(.down))
                while Double(y) < yb && y < b.h {
                    let hy = min(yb, Double(y + 1)) - max(ya, Double(y))
                    var x = Int(xa.rounded(.down))
                    while Double(x) < xb && x < b.w {
                        let wx = min(xb, Double(x + 1)) - max(xa, Double(x))
                        let a = hy * wx
                        if b.d[y * b.w + x] != 0 { sum += a }
                        area += a
                        x += 1
                    }
                    y += 1
                }
                out[oy * fw + ox] = area > 0 ? UInt8(min(255, Int(sum / area * 255))) : 0
            }
        }
        return (out, min(255, Int(Double(b.w) / Double(b.h) * 100)))
    }
}

struct OMRGlyphTemplate { var label: String; var v: [UInt8]; var aspect: Int }

/// Nearest-centroid classifier (templates in GlyphTemplates.generated.swift).
struct OMRGlyphClassifier {
    enum Role { case tabDigit, jianpuDigit, other }
    static let shared = OMRGlyphClassifier(templates: OMRGlyphTemplates.load())
    var templates: [OMRGlyphTemplate]

    /// Returns (label, confidence 0...1) or nil if no templates / too far.
    func classify(_ b: Bitmap, role: Role, allowed: Set<String>? = nil) -> (String, Double)? {
        guard !templates.isEmpty, let f = OMRGlyphFeatures.vector(b) else { return nil }
        var best = Double.infinity, second = Double.infinity
        var bestLabel = ""
        var perLabel: [String: Double] = [:]
        for t in templates {
            if let a = allowed, !a.contains(t.label) { continue }
            var d = 0
            for i in 0..<f.v.count { d += abs(Int(f.v[i]) - Int(t.v[i])) }
            let dist = Double(d) / Double(f.v.count * 255) + 0.35 * Double(abs(f.aspect - t.aspect)) / 100.0
            if dist < (perLabel[t.label] ?? .infinity) { perLabel[t.label] = dist }
        }
        for (l, d) in perLabel {
            if d < best { second = best; best = d; bestLabel = l } else if d < second { second = d }
        }
        if bestLabel.isEmpty { return nil }
        // confidence: absolute closeness and margin to the runner-up
        let closeness = max(0, 1 - best / 0.45)
        let margin = second.isFinite ? min(1, (second - best) / 0.08) : 1
        return (bestLabel, min(closeness, 0.5 + 0.5 * margin))
    }
}
