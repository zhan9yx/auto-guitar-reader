import Foundation

/// Exports a score as ChordPro text that `ChordProParser` reads back.
///
/// Preserved: title/artist/composer/lyricist/arranger/key/capo/tempo/time/tuning, play mode, chord
/// definitions, section names and kinds, line kinds, chord/lyric segments and tab events (rendered as ASCII tab
/// in `{sot}` blocks; beats are quantized to 1/8 beat and event durations become "until the next event").
/// Not preserved: segment `beats`, page anchors, strum patterns, arrangement, per-measure `beats` overrides.
public enum ChordProExporter {
    public static func export(_ score: Score) -> String {
        var out: [String] = []
        writeMeta(score, into: &out)
        for name in score.chordDefinitions.keys.sorted() {
            if let shape = score.chordDefinitions[name] { out.append(defineDirective(name, shape)) }
        }
        if !out.isEmpty { out.append("") }

        let beats = score.meta.timeSignature.beats
        for (i, section) in score.sections.enumerated() {
            let bare = i == 0 && section.name.isEmpty && section.kind == .other
            let kind = section.kind.rawValue.lowercased()
            if !bare {
                if section.name.isEmpty {
                    out.append(section.kind == .other ? "{start_of_other}" : "{start_of_\(kind): label=\"\"}")
                } else {
                    out.append("{start_of_\(kind): \(sanitize(section.name))}")
                }
            }
            for line in section.lines { out.append(contentsOf: lines(for: line, beats: beats)) }
            if !bare { out.append("{end_of_\(kind)}") }
            out.append("")
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "}", with: ")")
    }

    private static func formatNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private static func writeMeta(_ score: Score, into out: inout [String]) {
        let m = score.meta
        if !m.title.isEmpty { out.append("{title: \(sanitize(m.title))}") }
        if let v = m.artist, !v.isEmpty { out.append("{artist: \(sanitize(v))}") }
        if let v = m.composer, !v.isEmpty { out.append("{composer: \(sanitize(v))}") }
        if let v = m.lyricist, !v.isEmpty { out.append("{lyricist: \(sanitize(v))}") }
        if let v = m.arranger, !v.isEmpty { out.append("{arranger: \(sanitize(v))}") }
        if let v = m.key, !v.isEmpty { out.append("{key: \(sanitize(v))}") }
        if m.capo != 0 { out.append("{capo: \(m.capo)}") }
        if m.tempo != 80 { out.append("{tempo: \(formatNumber(m.tempo))}") }
        if m.timeSignature != TimeSignature() { out.append("{time: \(m.timeSignature.beats)/\(m.timeSignature.unit)}") }
        if m.tuning != ScoreMeta.standardTuning, m.tuning.count == 6 { out.append("{tuning: \(TuningParser.format(m.tuning))}") }
        for tag in m.tags { out.append("{meta: tag \(sanitize(tag))}") }
        let kinds = Set(score.sections.flatMap(\.lines).map(\.kind))
        let inferred: PlayMode = kinds.contains(.tab) && !kinds.contains(.lyrics) && !kinds.contains(.chords) ? .fingerstyle : .strumSing
        if m.mode != inferred { out.append("{meta: mode \(m.mode.rawValue)}") }
    }

    private static func defineDirective(_ name: String, _ shape: ChordShape) -> String {
        var base = max(1, shape.baseFret)
        if shape.frets.contains(where: { $0 > 0 && $0 < base }) { base = 1 }
        let rel = shape.frets.map { f -> String in
            if f < 0 { return "x" }
            return String(f > 0 ? f - base + 1 : 0)
        }
        var s = "{define: \(name) base-fret \(base) frets \(rel.joined(separator: " "))"
        if let fingers = shape.fingers, fingers.count == 6 { s += " fingers " + fingers.map(String.init).joined(separator: " ") }
        return s + "}"
    }

    private static func lines(for line: Line, beats: Int) -> [String] {
        switch line.kind {
        case .lyrics:
            let text = line.segments.map { ($0.chord.map { "[\($0)]" } ?? "") + $0.text }.joined()
            return text.isEmpty ? [] : [text]
        case .chords:
            let text = line.segments.compactMap { $0.chord.map { "[\($0)]" } }.joined(separator: " ")
            return text.isEmpty ? [] : [text]
        case .system:
            return []  // TODO(v2): export NotationSystem
        case .comment:
            guard let t = line.text, !t.isEmpty else { return [] }
            return ["{comment: \(sanitize(t))}"]
        case .tab:
            guard let tab = line.tab, !tab.measures.isEmpty else { return [] }
            return ["{sot}"] + AsciiTabParser.render(tab, defaultBeats: Double(beats)) + ["{eot}"]
        }
    }
}
