import Foundation
import AGRCore

// MARK: - Review issues

/// A problem found in an imported notation score (by OMR validation, the AI repair pass or the local lint).
/// `path` points into the score, e.g. "sections[0].lines[2].system.measures[3].melody[1]"; the first
/// `sections[i].lines[j].system.measures[k]` part is used to scroll to and flash the measure.
struct ReviewIssue: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case info = 0, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    var id = UUID()
    var path: String
    var message: String
    var severity: Severity = .warning

    init(path: String, message: String, severity: Severity = .warning) {
        self.path = path
        self.message = message
        self.severity = severity
    }

    /// The measure the path points at, if it has the `sections[i].lines[j].system.measures[k]` prefix.
    var measureRef: NotationMeasureRef? { ReviewIssuePath.measureRef(path) }

    static func == (a: ReviewIssue, b: ReviewIssue) -> Bool {
        a.path == b.path && a.message == b.message && a.severity == b.severity
    }
}

enum ReviewIssuePath {
    static func path(line: LineRef, measure: Int, tail: String = "") -> String {
        "sections[\(line.sectionIndex)].lines[\(line.lineIndex)].system.measures[\(measure)]" + tail
    }

    /// Parses `sections[i].lines[j].system.measures[k]...` (anything after the measure is ignored).
    static func measureRef(_ path: String) -> NotationMeasureRef? {
        let parts = path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4,
              let section = index(of: parts[0], name: "sections"),
              let line = index(of: parts[1], name: "lines"),
              parts[2] == "system",
              let measure = index(of: parts[3], name: "measures") else { return nil }
        return NotationMeasureRef(line: LineRef(sectionIndex: section, lineIndex: line), measure: measure)
    }

    private static func index(of part: String, name: String) -> Int? {
        let prefix = name + "["
        guard part.hasPrefix(prefix), let close = part.firstIndex(of: "]") else { return nil }
        let number = part[part.index(part.startIndex, offsetBy: prefix.count)..<close]
        guard let value = Int(number), value >= 0 else { return nil }
        return value
    }
}

/// Local consistency checks for notation scores (cheap; complements the importer's own validation).
enum NotationLint {
    static func issues(for score: Score) -> [ReviewIssue] {
        var out: [ReviewIssue] = []
        let defaultBeats = Double(max(score.meta.timeSignature.beats, 1))
        for (si, section) in score.sections.enumerated() {
            for (li, line) in section.lines.enumerated() where line.kind == .system {
                let ref = LineRef(sectionIndex: si, lineIndex: li)
                guard let system = line.system else {
                    out.append(ReviewIssue(path: "sections[\(si)].lines[\(li)]", message: "系统行缺少谱面内容", severity: .error))
                    continue
                }
                for (mi, m) in system.measures.enumerated() {
                    let beats = m.beats ?? defaultBeats
                    let label = "第 \(mi + 1) 小节"
                    if !m.melody.isEmpty {
                        let total = m.melody.reduce(0.0) { $0 + $1.duration }
                        if abs(total - beats) > 0.01 {
                            out.append(ReviewIssue(
                                path: ReviewIssuePath.path(line: ref, measure: mi, tail: ".melody"),
                                message: "\(label)：简谱时值合计 \(format(total)) 拍，小节应为 \(format(beats)) 拍",
                                severity: .warning))
                        }
                    }
                    for (ci, mark) in m.chords.enumerated() where ChordSymbol(mark.name) == nil {
                        out.append(ReviewIssue(
                            path: ReviewIssuePath.path(line: ref, measure: mi, tail: ".chords[\(ci)]"),
                            message: "\(label)：和弦“\(mark.name)”无法识别",
                            severity: .info))
                    }
                    for (ei, event) in m.tab.enumerated() {
                        if event.beat < 0 || event.beat >= beats + 0.001 {
                            out.append(ReviewIssue(
                                path: ReviewIssuePath.path(line: ref, measure: mi, tail: ".tab[\(ei)]"),
                                message: "\(label)：六线谱事件位置 \(format(event.beat)) 超出小节",
                                severity: .warning))
                        }
                        if event.notes.contains(where: { $0.string < 1 || $0.string > 6 }) {
                            out.append(ReviewIssue(
                                path: ReviewIssuePath.path(line: ref, measure: mi, tail: ".tab[\(ei)]"),
                                message: "\(label)：弦号必须是 1–6",
                                severity: .error))
                        }
                    }
                    let needsChord = m.tab.contains { $0.notes.contains { $0.chordTone } }
                    if needsChord && m.chords.isEmpty {
                        out.append(ReviewIssue(
                            path: ReviewIssuePath.path(line: ref, measure: mi, tail: ".chords"),
                            message: "\(label)：六线谱有“×”（和弦内音）但没有和弦",
                            severity: .warning))
                    }
                }
            }
        }
        return out
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

// MARK: - Measure editing model

/// What a string shows in the quick editor: nothing, "×" (chord tone) or a fret number.
enum TabCell: Hashable {
    case none
    case chordTone
    case fret(Int)

    static let maxFret = 24
}

enum MeasureEditing {
    static func cell(in event: TabEvent, string: Int) -> TabCell {
        guard let note = event.notes.first(where: { $0.string == string }) else { return .none }
        return note.chordTone ? .chordTone : .fret(note.fret)
    }

    /// Sets (or clears) one string of an event; keeps notes sorted low string number last → by string number.
    static func setCell(_ cell: TabCell, in event: inout TabEvent, string: Int) {
        var notes = event.notes
        let existing = notes.first(where: { $0.string == string })
        notes.removeAll { $0.string == string }
        switch cell {
        case .none: break
        case .chordTone: notes.append(TabNote.chordTone(string: string))
        case .fret(let fret):
            var note = TabNote(string: string, fret: min(max(fret, 0), TabCell.maxFret))
            note.technique = existing?.chordTone == false ? existing?.technique : nil
            notes.append(note)
        }
        event.notes = notes.sorted { $0.string < $1.string }
    }

    /// Adds a tab event after the last one (at the end of its duration, clamped to the measure).
    static func appendTabEvent(to measure: inout NotationMeasure, defaultBeats: Double) {
        let beats = measure.beats ?? defaultBeats
        let last = measure.tab.max { $0.beat + $0.duration < $1.beat + $1.duration }
        let start = min((last?.beat ?? 0) + (last?.duration ?? 0), max(beats - 0.25, 0))
        let duration = max(min(last?.duration ?? 0.5, beats - start), 0.25)
        measure.tab.append(TabEvent(beat: start, duration: duration))
    }

    static func appendMelodyNote(to measure: inout NotationMeasure, defaultBeats: Double) {
        let beats = measure.beats ?? defaultBeats
        let last = measure.melody.max { $0.beat + $0.duration < $1.beat + $1.duration }
        let start = min((last?.beat ?? 0) + (last?.duration ?? 0), max(beats - 0.25, 0))
        let duration = max(min(last?.duration ?? 1, beats - start), 0.25)
        let verses = measure.verseCount
        measure.melody.append(MelodyNote(beat: start, duration: duration, degree: 0,
                                         lyrics: Array(repeating: "", count: verses)))
    }

    /// Sets the lyric of `note` for `verse`, padding the verse array with "".
    static func setLyric(_ text: String, note: inout MelodyNote, verse: Int) {
        while note.lyrics.count <= verse { note.lyrics.append("") }
        note.lyrics[verse] = text
    }

    /// Adds an empty verse to every note of the measure.
    static func addVerse(to measure: inout NotationMeasure, verseCount: Int) {
        for index in measure.melody.indices {
            while measure.melody[index].lyrics.count < verseCount { measure.melody[index].lyrics.append("") }
        }
    }

    /// Chord name of the first mark (the one at the measure start), "" if none.
    static func primaryChordName(_ measure: NotationMeasure) -> String {
        measure.chords.sorted { $0.beat < $1.beat }.first?.name ?? ""
    }

    /// Renames the mark at beat 0 (creating it if needed); an empty name removes it. The printed shape is dropped.
    static func setPrimaryChord(_ name: String, in measure: inout NotationMeasure) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let index = measure.chords.indices.min { measure.chords[$0].beat < measure.chords[$1].beat }
        if trimmed.isEmpty {
            if let index = index { measure.chords.remove(at: index) }
            return
        }
        if let index = index {
            if measure.chords[index].name != trimmed { measure.chords[index].shape = nil }
            measure.chords[index].name = trimmed
        } else {
            measure.chords.append(ChordMark(name: trimmed, beat: 0))
        }
    }
}

extension Score {
    /// The measure a ref points at.
    func notationMeasure(_ ref: NotationMeasureRef) -> NotationMeasure? {
        guard sections.indices.contains(ref.line.sectionIndex),
              sections[ref.line.sectionIndex].lines.indices.contains(ref.line.lineIndex),
              let system = sections[ref.line.sectionIndex].lines[ref.line.lineIndex].system,
              system.measures.indices.contains(ref.measure) else { return nil }
        return system.measures[ref.measure]
    }

    /// Replaces a measure; returns false if the ref does not point at one.
    @discardableResult
    mutating func updateNotationMeasure(_ ref: NotationMeasureRef, _ measure: NotationMeasure) -> Bool {
        guard notationMeasure(ref) != nil else { return false }
        sections[ref.line.sectionIndex].lines[ref.line.lineIndex].system?.measures[ref.measure] = measure
        return true
    }
}
