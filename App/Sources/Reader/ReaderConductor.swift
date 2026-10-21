import Foundation
import Observation
import QuartzCore
import AGRCore

/// Orchestrates simulated playback, microphone following and auto-scroll for one open score.
///
/// * Playback and following are mutually exclusive (starting one stops the other).
/// * One display link (`AutoScrollCoordinator`) is the clock for everything visual: each frame polls the reading
///   position (playback engine position or the latest follower snapshot), updates the highlight (only on event
///   changes) and scrolls.
/// * The reader's idle timer flag is derived from `ReaderSession.isSessionActive`.
@MainActor
@Observable
final class ReaderConductor {
    enum Panel: Equatable {
        case none, playback, follow
    }

    enum Activity: Equatable {
        case idle, playing, following
    }

    // MARK: Observed state

    var panel: Panel = .none
    private(set) var activity: Activity = .idle
    /// The user scrolled by hand and automatic scrolling is paused ("回到跟随" is shown).
    private(set) var isManuallyScrolled = false
    /// Short human-readable note (interruption, device change, ...).
    var statusMessage: String?

    let playback = PlaybackController()
    let follow = FollowController()

    // MARK: Internals

    @ObservationIgnored let session: ReaderSession
    @ObservationIgnored private let audio = AudioSessionManager()
    @ObservationIgnored private var autoScroll: AutoScrollCoordinator?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var score: Score?
    @ObservationIgnored private var structure = Timeline()
    @ObservationIgnored private var transpose = 0
    @ObservationIgnored private var highlight = HighlightTracker()
    @ObservationIgnored private var activityStartedAt = 0.0
    @ObservationIgnored private var backgroundWatch: Task<Void, Never>?

    init(session: ReaderSession) {
        self.session = session
    }

    // MARK: Binding to a score

    /// Call whenever a score is (re)loaded. Stops everything that was running.
    func bind(score: Score, settings: SettingsStore) {
        stopActivity()
        self.score = score
        self.settings = settings
        structure = Timeline.build(from: score)
        highlight = HighlightTracker()

        playback.configure(score: score, defaultStrum: settings.defaultStrumPattern, countInBeats: settings.countInBeats)
        playback.onFinish = { [weak self] in self?.playbackFinished() }
        follow.mode = FollowSession.followMode(for: score.meta.mode)
        follow.onHardwareChange = { [weak self] in
            self?.stopActivity()
            self?.statusMessage = "音频设备已变化，已停止跟随。请重新开始。"
        }

        let coordinator = AutoScrollCoordinator(driver: session.driver, timeline: structure) { [weak settings] in
            settings?.autoScrollSettings ?? AutoScrollSettings()
        }
        coordinator.onOverrideChange = { [weak self] flag in
            if self?.isManuallyScrolled != flag { self?.isManuallyScrolled = flag }
        }
        autoScroll = coordinator

        session.driver.onDoubleTapLine = { [weak self] line in self?.handleDoubleTap(line) }
        audio.onEvent = { [weak self] event in self?.handleAudioEvent(event) }
    }

    /// Transposition of the reader (0 in image mode: the picture is the source of truth). Applied to the running
    /// performance: playback re-plans, the follower rebuilds its (pitch-sensitive) timeline.
    func setTranspose(_ semitones: Int) {
        guard semitones != transpose else { return }
        transpose = semitones
        playback.setTranspose(semitones)
        follow.updateTranspose(semitones)
    }

    // MARK: Panels

    func togglePanel(_ target: Panel) {
        if panel == target {
            closePanel()
        } else {
            stopActivity()
            statusMessage = nil
            panel = target
        }
    }

    func closePanel() {
        stopActivity()
        panel = .none
        statusMessage = nil
    }

    // MARK: Playback

    func startPlayback() {
        guard score != nil else { return }
        stopActivity()
        statusMessage = nil
        panel = .playback
        guard playback.start(audio: audio, transpose: transpose) else {
            statusMessage = playback.errorMessage
            audio.deactivate()
            return
        }
        activity = .playing
        activityStartedAt = CACurrentMediaTime()
        refreshSessionFlags()
        startAutoScroll()
    }

    func togglePlayPause() {
        if activity == .playing {
            playback.togglePause()
            refreshSessionFlags()
        } else {
            startPlayback()
        }
    }

    func restartPlayback() {
        if activity == .playing {
            playback.restart()
            autoScroll?.relocated()
            refreshSessionFlags()
        } else {
            startPlayback()
        }
    }

    private func playbackFinished() {
        // The piece ended: release the engine, keep the panel so the user can play again.
        stopActivity()
    }

    // MARK: Following

    func startFollow() async {
        guard let score = score, let settings = settings else { return }
        stopActivity()
        statusMessage = nil
        panel = .follow
        let options = FollowOptions(mode: follow.mode, transpose: transpose, followerConfig: settings.followerConfig,
                                    lyricsEnabled: settings.lyricsRecognitionEnabled,
                                    languageIdentifier: settings.recognitionLanguage.rawValue)
        activity = .following    // visible immediately ("starting"); reverted below on failure
        let ok = await follow.start(score: score, audio: audio, options: options)
        guard activity == .following else { return }     // stopped / panel closed while starting
        guard ok else {
            activity = .idle
            audio.deactivate()
            refreshSessionFlags()
            return
        }
        activityStartedAt = CACurrentMediaTime()
        refreshSessionFlags()
        startAutoScroll()
    }

    func toggleFollow() {
        if activity == .following {
            stopActivity()
        } else {
            Task { await startFollow() }
        }
    }

    func setFollowMode(_ mode: FollowMode) {
        follow.setMode(mode)
    }

    /// "回到跟随".
    func resumeAutoScroll() {
        autoScroll?.resumeFollowing()
    }

    // MARK: Stopping

    /// Stops playback / following, the display link and the audio session. The panel stays as it is.
    func stopActivity() {
        backgroundWatch?.cancel()
        backgroundWatch = nil
        autoScroll?.stop()
        playback.stop()
        follow.stop()
        audio.deactivate()
        audio.invalidate()
        activity = .idle
        isManuallyScrolled = false
        highlight = HighlightTracker()
        if session.highlight != nil { session.highlight = nil }
        refreshSessionFlags()
    }

    /// Reader disappears / score changes.
    func stopAll() {
        stopActivity()
        panel = .none
        statusMessage = nil
    }

    /// The app moved to the background: following needs the microphone and the screen, so it stops; playback may
    /// continue (UIBackgroundModes `audio`). The display link is paused in the background, so a small watcher
    /// keeps detecting the end of the piece there.
    func appDidEnterBackground() {
        switch activity {
        case .following:
            stopActivity()
            statusMessage = "App 进入后台，已停止跟随。"
        case .playing:
            backgroundWatch?.cancel()
            backgroundWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self = self, self.activity == .playing else { return }
                    _ = self.playback.tick()
                }
            }
        case .idle:
            break
        }
    }

    func appDidBecomeActive() {
        backgroundWatch?.cancel()
        backgroundWatch = nil
    }

    // MARK: Frame loop

    private func startAutoScroll() {
        autoScroll?.start { [weak self] now in self?.frame(now: now) }
    }

    private func frame(now: Double) -> ReadingSample? {
        switch activity {
        case .idle:
            return nil
        case .playing:
            guard let reading = playback.tick() else { return nil }
            applyHighlight(eventIndex: reading.eventIndex)
            return ReadingSample(eventIndex: reading.eventIndex, progressInEvent: reading.progressInEvent, confidence: 1)
        case .following:
            follow.pollLevel(now: now)
            guard let snapshot = follow.latestSnapshot, let reading = follow.latestReading else { return nil }
            // Do not move the highlight around while the follower is lost.
            if snapshot.state.confidence >= 0.3 || session.highlight == nil {
                applyHighlight(eventIndex: reading.eventIndex)
            }
            return reading
        }
    }

    private func applyHighlight(eventIndex: Int) {
        switch highlight.update(eventIndex: eventIndex, timeline: structure) {
        case .unchanged:
            break
        case .set(let target):
            session.highlight = (line: target.line, segmentIndex: target.segmentIndex)
        case .clear:
            session.highlight = nil
        }
    }

    private func refreshSessionFlags() {
        let playing = activity == .playing && playback.isPlaying
        let following = activity == .following
        if session.isPlaying != playing { session.isPlaying = playing }
        if session.isFollowing != following { session.isFollowing = following }
        let active = playing || following
        if session.isSessionActive != active { session.isSessionActive = active }
    }

    // MARK: Gestures

    private func handleDoubleTap(_ line: LineRef) {
        switch activity {
        case .following:
            follow.relocate(toLine: line)
            autoScroll?.relocated()
        case .playing:
            if let index = FollowRelocation.eventIndex(forLine: line, in: structure, near: playback.currentEventIndex) {
                playback.seek(toEvent: index)
                autoScroll?.relocated()
            }
        case .idle:
            break
        }
    }

    // MARK: Audio session events

    private func handleAudioEvent(_ event: AudioSessionManager.Event) {
        // Route notifications right after (re)configuring the session are our own doing.
        let settled = CACurrentMediaTime() - activityStartedAt > 1.5
        switch (activity, event) {
        case (.playing, .interruptionBegan):
            playback.pause()
            refreshSessionFlags()
            statusMessage = "播放被系统中断，已暂停。"
        case (.playing, .routeDeviceRemoved):
            guard settled else { return }
            playback.pause()
            refreshSessionFlags()
            statusMessage = "音频设备已断开，已暂停播放。"
        case (.playing, .interruptionEnded):
            statusMessage = "中断结束，点击播放继续。"
        case (.following, .interruptionBegan):
            stopActivity()
            statusMessage = "跟随被电话或其他应用中断，已停止。"
        case (.following, .routeDeviceRemoved), (.following, .routeDeviceAdded):
            guard settled else { return }
            stopActivity()
            statusMessage = "音频设备已变化，已停止跟随。请重新开始。"
        case (.idle, _):
            break
        case (_, .mediaServicesReset):
            stopActivity()
            statusMessage = "音频服务已重置，请重新开始。"
        default:
            break
        }
    }
}
