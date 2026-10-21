import Foundation
import AGRCore

/// Maps a tapped score line to the timeline event the follower should be relocated to.
enum FollowRelocation {
    /// First event of `line`. A section that is repeated in the arrangement has one pass per repetition; the pass whose
    /// first event is nearest to `current` wins (ties go forward). A line without events (comment / blank line) maps to
    /// the first event of the next line in the same section (else the last event before it).
    static func eventIndex(forLine line: LineRef, in timeline: Timeline, near current: Int) -> Int? {
        var exact: [Int: Int] = [:]          // passIndex -> first event of the line
        for e in timeline.events where e.line == line {
            if exact[e.passIndex] == nil { exact[e.passIndex] = e.index }
        }
        var chosen = exact
        if chosen.isEmpty {
            var next: [Int: Int] = [:]       // passIndex -> first event of the next line with events
            var previous: [Int: Int] = [:]   // passIndex -> last event of an earlier line
            for e in timeline.events where e.line.sectionIndex == line.sectionIndex {
                if e.line.lineIndex > line.lineIndex {
                    if next[e.passIndex] == nil { next[e.passIndex] = e.index }
                } else if e.line.lineIndex < line.lineIndex {
                    previous[e.passIndex] = e.index
                }
            }
            for (pass, idx) in next { chosen[pass] = idx }
            for (pass, idx) in previous where chosen[pass] == nil { chosen[pass] = idx }
        }
        return chosen.values.min { a, b in
            let da = abs(a - current), db = abs(b - current)
            return da != db ? da < db : a > b
        }
    }
}
