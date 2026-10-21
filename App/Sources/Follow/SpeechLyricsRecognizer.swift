import Foundation
import Speech
import AVFoundation

/// Thread-safe holder of the current recognition request. The microphone tap thread appends buffers through it
/// while the main actor swaps requests on restarts.
final class SpeechRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    /// Called on the tap thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func endAudio() {
        lock.lock()
        let current = request
        request = nil
        lock.unlock()
        current?.endAudio()
    }
}

/// Optional streaming speech recognition of the sung lyrics (zh-CN / en-US, on-device when supported). The partial
/// transcripts go to `FollowSession.applyTranscript`. Failure / denial never affects the rest of following.
@MainActor
final class SpeechLyricsRecognizer {
    private(set) var status: LyricsRecognitionStatus = .off {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    var onTranscript: ((String) -> Void)?
    var onStatus: ((LyricsRecognitionStatus) -> Void)?

    /// Feed microphone buffers into `bufferSink.append(_:)` (thread-safe, any thread).
    let bufferSink = SpeechRequestBox()

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var policy = SpeechRestartPolicy()
    private var running = false
    private var rolloverTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    init(locale: Locale) {
        self.locale = locale
    }

    var isRunning: Bool { running }

    // MARK: Lifecycle

    /// Requests authorization (first use) and starts recognizing. Returns when the first task has begun or the
    /// recognizer turned out to be unavailable; check `status`.
    func start() async {
        guard !running else { return }
        running = true
        status = .requestingPermission
        let authorization = await SpeechLyricsRecognizer.requestAuthorization()
        guard running else { return }   // stopped while the permission prompt was open
        switch authorization {
        case .authorized:
            break
        case .denied, .restricted:
            running = false
            status = .denied
            return
        default:
            running = false
            status = .unavailable("无法获得授权")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            running = false
            status = .unavailable("该语言暂不可用")
            return
        }
        self.recognizer = recognizer
        policy.reset()
        beginTask()
    }

    func stop() {
        running = false
        generation += 1                 // callbacks of the cancelled task are ignored
        rolloverTask?.cancel()
        restartTask?.cancel()
        rolloverTask = nil
        restartTask = nil
        bufferSink.endAudio()
        task?.cancel()
        task = nil
        recognizer = nil
        status = .off
    }

    // MARK: Tasks

    private func beginTask() {
        guard running, let recognizer = recognizer else { return }
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = false
        request.taskHint = .dictation
        bufferSink.set(request)

        task = recognizer.recognitionTask(with: request, resultHandler: SpeechLyricsRecognizer.makeResultHandler(owner: self, generation: gen))
        status = .listening

        rolloverTask?.cancel()
        let rollover = policy.rolloverSeconds
        rolloverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(rollover * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleRollover(generation: gen)
        }
    }

    private func handleResult(text: String?, isFinal: Bool, failed: Bool, ended: Bool, generation gen: Int) {
        guard running, gen == generation else { return }
        if let text = text, !text.isEmpty {
            policy.noteSuccess()
            onTranscript?(text)
        }
        if isFinal || ended {
            endTask()
            scheduleRestart(isFailure: failed)
        }
    }

    private func handleRollover(generation gen: Int) {
        guard running, gen == generation else { return }
        endTask()
        scheduleRestart(isFailure: false)
    }

    private func endTask() {
        rolloverTask?.cancel()
        rolloverTask = nil
        bufferSink.endAudio()
        task?.cancel()
        task = nil
        generation += 1   // ignore the cancelled task's trailing callbacks
    }

    private func scheduleRestart(isFailure: Bool) {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let delay = policy.requestRestart(now: now, isFailure: isFailure) else {
            running = false
            recognizer = nil
            status = .unavailable("识别服务反复出错")
            return
        }
        status = .restarting
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.beginTask()
        }
    }

    /// Nonisolated on purpose: the framework calls the handler on an arbitrary queue; only plain values are extracted
    /// there before hopping to the main actor.
    nonisolated private static func makeResultHandler(owner: SpeechLyricsRecognizer, generation gen: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?
            let ended = nsError != nil
            // 1110 = "No speech detected": normal during an instrumental intro, not a failure.
            let failed = ended && nsError?.code != 1110
            Task { @MainActor in
                owner?.handleResult(text: text, isFinal: isFinal, failed: failed, ended: ended, generation: gen)
            }
        }
    }

    // MARK: Authorization

    /// Nonisolated: the framework calls the completion on an arbitrary queue.
    nonisolated static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
