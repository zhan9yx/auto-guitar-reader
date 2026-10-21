import Foundation

// MARK: - Regex helper

/// Small cached wrapper around NSRegularExpression (patterns are static strings).
enum Rx {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: NSRegularExpression] = [:]
    }
    private static let cache = Cache()

    static func regex(_ pattern: String) -> NSRegularExpression {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let r = cache.items[pattern] { return r }
        // Patterns are compile-time constants in this module; a failure is a programming error.
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else {
            preconditionFailure("invalid regular expression: \(pattern)")
        }
        cache.items[pattern] = r
        return r
    }

    /// All matches; each match is the array of capture groups (index 0 = whole match) plus its UTF-16 location.
    static func matches(_ pattern: String, in s: String) -> [(groups: [String?], location: Int, length: Int)] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex(pattern).matches(in: s, options: [], range: full).map { m in
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            return (groups, m.range.location, m.range.length)
        }
    }

    static func firstMatch(_ pattern: String, in s: String) -> [String?]? {
        matches(pattern, in: s).first?.groups
    }

    static func test(_ pattern: String, _ s: String) -> Bool {
        regex(pattern).firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

// MARK: - String helpers

extension StringProtocol {
    /// Trims whitespace (including full-width space) from both ends.
    var agrTrimmed: String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s = s.dropFirst() }
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    var agrTrailingTrimmed: String {
        var s = Substring(self)
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}

extension Character {
    var isCJK: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }
}

/// Splits text into lines handling \r\n and \r, and strips a leading BOM.
func splitLines(_ text: String) -> [String] {
    var t = text
    if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
    t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    return t.components(separatedBy: "\n")
}

/// Maps full-width ASCII variants (Ａ, ＃, ／, ：…) to plain ASCII.
func foldFullWidth(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if (0xFF01...0xFF5E).contains(u.value), let a = Unicode.Scalar(u.value - 0xFEE0) {
            out.append(a)
        } else if u.value == 0x3000 {
            out.append(" ")
        } else {
            out.append(u)
        }
    }
    return String(out)
}

// MARK: - Section kinds

extension SectionKind {
    /// Default display name used when a section has no explicit label.
    var defaultName: String {
        switch self {
        case .intro: return "Intro"
        case .verse: return "Verse"
        case .preChorus: return "Pre-Chorus"
        case .chorus: return "Chorus"
        case .bridge: return "Bridge"
        case .interlude: return "Interlude"
        case .solo: return "Solo"
        case .outro: return "Outro"
        case .other: return ""
        }
    }

    private static let inferTable: [(SectionKind, [String])] = [
        (.preChorus, ["pre-chorus", "pre chorus", "prechorus", "pre_chorus", "导歌", "预副歌", "副歌前"]),
        (.chorus, ["chorus", "refrain", "hook", "副歌", "高潮"]),
        (.verse, ["verse", "主歌", "主段"]),
        (.intro, ["intro", "前奏", "开场", "引子"]),
        (.interlude, ["interlude", "instrumental", "间奏", "过门", "过场"]),
        (.outro, ["outro", "ending", "coda", "尾奏", "尾声", "结尾", "结束"]),
        (.bridge, ["bridge", "桥段", "过渡", "桥"]),
        (.solo, ["solo", "独奏"]),
    ]

    /// Kind of a label such as "Chorus 2", "主歌1", "Pre-Chorus"; nil if unknown.
    static func infer(from name: String) -> SectionKind? {
        let s = name.lowercased()
        for (kind, words) in inferTable where words.contains(where: { s.contains($0) }) { return kind }
        return nil
    }

    /// Kind from a ChordPro-style environment name (`verse`, `chorus`, `part`, ...). nil = not a known kind.
    static func fromDirectiveName(_ name: String) -> SectionKind? {
        switch name.lowercased() {
        case "verse": return .verse
        case "chorus": return .chorus
        case "bridge": return .bridge
        case "intro": return .intro
        case "prechorus", "pre_chorus", "pre-chorus": return .preChorus
        case "interlude": return .interlude
        case "solo": return .solo
        case "outro": return .outro
        case "other": return .other
        default: return nil
        }
    }
}

struct SectionHeader: Equatable {
    var name: String
    var kind: SectionKind
    /// Chords written after the label on the same line ("Intro: C G Am F").
    var trailingChords: String?
}

enum SectionHeaderParser {
    private static let strictVocabulary: Set<String> = [
        "verse", "chorus", "intro", "outro", "bridge", "prechorus", "interlude", "solo", "instrumental",
        "refrain", "hook", "ending", "coda", "guitarsolo", "leadsolo", "instrumentalbreak",
        "主歌", "副歌", "前奏", "间奏", "尾奏", "桥段", "过门", "尾声", "结尾", "导歌", "独奏", "过渡",
        "间奏solo", "吉他solo", "吉他独奏", "预副歌", "高潮",
    ]

    private static let pairs: [(Character, Character)] = [
        ("[", "]"), ("【", "】"), ("(", ")"), ("（", "）"), ("<", ">"), ("《", "》"), ("〔", "〕"), ("「", "」"),
    ]
    private static let decoration: Set<Character> = ["-", "=", "*", "#", "~", "_", "—", "–", "/", "\\", " ", "·", "•"]

    /// Detects `[Verse]`, `Chorus 2:`, `主歌1`, `【副歌】`, `--- Bridge ---`, `Intro: C G Am F`.
    static func parse(_ rawLine: String) -> SectionHeader? {
        var s = rawLine.agrTrimmed
        guard !s.isEmpty, TextWidth.columns(s) <= 48 else { return nil }
        var lenient = false

        for (o, c) in pairs where s.first == o {
            if let close = s.firstIndex(of: c) {
                let inner = String(s[s.index(after: s.startIndex)..<close])
                var rest = String(s[s.index(after: close)...]).agrTrimmed
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ":：")).agrTrimmed
                if rest.isEmpty || Rx.test(#"^[(（]?[xX×]\s*\d+[)）]?$"#, rest) {
                    s = inner.agrTrimmed
                    lenient = true
                }
            }
            break
        }

        let stripped = String(s.drop(while: { decoration.contains($0) }))
        let stripped2 = String(stripped.reversed().drop(while: { decoration.contains($0) }).reversed())
        if stripped2 != s { lenient = true; s = stripped2 }

        var trailingChords: String?
        // "Label: remainder"
        if let colon = s.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let label = String(s[..<colon]).agrTrimmed
            let remainder = String(s[s.index(after: colon)...]).agrTrimmed
            if remainder.isEmpty {
                s = label
                lenient = lenient || isStrictHeader(label)
            } else if !label.isEmpty, isStrictHeader(label), ChordLineParser.parse(remainder) != nil {
                s = label
                trailingChords = remainder
            } else if !lenient {
                return nil
            }
        }
        guard !s.isEmpty, !ChordNames.isChord(ChordNames.normalize(s)) else { return nil }
        guard let kind = SectionKind.infer(from: s) else { return nil }
        if !lenient && !isStrictHeader(s) { return nil }
        return SectionHeader(name: s, kind: kind, trailingChords: trailingChords)
    }

    /// Strict check: the label consists of a known section word plus optional number / repeat marker.
    static func isStrictHeader(_ name: String) -> Bool {
        let drop: Set<Character> = ["x", "×", "(", ")", "（", "）", "-", "_", ":", "：", ".", ",", "，"]
        let core = foldFullWidth(name).lowercased().filter { c in
            !c.isNumber && !c.isWhitespace && !drop.contains(c)
        }
        if strictVocabulary.contains(core) { return true }
        // "主歌A", "Verse B"
        if let last = core.last, last.isASCII, last.isLetter, strictVocabulary.contains(String(core.dropLast())) { return true }
        // "Pre-Chorus" with the hyphen removed above is covered by "prechorus"
        return false
    }
}

// MARK: - Chord names / chord lines

enum ChordNames {
    private static let extended =
        #"^[A-G][#b♯♭]?(?:maj|min|dim|aug|m|M|\+|°|ø|-)?(?:[#b♯♭+-]?\d{1,2}|sus[24]?|add\d{1,2}|\([^)]*\))*(?:/(?:[A-G][#b♯♭]?|\d{1,2}))?$"#

    /// True for chord symbols including slightly exotic extensions ("C6/9", "E7#9", "Cmaj7(9)") and "N.C.".
    static func isChord(_ token: String) -> Bool {
        if isNoChord(token) { return true }
        if ChordSymbol(token) != nil { return true }
        return token.count <= 12 && Rx.test(extended, token)
    }

    static func isNoChord(_ token: String) -> Bool {
        token == "N.C." || token == "N.C" || token == "NC" || token == "n.c."
    }

    /// Strips wrapping parentheses/brackets and folds full-width characters.
    static func normalize(_ token: String) -> String {
        var t = foldFullWidth(token).agrTrimmed
        t = t.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        while t.count >= 2, let f = t.first, let l = t.last, ("([".contains(f) && ")]".contains(l)) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    static func isFiller(_ token: String) -> Bool {
        let fillers: Set<String> = ["|", "||", "|:", ":|", ":", "-", "—", "–", "~", "/", "%", "*", "·", ".", "..", "...",
                                    "→", "->", "=>", "‖", "‖:", ":‖", "×", "x", "X", "//", "--"]
        if fillers.contains(token) { return true }
        return Rx.test(#"^[(（\[]?[xX×]\s*\d+[)）\]]?$"#, token) || Rx.test(#"^\d+[xX×]$"#, token)
    }
}

struct ChordLineToken: Equatable {
    var text: String
    var column: Int
    var isChord: Bool
}

struct ChordLine: Equatable {
    var tokens: [ChordLineToken]
    /// Real chords with their start display column.
    var chords: [(column: Int, chord: String)] {
        tokens.filter(\.isChord).map { ($0.column, ChordNames.normalize($0.text)) }
    }
    static func == (a: ChordLine, b: ChordLine) -> Bool { a.tokens == b.tokens }
}

enum ChordLineParser {
    /// Splits a line into whitespace/bar separated tokens with display columns.
    static func tokenize(_ line: String) -> [(text: String, column: Int)] {
        var tokens: [(String, Int)] = []
        var current = ""
        var startCol = 0
        var col = 0
        func flush() {
            if !current.isEmpty { tokens.append((current, startCol)); current = "" }
        }
        for ch in line {
            let w = TextWidth.columns(of: ch)
            if ch.isWhitespace {
                flush()
            } else if ch == "|" || ch == "｜" {
                flush()
                tokens.append((String(ch), col))
            } else {
                if current.isEmpty { startCol = col }
                current.append(ch)
            }
            col += w
        }
        flush()
        return tokens
    }

    /// A chord line: every token is a chord or a filler (`|`, `-`, `x2`, `%` ...) and there is at least one chord.
    static func parse(_ line: String) -> ChordLine? {
        let raw = tokenize(line)
        guard !raw.isEmpty, raw.count <= 64 else { return nil }
        var tokens: [ChordLineToken] = []
        var chordCount = 0
        for (text, col) in raw {
            let norm = ChordNames.normalize(text)
            if ChordNames.isFiller(norm) || ChordNames.isFiller(text) {
                tokens.append(ChordLineToken(text: text, column: col, isChord: false))
            } else if ChordNames.isChord(norm) {
                tokens.append(ChordLineToken(text: text, column: col, isChord: true))
                chordCount += 1
            } else {
                return nil
            }
        }
        return chordCount > 0 ? ChordLine(tokens: tokens) : nil
    }

    /// Chord-only segments for a `.chords` line.
    static func chordSegments(_ cl: ChordLine) -> [ChordSegment] {
        cl.chords.map { ChordSegment(chord: $0.chord, text: "") }
    }
}

// MARK: - Chord/lyric merging

enum ChordLyricMerger {
    /// Builds segments from lyric characters and chords placed at character indices (0...chars.count).
    /// Chords at the same index produce empty-text segments for all but the last.
    static func segments(chars: [Character], chords: [(index: Int, chord: String)]) -> [ChordSegment] {
        let n = chars.count
        let sorted = chords.enumerated().sorted {
            $0.element.index != $1.element.index ? $0.element.index < $1.element.index : $0.offset < $1.offset
        }.map { (index: min(max($0.element.index, 0), n), chord: $0.element.chord) }

        var segs: [ChordSegment] = []
        guard let first = sorted.first else {
            return n == 0 ? [] : [ChordSegment(chord: nil, text: String(chars))]
        }
        if first.index > 0 {
            segs.append(ChordSegment(chord: nil, text: String(chars[0..<first.index])))
        }
        for (k, item) in sorted.enumerated() {
            let end = k + 1 < sorted.count ? sorted[k + 1].index : n
            segs.append(ChordSegment(chord: item.chord, text: String(chars[item.index..<end])))
        }
        return cleaned(segs)
    }

    /// Drops whitespace-only unchorded lead segment and trailing whitespace of the last segment.
    static func cleaned(_ input: [ChordSegment]) -> [ChordSegment] {
        var segs = input
        if let f = segs.first, f.chord == nil, f.text.agrTrimmed.isEmpty, segs.count > 1 { segs.removeFirst() }
        if var last = segs.last {
            last.text = last.text.agrTrailingTrimmed
            segs[segs.count - 1] = last
        }
        return segs
    }

    /// Merges a chord line with the lyric line under it by display columns.
    static func merge(chordLine: ChordLine, lyric: String) -> [ChordSegment] {
        var indent = 0
        var body = Substring(lyric)
        while let f = body.first, f.isWhitespace { indent += TextWidth.columns(of: f); body = body.dropFirst() }
        let text = body.agrTrailingTrimmed
        let chars = Array(text)
        var starts: [Int] = []
        var col = 0
        for ch in chars { starts.append(col); col += TextWidth.columns(of: ch) }
        let total = col

        let placed: [(index: Int, chord: String)] = chordLine.chords.map { item in
            let c = max(0, item.column - indent)
            if c >= total { return (chars.count, item.chord) }
            var idx = 0
            for (i, s) in starts.enumerated() where s <= c { idx = i }
            return (idx, item.chord)
        }
        return segments(chars: chars, chords: placed)
    }
}

// MARK: - Section builder

/// Accumulates sections/lines and assigns stable ids ("s0", "s0l3") at the end.
struct SectionBuilder {
    private(set) var sections: [Section] = []
    private var implicitFlags: [Bool] = []
    private var currentIndex: Int?

    /// Starts a new explicit section.
    mutating func begin(name: String, kind: SectionKind) {
        sections.append(Section(id: "", name: name, kind: kind, lines: []))
        implicitFlags.append(false)
        currentIndex = sections.count - 1
    }

    /// Ends the current explicit section; following lines start a new implicit one.
    mutating func close() { currentIndex = nil }

    mutating func add(_ line: Line) {
        if currentIndex == nil {
            sections.append(Section(id: "", name: "", kind: .other, lines: []))
            implicitFlags.append(true)
            currentIndex = sections.count - 1
        }
        if let i = currentIndex { sections[i].lines.append(line) }
    }

    func finish() -> [Section] {
        var result: [Section] = []
        for (i, section) in sections.enumerated() where !(implicitFlags[i] && section.lines.isEmpty) {
            result.append(section)
        }
        for i in result.indices {
            result[i].id = "s\(i)"
            for j in result[i].lines.indices { result[i].lines[j].id = "s\(i)l\(j)" }
        }
        return result
    }
}

// MARK: - Tuning

enum TuningParser {
    /// "standard", "drop d", "D A D G B E", "DADGBE" → open-string MIDI notes (low → high). nil if unrecognised.
    static func parse(_ text: String) -> [Int]? {
        let t = foldFullWidth(text).lowercased().agrTrimmed
        if t.hasPrefix("standard") || t == "std" || t.hasPrefix("标准") { return ScoreMeta.standardTuning }
        if t.hasPrefix("drop d") || t.hasPrefix("dropd") { return [38, 45, 50, 55, 59, 64] }
        if t.contains("half step down") || t.contains("半音") { return ScoreMeta.standardTuning.map { $0 - 1 } }
        if t.contains("whole step down") || t.contains("全音") { return ScoreMeta.standardTuning.map { $0 - 2 } }
        // Six note names, e.g. "D A D G B E" or "DADGBE"
        let original = foldFullWidth(text)
        let names = Rx.matches(#"[A-G][#b]?"#, in: original.agrTrimmed).map { $0.groups[0] ?? "" }
        guard names.count == 6 else { return nil }
        var result: [Int] = []
        for name in names {
            guard let (pc, _, _) = ChordSymbol.parseNote(Substring(name)) else { return nil }
            if let prev = result.last {
                var m = prev + 1
                while m % 12 != pc { m += 1 }
                result.append(m)
            } else {
                var m = 36
                while m % 12 != pc { m += 1 }
                result.append(m)
            }
        }
        return result
    }

    /// Six note names with sharps (for export).
    static func format(_ tuning: [Int]) -> String {
        tuning.map { ChordSymbol.noteName($0) }.joined(separator: " ")
    }
}

// MARK: - Metadata lines

enum MetaItem: Equatable {
    case title(String), artist(String), composer(String), lyricist(String), arranger(String)
    case capo(Int), key(String, original: Bool), tempo(Double), time(Int, Int), tuning([Int])

    func apply(to meta: inout ScoreMeta) {
        switch self {
        case .title(let v): meta.title = v
        case .artist(let v): meta.artist = v
        case .composer(let v): meta.composer = v
        case .lyricist(let v): meta.lyricist = v
        case .arranger(let v): meta.arranger = v
        case .capo(let v): meta.capo = v
        case .key(let v, let original): if original || meta.key == nil { meta.key = v }
        case .tempo(let v): meta.tempo = v
        case .time(let b, let u): meta.timeSignature = TimeSignature(beats: b, unit: u)
        case .tuning(let v): meta.tuning = v
        }
    }
}

enum MetaLineParser {
    private static let noteRx = #"([A-G][#b♯♭]?)((?i:m(?:in(?:or)?)?)?)(?![A-Za-z])"#

    private static let textMarkers =
        #"(?<![A-Za-z])(?i:title|song|artist|singer|by|composer|music|lyricist|lyrics|words|arranger|arranged by|tuning)\s*[:：]\s*|(?:歌词|歌曲名|歌名|曲名|歌曲|歌手|演唱者|演唱|原唱|作曲|作词|编曲|词曲|调弦|定弦|词|曲)\s*[:：]\s*"#
    private static let numericMarkers = [
        #"(?i:capo|变调夹|变调|上夹)\s*[:：=]?\s*(?:on\s+|at\s+|第)?(\d{1,2}|[一二两三四五六七八九十]{1,3}|no\b|none\b|off\b|无|不用|没有)"#,
        #"(?:原调|选调|调式|调号|调性|(?<![A-Za-z])(?i:key(?:\s+of)?)|调(?=\s*[:：]))\s*[:：=]?\s*(?:是|为)?\s*"# + noteRx,
        #"^\s*1\s*[=＝]\s*"# + noteRx,
        #"(?i:bpm|tempo|速度)\s*[:：=]?\s*(?:[♩♪♫]\s*[=＝≈]?\s*)?(?:≈|约)?\s*(\d{2,3})"#,
        #"(\d{2,3})\s*(?i:bpm)"#,
        #"[♩♪♫]\s*[=＝≈]\s*(\d{2,3})"#,
        #"(?i:time(?:\s+signature)?|拍号|拍子|节拍)\s*[:：=]?\s*(\d{1,2})\s*/\s*(\d{1,2})"#,
    ]

    /// Returns the metadata items of a line. Empty = not a metadata line.
    /// The line must start with a recognised marker (so lyrics that merely contain "key" are not eaten).
    static func parse(_ rawLine: String) -> [MetaItem] {
        let line = rawLine.agrTrimmed
        guard !line.isEmpty, TextWidth.columns(line) <= 90 else { return [] }
        let noise = CharacterSet(charactersIn: "[]【】()（）<>《》*#•·-—– \t")
        let offset = line.unicodeScalars.prefix(while: { noise.contains($0) }).reduce(0) { $0 + String($1).utf16.count }

        var found: [(location: Int, items: [MetaItem])] = []
        found += textItems(in: line)
        found += numericItems(in: line)
        guard let minLoc = found.map(\.location).min(), minLoc <= offset else { return [] }
        return found.sorted { $0.location < $1.location }.flatMap(\.items)
    }

    private static func textItems(in line: String) -> [(location: Int, items: [MetaItem])] {
        let ns = line as NSString
        let markers = Rx.matches(textMarkers, in: line)
        guard !markers.isEmpty else { return [] }
        // Cut positions: all text markers plus numeric markers (so values stop there).
        var cuts = markers.map(\.location)
        for p in numericMarkers where !p.hasPrefix("^") { cuts += Rx.matches(p, in: line).map(\.location) }
        cuts.sort()
        var result: [(Int, [MetaItem])] = []
        for m in markers {
            let start = m.location + m.length
            let end = cuts.first(where: { $0 > m.location + m.length - 1 && $0 >= start }) ?? ns.length
            let value = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t,，;；、"))
            let marker = ns.substring(with: NSRange(location: m.location, length: m.length))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:：")).lowercased()
            guard !value.isEmpty else { continue }
            if let items = textItems(marker: marker, value: value) { result.append((m.location, items)) }
        }
        return result
    }

    private static func textItems(marker: String, value: String) -> [MetaItem]? {
        switch marker {
        case "title", "song", "歌名", "曲名", "歌曲名", "歌曲": return [.title(cleanTitle(value))]
        case "artist", "singer", "by", "歌手", "演唱者", "演唱", "原唱": return [.artist(value)]
        case "composer", "music", "作曲", "曲": return [.composer(value)]
        case "lyricist", "lyrics", "words", "作词", "词": return [.lyricist(value)]
        case "词曲": return [.lyricist(value), .composer(value)]
        case "arranger", "arranged by", "编曲": return [.arranger(value)]
        case "tuning", "调弦", "定弦":
            if let t = TuningParser.parse(value) { return [.tuning(t)] }
            return nil
        case "歌词": return []
        default: return nil
        }
    }

    private static func numericItems(in line: String) -> [(location: Int, items: [MetaItem])] {
        var result: [(Int, [MetaItem])] = []
        for (i, pattern) in numericMarkers.enumerated() {
            for m in Rx.matches(pattern, in: line) {
                if let items = numericItem(kind: i, groups: m.groups, line: line) {
                    // for "^\s*1=" the location of the real text is 0 anyway
                    result.append((m.location, items))
                }
            }
        }
        return result
    }

    private static func numericItem(kind: Int, groups g: [String?], line: String) -> [MetaItem]? {
        switch kind {
        case 0:
            guard let v = g[1] else { return nil }
            if let n = parseSmallInt(v) { return [.capo(n)] }
            return [.capo(0)]
        case 1, 2:
            guard let note = g[1] else { return nil }
            var key = note.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
            if let minor = g[2], !minor.isEmpty { key += "m" }
            let matchedText = g[0] ?? ""
            let original = kind == 1 && !matchedText.hasPrefix("选调")
            return [.key(key, original: original)]
        case 3, 4, 5:
            guard let v = g[1], let bpm = Double(v), (30...300).contains(bpm) else { return nil }
            return [.tempo(bpm)]
        case 6:
            guard let a = g[1], let b = g[2], let beats = Int(a), let unit = Int(b), beats > 0, [1, 2, 4, 8, 16, 32].contains(unit) else { return nil }
            return [.time(beats, unit)]
        default: return nil
        }
    }

    static func cleanTitle(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "《》「」\"“” ")).agrTrimmed
    }

    /// "2", "二", "十" → Int; nil for "none"/"无".
    static func parseSmallInt(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let digits: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.hasPrefix("十"), let d = s.dropFirst().first.flatMap({ digits[$0] }) { return 10 + d }
        if s.count == 1, let d = s.first.flatMap({ digits[$0] }) { return d }
        return nil
    }
}
