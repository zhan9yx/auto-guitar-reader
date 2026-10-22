import Foundation
import AGRCore

// Framework-free helpers of the notation renderer (no SwiftUI / UIKit): text metrics, duration
// classification, beam / underline grouping, lyric placement and the mini chord diagram model.
// Everything here is unit-tested on Linux (see NotationLayoutTests.swift).

// MARK: - Text metrics

enum NotationText {
    /// CJK ideographs, kana, hangul and full-width forms (incl. CJK punctuation) occupy one em.
    static func isWide(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF00...0xFFEF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }

    /// Width in em of one character: wide = 1, latin letters / digits ~0.56, narrow punctuation / space less.
    static func emWidth(_ character: Character) -> CGFloat {
        if isWide(character) { return 1.0 }
        if character == " " { return 0.3 }
        if character.isLetter || character.isNumber { return 0.56 }
        if character.isPunctuation || character.isSymbol { return 0.34 }
        return 0.6
    }

    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for character in text { total += emWidth(character) }
        return total * fontSize
    }
}

// MARK: - Durations (tab rhythm + 简谱)

/// A duration in beats split into a binary base value, a dot, and the beam count of that base.
struct NoteValue: Equatable {
    var base: Double
    var dotted: Bool
    /// 0 = quarter or longer, 1 = eighth, 2 = sixteenth, ...
    var beams: Int

    static let bases: [Double] = [4, 2, 1, 0.5, 0.25, 0.125, 0.0625]

    static func classify(_ duration: Double) -> NoteValue {
        let eps = 1e-3
        let d = max(duration, 0.03)
        for base in bases {
            if abs(d - base) < eps { return NoteValue(base: base, dotted: false, beams: beamCount(base)) }
            if abs(d - base * 1.5) < eps { return NoteValue(base: base, dotted: true, beams: beamCount(base)) }
        }
        // Irregular value: use the largest base not longer than it.
        for base in bases where base <= d + eps {
            return NoteValue(base: base, dotted: false, beams: beamCount(base))
        }
        return NoteValue(base: 0.0625, dotted: false, beams: 4)
    }

    static func beamCount(_ base: Double) -> Int {
        if base >= 1 { return 0 }
        var count = 0
        var value = 1.0
        while value > base + 1e-9 && count < 4 {
            value /= 2
            count += 1
        }
        return count
    }

    enum Stem: Equatable { case none, short, full }

    /// Stem style for the rhythm notation under the tab staff.
    var stem: Stem {
        if base >= 4 { return .none }
        if base >= 2 { return .short }
        return .full
    }
}

// MARK: - Beam / underline grouping

/// One horizontal beam (tab rhythm) or underline (简谱) piece: `level` is 1-based (1 = nearest the stem tip / digit),
/// covering items `from...to` of the list that was grouped. `from == to` is a stub (single note with a flag).
struct BeamSegment: Equatable {
    var level: Int
    var from: Int
    var to: Int
    var isStub: Bool { from == to }
}

struct BeamGroup: Equatable {
    /// Consecutive indices into the grouped list.
    var indices: [Int]
    var segments: [BeamSegment]
}

enum BeamGrouping {
    /// Groups notes that carry at least one beam and share a `bucket` (usually the beat they start in).
    /// `levels[i]` is the beam count of item i (0 = not beamable), `buckets[i]` the grouping bucket.
    /// Items must be in time order; an item without beams ends the current group.
    static func groups(levels: [Int], buckets: [Int]) -> [BeamGroup] {
        precondition(levels.count == buckets.count)
        var result: [BeamGroup] = []
        var current: [Int] = []
        func flush() {
            guard !current.isEmpty else { return }
            result.append(BeamGroup(indices: current, segments: segments(for: current, levels: levels)))
            current = []
        }
        for index in levels.indices {
            if levels[index] <= 0 {
                flush()
                continue
            }
            if let last = current.last, buckets[last] != buckets[index] { flush() }
            current.append(index)
        }
        flush()
        return result
    }

    private static func segments(for indices: [Int], levels: [Int]) -> [BeamSegment] {
        var out: [BeamSegment] = []
        let maxLevel = indices.map { levels[$0] }.max() ?? 0
        guard maxLevel >= 1 else { return out }
        for level in 1...maxLevel {
            var runStart: Int?
            var previous: Int?
            for index in indices {
                if levels[index] >= level {
                    if runStart == nil { runStart = index }
                    previous = index
                } else if let start = runStart, let end = previous {
                    out.append(BeamSegment(level: level, from: start, to: end))
                    runStart = nil
                    previous = nil
                }
            }
            if let start = runStart, let end = previous {
                out.append(BeamSegment(level: level, from: start, to: end))
            }
        }
        return out
    }

    /// Beat bucket used for grouping (floor of the onset, tolerant to float noise).
    static func bucket(forBeat beat: Double) -> Int { Int((beat + 1e-6).rounded(.down)) }
}

/// Rhythm marks under the tab staff: one entry per tab event that has notes or a strum.
struct RhythmMark: Equatable {
    var eventIndex: Int
    var beat: Double
    var value: NoteValue
}

enum RhythmLayout {
    static func marks(for events: [TabEvent]) -> [RhythmMark] {
        events.enumerated()
            .filter { !$0.element.notes.isEmpty || $0.element.stroke != nil }
            .sorted { $0.element.beat < $1.element.beat }
            .map { RhythmMark(eventIndex: $0.offset, beat: $0.element.beat, value: NoteValue.classify($0.element.duration)) }
    }

    /// Beam groups over `marks` (indices refer to `marks`).
    static func beamGroups(for marks: [RhythmMark]) -> [BeamGroup] {
        BeamGrouping.groups(
            levels: marks.map { $0.value.beams },
            buckets: marks.map { BeamGrouping.bucket(forBeat: $0.beat) }
        )
    }
}

// MARK: - 简谱

/// How one melody note is written: underlines (8th = 1, 16th = 2), augmentation dot, "-" extension marks.
struct JianpuValue: Equatable {
    var underlines: Int
    var dotted: Bool
    /// Number of extra beat marks ("-" for notes, repeated "0" for rests) after the digit.
    var extensions: Int

    static func describe(duration: Double) -> JianpuValue {
        let eps = 1e-3
        if duration >= 1 - eps {
            let whole = Int((duration + eps).rounded(.down))
            let fraction = duration - Double(whole)
            return JianpuValue(underlines: 0, dotted: fraction >= 0.4, extensions: max(whole - 1, 0))
        }
        let value = NoteValue.classify(duration)
        return JianpuValue(underlines: value.beams, dotted: value.dotted, extensions: 0)
    }
}

enum JianpuLayout {
    /// Underline groups over a measure's melody (indices refer to `notes`): notes shorter than a beat that start in
    /// the same beat are joined, 16ths get a second level.
    static func underlineGroups(for notes: [MelodyNote]) -> [BeamGroup] {
        BeamGrouping.groups(
            levels: notes.map { JianpuValue.describe(duration: $0.duration).underlines },
            buckets: notes.map { BeamGrouping.bucket(forBeat: $0.beat) }
        )
    }

    /// Display width of one melody glyph (digit + accidental + dot) for a digit font size.
    static func glyphWidth(_ note: MelodyNote, fontSize: CGFloat) -> CGFloat {
        var width = fontSize * 0.6
        if note.accidental != 0 { width += fontSize * 0.35 }
        if JianpuValue.describe(duration: note.duration).dotted { width += fontSize * 0.28 }
        return width
    }
}

// MARK: - Lyric placement

enum LyricPlacement {
    /// Left edges of lyric texts centred on `centers`, pushed right so that neighbours do not overlap.
    /// Items with width 0 (no lyric) are skipped and keep their centre as left edge.
    static func place(centers: [CGFloat], widths: [CGFloat], minGap: CGFloat) -> [CGFloat] {
        precondition(centers.count == widths.count)
        var lefts: [CGFloat] = []
        var previousRight = -CGFloat.greatestFiniteMagnitude
        for index in centers.indices {
            let width = widths[index]
            if width <= 0 {
                lefts.append(centers[index])
                continue
            }
            let left = max(centers[index] - width / 2, previousRight + minGap)
            lefts.append(left)
            previousRight = left + width
        }
        return lefts
    }
}

// MARK: - Mini chord diagram model

/// Window of frets and per-string markers of a chord shape (strings low E → high E).
struct ChordDiagramModel: Equatable {
    enum Marker: Equatable { case muted, open, fretted(row: Int) }

    /// First fret shown in the window (label "3" when > 1).
    var startFret: Int
    var rows: Int
    var markers: [Marker]

    init(shape: ChordShape, rows: Int = 4) {
        self.rows = rows
        let frets = shape.frets
        let positive = frets.filter { $0 > 0 }
        let maxFret = positive.max() ?? 0
        let minFret = positive.min() ?? 1
        if shape.baseFret > 1 {
            startFret = shape.baseFret
        } else if maxFret <= rows {
            startFret = 1
        } else {
            startFret = minFret
        }
        let start = startFret
        markers = frets.map { fret in
            if fret < 0 { return .muted }
            if fret == 0 { return .open }
            return .fretted(row: min(max(fret - start, 0), rows - 1))
        }
    }

    /// Barre of the lowest fretted row (index range of strings) if the same fret is held on >= 4 strings.
    var barre: (row: Int, from: Int, to: Int)? {
        var best: (row: Int, from: Int, to: Int)?
        for row in 0..<rows {
            let strings = markers.indices.filter { markers[$0] == .fretted(row: row) }
            if let first = strings.first, let last = strings.last, strings.count >= 3, last - first >= 3 {
                // Only a barre if the row is the lowest used one and spans through the high strings.
                let usedRows = markers.compactMap { marker -> Int? in
                    if case .fretted(let r) = marker { return r }
                    return nil
                }
                if row == usedRows.min() { best = (row, first, last) }
                break
            }
        }
        return best
    }
}
