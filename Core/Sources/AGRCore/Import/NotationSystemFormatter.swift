import Foundation

/// Text renderings of v2 `NotationSystem`s: an ASCII tab for debugging / diffing and the lossy ChordPro fallback.
public enum NotationSystemFormatter {
    /// Columns per beat in `asciiTab` (16th-note grid, 2 characters per slot).
    static let slotsPerBeat = 4
    static let cell = 2

    // MARK: ASCII tab

    /// Renders the system as aligned text rows:
    /// volta/marks, chords, six tab strings (e B G D A E; "x" = chord-tone pick, digits = frets), strokes
    /// ("v" down, "^" up), melody (degree with ' / , for octave dots, #/b prefix), one lyric row per verse.
    /// Beats are quantized to 1/4 beat; every measure is padded so all rows stay aligned.
    public static func asciiTab(_ system: NotationSystem, defaultBeats: Double = 4) -> String {
        let ms = system.measures
        guard !ms.isEmpty else { return "" }
        let verses = system.verseCount
        // Row keys: 0 marks, 1 chords, 2...7 strings (1..6), 8 strokes, 9 melody, 10... lyrics.
        let rowCount = 10 + verses
        var rows = [[String]](repeating: [], count: rowCount)
        var hasMelody = false, hasStroke = false

        for (i, m) in ms.enumerated() {
            let beats = max(m.beats ?? defaultBeats, 0.25)
            let slots = max(Int((beats * Double(slotsPerBeat)).rounded(.up)), 1)
            var tokens = [[(col: Int, text: String)]](repeating: [], count: rowCount)
            func col(_ beat: Double) -> Int { max(0, Int((beat * Double(slotsPerBeat)).rounded())) * cell }
            var label = ""
            if !m.volta.isEmpty { label += m.volta.map { "\($0)." }.joined(separator: ",") + " " }
            label += m.marks.joined(separator: " ")
            if !label.isEmpty { tokens[0].append((0, label)) }
            for c in m.chords { tokens[1].append((col(c.beat), c.name)) }
            for ev in m.tab {
                let c = col(ev.beat)
                for n in ev.notes where (1...6).contains(n.string) {
                    var t = n.chordTone ? "x" : String(n.fret)
                    switch n.technique {
                    case .hammerOn: t += "h"
                    case .pullOff: t += "p"
                    case .slideUp: t += "/"
                    case .slideDown: t += "\\"
                    case .bend: t += "b"
                    case .harmonic: t = "<" + t + ">"
                    case .mute: t = "(" + t + ")"
                    case .tie: t = "~" + t
                    case nil: break
                    }
                    tokens[1 + n.string].append((c, t))
                }
                if let s = ev.stroke { tokens[8].append((c, s == .down ? "v" : "^")); hasStroke = true }
            }
            for n in m.melody {
                var t = n.degree == 0 ? "0" : String(n.degree)
                if n.degree != 0 {
                    if n.accidental > 0 { t = "#" + t } else if n.accidental < 0 { t = "b" + t }
                    if n.octave > 0 { t += String(repeating: "'", count: n.octave) }
                    if n.octave < 0 { t += String(repeating: ",", count: -n.octave) }
                }
                if n.tieToNext { t += "~" }
                tokens[9].append((col(n.beat), t))
                hasMelody = true
                for v in 0..<verses where v < n.lyrics.count && !n.lyrics[v].isEmpty {
                    tokens[10 + v].append((col(n.beat), n.lyrics[v]))
                }
            }
            var width = slots * cell
            for r in tokens { for t in r { width = max(width, t.col + t.text.count + 1) } }
            for r in 0..<rowCount {
                let fill: Character = (2...7).contains(r) ? "-" : " "
                var chars = [Character](repeating: fill, count: width)
                for t in tokens[r].sorted(by: { $0.col < $1.col }) {
                    for (k, ch) in t.text.enumerated() where t.col + k < width { chars[t.col + k] = ch }
                }
                rows[r].append(String(chars))
            }
            _ = i
        }

        func boundary(_ i: Int) -> String {   // before measure i (i == ms.count → after the last)
            let prev: BarlineKind? = i > 0 ? ms[i - 1].rightBarline : nil
            let cur: BarlineKind? = i < ms.count ? ms[i].leftBarline : nil
            let end = prev == .endRepeat || prev == .startEndRepeat || (i == ms.count ? false : cur == .endRepeat)
            let start = cur == .startRepeat || cur == .startEndRepeat || prev == .startRepeat || prev == .startEndRepeat
            if end && start { return ":|:" }
            if end { return ":|" }
            if start { return "|:" }
            if prev == .final || cur == .final { return "|]" }
            if prev == .double || cur == .double { return "||" }
            return "|"
        }
        let bars = (0...ms.count).map(boundary)
        let labels = ["", "", "e", "B", "G", "D", "A", "E", "", "", ""]
        var lines: [String] = []
        for r in 0..<rowCount {
            if r == 8 && !hasStroke { continue }
            if r == 9 && !hasMelody { continue }
            let isString = (2...7).contains(r)
            var line = ""
            for (i, body) in rows[r].enumerated() {
                line += isString ? bars[i] : String(repeating: " ", count: bars[i].count)
                line += body
            }
            line += isString ? bars[ms.count] : ""
            let prefix: String
            switch r {
            case 0, 1: prefix = "  "
            case 8: prefix = "  "
            case 9: prefix = "♪ "
            case 10...: prefix = "\(r - 9)."
            default: prefix = labels[r] + " "
            }
            let text = prefix + line
            if r <= 1 || r >= 8 { lines.append(text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) }
            else { lines.append(text) }
        }
        // Drop empty leading rows (no marks / chords).
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty || false }.joined(separator: "\n")
    }

    // MARK: ChordPro (lossy)

    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "}", with: ")")
    }

    /// ChordPro lines for one system: `{c: ...}` notes (repeats, voltas, marks, non-standard chord names, extra verses)
    /// and one line with `[chord]syllable` text per measure (verse 1 only). Chord names are the normalized symbols
    /// so that `ChordProParser` can read them back; the printed names go into the notes. Tab, melody notes, chord
    /// diagrams and further verses are NOT exported.
    public static func chordProLines(_ system: NotationSystem) -> [String] {
        var notes: [String] = []
        var body = ""
        var anyLyric = false
        var renamed: [String] = []
        let ms = system.measures
        for (i, m) in ms.enumerated() {
            var parts: [(beat: Double, order: Int, text: String)] = []
            for c in m.chords {
                let norm = ChordNameNormalizer.normalize(c.name)
                let name = norm.symbol?.description ?? c.name
                if norm.symbol != nil, name != c.name.trimmingCharacters(in: .whitespaces) {
                    let entry = "\(c.name) = \(name)"
                    if !renamed.contains(entry) { renamed.append(entry) }
                }
                parts.append((c.beat, 0, "[\(name)]"))
            }
            for n in m.melody {
                let t = m.lyric(of: n, verse: 0)
                if !t.isEmpty { parts.append((n.beat, 1, t)); anyLyric = true }
            }
            parts.sort { $0.beat != $1.beat ? $0.beat < $1.beat : $0.order < $1.order }
            let text = parts.map(\.text).joined()
            body += text
            if !anyLyric || text.isEmpty { body += text.isEmpty ? "" : " " }
            if m.leftBarline == .startRepeat || m.leftBarline == .startEndRepeat { notes.append("m\(i + 1): repeat start") }
            if m.rightBarline == .endRepeat || m.rightBarline == .startEndRepeat { notes.append("m\(i + 1): repeat end") }
            if !m.volta.isEmpty { notes.append("m\(i + 1): ending \(m.volta.map(String.init).joined(separator: ","))") }
            for mark in m.marks { notes.append("m\(i + 1): \(mark)") }
        }
        var out: [String] = []
        if !renamed.isEmpty { notes.append("chord names: " + renamed.joined(separator: "; ")) }
        if system.verseCount > 1 { notes.append("\(system.verseCount) verses, only verse 1 exported") }
        for n in notes { out.append("{c: \(sanitize(n))}") }
        let line = body.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { out.append(line) }
        return out
    }
}
