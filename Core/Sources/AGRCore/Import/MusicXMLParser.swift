import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parser for uncompressed MusicXML (`score-partwise`).
///
/// Extracts title/composer/tempo/time/key, `<harmony>` chord symbols, `<lyric>` text and
/// `<technical><string>/<fret>` notes. With tab data the result has `.tab` lines (4 measures each, mode
/// `fingerstyle`); otherwise harmony + lyrics become chord/lyric lines. Rehearsal marks start sections.
public enum MusicXMLParser {
    public static func parse(_ data: Data) throws -> Score {
        guard !data.isEmpty else { throw ImportError.empty }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { throw ImportError.unsupportedFormat("mxl") }
        let reader = MusicXMLReader()
        let xml = XMLParser(data: data)
        xml.delegate = reader
        xml.shouldResolveExternalEntities = false
        let ok = xml.parse()
        if reader.isTimewise { throw ImportError.unsupportedFormat("score-timewise") }
        guard ok, reader.sawRoot, reader.closedRoot else {
            throw ImportError.malformed(xml.parserError?.localizedDescription ?? "not a MusicXML score-partwise document")
        }
        return try MusicXMLBuilder(reader: reader).build()
    }
}

// MARK: - Raw document model

struct XNote {
    var start = 0                // position in divisions from measure start
    var duration = 0
    var isRest = false
    var isChordMember = false
    var voice = 1
    var string: Int?
    var fret: Int?
    var lyric: String?
    var syllabic: String?
    var hammerStop = false, pullStop = false, slideStop = false, bend = false, harmonic = false, tieStop = false
}

struct XHarmony {
    var position: Int
    var name: String
}

struct XMeasure {
    var notes: [XNote] = []
    var harmonies: [XHarmony] = []
    var rehearsal: String?
    var beats = 4
    var beatType = 4
    var divisions = 1
}

struct XPart {
    var measures: [XMeasure] = []
}

// MARK: - XML reader

final class MusicXMLReader: NSObject, XMLParserDelegate {
    var sawRoot = false
    var closedRoot = false
    var isTimewise = false
    var workTitle: String?
    var movementTitle: String?
    var creators: [String: String] = [:]
    var tempo: Double?
    var keyFifths: Int?
    var keyMinor = false
    var parts: [XPart] = []

    private var path: [String] = []
    private var text = ""
    private var creatorType: String?

    // part state
    private var divisions = 1
    private var beats = 4
    private var beatType = 4
    private var position = 0
    private var lastStart = 0
    private var measure = XMeasure()

    // note / harmony state
    private var note: XNote?
    private var lyricNumber: String?
    private var lyricTaken = false
    private var lyricText = ""
    private var lyricSyllabic: String?
    private var harmony: (rootStep: String, rootAlter: Int, kind: String, kindText: String, bassStep: String, bassAlter: Int)?
    private var pendingSlideStart = false
    private var keyMode: String?
    private var timeBeats: String?
    private var perMinute: Double?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        let parent = path.last
        path.append(elementName)
        switch elementName {
        case "score-partwise": sawRoot = true
        case "score-timewise": isTimewise = true
        case "creator": creatorType = attributeDict["type"]
        case "part":
            parts.append(XPart())
            divisions = 1
        case "measure":
            measure = XMeasure(beats: beats, beatType: beatType, divisions: divisions)
            position = 0
            lastStart = 0
        case "sound":
            if tempo == nil, let t = attributeDict["tempo"].flatMap(Double.init), t > 0 { tempo = t }
        case "harmony":
            harmony = ("", 0, "", "", "", 0)
        case "kind":
            harmony?.kindText = attributeDict["text"] ?? ""
        case "note":
            note = XNote()
            lyricTaken = false
        case "rest": note?.isRest = true
        case "chord": if parent == "note" { note?.isChordMember = true }
        case "lyric":
            lyricNumber = attributeDict["number"]
            lyricText = ""
            lyricSyllabic = nil
        case "hammer-on": if attributeDict["type"] == "stop" { note?.hammerStop = true }
        case "pull-off": if attributeDict["type"] == "stop" { note?.pullStop = true }
        case "slide": if attributeDict["type"] == "stop" { note?.slideStop = true }
        case "bend": note?.bend = true
        case "harmonic": note?.harmonic = true
        case "tie": if attributeDict["type"] == "stop" { note?.tieStop = true }
        case "grace": note?.duration = 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.agrTrimmed
        path.removeLast()
        let parent = path.last
        switch elementName {
        case "work-title": if parent == "work" { workTitle = value }
        case "movement-title": movementTitle = value
        case "creator":
            if let t = creatorType, !value.isEmpty { creators[t.lowercased()] = value }
            creatorType = nil
        case "divisions": if let d = Int(value), d > 0 { divisions = d; measure.divisions = d }
        case "beats": if parent == "time" { timeBeats = value }
        case "beat-type":
            if parent == "time", let b = timeBeats.flatMap({ Int($0) }), let u = Int(value), b > 0, u > 0 {
                beats = b
                beatType = u
                measure.beats = b
                measure.beatType = u
            }
        case "fifths": if parent == "key", keyFifths == nil { keyFifths = Int(value) }
        case "mode": if parent == "key", keyMode == nil { keyMode = value; keyMinor = (value == "minor") }
        case "per-minute": if perMinute == nil { perMinute = Double(value) }
        case "rehearsal": if !value.isEmpty { measure.rehearsal = value }
        case "root-step": harmony?.rootStep = value
        case "root-alter": harmony?.rootAlter = Int(Double(value) ?? 0)
        case "kind": harmony?.kind = value
        case "bass-step": harmony?.bassStep = value
        case "bass-alter": harmony?.bassAlter = Int(Double(value) ?? 0)
        case "harmony": finishHarmony()
        case "duration":
            let d = Int(value) ?? 0
            if parent == "note" { note?.duration = d } else if parent == "backup" { position = max(0, position - d) } else if parent == "forward" { position += d }
        case "voice": if parent == "note" { note?.voice = Int(value) ?? 1 }
        case "string": if parent == "technical" { note?.string = Int(value) }
        case "fret": if parent == "technical" { note?.fret = Int(value) }
        case "syllabic": if parent == "lyric" { lyricSyllabic = value }
        case "text": if parent == "lyric" { lyricText += text }
        case "lyric": finishLyric()
        case "note": finishNote()
        case "measure": parts[parts.count - 1].measures.append(measure)
        case "score-partwise": closedRoot = true
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if tempo == nil, let p = perMinute, p > 0 { tempo = p }
    }

    private func finishHarmony() {
        guard let h = harmony else { return }
        harmony = nil
        guard !h.rootStep.isEmpty || h.kind == "none" else { return }
        var name: String
        if h.kind == "none" && h.rootStep.isEmpty {
            name = "N.C."
        } else {
            name = h.rootStep + MusicXMLReader.accidental(h.rootAlter) + MusicXMLReader.kindSuffix(h.kind, text: h.kindText)
            if !h.bassStep.isEmpty { name += "/" + h.bassStep + MusicXMLReader.accidental(h.bassAlter) }
        }
        measure.harmonies.append(XHarmony(position: position, name: name))
    }

    private func finishLyric() {
        guard note != nil, !lyricTaken else { return }
        guard lyricNumber == nil || lyricNumber == "1" else { return }
        let t = lyricText.agrTrimmed
        guard !t.isEmpty else { return }
        lyricTaken = true
        note?.lyric = t
        note?.syllabic = lyricSyllabic
    }

    private func finishNote() {
        guard var n = note else { return }
        note = nil
        if n.isChordMember {
            n.start = lastStart
        } else {
            n.start = position
            lastStart = position
            position += n.duration
        }
        measure.notes.append(n)
    }

    static func accidental(_ alter: Int) -> String {
        alter > 0 ? String(repeating: "#", count: alter) : String(repeating: "b", count: -alter)
    }

    static func kindSuffix(_ kind: String, text: String) -> String {
        switch kind {
        case "major": return ""
        case "minor": return "m"
        case "dominant", "dominant-seventh": return "7"
        case "major-seventh": return "maj7"
        case "minor-seventh": return "m7"
        case "diminished": return "dim"
        case "augmented": return "aug"
        case "half-diminished": return "m7b5"
        case "diminished-seventh": return "dim7"
        case "suspended-fourth": return "sus4"
        case "suspended-second": return "sus2"
        case "major-sixth": return "6"
        case "minor-sixth": return "m6"
        case "dominant-ninth": return "9"
        case "major-ninth": return "maj9"
        case "minor-ninth": return "m9"
        case "dominant-11th": return "11"
        case "dominant-13th": return "13"
        case "major-minor": return "mM7"
        case "power": return "5"
        default: return text
        }
    }
}

// MARK: - Score construction

struct MusicXMLBuilder {
    let reader: MusicXMLReader

    func build() throws -> Score {
        guard !reader.parts.isEmpty else { throw ImportError.malformed("no <part> found") }
        let allMeasures = reader.parts.flatMap(\.measures)
        let first = allMeasures.first ?? XMeasure()

        var meta = ScoreMeta(source: ScoreSource(kind: .musicXML))
        meta.title = reader.workTitle.flatMap { $0.isEmpty ? nil : $0 } ?? reader.movementTitle ?? ""
        meta.composer = reader.creators["composer"]
        meta.lyricist = reader.creators["lyricist"]
        meta.arranger = reader.creators["arranger"]
        meta.artist = reader.creators["artist"] ?? reader.creators["performer"]
        if let t = reader.tempo { meta.tempo = t }
        meta.timeSignature = TimeSignature(beats: first.beats, unit: first.beatType)
        if let f = reader.keyFifths, (-7...7).contains(f) {
            let majors = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"]
            let minors = ["Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#"]
            meta.key = reader.keyMinor ? minors[f + 7] + "m" : majors[f + 7]
        }

        let tabPart = reader.parts.first { $0.measures.contains { $0.notes.contains { Self.isTabNote($0) } } }
        let textPart = tabPart ?? reader.parts.first { part in
            part.measures.contains { !$0.harmonies.isEmpty || $0.notes.contains { $0.lyric != nil } }
        }
        guard let part = textPart else { throw ImportError.empty }

        var builder = SectionBuilder()
        let ranges = sectionRanges(part)
        for range in ranges {
            if let name = part.measures[range.lowerBound].rehearsal {
                builder.begin(name: name, kind: SectionKind.infer(from: name) ?? .other)
            } else if range.lowerBound == 0 {
                builder.begin(name: "", kind: .other)
            }
            let slice = Array(part.measures[range])
            let lines = tabPart != nil ? tabLines(slice, defaultBeats: meta.timeSignature.beats) : lyricLines(slice)
            for l in lines { builder.add(l) }
        }
        let sections = builder.finish()
        guard sections.contains(where: { !$0.lines.isEmpty }) else { throw ImportError.empty }
        meta.mode = tabPart != nil ? .fingerstyle : .strumSing
        return Score(meta: meta, sections: sections)
    }

    private static func isTabNote(_ n: XNote) -> Bool {
        !n.isRest && n.string != nil && n.fret != nil && (1...6).contains(n.string ?? 0)
    }

    /// Measure ranges split at rehearsal marks.
    private func sectionRanges(_ part: XPart) -> [Range<Int>] {
        var starts = [0]
        for (i, m) in part.measures.enumerated() where i > 0 && m.rehearsal != nil { starts.append(i) }
        return starts.enumerated().map { k, s in s..<(k + 1 < starts.count ? starts[k + 1] : part.measures.count) }
    }

    private func beatFactor(_ m: XMeasure) -> Double { Double(m.beatType) / 4.0 / Double(max(1, m.divisions)) }

    // MARK: Tab

    private func tabLines(_ measures: [XMeasure], defaultBeats: Int) -> [Line] {
        var lastFret: [Int: Int] = [:]
        var tabMeasures: [TabMeasure] = []
        for m in measures {
            let f = beatFactor(m)
            let notes = m.notes.filter(Self.isTabNote)
            let starts = Set(notes.map(\.start)).sorted()
            var events: [TabEvent] = []
            for s in starts {
                let group = notes.filter { $0.start == s }
                var tabNotes: [TabNote] = []
                for n in group {
                    guard let string = n.string, let fret = n.fret else { continue }
                    var tech: Technique?
                    if n.tieStop { tech = .tie }
                    else if n.hammerStop { tech = .hammerOn }
                    else if n.pullStop { tech = .pullOff }
                    else if n.slideStop { tech = fret >= (lastFret[string] ?? 0) ? .slideUp : .slideDown }
                    else if n.bend { tech = .bend }
                    else if n.harmonic { tech = .harmonic }
                    tabNotes.append(TabNote(string: string, fret: fret, technique: tech))
                    lastFret[string] = fret
                }
                let dur = Double(group.map(\.duration).max() ?? 0) * f
                events.append(TabEvent(beat: Double(s) * f, duration: max(dur, 0.125), notes: tabNotes.sorted { $0.string < $1.string }))
            }
            for h in m.harmonies where !events.isEmpty {
                let hb = Double(h.position) * f
                let idx = events.firstIndex { $0.beat >= hb - 1e-6 } ?? events.count - 1
                if events[idx].chord == nil { events[idx].chord = h.name }
            }
            tabMeasures.append(TabMeasure(beats: m.beats == defaultBeats ? nil : Double(m.beats), events: events))
        }
        var lines: [Line] = []
        var i = 0
        while i < tabMeasures.count {
            let end = min(i + 4, tabMeasures.count)
            lines.append(Line(kind: .tab, tab: TabBlock(measures: Array(tabMeasures[i..<end]))))
            i = end
        }
        return lines
    }

    // MARK: Chords + lyrics

    private func lyricLines(_ measures: [XMeasure]) -> [Line] {
        var lines: [Line] = []
        var i = 0
        while i < measures.count {
            let end = min(i + 4, measures.count)
            var items: [(measure: Int, pos: Int, order: Int, chord: String?, text: String)] = []
            for (mi, m) in measures[i..<end].enumerated() {
                for h in m.harmonies { items.append((mi, h.position, 0, h.name, "")) }
                for n in m.notes where n.lyric != nil && !n.isRest {
                    let t = n.lyric ?? ""
                    let cjk = t.contains(where: { $0.isCJK })
                    let space = !cjk && (n.syllabic == nil || n.syllabic == "single" || n.syllabic == "end")
                    items.append((mi, n.start, 1, nil, t + (space ? " " : "")))
                }
            }
            items.sort { ($0.measure, $0.pos, $0.order) < ($1.measure, $1.pos, $1.order) }
            var segs: [ChordSegment] = []
            for it in items {
                if let chord = it.chord {
                    segs.append(ChordSegment(chord: chord, text: ""))
                } else if segs.isEmpty {
                    segs.append(ChordSegment(chord: nil, text: it.text))
                } else {
                    segs[segs.count - 1].text += it.text
                }
            }
            if !segs.isEmpty { lines.append(InlineChordParser.makeLine(segs)) }
            i = end
        }
        return lines
    }
}
