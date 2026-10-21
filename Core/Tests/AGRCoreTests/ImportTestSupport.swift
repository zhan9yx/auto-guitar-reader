import Foundation
import XCTest
@testable import AGRCore

/// Shared helpers for the Import* test files.
enum ImportTestSupport {
    /// All lines of a score, flattened.
    static func allLines(_ score: Score) -> [Line] { score.sections.flatMap(\.lines) }

    /// `[chord]text` rendering of a lyrics/chords line (same syntax ChordPro uses).
    static func render(_ line: Line) -> String {
        line.segments.map { ($0.chord.map { "[\($0)]" } ?? "") + $0.text }.joined()
    }

    /// Builds a chord line by placing chords at display columns.
    static func chordLine(_ chords: [(Int, String)]) -> String {
        var out = ""
        var col = 0
        for (c, name) in chords.sorted(by: { $0.0 < $1.0 }) {
            if c > col { out += String(repeating: " ", count: c - col); col = c }
            out += name
            col += name.count
        }
        return out
    }

    static func hexData(_ hex: String) -> Data {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return data
    }

    /// Minimal OCR token with a box derived from font size (normalized units).
    static func token(_ text: String, x: Double, y: Double, w: Double? = nil, h: Double = 0.02) -> OCRToken {
        let cols = Double(max(1, TextWidth.columns(text[...])))
        return OCRToken(text: text, x: x, y: y, width: w ?? cols * h * 0.5, height: h, confidence: 0.95)
    }
}
