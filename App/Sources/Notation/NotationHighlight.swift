import Foundation
import AGRCore

/// Identifies one measure of a `.system` line.
struct NotationMeasureRef: Hashable {
    var line: LineRef
    var measure: Int
}

/// Position inside a notation system highlighted by playback / following.
struct NotationHighlight: Equatable {
    var line: LineRef
    var measureIndex: Int
    /// Beat inside the measure (0 = measure start).
    var beat: Double
}

enum NotationHighlightMapper {
    /// Maps a timeline event of a `.system` line to (measure, beat).
    ///
    /// ASSUMPTION about Core v2: system events carry `tabMeasureIndex` = index into `NotationSystem.measures`
    /// and `tabEventIndex` = index into that measure's `tab` (nil for rest / melody-only events). When the
    /// measure index is missing, the position is derived from `progressInLine.lowerBound` (fraction of the
    /// line's total beats, measures concatenated). The beat comes from `tab[tabEventIndex].beat`, else from
    /// the progress fraction, else 0.
    static func highlight(for event: TimelineEvent, in score: Score, defaultBeats: Double? = nil) -> NotationHighlight? {
        let ref = event.line
        guard score.sections.indices.contains(ref.sectionIndex),
              score.sections[ref.sectionIndex].lines.indices.contains(ref.lineIndex) else { return nil }
        let line = score.sections[ref.sectionIndex].lines[ref.lineIndex]
        guard line.kind == .system, let system = line.system, !system.measures.isEmpty else { return nil }
        let fallbackBeats = defaultBeats ?? Double(max(score.meta.timeSignature.beats, 1))

        if let measureIndex = event.tabMeasureIndex, system.measures.indices.contains(measureIndex) {
            let measure = system.measures[measureIndex]
            if let eventIndex = event.tabEventIndex, measure.tab.indices.contains(eventIndex) {
                return NotationHighlight(line: ref, measureIndex: measureIndex, beat: measure.tab[eventIndex].beat)
            }
            return NotationHighlight(line: ref, measureIndex: measureIndex,
                                     beat: position(inLine: system, fraction: event.progressInLine.lowerBound,
                                                    defaultBeats: fallbackBeats, restrictedTo: measureIndex)
                                        ?? 0)
        }
        return position(inLine: system, fraction: event.progressInLine.lowerBound, defaultBeats: fallbackBeats)
            .map { NotationHighlight(line: ref, measureIndex: $0.measure, beat: $0.beat) }
    }

    /// (measure, beat) at a fraction (0...1) of the line's total beats.
    static func position(inLine system: NotationSystem, fraction: Double, defaultBeats: Double)
        -> (measure: Int, beat: Double)? {
        let lengths = system.measures.map { max($0.beats ?? defaultBeats, 0.0001) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var remaining = min(max(fraction, 0), 1) * total
        for (index, length) in lengths.enumerated() {
            if remaining < length || index == lengths.count - 1 {
                return (index, min(remaining, length))
            }
            remaining -= length
        }
        return nil
    }

    /// Beat inside `measureIndex` for a line fraction, clamped to that measure; nil if the fraction falls elsewhere.
    static func position(inLine system: NotationSystem, fraction: Double, defaultBeats: Double,
                         restrictedTo measureIndex: Int) -> Double? {
        guard let p = position(inLine: system, fraction: fraction, defaultBeats: defaultBeats),
              p.measure == measureIndex else { return nil }
        return p.beat
    }
}
