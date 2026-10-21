import Foundation

// MARK: - Chord symbols
//
// Shared by importers (chord-line detection), timeline (voicings),
// playback, follower (chroma templates) and UI (transpose display).

public struct ChordSymbol: Hashable, Sendable, CustomStringConvertible {
    public enum Quality: String, CaseIterable, Sendable {
        case major = "", minor = "m", dim = "dim", aug = "aug"
        case sus2 = "sus2", sus4 = "sus4"
        case dom7 = "7", maj7 = "maj7", min7 = "m7", minMaj7 = "mM7", dim7 = "dim7", halfDim7 = "m7b5"
        case dom7sus4 = "7sus4", six = "6", min6 = "m6", add9 = "add9", minAdd9 = "madd9"
        case dom9 = "9", maj9 = "maj9", min9 = "m9", power = "5", dom11 = "11", dom13 = "13"
    }

    /// Root pitch class 0...11 (C = 0).
    public var root: Int
    public var quality: Quality
    /// Slash bass pitch class (C/G → 7). nil = root.
    public var bass: Int?
    /// Prefer flats when spelling (parsed from "Bb", or key context).
    public var preferFlats: Bool

    public init(root: Int, quality: Quality = .major, bass: Int? = nil, preferFlats: Bool = false) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
        self.bass = bass.map { (($0 % 12) + 12) % 12 }
        self.preferFlats = preferFlats
    }

    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    public static func noteName(_ pc: Int, preferFlats: Bool = false) -> String {
        let i = ((pc % 12) + 12) % 12
        return preferFlats ? flatNames[i] : sharpNames[i]
    }

    /// Parses a note name prefix ("C", "F#", "Bb", "C♯", "E♭"). Returns (pc, length, isFlat).
    static func parseNote(_ s: Substring) -> (Int, Int, Bool)? {
        guard let first = s.first else { return nil }
        let base: Int
        switch first.uppercased() {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        guard first.isUppercase else { return nil }
        var pc = base, len = 1, flat = false
        let rest = s.dropFirst()
        if let acc = rest.first {
            if acc == "#" || acc == "♯" { pc += 1; len += 1 }
            else if acc == "b" || acc == "♭" { pc -= 1; len += 1; flat = true }
        }
        return ((pc + 12) % 12, len, flat)
    }

    /// Quality aliases → canonical quality. Order matters (longest first).
    static let qualityAliases: [(String, Quality)] = [
        ("maj9", .maj9), ("maj7", .maj7), ("Maj7", .maj7), ("M7", .maj7), ("Δ7", .maj7), ("Δ", .maj7),
        ("mMaj7", .minMaj7), ("mM7", .minMaj7), ("m(maj7)", .minMaj7),
        ("m7b5", .halfDim7), ("m7-5", .halfDim7), ("ø7", .halfDim7), ("ø", .halfDim7),
        ("madd9", .minAdd9), ("m(add9)", .minAdd9),
        ("min7", .min7), ("m7", .min7), ("-7", .min7),
        ("min9", .min9), ("m9", .min9), ("min6", .min6), ("m6", .min6),
        ("min", .minor), ("m", .minor), ("-", .minor),
        ("dim7", .dim7), ("°7", .dim7), ("dim", .dim), ("°", .dim), ("o", .dim),
        ("aug", .aug), ("+", .aug),
        ("7sus4", .dom7sus4), ("7sus", .dom7sus4), ("sus4", .sus4), ("sus2", .sus2), ("sus", .sus4),
        ("add9", .add9), ("add2", .add9), ("(add9)", .add9), ("2", .add9),
        ("13", .dom13), ("11", .dom11), ("9", .dom9), ("7", .dom7), ("6", .six), ("5", .power),
        ("maj", .major), ("M", .major), ("", .major),
    ]

    /// Parses "Am7", "C/G", "F#m7b5", "Bbmaj7", "Dsus4", "G(add9)". Returns nil if not a chord.
    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var main = Substring(s)
        var bassPC: Int? = nil
        if let slash = s.lastIndex(of: "/") {
            let bassPart = s[s.index(after: slash)...]
            guard let (b, blen, _) = ChordSymbol.parseNote(bassPart), blen == bassPart.count else { return nil }
            bassPC = b
            main = s[..<slash]
        }
        guard let (root, len, flat) = ChordSymbol.parseNote(main) else { return nil }
        let qualityText = String(main.dropFirst(len))
        guard let q = ChordSymbol.qualityAliases.first(where: { $0.0 == qualityText })?.1 else { return nil }
        self.init(root: root, quality: q, bass: bassPC, preferFlats: flat)
    }

    /// Intervals (semitones above root) of the chord tones.
    public var intervals: [Int] {
        switch quality {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dim: return [0, 3, 6]
        case .aug: return [0, 4, 8]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .dom7: return [0, 4, 7, 10]
        case .maj7: return [0, 4, 7, 11]
        case .min7: return [0, 3, 7, 10]
        case .minMaj7: return [0, 3, 7, 11]
        case .dim7: return [0, 3, 6, 9]
        case .halfDim7: return [0, 3, 6, 10]
        case .dom7sus4: return [0, 5, 7, 10]
        case .six: return [0, 4, 7, 9]
        case .min6: return [0, 3, 7, 9]
        case .add9: return [0, 2, 4, 7]
        case .minAdd9: return [0, 2, 3, 7]
        case .dom9: return [0, 2, 4, 7, 10]
        case .maj9: return [0, 2, 4, 7, 11]
        case .min9: return [0, 2, 3, 7, 10]
        case .power: return [0, 7]
        case .dom11: return [0, 5, 7, 10]
        case .dom13: return [0, 4, 7, 9, 10]
        }
    }

    /// Pitch classes of chord tones (including slash bass).
    public var pitchClasses: Set<Int> {
        var s = Set(intervals.map { (root + $0) % 12 })
        if let bass { s.insert(bass) }
        return s
    }

    /// Lowest sounding pitch class.
    public var bassPitchClass: Int { bass ?? root }

    public func transposed(by semitones: Int, preferFlats: Bool? = nil) -> ChordSymbol {
        ChordSymbol(root: root + semitones, quality: quality, bass: bass.map { $0 + semitones },
                    preferFlats: preferFlats ?? self.preferFlats)
    }

    public var description: String {
        var s = ChordSymbol.noteName(root, preferFlats: preferFlats) + quality.rawValue
        if let bass { s += "/" + ChordSymbol.noteName(bass, preferFlats: preferFlats) }
        return s
    }

    /// Heuristic: is this whitespace-separated token a chord symbol (for chord-line detection)?
    public static func isChordToken(_ token: String) -> Bool { ChordSymbol(token) != nil }
}
