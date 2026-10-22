import Foundation

/// Compact one-line text rendering of notation measures. Used in prompts (`AIIssue.context`)
/// and in the fix review UI (before → after).
///
/// Measure: `[beats=3] |: C@0 G@2 | tab 0:×6×4×3 1:5:3 2.5:↓ | mel ♯4'(0+1) 1,(1+0.5)~ 0(1.5+0.5) | v1 我 曾 | v2 · 你 :|`
///   chords `name@beat` (@0 omitted), tab events `beat:` + `×<string>` chord-tone picks or `<string>:<fret>` plus
///   `↓`/`↑` strokes and chord names, melody `[♯|♭]degree[']*|[,]*(beat+duration)[~]` (degree 0 = rest),
///   verses `vN` with `·` for an empty syllable.
public enum AICompactRenderer {
    public static func number(_ x: Double) -> String {
        if x == x.rounded() && abs(x) < 1e9 { return String(Int(x)) }
        var s = String(format: "%.3f", x)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    public static func render(measure m: NotationMeasure) -> String {
        var parts: [String] = []
        if let b = m.beats { parts.append("[beats=\(number(b))]") }
        let left = barText(m.leftBarline, left: true)
        if !left.isEmpty { parts.append(left) }
        if !m.volta.isEmpty { parts.append("volta" + m.volta.map(String.init).joined(separator: "/")) }
        if !m.chords.isEmpty {
            parts.append(m.chords.map { $0.beat == 0 ? $0.name : "\($0.name)@\(number($0.beat))" }.joined(separator: " "))
        }
        if !m.tab.isEmpty { parts.append("tab " + m.tab.map(render(event:)).joined(separator: " ")) }
        if !m.melody.isEmpty { parts.append("mel " + m.melody.map(render(note:)).joined(separator: " ")) }
        let verses = m.verseCount
        for v in 0..<verses {
            let syl = m.melody.map { v < $0.lyrics.count && !$0.lyrics[v].isEmpty ? $0.lyrics[v] : "·" }
            parts.append("v\(v + 1) " + syl.joined(separator: " "))
        }
        if !m.marks.isEmpty { parts.append("marks:" + m.marks.joined(separator: ",")) }
        let right = barText(m.rightBarline, left: false)
        if !right.isEmpty { parts.append(right) }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: " | ")
    }

    public static func render(event e: TabEvent) -> String {
        var s = number(e.beat) + ":"
        if let c = e.chord { s += "[\(c)]" }
        if let st = e.stroke { s += st == .down ? "↓" : "↑" }
        let notes = e.notes.map { n -> String in
            let base = n.chordTone ? "×\(n.string)" : "\(n.string):\(n.fret)"
            return n.technique.map { base + "(\($0.rawValue))" } ?? base
        }
        return s + notes.joined(separator: "")
    }

    public static func render(note n: MelodyNote) -> String {
        var s = ""
        if n.accidental > 0 { s += "♯" } else if n.accidental < 0 { s += "♭" }
        s += String(n.degree)
        if n.octave > 0 { s += String(repeating: "'", count: n.octave) }
        if n.octave < 0 { s += String(repeating: ",", count: -n.octave) }
        s += "(\(number(n.beat))+\(number(n.duration)))"
        if n.tieToNext { s += "~" }
        return s
    }

    static func barText(_ b: BarlineKind, left: Bool) -> String {
        switch b {
        case .single: return ""
        case .double: return left ? "" : "||"
        case .final: return left ? "" : "|]"
        case .startRepeat: return "|:"
        case .endRepeat: return ":|"
        case .startEndRepeat: return ":|:"
        }
    }

    /// Renders the whole system (one measure per line, numbered).
    public static func render(system: NotationSystem, startIndex: Int = 0) -> String {
        system.measures.enumerated().map { "m\($0.offset + startIndex): " + render(measure: $0.element) }.joined(separator: "\n")
    }

    /// Before/after text for a patched location. If `path` lies inside a notation measure
    /// (`...system.measures[k]...`) the whole measure is rendered compactly; otherwise the JSON subtree
    /// at the deepest resolvable ancestor is shown.
    public static func describe(path: String, in score: Score) -> String {
        guard let tokens = try? ScorePath.parse(path), let tree = try? AIJSONValue.from(score) else { return "(?)" }
        return describe(tokens: tokens, in: tree)
    }

    static func describe(tokens: [PathToken], in tree: AIJSONValue) -> String {
        // Find `measures[k]` preceded by `system`.
        for i in 0..<tokens.count {
            if case .key("measures") = tokens[i], i + 1 < tokens.count, case .index = tokens[i + 1], i >= 1, case .key("system") = tokens[i - 1] {
                let prefix = Array(tokens[0...(i + 1)])
                if let node = ScorePatcher.resolve(prefix[...], in: tree), let m = try? node.decode(NotationMeasure.self) {
                    return render(measure: m)
                }
                // measures[k] no longer exists (deleted): fall back to the parent array length
                return "(无此小节)"
            }
        }
        var prefix = tokens
        while !prefix.isEmpty {
            if let node = ScorePatcher.resolve(prefix[...], in: tree) {
                let text = node.compactText
                return text.count > 240 ? String(text.prefix(240)) + "…" : text
            }
            prefix.removeLast()
        }
        return "(无)"
    }
}
