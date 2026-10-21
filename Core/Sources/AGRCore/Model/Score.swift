import Foundation

// MARK: - AGR Score (standardized, script-readable score format)
//
// Serialized as JSON ("agr-score", version 1). See docs/SCORE_FORMAT.md.
// This file is the contract shared by importers, timeline, playback,
// follower and UI. Change it only together with the docs and a version bump.

public struct Score: Codable, Identifiable, Hashable, Sendable {
    public static let formatID = "agr-score"
    public static let currentVersion = 1

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
        tags: [String] = []
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
    }

    enum CodingKeys: String, CodingKey {
        case title, artist, composer, lyricist, arranger, key, capo, tempo, timeSignature, tuning, mode, source, tags
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

    public init(id: String = UUID().uuidString, kind: LineKind, segments: [ChordSegment] = [],
                tab: TabBlock? = nil, text: String? = nil, anchor: PageAnchor? = nil) {
        self.id = id
        self.kind = kind
        self.segments = segments
        self.tab = tab
        self.text = text
        self.anchor = anchor
    }

    enum CodingKeys: String, CodingKey { case id, kind, segments, tab, text, anchor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(LineKind.self, forKey: .kind)
        segments = try c.decodeIfPresent([ChordSegment].self, forKey: .segments) ?? []
        tab = try c.decodeIfPresent(TabBlock.self, forKey: .tab)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        anchor = try c.decodeIfPresent(PageAnchor.self, forKey: .anchor)
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
    public var fret: Int
    public var technique: Technique?

    public init(string: Int, fret: Int, technique: Technique? = nil) {
        self.string = string
        self.fret = fret
        self.technique = technique
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
