import Foundation

// MARK: - Chord name normalization
//
// Printed chord names on Chinese 弹唱谱 sites are not always plain symbols:
//   "D7(5)" / "G7(3)"  – the number in parentheses is the string carrying the bass / a fingering variant.
//                        Harmonically it is just D7 / G7; the written name stays for display.
//   "D(7)"             – optional seventh (D, or D7): treated as D7.
//   "Ｃ", "Ａm７", "B♭", "F♯m" – full-width characters and ♯/♭ glyphs.
// `ChordNameNormalizer` maps such names to a `ChordSymbol` plus the extracted extras.

public struct NormalizedChordName: Hashable, Sendable {
    /// Name as written (trimmed), for display.
    public var written: String
    /// Chord used for harmony / voicing; nil for "N.C." or unparseable names.
    public var symbol: ChordSymbol?
    /// Number in parentheses that denotes a string / fingering variant ("D7(5)" → 5).
    public var variant: Int?
    /// Parenthesised optional extension that was folded into `symbol` ("D(7)" → "7").
    public var optionalExtension: String?
    /// Canonical, enharmonic-insensitive comparison key (e.g. "D7(5)", "D7?", "C/G"); the folded text for unknown names.
    public var key: String
}

public enum ChordNameNormalizer {
    public static func normalize(_ written: String) -> NormalizedChordName {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = foldWidth(trimmed).filter { !$0.isWhitespace }
        func result(_ sym: ChordSymbol?, variant: Int? = nil, ext: String? = nil) -> NormalizedChordName {
            var k = folded
            if let sym {
                var plain = sym
                plain.preferFlats = false
                k = plain.description
                if let variant { k += "(\(variant))" }
                if ext != nil { k += "?" }
            }
            return NormalizedChordName(written: trimmed, symbol: sym, variant: variant, optionalExtension: ext, key: k)
        }
        let upper = folded.uppercased()
        if folded.isEmpty || upper == "N.C." || upper == "NC" || upper == "N.C" { return result(nil) }

        if let open = folded.lastIndex(of: "("), folded.hasSuffix(")"), open != folded.startIndex {
            let base = String(folded[..<open])
            let inner = String(folded[folded.index(after: open)..<folded.index(before: folded.endIndex)])
            if !inner.isEmpty, inner.allSatisfy(\.isNumber), inner.count <= 2, let n = Int(inner) {
                if let sym = parse(base) {
                    if let (ext, s) = optionalExtension(base: base, symbol: sym, inner: inner) { return result(s, ext: ext) }
                    return result(sym, variant: n)
                }
            } else if !inner.isEmpty {
                for candidate in [base + inner, base + "(" + inner + ")"] {
                    if let s = parse(candidate) { return result(s) }
                }
                if let s = parse(base) { return result(s) }
            }
        }
        return result(parse(folded))
    }

    /// Chord symbol for a printed name (nil for N.C. / unparseable).
    public static func symbol(_ written: String) -> ChordSymbol? { normalize(written).symbol }

    /// Comparison key (see `NormalizedChordName.key`).
    public static func key(_ written: String) -> String { normalize(written).key }

    // MARK: Internals

    private static func optionalExtension(base: String, symbol: ChordSymbol, inner: String) -> (String, ChordSymbol)? {
        switch (inner, symbol.quality) {
        case ("7", .major), ("7", .minor):
            return parse(base + "7").map { ("7", $0) }
        case ("7", .sus4):
            return parse(base.replacingOccurrences(of: "sus4", with: "7sus4")).map { ("7", $0) }
        case ("9", .major):
            return parse(base + "add9").map { ("9", $0) }
        case ("9", .minor):
            return parse(base + "add9").map { ("9", $0) }
        default:
            return nil
        }
    }

    private static func parse(_ s: String) -> ChordSymbol? {
        if let c = ChordSymbol(s) { return c }
        // Lower-case root ("am", "d7", "f#m").
        if let f = s.first, "abcdefg".contains(f) {
            let fixed = f.uppercased() + s.dropFirst()
            if let c = ChordSymbol(fixed) { return c }
        }
        // Slash chord with a lower-case bass ("C/g").
        if let slash = s.lastIndex(of: "/") {
            let bass = s[s.index(after: slash)...]
            if let f = bass.first, "abcdefg".contains(f) {
                let fixed = s[...slash] + f.uppercased() + bass.dropFirst()
                if let c = ChordSymbol(String(fixed)) { return c }
            }
        }
        // "-5" style flat five on a minor seventh etc. is not supported; "M7"/"maj7" are in the alias table.
        return nil
    }

    /// Full-width ASCII → ASCII, ♯/♭ → #/b, typographic dashes → "-", ideographic space → space, natural sign removed.
    public static func foldWidth(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFF01...0xFF5E: out.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0x3000: out.append(" ")
            case 0x266F: out.append("#")          // ♯
            case 0x266D: out.append("b")          // ♭
            case 0x266E: break                    // ♮
            case 0x2212, 0x2013, 0x2014: out.append("-")
            case 0x2018, 0x2019: out.append("'")
            default: out.append(u)
            }
        }
        return String(out)
    }
}
