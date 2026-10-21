import Foundation
import AGRCore

// Framework-free follow pipeline: samples in -> FeatureExtractor -> ScoreFollower (+ LyricsAligner) -> throttled
// snapshots out. All heavy work happens on one serial "analysis" queue; the capture thread only copies samples and
// enqueues them. The adapters (MicCapture, SpeechLyricsRecognizer, FollowController) live in separate files.

/// What the UI / auto-scroller sees of the follower. Published at most ~30 Hz (plus immediately on event changes).
struct FollowSnapshot: Equatable, Sendable {
    var state: FollowState
    /// Line / chord segment of `state.eventIndex` (for the highlight).
    var line: LineRef?
    var segmentIndex: Int?
    /// Incremented by every relocation; snapshots of an older epoch are stale and dropped.
    var epoch: Int
    /// How many lyric-evidence updates have been applied so far.
    var lyricsEvidenceCount: Int

    var eventIndex: Int { state.eventIndex }
}

struct FollowSessionConfig {
    var mode: FollowMode
    var transpose: Int = 0
    var inputSampleRate: Double
    var followerConfig = FollowerConfig()
    var featureConfig = FeatureConfig()
    /// Create a `LyricsAligner` when the score has lyrics (evidence is only applied in strumSing mode).
    var lyricsEnabled = true
    /// Minimum audio-time distance between two published snapshots (event changes are published immediately).
    var publishInterval: Double = 1.0 / 30.0
    /// Back-pressure: chunks queued beyond this are dropped (about 3 s of 1024-sample chunks at 44.1 kHz).
    var maxPendingChunks = 128

    init(mode: FollowMode, transpose: Int = 0, inputSampleRate: Double) {
        self.mode = mode
        self.transpose = transpose
        self.inputSampleRate = inputSampleRate
    }
}

final class FollowSession: @unchecked Sendable {
    let score: Score
    let config: FollowSessionConfig
    /// Timeline of the untransposed score. The event layout (lines, passes, order) does not depend on the
    /// transposition, so it is used for line -> event mapping from any thread.
    let structure: Timeline

    private let queue: DispatchQueue

    // Owned by `queue`.
    private var timeline: Timeline
    private var transpose: Int
    private var mode: FollowMode
    private let extractor: FeatureExtractor
    private var follower: ScoreFollower
    private var aligner: LyricsAligner?
    private var lastPublishTime = -Double.infinity
    private var lastPublishedEvent = -1
    private var lyricsEvidenceCount = 0

    // Shared (guarded by `lock`).
    private let lock = NSLock()
    private var epoch = 0
    private var pendingChunks = 0
    private var droppedChunks = 0
    private var stopped = false
    private var latest: FollowSnapshot?
    private var publishHandler: ((FollowSnapshot) -> Void)?

    static func followMode(for mode: PlayMode) -> FollowMode {
        mode == .fingerstyle ? .fingerstyle : .strumSing
    }

    init(score: Score, config: FollowSessionConfig,
         queue: DispatchQueue = DispatchQueue(label: "agr.follow.analysis", qos: .userInitiated)) {
        self.score = score
        self.config = config
        self.queue = queue
        self.structure = Timeline.build(from: score)
        self.transpose = config.transpose
        self.mode = config.mode
        let tl = config.transpose == 0 ? structure : Timeline.build(from: score, options: TimelineOptions(transpose: config.transpose))
        self.timeline = tl
        self.extractor = FeatureExtractor(config: config.featureConfig, inputSampleRate: config.inputSampleRate)
        self.follower = ScoreFollower(timeline: tl, mode: config.mode, featureConfig: config.featureConfig,
                                      config: config.followerConfig)
        if config.lyricsEnabled {
            let a = LyricsAligner(timeline: tl)
            self.aligner = a.corpusLength >= 6 ? a : nil
        }
    }

    // MARK: Output

    /// Called on the analysis queue (and, for the optimistic snapshot of `relocate`, on the calling thread).
    var onPublish: ((FollowSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return publishHandler }
        set { lock.lock(); publishHandler = newValue; lock.unlock() }
    }

    var latestSnapshot: FollowSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    var currentEpoch: Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    var droppedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedChunks
    }

    /// True when a lyrics aligner exists (the score has lyrics and recognition is enabled).
    var usesLyrics: Bool { queue.sync { aligner != nil } }

    /// Blocks until everything enqueued so far has been processed (tests, shutdown).
    func drain() { queue.sync {} }

    /// Stops publishing and drops further input.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    // MARK: Input (any thread)

    func ingest(samples: UnsafeBufferPointer<Float>) {
        ingest(samples: Array(samples))
    }

    /// Hands a chunk of mono samples (at `config.inputSampleRate`) to the analysis queue. Returns immediately.
    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
        if pendingChunks >= config.maxPendingChunks {
            droppedChunks += 1
            lock.unlock()
            return
        }
        pendingChunks += 1
        let epochAtEnqueue = epoch
        // Enqueued while holding the lock, so the queue order matches the order of epoch changes (`relocate`).
        queue.async { [self] in
            lock.lock(); pendingChunks -= 1; lock.unlock()
            process(samples, epochAtEnqueue: epochAtEnqueue)
        }
        lock.unlock()
    }

    // MARK: Control (any thread)

    /// Maps `line` to the first event of that line (nearest pass to the current position), relocates the follower
    /// there and publishes an optimistic snapshot so the scroller reacts immediately. Returns the event index.
    @discardableResult
    func relocate(toLine line: LineRef) -> Int? {
        lock.lock()
        let current = latest?.eventIndex ?? 0
        lock.unlock()
        guard let index = FollowRelocation.eventIndex(forLine: line, in: structure, near: current) else { return nil }
        relocate(toEvent: index)
        return index
    }

    func relocate(toEvent index: Int) {
        guard structure.events.indices.contains(index) else { return }
        lock.lock()
        epoch += 1
        let newEpoch = epoch
        let previous = latest
        let optimistic = FollowSnapshot(
            state: FollowState(eventIndex: index, progressInEvent: 0, confidence: max(previous?.state.confidence ?? 0, 0.6),
                               tempoRatio: previous?.state.tempoRatio ?? 1, isPaused: false, time: previous?.state.time ?? 0),
            line: structure.events[index].line, segmentIndex: structure.events[index].segmentIndex,
            epoch: newEpoch, lyricsEvidenceCount: previous?.lyricsEvidenceCount ?? 0)
        let isStopped = stopped
        if !isStopped {
            latest = optimistic
            queue.async { [self] in
                follower.relocate(toEvent: index)
                lastPublishedEvent = index
            }
        }
        let handler = publishHandler
        lock.unlock()
        guard !isStopped else { return }
        handler?(optimistic)
    }

    /// The reader's transposition changed: rebuild the timeline (the follower is pitch-sensitive: it must expect the
    /// pitches the player actually plays) and keep the position.
    func updateTranspose(_ semitones: Int) {
        queue.async { [self] in
            guard semitones != transpose else { return }
            transpose = semitones
            rebuildFollower()
        }
    }

    func updateMode(_ newMode: FollowMode) {
        queue.async { [self] in
            guard newMode != mode else { return }
            mode = newMode
            rebuildFollower()
        }
    }

    /// New (partial) speech transcript. Aligned against the lyrics on the analysis queue; the result is multiplied
    /// into the follower's posterior.
    func applyTranscript(_ text: String) {
        queue.async { [self] in
            guard let aligner = aligner, mode == .strumSing else { return }
            guard let result = aligner.update(transcript: text) else { return }
            follower.applyLyricsEvidence(result.evidence, weight: result.weight)
            lyricsEvidenceCount += 1
        }
    }

    // MARK: Analysis queue

    private func rebuildFollower() {
        let state = follower.state
        timeline = transpose == 0 ? structure : Timeline.build(from: score, options: TimelineOptions(transpose: transpose))
        follower = ScoreFollower(timeline: timeline, mode: mode, featureConfig: config.featureConfig, config: config.followerConfig)
        follower.relocate(toEvent: state.eventIndex)
    }

    private func process(_ samples: [Float], epochAtEnqueue: Int) {
        let frames = extractor.process(samples)
        guard !frames.isEmpty else { return }
        var last = follower.state
        for frame in frames { last = follower.process(frame) }
        let changed = last.eventIndex != lastPublishedEvent
        guard changed || last.time - lastPublishTime >= config.publishInterval - 1e-9 else { return }
        publish(last, epochAtEnqueue: epochAtEnqueue)
    }

    private func publish(_ state: FollowState, epochAtEnqueue: Int) {
        let events = timeline.events
        let event = events.indices.contains(state.eventIndex) ? events[state.eventIndex] : nil
        lock.lock()
        // A relocation happened after this chunk was enqueued: its result describes the old position.
        guard !stopped, epoch == epochAtEnqueue else { lock.unlock(); return }
        let snapshot = FollowSnapshot(state: state, line: event?.line, segmentIndex: event?.segmentIndex,
                                      epoch: epoch, lyricsEvidenceCount: lyricsEvidenceCount)
        latest = snapshot
        let handler = publishHandler
        lock.unlock()
        lastPublishTime = state.time
        lastPublishedEvent = state.eventIndex
        handler?(snapshot)
    }
}
