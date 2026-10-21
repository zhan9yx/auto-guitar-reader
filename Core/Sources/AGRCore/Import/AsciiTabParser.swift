import Foundation

/// Parser for ASCII guitar tablature (`e|---3---|` six-line groups).
///
/// Column position inside a measure maps linearly to the beat position
/// (`beat = column / measureWidth * measureBeats`, quantized to 1/8 beat).
public enum AsciiTabParser {
    /// Parses a six-line tab group (top line = 1st string unless labels say otherwise).
    public static func parseBlock(_ lines: [String]) -> TabBlock? {
        parseBlock(lines, beatsPerMeasure: 4, chordLine: nil)
    }

    /// Parses a six-line group with an explicit measure length and an optional chord-name line above it.
    public static func parseBlock(_ lines: [String], beatsPerMeasure: Double, chordLine: String? = nil) -> TabBlock? {
        guard lines.count == 6 else { return nil }
        let parts = lines.compactMap { splitTabLine($0) }
        guard parts.count == 6 else { return nil }
        return buildBlock(parts: parts, beatsPerMeasure: max(0.5, beatsPerMeasure), chordLine: chordLine)
    }

    /// Parses a document containing tab groups (plus optional metadata, section headers and chord names above the tabs).
    public static func parse(_ text: String) throws -> Score {
        let lines = splitLines(text)
        guard lines.contains(where: { !$0.agrTrimmed.isEmpty }) else { throw ImportError.empty }
        let groups = findGroups(in: lines)
        guard !groups.isEmpty else { throw ImportError.malformed("no six-line tab block found") }

        var meta = ScoreMeta(mode: .fingerstyle, source: ScoreSource(kind: .asciiTab))
        // First pass: metadata (so the time signature is known when parsing the blocks).
        var consumed = Set<Int>()
        let groupStarts = Set(groups.map(\.lowerBound))
        for (i, line) in lines.enumerated() {
            if groups.contains(where: { $0.contains(i) }) { continue }
            let items = MetaLineParser.parse(line)
            if !items.isEmpty { items.forEach { $0.apply(to: &meta) }; consumed.insert(i) }
        }
        if let t = TitleLine.detect(lines: lines, consumed: consumed, isContent: { idx in !groups.contains(where: { $0.contains(idx) }) }) {
            meta.title = t.title
            if let a = t.artist { meta.artist = a }
            consumed.insert(t.index)
        }

        var builder = SectionBuilder()
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            if consumed.contains(i) { continue }
            if let g = groups.first(where: { $0.lowerBound == i }) {
                var chordLine: String?
                if i > 0, !consumed.contains(i - 1), ChordLineParser.parse(lines[i - 1]) != nil { chordLine = lines[i - 1] }
                let six = Array(lines[g])
                if let block = parseBlock(six, beatsPerMeasure: Double(meta.timeSignature.beats), chordLine: chordLine) {
                    builder.add(Line(kind: .tab, tab: block))
                }
                i = g.upperBound - 1
                continue
            }
            let trimmed = lines[i].agrTrimmed
            if trimmed.isEmpty { continue }
            if let h = SectionHeaderParser.parse(trimmed) { builder.begin(name: h.name, kind: h.kind); continue }
            // chord names directly above a tab group were consumed by that group
            if i + 1 < lines.count, groupStarts.contains(i + 1), ChordLineParser.parse(lines[i]) != nil { continue }
            builder.add(Line(kind: .comment, text: trimmed))
        }
        var score = Score(meta: meta, sections: builder.finish())
        score.meta.source = ScoreSource(kind: .asciiTab)
        return score
    }

    // MARK: Line splitting / group detection

    struct TabLineParts {
        var label: String?
        /// Index (in characters of the raw line) of the first body character.
        var bodyStart: Int
        var body: [Character]
    }

    private static let bodyAllowed: Set<Character> = Set("-|0123456789hpbrsvHPBRSxX/\\~^()<>[]*.=:_ ")

    /// Splits `e|--3--|` into label and body; nil if the line is not a tab line.
    static func splitTabLine(_ line: String) -> TabLineParts? {
        let chars = Array(line.replacingOccurrences(of: "\t", with: " "))
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        let start = i
        // Optional label.
        var label: String?
        var j = i
        if "ABCDEFGabcdefg".contains(chars[j]) {
            j += 1
            if j < chars.count, chars[j] == "#" || (chars[j] == "b" && j + 1 < chars.count && (chars[j + 1] == "|" || chars[j + 1] == "-" || chars[j + 1] == " ")) {
                j += 1
            }
        } else if "123456".contains(chars[j]) {
            j += 1
        } else {
            j = i
        }
        if j > i {
            var k = j
            while k < chars.count, chars[k] == " " { k += 1 }
            if k < chars.count, chars[k] == "|" || chars[k] == "-" {
                label = String(chars[i..<j])
                i = k
            } else {
                i = start
            }
        }
        guard i < chars.count, chars[i] == "|" || chars[i] == "-" else { return nil }
        var end = chars.count
        while end > i, chars[end - 1] == " " { end -= 1 }
        let body = Array(chars[i..<end])
        guard body.count >= 4, body.allSatisfy({ bodyAllowed.contains($0) }) else { return nil }
        let meaningful = body.filter { $0 == "-" || $0 == "|" || $0.isNumber }.count
        guard body.filter({ $0 == "-" }).count >= 3, meaningful * 2 >= body.count else { return nil }
        return TabLineParts(label: label, bodyStart: i, body: body)
    }

    /// Ranges of consecutive 6-line tab groups.
    static func findGroups(in lines: [String]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var i = 0
        while i < lines.count {
            guard splitTabLine(lines[i]) != nil else { i += 1; continue }
            var j = i
            while j < lines.count, splitTabLine(lines[j]) != nil { j += 1 }
            let count = (j - i) / 6
            for k in 0..<count { result.append((i + 6 * k)..<(i + 6 * k + 6)) }
            i = j
        }
        return result
    }

    /// Parses all groups in `lines` into tab lines (used for ChordPro `{sot}` bodies); other text becomes comments.
    static func parseLines(_ lines: [String], beatsPerMeasure: Double) -> [Line] {
        let groups = findGroups(in: lines)
        var result: [Line] = []
        var i = 0
        while i < lines.count {
            if let g = groups.first(where: { $0.lowerBound == i }) {
                var chordLine: String?
                if i > 0, ChordLineParser.parse(lines[i - 1]) != nil { chordLine = lines[i - 1] }
                if let block = parseBlock(Array(lines[g]), beatsPerMeasure: beatsPerMeasure, chordLine: chordLine) {
                    result.append(Line(kind: .tab, tab: block))
                }
                i = g.upperBound
                continue
            }
            let t = lines[i].agrTrimmed
            let nextIsGroup = groups.contains(where: { $0.lowerBound == i + 1 })
            if !t.isEmpty, !(nextIsGroup && ChordLineParser.parse(lines[i]) != nil) {
                result.append(Line(kind: .comment, text: t))
            }
            i += 1
        }
        return result
    }

    // MARK: Block construction

    private struct ParsedNote {
        var col: Int
        var note: TabNote
    }

    private static func isReversed(_ labels: [String?]) -> Bool {
        guard let first = labels.first ?? nil, let last = labels.last ?? nil else { return false }
        if first == "6" && last == "1" { return true }
        return first == "E" && last == "e"
    }

    private static func buildBlock(parts: [TabLineParts], beatsPerMeasure: Double, chordLine: String?) -> TabBlock? {
        let reversed = isReversed(parts.map(\.label))
        let minStart = parts.map(\.bodyStart).min() ?? 0
        // Align rows on absolute source columns.
        var rows: [[Character]] = parts.map { Array(repeating: "-", count: $0.bodyStart - minStart) + $0.body }
        let width = rows.map(\.count).max() ?? 0
        for r in rows.indices where rows[r].count < width { rows[r] += Array(repeating: "-", count: width - rows[r].count) }
        guard width >= 3 else { return nil }

        // Bar columns: '|' on at least 4 of the 6 lines.
        var isBar = [Bool](repeating: false, count: width)
        for c in 0..<width where rows.filter({ $0[c] == "|" }).count >= 4 { isBar[c] = true }

        var segments: [Range<Int>] = []
        var c = 0
        while c < width {
            if isBar[c] { c += 1; continue }
            var e = c
            while e < width, !isBar[e] { e += 1 }
            segments.append(c..<e)
            c = e
        }

        var measures: [TabMeasure] = []
        var eventColumns: [(measure: Int, event: Int, column: Int)] = []
        for seg in segments {
            var byCol: [Int: [TabNote]] = [:]
            for r in 0..<6 {
                let string = reversed ? 6 - r : r + 1
                for pn in parseString(Array(rows[r][seg]), string: string) {
                    byCol[pn.col, default: []].append(pn.note)
                }
            }
            if byCol.isEmpty && seg.count < 2 { continue }
            let cols = byCol.keys.sorted()
            var events: [TabEvent] = []
            for col in cols {
                let raw = Double(col) / Double(seg.count) * beatsPerMeasure
                var beat = (raw * 8).rounded() / 8
                beat = min(beat, max(0, beatsPerMeasure - 0.125))
                let notes = (byCol[col] ?? []).sorted { $0.string < $1.string }
                events.append(TabEvent(beat: beat, duration: 0.125, notes: notes))
            }
            for k in events.indices {
                let next = k + 1 < events.count ? events[k + 1].beat : beatsPerMeasure
                events[k].duration = max(0.125, next - events[k].beat)
                eventColumns.append((measures.count, k, minStart + seg.lowerBound + cols[k]))
            }
            measures.append(TabMeasure(beats: nil, events: events))
        }
        guard !measures.isEmpty else { return nil }
        var block = TabBlock(measures: measures)
        if let chordLine { attachChords(chordLine, to: &block, columns: eventColumns) }
        return block
    }

    /// Chord names written above the tab attach to the nearest (unassigned) event column.
    private static func attachChords(_ chordLine: String, to block: inout TabBlock, columns: [(measure: Int, event: Int, column: Int)]) {
        guard let cl = ChordLineParser.parse(chordLine), !columns.isEmpty else { return }
        var taken = Set<Int>()
        for (col, chord) in cl.chords {
            let ranked = columns.indices.sorted { abs(columns[$0].column - col) < abs(columns[$1].column - col) }
            guard let pick = ranked.first(where: { !taken.contains($0) }) ?? ranked.first else { continue }
            taken.insert(pick)
            let ec = columns[pick]
            block.measures[ec.measure].events[ec.event].chord = chord
        }
    }

    /// Tokenizes one string's characters within a measure.
    private static func parseString(_ seg: [Character], string: Int) -> [ParsedNote] {
        var notes: [ParsedNote] = []
        var pending: Technique?
        var pendingSlide = false
        var swallow = false
        var lastEnd = -1
        var i = 0
        let n = seg.count

        func digitsRun(from s: Int) -> (value: Int, end: Int)? {
            var e = s
            while e < n, seg[e].isASCII, seg[e].isNumber { e += 1 }
            guard e > s, e - s <= 3, let v = Int(String(seg[s..<e])) else { return nil }
            return (v, e)
        }

        while i < n {
            let ch = seg[i]
            if ch.isASCII, ch.isNumber, let (fret, end) = digitsRun(from: i) {
                if swallow {
                    swallow = false
                    pending = nil
                } else {
                    var tech = pending
                    if pendingSlide {
                        tech = (notes.last.map { fret >= $0.note.fret } ?? true) ? .slideUp : .slideDown
                    }
                    notes.append(ParsedNote(col: i, note: TabNote(string: string, fret: fret, technique: tech)))
                }
                pending = nil
                pendingSlide = false
                lastEnd = end
                i = end
                continue
            }
            switch ch {
            case "h", "H": pending = .hammerOn
            case "p", "P": pending = .pullOff
            case "/": pending = .slideUp
            case "\\": pending = .slideDown
            case "s", "S": pendingSlide = true
            case "b", "B":
                if lastEnd == i, !notes.isEmpty {
                    notes[notes.count - 1].note.technique = .bend
                    swallow = true
                }
            case "r", "R": swallow = true
            case "x", "X":
                notes.append(ParsedNote(col: i, note: TabNote(string: string, fret: 0, technique: .mute)))
                pending = nil
            case "<", "[", "(":
                let closer: Character = ch == "<" ? ">" : (ch == "[" ? "]" : ")")
                if let (fret, end) = digitsRun(from: i + 1), end < n, seg[end] == closer {
                    notes.append(ParsedNote(col: i, note: TabNote(string: string, fret: fret, technique: ch == "(" ? .tie : .harmonic)))
                    lastEnd = end + 1
                    i = end + 1
                    pending = nil
                    continue
                }
            case "-":
                pending = nil
                pendingSlide = false
                swallow = false
            default: break
            }
            i += 1
        }
        return notes
    }

    // MARK: Rendering (used by ChordProExporter)

    private static let stringLabels = ["e", "B", "G", "D", "A", "E"]

    private static func cellText(_ note: TabNote) -> String {
        switch note.technique {
        case .mute?: return "x"
        case .harmonic?: return "<\(note.fret)>"
        case .tie?: return "(\(note.fret))"
        default: return String(note.fret)
        }
    }

    /// Renders a tab block as ASCII (optional chord line + six string lines) that `parseBlock` reads back.
    static func render(_ block: TabBlock, defaultBeats: Double) -> [String] {
        let all = block.measures.flatMap(\.events).flatMap(\.notes)
        let maxCell = all.map { cellText($0).count }.max() ?? 1
        let w = maxCell + 1
        func lengthOf(_ m: TabMeasure) -> Double { m.beats ?? defaultBeats }
        // Global density: columns per beat in {1,2,4,8}.
        var g = 1
        for e in block.measures.flatMap(\.events) {
            while g < 8, abs(e.beat * Double(g) - (e.beat * Double(g)).rounded()) > 1e-6 { g *= 2 }
        }

        var rows: [[Character]] = stringLabels.map { Array($0 + "|") }
        var chordLine: [Character] = Array(repeating: " ", count: 2)
        var hasChord = false
        var cursor = 2
        var lastChordEnd = 0
        for m in block.measures {
            let slots = max(1, Int((lengthOf(m) * Double(g)).rounded()))
            var cells: [[Character]] = Array(repeating: Array(repeating: "-", count: slots * w), count: 6)
            for e in m.events {
                let k = min(max(0, Int((e.beat * Double(g)).rounded())), slots - 1)
                for note in e.notes where (1...6).contains(note.string) {
                    let r = note.string - 1
                    let text = Array(cellText(note))
                    for (d, c) in text.enumerated() { cells[r][k * w + d] = c }
                    switch note.technique {
                    case .bend?: cells[r][k * w + text.count] = "b"
                    case .hammerOn?, .pullOff?, .slideUp?, .slideDown?:
                        if k > 0 {
                            let conn: Character = note.technique == .hammerOn ? "h" : note.technique == .pullOff ? "p" : note.technique == .slideUp ? "/" : "\\"
                            cells[r][k * w - 1] = conn
                        }
                    default: break
                    }
                }
                if let chord = e.chord, !chord.isEmpty {
                    let pos = cursor + k * w
                    if pos >= lastChordEnd {
                        if chordLine.count < pos { chordLine += Array(repeating: " ", count: pos - chordLine.count) }
                        chordLine += Array(chord)
                        lastChordEnd = pos + chord.count + 1
                        hasChord = true
                    }
                }
            }
            for r in 0..<6 { rows[r] += cells[r]; rows[r].append("|") }
            cursor += slots * w + 1
        }
        var result = rows.map { String($0) }
        if hasChord { result.insert(String(chordLine).agrTrailingTrimmed, at: 0) }
        return result
    }
}
