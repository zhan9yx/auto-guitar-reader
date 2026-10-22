import Foundation

// MARK: - AGR Score (standardized, script-readable score format)
//
// Serialized as JSON ("agr-score", version 1). See docs/SCORE_FORMAT.md.
// This file is the contract shared by importers, timeline, playback,
// follower and UI. Change it only together with the docs and a version bump.

public struct Score: Codable, Identifiable, Hashable, Sendable {
    public static let formatID = "agr-score"
    public static let currentVersion = 2

    public var format: String
    public var version: Int
    public var id: UUID
    public var meta: ScoreMeta
    /// Chord fingerings keyed by chord symbol as written (e.g. "Am", "G/B").
    public var chordDefinitions: [String: ChordShape]
    public var strumPatterns: [StrumPattern]
    public var sections: [Section]
    /// Play order as section ids (repeats allowed). nil = `sections` in order.
    public var arrangement: [String]?
    /// Original page images (image/PDF imports). Files live next to score.json.
    public var pages: [PageImage]

    public init(
        id: UUID = UUID(),
        meta: ScoreMeta = ScoreMeta(),
        chordDefinitions: [String: ChordShape] = [:],
        strumPatterns: [StrumPattern] = [],
        sections: [Section] = [],
        arrangement: [String]? = nil,
        pages: [PageImage] = []
    ) {
        self.format = Score.formatID
        self.version = Score.currentVersion
        self.id = id
        self.meta = meta
        self.chordDefinitions = chordDefinitions
        self.strumPatterns = strumPatterns
        self.sections = sections
        self.arrangement = arrangement
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey {
        case format, version, id, meta, chordDefinitions, strumPatterns, sections, arrangement, pages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Score.formatID
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Score.currentVersion
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        meta = try c.decodeIfPresent(ScoreMeta.self, forKey: .meta) ?? ScoreMeta()
        chordDefinitions = try c.decodeIfPresent([String: ChordShape].self, forKey: .chordDefinitions) ?? [:]
        strumPatterns = try c.decodeIfPresent([StrumPattern].self, forKey: .strumPatterns) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        arrangement = try c.decodeIfPresent([String].self, forKey: .arrangement)
        pages = try c.decodeIfPresent([PageImage].self, forKey: .pages) ?? []
    }

    /// Sections in play order (arrangement expanded; unknown ids skipped).
    public var playOrder: [Section] {
        guard let arrangement, !arrangement.isEmpty else { return sections }
        let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return arrangement.compactMap { byID[$0] }
    }
}

public enum PlayMode: String, Codable, CaseIterable, Sendable {
    /// 弹唱: chords + lyrics, strummed accompaniment with singing.
    case strumSing
    /// 指弹: fingerstyle, note-level tablature.
    case fingerstyle
}

public struct TimeSignature: Codable, Hashable, Sendable {
    public var beats: Int
    public var unit: Int
    public init(beats: Int = 4, unit: Int = 4) {
        self.beats = beats
        self.unit = unit
    }
}

public enum SourceKind: String, Codable, Sendable {
    case agr, chordpro, chordText, asciiTab, musicXML, guitarPro, image, pdf, manual
}

public struct ScoreSource: Codable, Hashable, Sendable {
    public var kind: SourceKind
    public var fileName: String?
    public var importedAt: Date?
    public init(kind: SourceKind, fileName: String? = nil, importedAt: Date? = nil) {
        self.kind = kind
        self.fileName = fileName
        self.importedAt = importedAt
    }
}

public struct ScoreMeta: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String?
    public var composer: String?
    public var lyricist: String?
    public var arranger: String?
    /// Original key as written, e.g. "G", "Em". (原调)
    public var key: String?
    /// Capo fret (变调夹). Sounding pitch = written chord shape + capo.
    public var capo: Int
    /// Tempo in BPM (quarter = unit of `timeSignature`).
    public var tempo: Double
    public var timeSignature: TimeSignature
    /// Open-string MIDI notes, low (6th string) → high (1st string).
    public var tuning: [Int]
    public var mode: PlayMode
    public var source: ScoreSource?
    public var tags: [String]
    /// Non-musical text found on the page and kept for reference (credits like "制谱：…").
    /// Watermarks / site ads are dropped by importers, not stored here.
    public var credits: [String]

    public static let standardTuning = [40, 45, 50, 55, 59, 64]

    public init(
        title: String = "",
        artist: String? = nil,
        composer: String? = nil,
        lyricist: String? = nil,
        arranger: String? = nil,
        key: String? = nil,
        capo: Int = 0,
        tempo: Double = 80,
        timeSignature: TimeSignature = TimeSignature(),
        tuning: [Int] = ScoreMeta.standardTuning,
        mode: PlayMode = .strumSing,
        source: ScoreSource? = nil,
        tags: [String] = [],
        credits: [String] = []
    ) {
        self.title = title
        self.artist = artist
        self.composer = composer
        self.lyricist = lyricist
        self.arranger = arranger
        self.key = key
        self.capo = capo
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.tuning = tuning
        self.mode = mode
        self.source = source
        self.tags = tags
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey {
        case title, artist, composer, lyricist, arranger, key, capo, tempo, timeSignature, tuning, mode, source, tags, credits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        composer = try c.decodeIfPresent(String.self, forKey: .composer)
        lyricist = try c.decodeIfPresent(String.self, forKey: .lyricist)
        arranger = try c.decodeIfPresent(String.self, forKey: .arranger)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        capo = try c.decodeIfPresent(Int.self, forKey: .capo) ?? 0
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? 80
        timeSignature = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? TimeSignature()
        tuning = try c.decodeIfPresent([Int].self, forKey: .tuning) ?? ScoreMeta.standardTuning
        mode = try c.decodeIfPresent(PlayMode.self, forKey: .mode) ?? .strumSing
        source = try c.decodeIfPresent(ScoreSource.self, forKey: .source)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        credits = try c.decodeIfPresent([String].self, forKey: .credits) ?? []
    }
}

public enum SectionKind: String, Codable, CaseIterable, Sendable {
    case intro, verse, preChorus, chorus, bridge, interlude, solo, outro, other
}

public struct Section: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Display name as written, e.g. "主歌 1", "Chorus".
    public var name: String
    public var kind: SectionKind
    public var lines: [Line]
    /// Strum pattern used for playback of this section (id in Score.strumPatterns).
    public var strumPatternID: String?

    public init(id: String = UUID().uuidString, name: String = "", kind: SectionKind = .other,
                lines: [Line] = [], strumPatternID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lines = lines
        self.strumPatternID = strumPatternID
    }
}

public enum LineKind: String, Codable, Sendable {
    /// Lyrics with chords placed above characters (chord-over-lyrics).
    case lyrics
    /// Chord-only line, e.g. intro "| G | D | Em | C |". Uses `segments` with empty text.
    case chords
    /// Tablature block (one system of six-line tab).
    case tab
    /// Free text / annotation, not played.
    case comment
    /// Full notation system (v2): measures with chord diagrams, tablature
    /// (incl. chord-tone "×" picks and strums), numbered-notation melody and
    /// multi-verse lyrics — the common Chinese 弹唱六线谱 layout. Uses `system`.
    case system
}

public struct Line: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: LineKind
    /// For .lyrics / .chords.
    public var segments: [ChordSegment]
    /// For .tab.
    public var tab: TabBlock?
    /// For .comment.
    public var text: String?
    /// Region of the original page image this line came from (image imports).
    public var anchor: PageAnchor?
    /// For .system.
    public var system: NotationSystem?

    public init(id: String = UUID().uuidString, kind: LineKind, segments: [ChordSegment] = [],
                tab: TabBlock? = nil, text: String? = nil, anchor: PageAnchor? = nil,
                system: NotationSystem? = nil) {
        self.id = id
        self.kind = kind
        self.segments = segments
        self.tab = tab
        self.text = text
        self.anchor = anchor
        self.system = system
    }

    enum CodingKeys: String, CodingKey { case id, kind, segments, tab, text, anchor, system }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(LineKind.self, forKey: .kind)
        segments = try c.decodeIfPresent([ChordSegment].self, forKey: .segments) ?? []
        tab = try c.decodeIfPresent(TabBlock.self, forKey: .tab)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        anchor = try c.decodeIfPresent(PageAnchor.self, forKey: .anchor)
        system = try c.decodeIfPresent(NotationSystem.self, forKey: .system)
    }

    /// Lyrics text of the line (segments concatenated).
    public var lyricText: String { segments.map(\.text).joined() }
}

/// A chord change followed by the lyrics sung over it.
/// "[G]我曾经[C]跨过山和" → [ {G,"我曾经"}, {C,"跨过山和"} ].
/// A leading segment with chord == nil holds text before the first chord.
public struct ChordSegment: Codable, Hashable, Sendable {
    /// Chord symbol as written (parse with `ChordSymbol(_:)`). nil = no change.
    public var chord: String?
    public var text: String
    /// Duration in beats. nil = default (see docs/SCORE_FORMAT.md, "Default durations").
    public var beats: Double?

    public init(chord: String? = nil, text: String = "", beats: Double? = nil) {
        self.chord = chord
        self.text = text
        self.beats = beats
    }

    enum CodingKeys: String, CodingKey { case chord, text, beats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chord = try c.decodeIfPresent(String.self, forKey: .chord)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        beats = try c.decodeIfPresent(Double.self, forKey: .beats)
    }
}

public struct TabBlock: Codable, Hashable, Sendable {
    public var measures: [TabMeasure]
    public init(measures: [TabMeasure] = []) { self.measures = measures }
}

public struct TabMeasure: Codable, Hashable, Sendable {
    /// Length in beats. nil = time signature beats.
    public var beats: Double?
    public var events: [TabEvent]
    public init(beats: Double? = nil, events: [TabEvent] = []) {
        self.beats = beats
        self.events = events
    }
}

public enum Stroke: String, Codable, Sendable { case down, up }

public struct TabEvent: Codable, Hashable, Sendable {
    /// Onset in beats from the start of the measure.
    public var beat: Double
    /// Duration in beats.
    public var duration: Double
    public var notes: [TabNote]
    /// Chord name shown above this event, if any.
    public var chord: String?
    /// Strum direction marker (for rhythm-tab style notation).
    public var stroke: Stroke?

    public init(beat: Double, duration: Double, notes: [TabNote] = [], chord: String? = nil, stroke: Stroke? = nil) {
        self.beat = beat
        self.duration = duration
        self.notes = notes
        self.chord = chord
        self.stroke = stroke
    }
}

public enum Technique: String, Codable, Sendable {
    case hammerOn, pullOff, slideUp, slideDown, bend, harmonic, mute, tie
}

public struct TabNote: Codable, Hashable, Sendable {
    /// 1 = high E (1st string) ... 6 = low E (6th string).
    public var string: Int
    /// Absolute fret. Ignored when `chordTone` is true.
    public var fret: Int
    public var technique: Technique?
    /// "×" on a string in 弹唱谱: play this string as fretted by the current chord
    /// shape (`NotationMeasure.chords` / `Score.chordDefinitions`).
    public var chordTone: Bool

    public init(string: Int, fret: Int, technique: Technique? = nil, chordTone: Bool = false) {
        self.string = string
        self.fret = fret
        self.technique = technique
        self.chordTone = chordTone
    }

    /// A "×" chord-tone pick on `string`.
    public static func chordTone(string: Int) -> TabNote { TabNote(string: string, fret: 0, chordTone: true) }

    enum CodingKeys: String, CodingKey { case string, fret, technique, chordTone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = try c.decode(Int.self, forKey: .string)
        chordTone = try c.decodeIfPresent(Bool.self, forKey: .chordTone) ?? false
        fret = try c.decodeIfPresent(Int.self, forKey: .fret) ?? 0
        technique = try c.decodeIfPresent(Technique.self, forKey: .technique)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(string, forKey: .string)
        if chordTone { try c.encode(true, forKey: .chordTone) } else { try c.encode(fret, forKey: .fret) }
        try c.encodeIfPresent(technique, forKey: .technique)
    }
}

// MARK: - Notation system (v2)

/// One printed system (a row of measures spanning the page width).
public struct NotationSystem: Codable, Hashable, Sendable {
    public var measures: [NotationMeasure]
    /// Number of lyric verses printed under this system (max over measures).
    public var verseCount: Int { measures.map(\.verseCount).max() ?? 0 }
    public init(measures: [NotationMeasure] = []) { self.measures = measures }
}

public enum BarlineKind: String, Codable, Sendable { case single, double, final, startRepeat, endRepeat, startEndRepeat }

public struct NotationMeasure: Codable, Hashable, Sendable {
    /// Length in beats. nil = time signature beats (pickup measures set this).
    public var beats: Double?
    /// Chord changes inside the measure (usually one at beat 0).
    public var chords: [ChordMark]
    /// Tablature events (onsets in beats from measure start).
    public var tab: [TabEvent]
    /// Numbered-notation (简谱) melody.
    public var melody: [MelodyNote]
    public var leftBarline: BarlineKind
    public var rightBarline: BarlineKind
    /// Volta (ending) numbers this measure belongs to, e.g. [1] or [2]. Empty = all passes.
    public var volta: [Int]
    /// Free annotations attached to the measure (e.g. "D.S.", "Fine", "rit.", section label).
    public var marks: [String]

    public init(beats: Double? = nil, chords: [ChordMark] = [], tab: [TabEvent] = [], melody: [MelodyNote] = [],
                leftBarline: BarlineKind = .single, rightBarline: BarlineKind = .single,
                volta: [Int] = [], marks: [String] = []) {
        self.beats = beats
        self.chords = chords
        self.tab = tab
        self.melody = melody
        self.leftBarline = leftBarline
        self.rightBarline = rightBarline
        self.volta = volta
        self.marks = marks
    }

    enum CodingKeys: String, CodingKey { case beats, chords, tab, melody, leftBarline, rightBarline, volta, marks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beats = try c.decodeIfPresent(Double.self, forKey: .beats)
        chords = try c.decodeIfPresent([ChordMark].self, forKey: .chords) ?? []
        tab = try c.decodeIfPresent([TabEvent].self, forKey: .tab) ?? []
        melody = try c.decodeIfPresent([MelodyNote].self, forKey: .melody) ?? []
        leftBarline = try c.decodeIfPresent(BarlineKind.self, forKey: .leftBarline) ?? .single
        rightBarline = try c.decodeIfPresent(BarlineKind.self, forKey: .rightBarline) ?? .single
        volta = try c.decodeIfPresent([Int].self, forKey: .volta) ?? []
        marks = try c.decodeIfPresent([String].self, forKey: .marks) ?? []
    }

    public var verseCount: Int { melody.map(\.lyrics.count).max() ?? 0 }
}

/// Chord name (+ optional diagram read from the page) placed at a beat.
public struct ChordMark: Codable, Hashable, Sendable {
    /// Chord symbol as written, e.g. "D7(5)" is kept verbatim; parse with `ChordSymbol(normalizing:)` helpers.
    public var name: String
    public var beat: Double
    /// Fingering read from the printed chord diagram, if any.
    public var shape: ChordShape?
    public init(name: String, beat: Double = 0, shape: ChordShape? = nil) {
        self.name = name
        self.beat = beat
        self.shape = shape
    }
}

/// One 简谱 note or rest.
public struct MelodyNote: Codable, Hashable, Sendable {
    public var beat: Double
    public var duration: Double
    /// 1...7 scale degree in the key of `ScoreMeta.key` (1 = do); 0 = rest.
    public var degree: Int
    /// -1 flat, 0 natural, +1 sharp.
    public var accidental: Int
    /// Octave dots: +1 = one dot above, -1 = one dot below.
    public var octave: Int
    /// Tie/slur to the next note (no new attack when it's a tie of the same pitch).
    public var tieToNext: Bool
    /// Lyric syllable per verse ("" = none for that verse). Index 0 = first verse line.
    public var lyrics: [String]

    public init(beat: Double, duration: Double, degree: Int, accidental: Int = 0, octave: Int = 0,
                tieToNext: Bool = false, lyrics: [String] = []) {
        self.beat = beat
        self.duration = duration
        self.degree = degree
        self.accidental = accidental
        self.octave = octave
        self.tieToNext = tieToNext
        self.lyrics = lyrics
    }

    enum CodingKeys: String, CodingKey { case beat, duration, degree, accidental, octave, tieToNext, lyrics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beat = try c.decode(Double.self, forKey: .beat)
        duration = try c.decode(Double.self, forKey: .duration)
        degree = try c.decode(Int.self, forKey: .degree)
        accidental = try c.decodeIfPresent(Int.self, forKey: .accidental) ?? 0
        octave = try c.decodeIfPresent(Int.self, forKey: .octave) ?? 0
        tieToNext = try c.decodeIfPresent(Bool.self, forKey: .tieToNext) ?? false
        lyrics = try c.decodeIfPresent([String].self, forKey: .lyrics) ?? []
    }

    public var isRest: Bool { degree == 0 }

    /// Sounding MIDI pitch given the key tonic pitch class (1=C → 0) and a reference octave
    /// (degree 1 with no dots = `tonicMidi`, default C4 = 60 + pc).
    public func midi(tonicPitchClass: Int, tonicMidiBase: Int = 60) -> Int? {
        guard degree >= 1 && degree <= 7 else { return nil }
        let major = [0, 2, 4, 5, 7, 9, 11]
        return tonicMidiBase + tonicPitchClass + major[degree - 1] + accidental + 12 * octave
    }
}

/// Normalized region (0...1) on an original page image.
public struct PageAnchor: Codable, Hashable, Sendable {
    public var page: Int
    public var y: Double
    public var height: Double
    public init(page: Int, y: Double, height: Double) {
        self.page = page
        self.y = y
        self.height = height
    }
}

public struct PageImage: Codable, Hashable, Sendable {
    /// File name relative to the score package directory, e.g. "page-0.jpg".
    public var fileName: String
    public var width: Int
    public var height: Int
    public init(fileName: String, width: Int, height: Int) {
        self.fileName = fileName
        self.width = width
        self.height = height
    }
}

public struct ChordShape: Codable, Hashable, Sendable {
    /// Six absolute frets, low E → high E. -1 = muted, 0 = open.
    public var frets: [Int]
    public var fingers: [Int]?
    public var baseFret: Int

    public init(frets: [Int], fingers: [Int]? = nil, baseFret: Int = 1) {
        self.frets = frets
        self.fingers = fingers
        self.baseFret = baseFret
    }

    enum CodingKeys: String, CodingKey { case frets, fingers, baseFret }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frets = try c.decode([Int].self, forKey: .frets)
        fingers = try c.decodeIfPresent([Int].self, forKey: .fingers)
        baseFret = try c.decodeIfPresent(Int.self, forKey: .baseFret) ?? 1
    }
}

/// One measure of strumming. `strokes` has one char per slot,
/// slots = timeSignature.beats * subdivision.
///   D = down strum, U = up strum, - = rest/sustain, X = muted chuck,
///   B = bass note (root on lowest string), 1-6 = single string pluck.
/// Example 4/4 eighths: "D-DU-UDU".
public struct StrumPattern: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var subdivision: Int
    public var strokes: String

    public init(id: String, name: String, subdivision: Int, strokes: String) {
        self.id = id
        self.name = name
        self.subdivision = subdivision
        self.strokes = strokes
    }

    public static let defaultPop = StrumPattern(id: "pop8", name: "流行八分", subdivision: 2, strokes: "D-DU-UDU")
    public static let arpeggio = StrumPattern(id: "arp8", name: "分解和弦", subdivision: 2, strokes: "B321B321")
}

// MARK: - JSON coding

public enum ScoreCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ score: Score) throws -> Data { try encoder().encode(score) }
    public static func decode(_ data: Data) throws -> Score { try decoder().decode(Score.self, from: data) }
}
