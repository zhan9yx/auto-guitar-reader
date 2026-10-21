import Foundation
import Observation
import AGRCore

/// Main-actor glue of simulated playback: the user-facing parameters (observed by the playback bar), the
/// `PlaybackSession` state machine and the AVAudioEngine adapter. Parameter changes while playing are re-planned
/// (debounced) and resume at the equivalent beat.
@MainActor
@Observable
final class PlaybackController {
    // MARK: Parameters (UI)

    var tempoScale: Double = 1 {
        didSet { if tempoScale != oldValue { scheduleReplan() } }
    }
    /// nil = 跟随谱面.
    var strumID: String? = nil {
        didSet { if strumID != oldValue { applyParameters() } }
    }
    var countInEnabled = true {
        didSet { if countInEnabled != oldValue { applyParameters() } }
    }
    var metronome = false {
        didSet { if metronome != oldValue { applyParameters() } }
    }
    /// Index into the timeline's section passes; nil = no loop.
    var loopPass: Int? = nil {
        didSet { if loopPass != oldValue { applyParameters() } }
    }
    var volume: Double = 0.8 {
        didSet { applyVolume() }
    }
    var brightness: Double = 0.5 {
        didSet { applyBrightness() }
    }

    // MARK: State (UI)

    private(set) var state: PlaybackState = .idle
    private(set) var errorMessage: String?
    private(set) var loopOptions: [LoopOption] = []
    private(set) var strumOptions: [StrumPattern] = []

    var isPlaying: Bool { state == .playing }

    // MARK: Internals

    @ObservationIgnored let engine = PlaybackEngine()
    @ObservationIgnored private var session: PlaybackSession?
    @ObservationIgnored private(set) var score: Score?
    @ObservationIgnored private var transpose = 0
    @ObservationIgnored private var countInBeats = 4
    @ObservationIgnored private var replanTask: Task<Void, Never>?
    /// The piece (or the loop's last repeat) ended by itself.
    @ObservationIgnored var onFinish: (() -> Void)?

    init() {}

    // MARK: Setup

    func configure(score: Score, defaultStrum: StrumPattern?, countInBeats: Int) {
        stop()
        self.score = score
        self.countInBeats = countInBeats
        let structure = Timeline.build(from: score)
        loopOptions = LoopOption.options(for: score, timeline: structure)
        var patterns: [StrumPattern] = [.defaultPop, .arpeggio]
        for p in score.strumPatterns where !patterns.contains(where: { $0.id == p.id }) { patterns.append(p) }
        strumOptions = patterns
        strumID = defaultStrum?.id
        loopPass = nil
        tempoScale = 1
    }

    /// Notated BPM scaled by the slider, e.g. "92 BPM".
    var bpmLabel: String {
        let base = (score?.meta.tempo ?? 0) > 0 ? (score?.meta.tempo ?? 80) : 80
        return "\(Int((base * tempoScale).rounded())) BPM"
    }

    var tempoPercentLabel: String { "\(Int((tempoScale * 100).rounded()))%" }

    // MARK: Transport

    /// Activates the audio session, starts the engine and begins playing from the start.
    @discardableResult
    func start(audio: AudioSessionManager, transpose: Int) -> Bool {
        guard let score = score else { return false }
        stop()
        errorMessage = nil
        self.transpose = transpose
        do {
            try audio.activate(.playback)
            engine.setVolume(Float(volume))
            engine.setBrightness(Float(brightness))
            try engine.start()
        } catch {
            errorMessage = "无法启动音频：\(describeError(error))"
            return false
        }
        let s = PlaybackSession(score: score, output: engine, params: currentParameters())
        s.onFinish = { [weak self] in self?.handleFinished() }
        session = s
        s.play()
        state = s.state
        return true
    }

    func togglePause() {
        guard let session = session else { return }
        session.togglePause()
        state = session.state
    }

    func pause() {
        session?.pause()
        if let session = session { state = session.state }
    }

    func resume() {
        session?.play()
        if let session = session { state = session.state }
    }

    func restart() {
        guard let session = session else { return }
        session.restart()
        state = session.state
    }

    /// Releases the engine; the next `start` begins from the top.
    func stop() {
        replanTask?.cancel()
        replanTask = nil
        session?.stop()
        session = nil
        engine.stop()
        state = .idle
    }

    func seek(toEvent index: Int) {
        session?.seek(toEvent: index)
    }

    /// Display-rate poll (called by the reader's frame loop).
    func tick() -> PlaybackReading? {
        guard let session = session else { return nil }
        let reading = session.tick()
        if session.state != state { state = session.state }
        return reading
    }

    var currentEventIndex: Int { session?.reading?.eventIndex ?? 0 }

    // MARK: Parameters

    func setTranspose(_ semitones: Int) {
        guard semitones != transpose else { return }
        transpose = semitones
        applyParameters()
    }

    private func currentParameters() -> PlaybackParameters {
        var p = PlaybackParameters()
        p.tempoScale = tempoScale
        p.transpose = transpose
        p.strumPattern = strumID.flatMap { id in strumOptions.first { $0.id == id } }
        p.countInBeats = countInEnabled ? countInBeats : 0
        p.metronome = metronome
        p.loopPass = loopPass
        return p
    }

    private func scheduleReplan() {
        guard session != nil else { return }
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // slider drags: plan once the thumb settles
            guard !Task.isCancelled else { return }
            self?.applyParameters()
        }
    }

    private func applyParameters() {
        guard let session = session else { return }
        replanTask?.cancel()
        session.updateParameters(currentParameters())
    }

    private func applyVolume() {
        let v = Float(volume)
        if let session = session { session.setVolume(v) } else { engine.setVolume(min(max(v, 0), 1)) }
    }

    private func applyBrightness() {
        let v = Float(brightness)
        if let session = session { session.setBrightness(v) } else { engine.setBrightness(min(max(v, 0), 1)) }
    }

    private func handleFinished() {
        state = .idle
        onFinish?()
    }
}
