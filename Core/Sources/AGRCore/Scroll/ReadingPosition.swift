import Foundation

/// Maps a follower state onto the document: y of the current reading position.
public enum ReadingPosition {
    /// `lineFrame` returns the document frame (minY, height) of a score line, nil if it is not laid out.
    /// The position inside the line interpolates `event.progressInLine` with `state.progressInEvent`
    /// (y = minY + height * progress), so the view drifts smoothly while a line is played.
    public static func documentY(state: FollowState, timeline: Timeline,
                                 lineFrame: (LineRef) -> (minY: Double, height: Double)?) -> Double? {
        documentY(eventIndex: state.eventIndex, progressInEvent: state.progressInEvent, timeline: timeline, lineFrame: lineFrame)
    }

    public static func documentY(eventIndex: Int, progressInEvent: Double, timeline: Timeline,
                                 lineFrame: (LineRef) -> (minY: Double, height: Double)?) -> Double? {
        guard timeline.events.indices.contains(eventIndex) else { return nil }
        let e = timeline.events[eventIndex]
        guard let f = lineFrame(e.line) else { return nil }
        let p = min(max(progressInEvent, 0), 1)
        let lo = e.progressInLine.lowerBound, hi = e.progressInLine.upperBound
        let progress = min(max(lo + (hi - lo) * p, 0), 1)
        return f.minY + f.height * progress
    }
}
