import Foundation
import Observation
import AVFoundation
import AGRCore

/// Everything the user chose for one follow run.
struct FollowOptions {
    var mode: FollowMode
    var transpose: Int
    var followerConfig: FollowerConfig
    var lyricsEnabled: Bool
    var languageIdentifier: String
}

/// Main-actor glue of the follow pipeline: microphone permission + capture, `FollowSession` (analysis queue),
/// optional speech recognition. Publishes small, rate-limited UI state; the per-frame data for the auto-scroller is
/// kept outside of observation (`latestReading`).
///
/// Threading: `MicCapture` tap thread -> `FollowSession.ingest` (copies, enqueues) -> analysis queue ->
/// `onPublish` -> `DispatchQueue.main` -> `receive`.
@MainActor
@Observable
final class FollowController {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case micDenied
        case failed(String)
    }

    enum ConfidenceLevel: Equatable {
        case none, low, medium, high
    }

    // Observed by the follow bar (each changes rarely).
    private(set) var phase: Phase = .idle
    var mode: FollowMode = .strumSing
    private(set) var confidenceLevel: ConfidenceLevel = .none
    private(set) var tempoRatio: Double = 1
    private(set) var isPaused = false
    private(set) var inputLevel: Double = 0
    private(set) var lyricsStatus: LyricsRecognitionStatus = .off

    // Per-frame data, deliberately not observed.
    @ObservationIgnored private(set) var latestSnapshot: FollowSnapshot?
    @ObservationIgnored private(set) var latestReading: ReadingSample?

    @ObservationIgnored private var session: FollowSession?
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private var speech: SpeechLyricsRecognizer?
    @ObservationIgnored private var options: FollowOptions?
    @ObservationIgnored private var acceptedEpoch = 0
    @ObservationIgnored private var lastLevelPoll = 0.0

    /// The hardware changed while following (sample rate / route); the owner stops following.
    @ObservationIgnored var onHardwareChange: (() -> Void)?

    var isRunning: Bool { phase == .running }
    var isActive: Bool { phase == .running || phase == .starting }

    init() {}

    // MARK: Start / stop

    /// Asks for the microphone, activates the audio session, starts capture + analysis (+ speech).
    /// Returns false when following did not start (see `phase`).
    func start(score: Score, audio: AudioSessionManager, options: FollowOptions) async -> Bool {
        guard !isActive else { return isRunning }
        phase = .starting
        self.options = options
        mode = options.mode

        let allowed = await audio.requestMicPermission()
        guard phase == .starting else { return false }      // stopped while the prompt was open
        guard allowed else {
            phase = .micDenied
            return false
        }

        do {
            try audio.activate(.follow)
            let sampleRate = try mic.prepare()
            var config = FollowSessionConfig(mode: options.mode, transpose: options.transpose, inputSampleRate: sampleRate)
            config.followerConfig = options.followerConfig
            config.lyricsEnabled = options.lyricsEnabled
            let session = FollowSession(score: score, config: config)
            acceptedEpoch = session.currentEpoch
            session.onPublish = FollowController.makePublishHandler(controller: self)
            self.session = session

            // Speech recognizer first, so its buffer sink exists when the tap starts.
            var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
            if options.lyricsEnabled, session.usesLyrics {
                let recognizer = SpeechLyricsRecognizer(locale: Locale(identifier: options.languageIdentifier))
                recognizer.onTranscript = { [weak self] text in self?.session?.applyTranscript(text) }
                recognizer.onStatus = { [weak self] status in self?.lyricsStatus = status }
                speech = recognizer
                bufferHandler = FollowController.makeBufferHandler(sink: recognizer.bufferSink)
            } else {
                lyricsStatus = .off
            }

            mic.onConfigurationChange = { [weak self] in self?.onHardwareChange?() }
            try mic.start(onSamples: FollowController.makeSampleHandler(session: session), onBuffer: bufferHandler)
            phase = .running
            if options.mode == .strumSing { startSpeechIfNeeded() }
            return true
        } catch {
            tearDown()
            audio.deactivate()
            phase = .failed(describeError(error))
            return false
        }
    }

    func stop() {
        tearDown()
        phase = .idle
    }

    private func tearDown() {
        mic.onConfigurationChange = nil
        mic.stop()
        speech?.stop()
        speech = nil
        session?.onPublish = nil
        session?.stop()
        session = nil
        latestSnapshot = nil
        latestReading = nil
        confidenceLevel = .none
        tempoRatio = 1
        isPaused = false
        inputLevel = 0
        lyricsStatus = .off
    }

    // MARK: Control

    func setMode(_ newMode: FollowMode) {
        guard newMode != mode else { return }
        mode = newMode
        session?.updateMode(newMode)
        if phase == .running {
            if newMode == .strumSing { startSpeechIfNeeded() } else { stopSpeech() }
        }
    }

    func updateTranspose(_ semitones: Int) {
        session?.updateTranspose(semitones)
    }

    /// Double tap on a line: continue from there.
    func relocate(toLine line: LineRef) {
        guard let session = session else { return }
        if session.relocate(toLine: line) != nil {
            // Snapshots computed before the relocation are stale now.
            acceptedEpoch = session.currentEpoch
        }
    }

    private func startSpeechIfNeeded() {
        guard let speech = speech, !speech.isRunning else { return }
        Task { await speech.start() }
    }

    private func stopSpeech() {
        speech?.stop()
    }

    // MARK: Updates

    fileprivate func receive(_ snapshot: FollowSnapshot) {
        guard phase == .running, snapshot.epoch >= acceptedEpoch else { return }
        latestSnapshot = snapshot
        latestReading = ReadingSample(eventIndex: snapshot.eventIndex, progressInEvent: snapshot.state.progressInEvent,
                                      confidence: snapshot.state.confidence)
        let level = FollowController.level(confidence: snapshot.state.confidence)
        if level != confidenceLevel { confidenceLevel = level }
        let ratio = (snapshot.state.tempoRatio * 100).rounded() / 100
        if ratio != tempoRatio { tempoRatio = ratio }
        if snapshot.state.isPaused != isPaused { isPaused = snapshot.state.isPaused }
    }

    /// Meter update at most ~15 times per second, quantized so SwiftUI only re-renders on visible changes.
    func pollLevel(now: Double) {
        guard phase == .running, now - lastLevelPoll >= 1.0 / 15.0 else { return }
        lastLevelPoll = now
        let position = Double((AudioMath.meterPosition(dB: mic.levelDB) * 20).rounded() / 20)
        if position != inputLevel { inputLevel = position }
    }

    // MARK: Cross-thread closures
    //
    // Built in nonisolated context on purpose: they run on the capture thread / the analysis queue and must not
    // inherit main-actor isolation.

    nonisolated private static func makeSampleHandler(session: FollowSession) -> ([Float]) -> Void {
        return { samples in session.ingest(samples: samples) }
    }

    nonisolated private static func makeBufferHandler(sink: SpeechRequestBox) -> (AVAudioPCMBuffer) -> Void {
        return { buffer in sink.append(buffer) }
    }

    nonisolated private static func makePublishHandler(controller: FollowController) -> (FollowSnapshot) -> Void {
        return { [weak controller] snapshot in
            guard let controller = controller else { return }
            // Strong only until the block runs (a few milliseconds).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.receive(snapshot) }
            }
        }
    }

    nonisolated static func level(confidence: Double) -> ConfidenceLevel {
        if confidence >= 0.7 { return .high }
        if confidence >= 0.4 { return .medium }
        return .low
    }
}
