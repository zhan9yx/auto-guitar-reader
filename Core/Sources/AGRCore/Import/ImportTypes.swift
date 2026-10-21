import Foundation

// MARK: - Public import types

/// Errors thrown by the importers.
public enum ImportError: Error, Equatable {
    /// The format is recognised but not supported (e.g. compressed `.mxl`).
    case unsupportedFormat(String)
    /// The input contains no usable content.
    case empty
    /// The input is broken or does not look like the expected format.
    case malformed(String)
}

/// Formats that `ScoreImporter` can detect.
public enum ScoreFormat: String, Sendable { case agr, chordpro, chordText, asciiTab, musicXML }

/// Display-column width: CJK / full-width = 2, others = 1 (for chord-over-lyrics alignment).
public enum TextWidth {
    /// Total display columns of `s`. Combining marks / control characters count 0,
    /// East-Asian wide and full-width characters (and emoji) count 2, everything else 1.
    public static func columns(_ s: Substring) -> Int {
        var total = 0
        for ch in s { total += columns(of: ch) }
        return total
    }

    /// Convenience overload for `String`.
    public static func columns(_ s: String) -> Int { columns(s[...]) }

    /// Display columns of a single grapheme cluster.
    public static func columns(of ch: Character) -> Int {
        guard let scalar = ch.unicodeScalars.first else { return 0 }
        let v = scalar.value
        if v == 0x09 { return 1 }
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        for r in wideRanges where r.contains(v) { return 2 }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,    // Hangul Jamo
        0x2E80...0x303E,    // CJK radicals, ideographic space & punctuation
        0x3041...0x33FF,    // Kana, CJK symbols
        0x3400...0x4DBF,    // CJK extension A
        0x4E00...0x9FFF,    // CJK unified
        0xA000...0xA4CF,    // Yi
        0xAC00...0xD7A3,    // Hangul syllables
        0xF900...0xFAFF,    // CJK compatibility ideographs
        0xFE30...0xFE6F,    // CJK compatibility forms
        0xFF00...0xFF60,    // Full-width forms
        0xFFE0...0xFFE6,    // Full-width signs
        0x1F300...0x1F64F,  // Emoji
        0x1F900...0x1F9FF,  // Emoji (supplemental)
        0x20000...0x3FFFD,  // CJK extensions B...
    ]
}

// MARK: - OCR input types

/// One OCR text box. Boxes are normalized to the page: origin top-left, 0...1.
public struct OCRToken: Codable, Hashable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

/// OCR result of one page image.
public struct OCRPage: Codable, Hashable, Sendable {
    public var tokens: [OCRToken]
    public var imageFileName: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(tokens: [OCRToken], imageFileName: String? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.tokens = tokens
        self.imageFileName = imageFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
