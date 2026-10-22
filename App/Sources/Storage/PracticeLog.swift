import Foundation
import Observation

enum PracticeMode: String, Codable, Sendable {
    case playback
    case follow

    var label: String {
        switch self {
        case .playback: return "模拟播放"
        case .follow: return "跟弹"
        }
    }
}

/// One finished playback / follow session.
struct PracticeSession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var scoreID: UUID
    var title: String
    var mode: PracticeMode
    var start: Date
    var duration: TimeInterval
}

/// A score the reader opened (for "最近打开").
struct RecentOpen: Codable, Hashable, Sendable {
    var scoreID: UUID
    var title: String
    var date: Date
}

/// Per-score aggregate shown in the profile's 练习记录 section.
struct ScorePracticeSummary: Identifiable, Hashable, Sendable {
    var scoreID: UUID
    var title: String
    var lastPracticed: Date
    var playbackSeconds: TimeInterval
    var followSeconds: TimeInterval
    var sessionCount: Int

    var id: UUID { scoreID }
    var playbackMinutes: Double { playbackSeconds / 60 }
    var followMinutes: Double { followSeconds / 60 }
    var totalMinutes: Double { (playbackSeconds + followSeconds) / 60 }
}

struct DayMinutes: Identifiable, Hashable, Sendable {
    /// Start of the day (in the calendar used for aggregation).
    var day: Date
    var minutes: Double
    var id: Date { day }
}

/// Persistent practice history. Pure value type: all aggregation is unit-testable.
struct PracticeLog: Codable, Equatable, Sendable {
    /// Sessions shorter than this are accidental taps and are not recorded.
    static let minimumDuration: TimeInterval = 5
    static let maxSessions = 5000
    static let maxRecentOpens = 30

    var version = 1
    var sessions: [PracticeSession] = []
    var recentOpens: [RecentOpen] = []

    init() {}

    // MARK: Recording

    /// Returns whether the session was long enough to be kept.
    @discardableResult
    mutating func record(scoreID: UUID, title: String, mode: PracticeMode, start: Date, duration: TimeInterval,
                         id: UUID = UUID()) -> Bool {
        guard duration.isFinite, duration >= Self.minimumDuration else { return false }
        sessions.append(PracticeSession(id: id, scoreID: scoreID, title: title, mode: mode, start: start, duration: duration))
        if sessions.count > Self.maxSessions {
            sessions.sort { $0.start < $1.start }
            sessions.removeFirst(sessions.count - Self.maxSessions)
        }
        return true
    }

    mutating func noteOpened(scoreID: UUID, title: String, at date: Date) {
        recentOpens.removeAll { $0.scoreID == scoreID }
        recentOpens.insert(RecentOpen(scoreID: scoreID, title: title, date: date), at: 0)
        if recentOpens.count > Self.maxRecentOpens {
            recentOpens.removeLast(recentOpens.count - Self.maxRecentOpens)
        }
    }

    /// Drops everything about a score that no longer exists in the library.
    mutating func forget(scoreID: UUID) {
        recentOpens.removeAll { $0.scoreID == scoreID }
    }

    // MARK: Aggregation

    var totalSeconds: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var totalMinutes: Double { totalSeconds / 60 }
    var sessionCount: Int { sessions.count }

    func seconds(for mode: PracticeMode) -> TimeInterval {
        sessions.reduce(0) { $0 + ($1.mode == mode ? $1.duration : 0) }
    }

    /// One entry per score, most recently practiced first. The title of the newest session wins.
    func perScore() -> [ScorePracticeSummary] {
        var byScore: [UUID: ScorePracticeSummary] = [:]
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            var entry = byScore[session.scoreID] ?? ScorePracticeSummary(
                scoreID: session.scoreID, title: session.title, lastPracticed: session.start,
                playbackSeconds: 0, followSeconds: 0, sessionCount: 0)
            entry.title = session.title
            entry.lastPracticed = max(entry.lastPracticed, session.start)
            switch session.mode {
            case .playback: entry.playbackSeconds += session.duration
            case .follow: entry.followSeconds += session.duration
            }
            entry.sessionCount += 1
            byScore[session.scoreID] = entry
        }
        return byScore.values.sorted { $0.lastPracticed > $1.lastPracticed }
    }

    /// Minutes per calendar day for the `days` days ending with the day of `now` (oldest first, always `days` entries).
    func dailyMinutes(endingAt now: Date, days: Int = 7, calendar: Calendar = .current) -> [DayMinutes] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: Double] = [:]
        var order: [Date] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) {
                buckets[day] = 0
                order.append(day)
            }
        }
        for session in sessions {
            let day = calendar.startOfDay(for: session.start)
            if buckets[day] != nil { buckets[day]! += session.duration / 60 }
        }
        return order.map { DayMinutes(day: $0, minutes: buckets[$0] ?? 0) }
    }

    func minutesInLastDays(_ days: Int, endingAt now: Date, calendar: Calendar = .current) -> Double {
        dailyMinutes(endingAt: now, days: days, calendar: calendar).reduce(0) { $0 + $1.minutes }
    }

    // MARK: Persistence

    static func load(from url: URL) -> PracticeLog {
        guard let data = try? Data(contentsOf: url), let log = try? decoder().decode(PracticeLog.self, from: data) else {
            return PracticeLog()
        }
        return log
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("practice.json")
    }
}

/// Observable owner of the practice log (`practice.json` in Application Support). The reader's conductor reports
/// session start / end here; the profile screen reads `log`.
@Observable
@MainActor
final class PracticeStore {
    static let shared = PracticeStore()

    private(set) var log: PracticeLog

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var active: (scoreID: UUID, title: String, mode: PracticeMode, start: Date)?

    init(url: URL = PracticeLog.defaultURL(), now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        self.log = PracticeLog.load(from: url)
    }

    var isSessionActive: Bool { active != nil }

    /// A playback / follow session started. Any session still open is closed first.
    func begin(scoreID: UUID, title: String, mode: PracticeMode) {
        end()
        active = (scoreID, title, mode, now())
    }

    /// The running session (if any) ended: it is recorded when it lasted long enough.
    func end() {
        guard let session = active else { return }
        active = nil
        let duration = now().timeIntervalSince(session.start)
        if log.record(scoreID: session.scoreID, title: session.title, mode: session.mode,
                      start: session.start, duration: duration) {
            persist()
        }
    }

    func noteOpened(scoreID: UUID, title: String) {
        log.noteOpened(scoreID: scoreID, title: title, at: now())
        persist()
    }

    func forget(scoreID: UUID) {
        log.forget(scoreID: scoreID)
        persist()
    }

    func reload() {
        log = PracticeLog.load(from: url)
    }

    private func persist() {
        try? log.save(to: url)
    }
}
