import Foundation

/// Prototype classifier for glyphs of the numbered-notation row: digits "0"..."7", accidentals "#" / "b",
/// parentheses "(" / ")" and "o" (anything else: stems, lyric characters, ...).
/// Prototypes are k-means centroids of the 12x16 glyph features (`OMRGlyphFeatures`) of synthetic training pages
/// (`OMRJianpuTemplates.generated.swift`, produced by `agr-tool omr-jianpu-train` + a k-means pass).
struct JianpuClassifier: Sendable {
    struct Proto: Sendable { var label: String; var v: [UInt8]; var aspect: Int }
    struct Result: Sendable {
        var label: String
        /// Normalised L1 distance to the nearest prototype of `label` (0 = identical, ~0.5 = unrelated).
        var dist: Double
        /// Distance of the runner-up label minus `dist`.
        var margin: Double
    }

    static let shared = JianpuClassifier(protos: OMRJianpuTemplates.load())
    var protos: [Proto]

    var isEmpty: Bool { protos.isEmpty }

    /// Best distance per label.
    func distances(_ b: Bitmap, allowed: Set<String>? = nil) -> [(String, Double)] {
        guard let f = OMRGlyphFeatures.vector(b) else { return [] }
        return distances(vector: f.v, aspect: f.aspect, allowed: allowed)
    }

    func distances(vector: [UInt8], aspect: Int, allowed: Set<String>? = nil) -> [(String, Double)] {
        var per: [String: Double] = [:]
        for p in protos {
            if let a = allowed, !a.contains(p.label) { continue }
            var d = 0
            for i in 0..<vector.count { d += abs(Int(vector[i]) - Int(p.v[i])) }
            let dist = Double(d) / Double(vector.count * 255) + 0.35 * Double(abs(aspect - p.aspect)) / 100.0
            if dist < (per[p.label] ?? .infinity) { per[p.label] = dist }
        }
        return per.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    func classify(_ b: Bitmap, allowed: Set<String>? = nil) -> Result? {
        let d = distances(b, allowed: allowed)
        guard let first = d.first else { return nil }
        let second = d.count > 1 ? d[1].1 : first.1 + 0.2
        return Result(label: first.0, dist: first.1, margin: second - first.1)
    }

    static let digitLabels: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7"]
}

enum OMRJianpuTemplates {
    /// Lines "label:hex(192):aspect".
    static func load() -> [JianpuClassifier.Proto] {
        var out: [JianpuClassifier.Proto] = []
        out.reserveCapacity(OMRJianpuTemplateData.lines.count)
        for l in OMRJianpuTemplateData.lines {
            let p = l.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 3 else { continue }
            let hex = Array(p[1].utf8)
            var v = [UInt8](repeating: 0, count: hex.count / 2)
            func nib(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c - 48 }
            for i in 0..<v.count { v[i] = nib(hex[2 * i]) << 4 | nib(hex[2 * i + 1]) }
            if v.count == OMRGlyphFeatures.length { out.append(.init(label: String(p[0]), v: v, aspect: Int(p[2]) ?? 100)) }
        }
        return out
    }
}
