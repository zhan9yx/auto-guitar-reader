import SwiftUI
import Observation
import AGRCore

/// Mutable state shared between the reader and the (next-phase) playback / follow controllers.
///
/// The reader creates one by default; a controller can also create it first and pass it to
/// `ScoreReaderView(scoreID:session:...)` so it can set `highlight`, flip the activity flags and drive `driver`.
@Observable
@MainActor
final class ReaderSession {
    /// Line / segment currently highlighted by playback or follow.
    var highlight: (line: LineRef, segmentIndex: Int?)?
    /// True while a play / follow session is active (the reader keeps the screen awake).
    var isSessionActive: Bool = false
    var isPlaying: Bool = false
    var isFollowing: Bool = false

    /// Scroll bridge (not observed: it changes every frame).
    let driver = ScrollDriver()

    init() {}
}
