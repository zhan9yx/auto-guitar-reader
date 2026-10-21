import Foundation

// MARK: - Voicing (chord → guitar fingering)
//
// A voicing is six absolute frets (low E → high E, -1 = muted) *relative to the capo*
// (i.e. the shape the player reads). Sounding pitch = tuning[i] + capo + fret.

public struct Voicing: Hashable, Sendable, CustomStringConvertible {
    /// 6 entries, low → high string, -1 = muted, 0 = open.
    public var frets: [Int]

    public init(frets: [Int]) {
        self.frets = frets
    }

    /// Parses a compact shape string such as "x32010" ('x' = muted, single digits only).
    public init?(_ text: String) {
        var out: [Int] = []
        for ch in text.lowercased() {
            if ch == "x" { out.append(-1) }
            else if let d = ch.wholeNumberValue { out.append(d) }
            else { return nil }
        }
        guard out.count == 6 else { return nil }
        self.frets = out
    }

    /// Sounding MIDI notes, low → high, muted strings skipped.
    public func midiNotes(tuning: [Int], capo: Int) -> [Int] {
        stringNotes(tuning: tuning, capo: capo).map(\.midi)
    }

    /// (string index 0 = lowest, midi) for each played string, low → high.
    public func stringNotes(tuning: [Int], capo: Int) -> [(string: Int, midi: Int)] {
        var out: [(string: Int, midi: Int)] = []
        for i in 0..<min(frets.count, tuning.count) where frets[i] >= 0 {
            out.append((i, tuning[i] + capo + frets[i]))
        }
        return out
    }

    /// Indices of played strings, low → high.
    public var playedStrings: [Int] { frets.indices.filter { frets[$0] >= 0 } }

    public var description: String {
        frets.map { $0 < 0 ? "x" : ($0 > 9 ? "(\($0))" : String($0)) }.joined()
    }
}

public enum VoicingLibrary {
    /// Standard-tuning open strings, used for shape computation (shapes are tuning-relative to standard).
    static let standard = ScoreMeta.standardTuning

    /// chordDefinitions override (when `written` matches a key) → built-in open-chord table
    /// → movable barre shapes (E-form / A-form, lower fret position wins) → generic root/5th/3rd stack.
    /// Slash chords put the bass note on the lowest playable string.
    public static func voicing(for chord: ChordSymbol,
                               definitions: [String: ChordShape] = [:],
                               written: String? = nil) -> Voicing {
        if let w = written?.trimmingCharacters(in: .whitespaces),
           let shape = definitions[w], shape.frets.count == 6 {
            return Voicing(frets: shape.frets)
        }
        if let exact = openTable[key(chord)] { return exact }
        var plain = chord
        plain.bass = nil
        let base: Voicing = openTable[key(plain)] ?? movable(for: plain)
        if let b = chord.bass, b != chord.root {
            return applyBass(b, to: base, chord: chord)
        }
        return base
    }

    // MARK: Open-chord table

    static func key(_ c: ChordSymbol) -> String {
        let b = (c.bass == nil || c.bass == c.root) ? -1 : c.bass!
        return "\(c.root)|\(c.quality.rawValue)|\(b)"
    }

    static let openTable: [String: Voicing] = {
        let raw: [(String, String)] = [
            ("C", "x32010"), ("D", "xx0232"), ("E", "022100"), ("G", "320003"), ("A", "x02220"),
            ("Am", "x02210"), ("Em", "022000"), ("Dm", "xx0231"),
            ("E7", "020100"), ("A7", "x02020"), ("D7", "xx0212"), ("G7", "320001"), ("C7", "x32310"), ("B7", "x21202"),
            ("Cmaj7", "x32000"), ("Fmaj7", "xx3210"), ("Gmaj7", "320002"), ("Amaj7", "x02120"), ("Dmaj7", "xx0222"),
            ("Emaj7", "021100"),
            ("Am7", "x02010"), ("Em7", "022030"), ("Dm7", "xx0211"), ("Bm7", "x20202"),
            ("Dsus4", "xx0233"), ("Asus4", "x02230"), ("Esus4", "022200"),
            ("Dsus2", "xx0230"), ("Asus2", "x02200"), ("Gsus4", "330013"),
            ("Cadd9", "x32030"), ("Gadd9", "320203"), ("Aadd9", "x02420"),
            ("C6", "x32210"), ("G6", "320000"), ("A6", "x02222"), ("E6", "022120"),
            ("Em6", "022020"), ("Am6", "x02212"),
            ("A7sus4", "x02030"), ("D7sus4", "xx0213"), ("E7sus4", "020200"),
            ("F", "133211"), ("Fm", "133111"), ("Bm", "x24432"), ("F#m", "244222"), ("B", "x24442"),
            ("Bb", "x13331"), ("C#m", "x46654"), ("Gm", "355333"), ("Cm", "x35543"),
            ("F7", "131211"), ("Bm7b5", "x2323x"),
            // slash chords
            ("G/B", "x20003"), ("C/G", "332010"), ("D/F#", "200232"), ("Am/G", "302210"),
            ("C/E", "032010"), ("Am/E", "002210"), ("D/A", "x00232"), ("E/G#", "422100"),
            ("G/F#", "2x0003"), ("Em/B", "x22000"), ("Em/D", "xx0000"), ("Dm/F", "1x0231"),
            ("Fmaj7/C", "x33210"), ("F/C", "x33211"), ("A/C#", "x42220"), ("G/D", "xx0003"),
            ("Am7/G", "302010"), ("D/C", "x30232"),
        ]
        var out: [String: Voicing] = [:]
        for (name, shape) in raw {
            guard let c = ChordSymbol(name), let v = Voicing(shape) else { continue }
            // First definition wins (so the table above can list preferred forms first).
            if out[key(c)] == nil { out[key(c)] = v }
        }
        return out
    }()

    // MARK: Movable shapes

    /// Shape templates relative to the barre fret; -1 = muted. Nonnegative entries are offset by the barre fret.
    static let eForm: [ChordSymbol.Quality: [Int]] = [
        .major: [0, 2, 2, 1, 0, 0], .minor: [0, 2, 2, 0, 0, 0], .dom7: [0, 2, 0, 1, 0, 0],
        .maj7: [0, 2, 1, 1, 0, 0], .min7: [0, 2, 0, 0, 0, 0], .sus4: [0, 2, 2, 2, 0, 0],
        .six: [0, 2, 2, 1, 2, 0], .min6: [0, 2, 2, 0, 2, 0], .dom7sus4: [0, 2, 0, 2, 0, 0],
        .dom9: [0, 2, 0, 1, 0, 2], .aug: [0, 3, 2, 1, 1, 0], .power: [0, 2, 2, -1, -1, -1],
    ]
    static let aForm: [ChordSymbol.Quality: [Int]] = [
        .major: [-1, 0, 2, 2, 2, 0], .minor: [-1, 0, 2, 2, 1, 0], .dom7: [-1, 0, 2, 0, 2, 0],
        .maj7: [-1, 0, 2, 1, 2, 0], .min7: [-1, 0, 2, 0, 1, 0], .sus4: [-1, 0, 2, 2, 3, 0],
        .sus2: [-1, 0, 2, 2, 0, 0], .six: [-1, 0, 2, 2, 2, 2], .min6: [-1, 0, 2, 2, 1, 2],
        .dim: [-1, 0, 1, 2, 1, -1], .halfDim7: [-1, 0, 1, 0, 1, -1], .dim7: [-1, 0, 1, 2, 1, 2],
        .aug: [-1, 0, 3, 2, 2, 1], .add9: [-1, 0, 2, 4, 2, 0], .minAdd9: [-1, 0, 2, 4, 1, 0],
        .dom9: [-1, 0, 2, 4, 2, 3], .maj9: [-1, 0, 2, 1, 0, 0], .minMaj7: [-1, 0, 2, 1, 1, 0],
        .dom7sus4: [-1, 0, 2, 0, 3, 0], .power: [-1, 0, 2, 2, -1, -1],
    ]

    /// Quality used when no template exists for the exact one.
    static func simplified(_ q: ChordSymbol.Quality) -> ChordSymbol.Quality {
        switch q {
        case .min9: return .min7
        case .dom11: return .dom7sus4
        case .dom13: return .dom7
        case .maj9: return .maj7
        case .minAdd9: return .minor
        case .add9: return .major
        case .sus2: return .sus4
        case .dim, .halfDim7, .dim7: return .minor
        case .minMaj7: return .minor
        default: return .major
        }
    }

    static func movable(for chord: ChordSymbol) -> Voicing {
        var quality = chord.quality
        for _ in 0..<3 {
            let e = eForm[quality], a = aForm[quality]
            if e != nil || a != nil {
                return pick(root: chord.root, e: e, a: a)
            }
            quality = simplified(quality)
        }
        // Generic root + fifth + third stack.
        let minor = chord.intervals.contains(3)
        return pick(root: chord.root, e: eForm[minor ? .minor : .major], a: aForm[minor ? .minor : .major])
    }

    private static func pick(root: Int, e: [Int]?, a: [Int]?) -> Voicing {
        let fE = (root - 4 + 12) % 12   // E-form: root on 6th string
        let fA = (root - 9 + 12) % 12   // A-form: root on 5th string
        func build(_ t: [Int], _ f: Int) -> Voicing { Voicing(frets: t.map { $0 < 0 ? -1 : $0 + f }) }
        switch (e, a) {
        case let (e?, a?):
            return fE <= fA ? build(e, fE) : build(a, fA)
        case let (e?, nil):
            return build(e, fE)
        case let (nil, a?):
            return build(a, fA)
        default:
            return Voicing(frets: [-1, -1, -1, -1, -1, -1])
        }
    }

    // MARK: Slash bass

    /// Puts `bass` (pitch class) on the lowest playable string near the voicing's position and mutes lower strings.
    static func applyBass(_ bass: Int, to v: Voicing, chord: ChordSymbol) -> Voicing {
        var frets = v.frets
        let played = frets.filter { $0 >= 0 }
        guard !played.isEmpty else { return v }
        // Already the lowest note?
        if let low = frets.indices.first(where: { frets[$0] >= 0 }),
           (standard[low] + frets[low]) % 12 == bass { return v }
        let fretted = played.filter { $0 > 0 }
        let lo = fretted.min() ?? 0
        let hi = max(played.max() ?? 0, 0)
        for s in 0..<5 {
            let f = ((bass - standard[s]) % 12 + 12) % 12
            let ok = f == 0 || (f >= lo - 2 && f <= max(hi, 3))
            guard ok else { continue }
            var out = frets
            for i in 0..<s { out[i] = -1 }
            out[s] = f
            // Fill a contiguous muted run above the bass with open strings that are chord tones.
            var i = s + 1
            let tones = chord.pitchClasses
            while i < 6, out[i] < 0, tones.contains(standard[i] % 12) { out[i] = 0; i += 1 }
            return Voicing(frets: out)
        }
        frets = v.frets
        return Voicing(frets: frets)
    }
}
