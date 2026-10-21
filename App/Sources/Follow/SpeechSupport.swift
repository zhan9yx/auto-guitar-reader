import Foundation

/// Status of the optional speech-lyrics recognition, shown as a small label in the follow bar.
enum LyricsRecognitionStatus: Equatable {
    case off
    case requestingPermission
    case listening
    case restarting
    case denied
    case unavailable(String)

    var label: String {
        switch self {
        case .off: return "歌词识别：关闭"
        case .requestingPermission: return "歌词识别：等待授权"
        case .listening: return "歌词识别：识别中"
        case .restarting: return "歌词识别：重启中"
        case .denied: return "歌词识别：未授权"
        case .unavailable(let reason): return "歌词识别：不可用（\(reason)）"
        }
    }

    var isActive: Bool {
        switch self {
        case .listening, .restarting: return true
        default: return false
        }
    }
}

/// Restart schedule of the speech recognition task: Apple limits a recognition task to about a minute, so it is
/// renewed every `rolloverSeconds`; errors / final results restart it with exponential backoff, at most
/// `maxRestartsPerMinute` times per minute (when the budget is used up the next restart waits for a free slot).
/// After `maxConsecutiveFailures` hard failures in a row the recognizer gives up (following continues without it).
struct SpeechRestartPolicy {
    var rolloverSeconds: Double = 50
    var maxRestartsPerMinute: Int = 6
    var maxConsecutiveFailures: Int = 8
    var baseDelay: Double = 0.5
    var maxDelay: Double = 8

    private var stamps: [Double] = []
    private var consecutiveFailures = 0

    init() {}

    /// A transcript arrived: the recognizer works, forget the failure streak.
    mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    /// Delay (seconds) before the next task may start, or nil to give up.
    /// `isFailure`: the previous task ended with an error (backoff grows); false for rollovers, final results and
    /// "no speech detected" (an instrumental intro is not an error).
    mutating func requestRestart(now: Double, isFailure: Bool) -> Double? {
        stamps.removeAll { now - $0 > 60 }
        var delay = 0.1
        if isFailure {
            consecutiveFailures += 1
            if consecutiveFailures > maxConsecutiveFailures { return nil }
            delay = min(baseDelay * pow(2, Double(consecutiveFailures - 1)), maxDelay)
        }
        // Restart budget: wait until the oldest restart leaves the 60 s window.
        var start = now + delay
        if stamps.count >= maxRestartsPerMinute {
            let freeAt = stamps[stamps.count - maxRestartsPerMinute] + 60
            start = max(start, freeAt)
        }
        stamps.append(start)
        return max(start - now, 0)
    }

    mutating func reset() {
        stamps = []
        consecutiveFailures = 0
    }
}
