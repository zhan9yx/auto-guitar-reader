import Foundation

// MARK: - Inline `[C]text` parsing (shared by ChordPro and chord-text parsers)

enum InlineChordParser {
    /// Parses `[C]我曾经[G]跨过`. Bracketed text that is not a chord stays literal.
    /// Returns nil when the line contains no chord brackets.
    static func parse(_ line: String) -> [ChordSegment]? {
        var segments: [ChordSegment] = []
        var chord: String?
        var text = ""
        var hasChord = false
        var started = false
        let chars = Array(line)
        var i = 0
        func flush() {
            if started || !text.isEmpty { segments.append(ChordSegment(chord: chord, text: text)) }
            text = ""
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "[", let close = chars[(i + 1)...].firstIndex(of: "]") {
                let inner = String(chars[(i + 1)..<close]).agrTrimmed
                let norm = ChordNames.normalize(inner)
                if !inner.isEmpty, ChordNames.isChord(norm) {
                    flush()
                    chord = norm
                    started = true
                    hasChord = true
                    i = close + 1
                    continue
                }
            }
            text.append(ch)
            i += 1
        }
        flush()
        return hasChord ? segments : nil
    }

    /// Text made only of spaces / bar marks does not count as lyrics.
    static func isFillerText(_ s: String) -> Bool {
        s.allSatisfy { $0.isWhitespace || $0 == "|" || $0 == "-" || $0 == "｜" }
    }

    /// Builds a `.lyrics` or `.chords` line from inline segments.
    static func makeLine(_ segments: [ChordSegment]) -> Line {
        if segments.allSatisfy({ isFillerText($0.text) }) {
            return Line(kind: .chords, segments: segments.compactMap { $0.chord.map { ChordSegment(chord: $0, text: "") } })
        }
        return Line(kind: .lyrics, segments: ChordLyricMerger.cleaned(segments))
    }
}

// MARK: - Title line detection

enum TitleLine {
    /// Detects a title on the first content line: "Title - Artist", or a short line followed by a blank/metadata/header line.
    static func detect(lines: [String], consumed: Set<Int>, isContent: (Int) -> Bool) -> (index: Int, title: String, artist: String?)? {
        guard let i = lines.indices.first(where: { isContent($0) && !consumed.contains($0) && !lines[$0].agrTrimmed.isEmpty }) else { return nil }
        let raw = lines[i].agrTrimmed
        guard TextWidth.columns(raw) <= 60 else { return nil }
        if ChordLineParser.parse(raw) != nil || SectionHeaderParser.parse(raw) != nil { return nil }
        if Rx.test(#"\[[A-G][^\]]*\]"#, raw) { return nil }
        if let g = Rx.firstMatch(#"^《([^》]+)》\s*(.*)$"#, in: raw), let title = g[1] {
            let rest = (g[2] ?? "").agrTrimmed
            if rest.isEmpty || TextWidth.columns(rest) <= 30 {
                return (i, title.agrTrimmed, rest.isEmpty ? nil : rest)
            }
        }
        for sep in [" - ", " – ", " — ", " ~ "] {
            if let r = raw.range(of: sep) {
                let left = String(raw[..<r.lowerBound]).agrTrimmed
                let right = String(raw[r.upperBound...]).agrTrimmed
                if !left.isEmpty, !right.isEmpty {
                    return (i, MetaLineParser.cleanTitle(left), MetaLineParser.cleanTitle(right))
                }
            }
        }
        if let last = raw.last, "。，,!！?？；;".contains(last) { return nil }
        let next = i + 1 < lines.count ? lines[i + 1] : ""
        let nextBlank = next.agrTrimmed.isEmpty
        let nextMeta = consumed.contains(i + 1) || SectionHeaderParser.parse(next) != nil
        guard i + 1 >= lines.count || nextBlank || nextMeta else { return nil }
        return (i, MetaLineParser.cleanTitle(raw), nil)
    }
}

// MARK: - Chord-over-lyrics parser

/// Parser for chord-over-lyrics text (Ultimate Guitar, Chinese guitar sites, plain .txt).
///
/// A chord line (all tokens are chords or fillers) is merged with the lyric line below it by display column,
/// so CJK characters (2 columns) line up correctly. Embedded six-line ASCII tab blocks become `.tab` lines.
public enum ChordTextParser {
    public static func parse(_ text: String) throws -> Score {
        let lines = splitLines(preprocess(text))
        guard lines.contains(where: { !$0.agrTrimmed.isEmpty }) else { throw ImportError.empty }
        let groups = AsciiTabParser.findGroups(in: lines)
        let inGroup: (Int) -> Bool = { i in groups.contains(where: { $0.contains(i) }) }

        var meta = ScoreMeta(source: ScoreSource(kind: .chordText))
        var consumed = Set<Int>()
        for (i, line) in lines.enumerated() where !inGroup(i) {
            if ChordLineParser.parse(line) != nil || line.agrTrimmed.isEmpty { continue }
            let items = MetaLineParser.parse(line)
            if !items.isEmpty { items.forEach { $0.apply(to: &meta) }; consumed.insert(i) }
        }
        if let t = TitleLine.detect(lines: lines, consumed: consumed, isContent: { !inGroup($0) }) {
            meta.title = t.title
            if let a = t.artist { meta.artist = a }
            consumed.insert(t.index)
        }

        var builder = SectionBuilder()
        var pending: (line: ChordLine, index: Int, raw: String)?
        func flushPending() {
            if let p = pending { builder.add(Line(kind: .chords, segments: ChordLineParser.chordSegments(p.line))) }
            pending = nil
        }

        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let raw = lines[i]
            let trimmed = raw.agrTrimmed
            if consumed.contains(i) { flushPending(); continue }
            if let g = groups.first(where: { $0.lowerBound == i }) {
                var chordRaw: String?
                if let p = pending, p.index == i - 1 { chordRaw = p.raw; pending = nil } else { flushPending() }
                if let block = AsciiTabParser.parseBlock(Array(lines[g]), beatsPerMeasure: Double(meta.timeSignature.beats), chordLine: chordRaw) {
                    builder.add(Line(kind: .tab, tab: block))
                }
                i = g.upperBound - 1
                continue
            }
            if trimmed.isEmpty { flushPending(); continue }
            if let h = SectionHeaderParser.parse(trimmed) {
                flushPending()
                builder.begin(name: h.name, kind: h.kind)
                if let tc = h.trailingChords, let cl = ChordLineParser.parse(tc) {
                    builder.add(Line(kind: .chords, segments: ChordLineParser.chordSegments(cl)))
                }
                continue
            }
            if let cl = ChordLineParser.parse(raw) {
                flushPending()
                pending = (cl, i, raw)
                continue
            }
            if isSeparator(trimmed) { flushPending(); continue }
            if let inline = InlineChordParser.parse(raw) {
                flushPending()
                builder.add(InlineChordParser.makeLine(inline))
                continue
            }
            if isRepeatMarker(trimmed) {
                flushPending()
                builder.add(Line(kind: .comment, text: trimmed))
                continue
            }
            // Plain lyric line.
            if let p = pending {
                pending = nil
                let segs = ChordLyricMerger.merge(chordLine: p.line, lyric: raw)
                builder.add(Line(kind: .lyrics, segments: segs))
            } else {
                builder.add(Line(kind: .lyrics, segments: [ChordSegment(chord: nil, text: trimmed)]))
            }
        }
        flushPending()

        let sections = builder.finish()
        guard !sections.isEmpty else { throw ImportError.empty }
        var score = Score(meta: meta, sections: sections)
        let kinds = Set(sections.flatMap(\.lines).map(\.kind))
        if kinds.contains(.tab) && !kinds.contains(.lyrics) && !kinds.contains(.chords) { score.meta.mode = .fingerstyle }
        return score
    }

    /// Removes Ultimate-Guitar markup (`[ch]`, `[tab]`) and expands tabs.
    static func preprocess(_ text: String) -> String {
        var t = text
        for tag in ["[ch]", "[/ch]", "[tab]", "[/tab]", "[CH]", "[/CH]", "[TAB]", "[/TAB]"] {
            t = t.replacingOccurrences(of: tag, with: "")
        }
        return t.replacingOccurrences(of: "\t", with: "    ")
    }

    private static func isSeparator(_ s: String) -> Bool {
        s.count >= 3 && s.allSatisfy { "-=*_~·—– ".contains($0) }
    }

    private static func isRepeatMarker(_ s: String) -> Bool {
        Rx.test(#"^[(（\[]?\s*(?:[xX×]\s*\d+|重复\s*\d*\s*[次遍]?|repeat\s*\d*x?)\s*[)）\]]?$"#, s)
    }
}
