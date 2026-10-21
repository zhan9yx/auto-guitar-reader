import Foundation

/// ChordPro parser (`{title: ...}`, `[C]inline chords`, `{soc}`, `{sot}` ...).
///
/// Supported directives: title/t, subtitle/st (used as artist when none given), artist, composer, lyricist,
/// arranger, key, capo, tempo, time, tuning, meta, define, comment/c/ci/cb, start_of_*/end_of_* (chorus, verse,
/// bridge, part, tab, any SectionKind name) and the short forms soc/eoc, sov/eov, sob/eob, sot/eot.
/// Unknown directives are ignored.
public enum ChordProParser {
    public static func parse(_ text: String) throws -> Score {
        let lines = splitLines(text)
        guard lines.contains(where: { !$0.agrTrimmed.isEmpty }) else { throw ImportError.empty }

        var state = State(beatsPerMeasure: prescanBeats(lines))
        for line in lines { state.consume(line) }
        return try state.finish()
    }

    // MARK: Directive syntax

    struct Directive {
        var name: String
        var arg: String
    }

    static func directive(in line: String) -> Directive? {
        let t = line.agrTrimmed
        guard t.hasPrefix("{"), t.hasSuffix("}"), t.count >= 3 else { return nil }
        let inner = String(t.dropFirst().dropLast()).agrTrimmed
        guard let first = inner.first, first.isLetter || first == "_" else { return nil }
        var name = ""
        var idx = inner.startIndex
        while idx < inner.endIndex, inner[idx].isLetter || inner[idx].isNumber || inner[idx] == "_" || inner[idx] == "-" {
            name.append(inner[idx])
            idx = inner.index(after: idx)
        }
        var rest = String(inner[idx...]).agrTrimmed
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()).agrTrimmed }
        return Directive(name: name.lowercased().replacingOccurrences(of: "-", with: "_"), arg: rest)
    }

    private static func prescanBeats(_ lines: [String]) -> Double {
        for l in lines {
            if let d = directive(in: l), d.name == "time", let (b, _) = parseTime(d.arg) { return Double(b) }
        }
        return 4
    }

    static func parseTime(_ s: String) -> (Int, Int)? {
        guard let g = Rx.firstMatch(#"(\d{1,2})\s*/\s*(\d{1,2})"#, in: s), let a = g[1].flatMap({ Int($0) }), let b = g[2].flatMap({ Int($0) }), a > 0, b > 0 else { return nil }
        return (a, b)
    }

    // MARK: Parsing state

    private struct State {
        var meta = ScoreMeta(source: ScoreSource(kind: .chordpro))
        var builder = SectionBuilder()
        var definitions: [String: ChordShape] = [:]
        var subtitle: String?
        var explicitMode: PlayMode?
        var tabBody: [String]?
        var inGrid = false
        let beatsPerMeasure: Double

        init(beatsPerMeasure: Double) { self.beatsPerMeasure = beatsPerMeasure }

        mutating func consume(_ rawLine: String) {
            let trimmed = rawLine.agrTrimmed
            if tabBody != nil {
                if let d = ChordProParser.directive(in: rawLine), d.name == "end_of_tab" || d.name == "eot" {
                    finishTab()
                } else {
                    tabBody?.append(rawLine)
                }
                return
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }
            if let d = ChordProParser.directive(in: rawLine) {
                handle(d)
                return
            }
            if inGrid { return }
            if let inline = InlineChordParser.parse(rawLine) {
                builder.add(InlineChordParser.makeLine(inline))
            } else {
                builder.add(Line(kind: .lyrics, segments: [ChordSegment(chord: nil, text: trimmed)]))
            }
        }

        mutating func finishTab() {
            let body = tabBody ?? []
            tabBody = nil
            for line in AsciiTabParser.parseLines(body, beatsPerMeasure: beatsPerMeasure) { builder.add(line) }
        }

        mutating func handle(_ d: Directive) {
            let arg = d.arg
            switch d.name {
            case "title", "t": meta.title = arg
            case "subtitle", "st": subtitle = arg
            case "artist": meta.artist = arg
            case "composer": meta.composer = arg
            case "lyricist": meta.lyricist = arg
            case "arranger": meta.arranger = arg
            case "key": if !arg.isEmpty { meta.key = arg }
            case "capo": if let n = Rx.firstMatch(#"(\d+)"#, in: arg)?[1].flatMap({ Int($0) }) { meta.capo = n }
            case "tempo": if let v = Rx.firstMatch(#"(\d+(?:\.\d+)?)"#, in: arg)?[1].flatMap({ Double($0) }), v > 0 { meta.tempo = v }
            case "time": if let (b, u) = ChordProParser.parseTime(arg) { meta.timeSignature = TimeSignature(beats: b, unit: u) }
            case "tuning": if let t = TuningParser.parse(arg) { meta.tuning = t }
            case "meta": handleMeta(arg)
            case "define": handleDefine(arg)
            case "comment", "c", "comment_italic", "ci", "comment_box", "cb":
                if !arg.isEmpty { builder.add(Line(kind: .comment, text: arg)) }
            case "start_of_tab", "sot": tabBody = []
            case "start_of_grid", "sog": inGrid = true
            case "end_of_grid", "eog": inGrid = false
            case "soc": beginSection(kindName: "chorus", arg: arg)
            case "sov": beginSection(kindName: "verse", arg: arg)
            case "sob": beginSection(kindName: "bridge", arg: arg)
            case "eoc", "eov", "eob": builder.close()
            default:
                if d.name.hasPrefix("start_of_") {
                    beginSection(kindName: String(d.name.dropFirst("start_of_".count)), arg: arg)
                } else if d.name.hasPrefix("end_of_") {
                    builder.close()
                }
            }
        }

        mutating func beginSection(kindName: String, arg: String) {
            var label: String?
            if let g = Rx.firstMatch(#"label\s*=\s*"([^"]*)""#, in: arg) {
                label = g[1] ?? ""
            } else if !arg.isEmpty, !Rx.test(#"^\w+\s*="#, arg) {
                label = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).agrTrimmed
            }
            let kind: SectionKind
            if let k = SectionKind.fromDirectiveName(kindName) {
                kind = k
            } else {
                kind = label.flatMap { SectionKind.infer(from: $0) } ?? SectionKind.infer(from: kindName) ?? .other
            }
            builder.begin(name: label ?? (SectionKind.fromDirectiveName(kindName) != nil ? kind.defaultName : ""), kind: kind)
        }

        mutating func handleMeta(_ arg: String) {
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let value = parts[1].agrTrimmed
            switch parts[0].lowercased() {
            case "mode": explicitMode = PlayMode(rawValue: value)
            case "title": meta.title = value
            case "artist": meta.artist = value
            case "tag": meta.tags.append(value)
            default: handle(Directive(name: parts[0].lowercased(), arg: value))
            }
        }

        mutating func handleDefine(_ arg: String) {
            let tokens = arg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let name = tokens.first else { return }
            var base = 1
            var frets: [Int]?
            var fingers: [Int]?
            var i = 1
            func fretValue(_ s: String) -> Int? {
                if ["x", "X", "N", "n", "-"].contains(s) { return -1 }
                return Int(s)
            }
            while i < tokens.count {
                switch tokens[i].lowercased() {
                case "base_fret", "base-fret":
                    if i + 1 < tokens.count, let b = Int(tokens[i + 1]) { base = max(1, b) }
                    i += 2
                case "frets":
                    let vals = tokens[(i + 1)...].prefix(6).compactMap(fretValue)
                    if vals.count == 6 { frets = vals }
                    i += 7
                case "fingers":
                    let vals = tokens[(i + 1)...].prefix(6).map { Int($0) ?? 0 }
                    if vals.count == 6 { fingers = vals }
                    i += 7
                default: i += 1
                }
            }
            guard let rel = frets else { return }
            let absolute = rel.map { $0 > 0 ? $0 + base - 1 : $0 }
            definitions[name] = ChordShape(frets: absolute, fingers: fingers, baseFret: base)
        }

        mutating func finish() throws -> Score {
            if tabBody != nil { finishTab() }
            if meta.artist == nil, let s = subtitle, !s.isEmpty { meta.artist = s }
            let sections = builder.finish()
            if sections.isEmpty && meta.title.isEmpty && definitions.isEmpty { throw ImportError.empty }
            var score = Score(meta: meta, chordDefinitions: definitions, sections: sections)
            let kinds = Set(sections.flatMap(\.lines).map(\.kind))
            if let m = explicitMode {
                score.meta.mode = m
            } else if kinds.contains(.tab) && !kinds.contains(.lyrics) && !kinds.contains(.chords) {
                score.meta.mode = .fingerstyle
            }
            return score
        }
    }
}
