import Foundation

// Additive helpers for the v2 notation-system types (see Score.swift). No stored state.

extension ScoreMeta {
    /// Pitch class (0...11, C = 0) of the numbered-notation tonic ("1 = ...") derived from `key`.
    /// Accepts "C", "Bb", "F#", "1=D", "1=♭B", "Key: G". A minor key ("Am") maps to its relative major
    /// (jianpu is written "1 = C" for A minor), so "Am" → 0. Unknown / missing → 0 (C).
    public var tonicPitchClass: Int {
        guard var k = key?.trimmingCharacters(in: .whitespaces), !k.isEmpty else { return 0 }
        k = ChordNameNormalizer.foldWidth(k)
        if let eq = k.firstIndex(of: "=") { k = String(k[k.index(after: eq)...]) }
        if k.lowercased().hasPrefix("key") {
            k = String(k.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: ": ="))
        }
        // "♭B" / "bB" prefix style (flat before the letter).
        var shift = 0
        if let f = k.first, f == "b" || f == "#", k.dropFirst().first?.isUppercase == true {
            shift = f == "b" ? -1 : 1
            k.removeFirst()
        }
        guard let sym = ChordSymbol(k) else { return 0 }
        var pc = sym.root + shift
        if [.minor, .min7, .min6, .min9].contains(sym.quality) { pc += 3 }
        return ((pc % 12) + 12) % 12
    }
}

extension NotationMeasure {
    /// Length in beats (`beats` or the given default).
    public func length(default d: Double) -> Double { max(beats ?? d, 0) }

    /// Lyric syllable of `note` for `verse`, clamped to the verses this measure actually has ("" if none).
    public func lyric(of note: MelodyNote, verse: Int) -> String {
        guard !note.lyrics.isEmpty, verseCount > 0 else { return "" }
        let v = min(max(verse, 0), verseCount - 1)
        return v < note.lyrics.count ? note.lyrics[v] : ""
    }
}

extension ChordShape {
    /// The shape as a `Voicing` (nil unless it has six frets).
    public var voicing: Voicing? { frets.count == 6 ? Voicing(frets: frets) : nil }
}

extension Line {
    /// Convenience for building `.system` lines.
    public static func system(_ system: NotationSystem, id: String = UUID().uuidString, anchor: PageAnchor? = nil) -> Line {
        Line(id: id, kind: .system, anchor: anchor, system: system)
    }
}
