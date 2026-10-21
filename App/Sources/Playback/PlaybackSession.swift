import Foundation
import AGRCore

// Framework-free playback state machine. The audio side is hidden behind `PlaybackOutput` (implemented by
// `PlaybackEngine` with AVAudioEngine; a fake in the unit tests).

/// The audio side of playback. All members are called from the main actor; implementations must make the hand-over to
/// the audio thread safe (see `SequencerBox`).
@MainActor
protocol PlaybackOutput: AnyObject {
    var sampleRate: Double { get }
    /// Replaces the sequencer with one rendering `events`, positioned at `seekSeconds` (engine time, count-in included).
    func install(events: [NoteEvent], seekSeconds: Double, playing: Bool)
    func setPlaying(_ playing: Bool)
    func seek(toSeconds: Double)
    /// Engine time as seen from the main thread (see `SequencerEngine.positionSeconds`).
    var positionSeconds: Double { get }
    func setVolume(_ volume: Float)
    func setBrightness(_ brightness: Float)
}

enum PlaybackState: Equatable {
    case idle
    case playing
    case paused
}

@MainActor
final class PlaybackSession {
    private(set) var state: PlaybackState = .idle
    private(set) var plan: PlaybackPlan
    private(set) var params: PlaybackParameters
    let score: Score
    private let output: PlaybackOutput
    /// True once `output` holds a sequencer for `plan` (lazy: planning happens on the first play).
    private var installed = false
    private var lastReading: PlaybackReading?

    /// Called when the piece (or the loop's last repeat) has finished.
    var onFinish: (() -> Void)?

    init(score: Score, output: PlaybackOutput, params: PlaybackParameters = PlaybackParameters()) {
        self.score = score
        self.output = output
        self.params = params
        self.plan = PlaybackPlan.make(score: score, params: params)
    }

    var timeline: Timeline { plan.timeline }
    var isPlaying: Bool { state == .playing }

    // MARK: Transport

    /// Starts from the beginning when idle, resumes when paused.
    func play() {
        switch state {
        case .playing:
            return
        case .paused:
            output.setPlaying(true)
            state = .playing
        case .idle:
            output.install(events: plan.events, seekSeconds: 0, playing: true)
            installed = true
            state = .playing
        }
    }

    func pause() {
        guard state == .playing else { return }
        output.setPlaying(false)
        state = .paused
    }

    func togglePause() {
        if state == .playing { pause() } else { play() }
    }

    /// Back to the start (count-in again) and keep the current play / pause state; idle starts playing.
    func restart() {
        guard installed else { play(); return }
        output.seek(toSeconds: 0)
        output.setPlaying(true)
        state = .playing
        lastReading = nil
    }

    /// Silences the output and forgets the position. The next `play()` starts from the beginning.
    func stop() {
        if installed {
            output.setPlaying(false)
            output.seek(toSeconds: 0)
        }
        state = .idle
        lastReading = nil
    }

    /// Jumps to the first beat of `eventIndex` (tap on a line while playing).
    func seek(toEvent eventIndex: Int) {
        guard installed, plan.timeline.events.indices.contains(eventIndex) else { return }
        let t = plan.engineSeconds(forBeat: plan.timeline.events[eventIndex].startBeat)
        output.seek(toSeconds: t)
    }

    // MARK: Parameters

    /// Re-plans with new parameters. While playing or paused the sequencer is replaced and resumes at the equivalent
    /// beat (same musical position, new tempo / transposition / strum / loop).
    func updateParameters(_ newParams: PlaybackParameters) {
        var p = newParams
        p.tempoScale = newParams.clampedTempoScale
        guard p != params else { return }
        let old = plan
        let oldSeconds = installed ? output.positionSeconds : 0
        let new = PlaybackPlan.make(score: score, params: p)
        params = p
        plan = new
        guard installed else { return }
        let resume = PlaybackPlan.resumeSeconds(from: old, atEngineSeconds: oldSeconds, to: new)
        output.install(events: new.events, seekSeconds: resume, playing: state == .playing)
    }

    func setVolume(_ v: Float) { output.setVolume(min(max(v, 0), 1)) }
    func setBrightness(_ v: Float) { output.setBrightness(min(max(v, 0), 1)) }

    // MARK: Position

    /// Polls the engine position (display rate). Detects the end of the piece.
    @discardableResult
    func tick() -> PlaybackReading? {
        guard installed, state != .idle else { return lastReading }
        let t = output.positionSeconds
        if state == .playing, t >= plan.finishSeconds {
            output.setPlaying(false)
            state = .idle
            installed = true
            output.seek(toSeconds: 0)
            lastReading = nil
            onFinish?()
            return nil
        }
        lastReading = plan.reading(atEngineSeconds: t)
        return lastReading
    }

    var reading: PlaybackReading? { lastReading }
}
