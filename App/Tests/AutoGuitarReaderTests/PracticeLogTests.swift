import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

final class PracticeLogTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 3, day: day, hour: hour))!
    }

    private let a = UUID()
    private let b = UUID()

    func testShortSessionsAreIgnored() {
        var log = PracticeLog()
        XCTAssertFalse(log.record(scoreID: a, title: "A", mode: .playback, start: date(1), duration: 4.9))
        XCTAssertFalse(log.record(scoreID: a, title: "A", mode: .playback, start: date(1), duration: .nan))
        XCTAssertTrue(log.record(scoreID: a, title: "A", mode: .playback, start: date(1), duration: 5))
        XCTAssertEqual(log.sessionCount, 1)
    }

    func testPerScoreAggregation() {
        var log = PracticeLog()
        log.record(scoreID: a, title: "旧名", mode: .playback, start: date(1), duration: 120)
        log.record(scoreID: a, title: "新名", mode: .follow, start: date(3), duration: 300)
        log.record(scoreID: a, title: "新名", mode: .follow, start: date(2), duration: 60)
        log.record(scoreID: b, title: "B", mode: .playback, start: date(4), duration: 600)

        let all = log.perScore()
        XCTAssertEqual(all.map(\.scoreID), [b, a], "most recently practiced first")
        let sa = all[1]
        XCTAssertEqual(sa.title, "新名", "title of the newest session")
        XCTAssertEqual(sa.sessionCount, 3)
        XCTAssertEqual(sa.playbackSeconds, 120)
        XCTAssertEqual(sa.followSeconds, 360)
        XCTAssertEqual(sa.playbackMinutes, 2, accuracy: 1e-9)
        XCTAssertEqual(sa.followMinutes, 6, accuracy: 1e-9)
        XCTAssertEqual(sa.lastPracticed, date(3))
        XCTAssertEqual(log.totalMinutes, 18, accuracy: 1e-9)
        XCTAssertEqual(log.seconds(for: .follow), 360)
    }

    func testDailyMinutesWindowAlwaysHasSevenDaysOldestFirst() {
        var log = PracticeLog()
        log.record(scoreID: a, title: "A", mode: .playback, start: date(10, hour: 1), duration: 600)   // today
        log.record(scoreID: a, title: "A", mode: .follow, start: date(10, hour: 23), duration: 1200)    // today
        log.record(scoreID: a, title: "A", mode: .follow, start: date(8), duration: 300)               // 2 days ago
        log.record(scoreID: a, title: "A", mode: .follow, start: date(4), duration: 3600)              // 6 days ago (edge)
        log.record(scoreID: a, title: "A", mode: .follow, start: date(3), duration: 3600)              // outside
        log.record(scoreID: a, title: "A", mode: .follow, start: date(11), duration: 3600)             // future: ignored

        let days = log.dailyMinutes(endingAt: date(10, hour: 15), days: 7, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.day, calendar.startOfDay(for: date(4)))
        XCTAssertEqual(days.last?.day, calendar.startOfDay(for: date(10)))
        XCTAssertEqual(days.map(\.minutes), [60, 0, 0, 0, 5, 0, 30])
        XCTAssertEqual(log.minutesInLastDays(7, endingAt: date(10), calendar: calendar), 95, accuracy: 1e-9)
        XCTAssertEqual(log.dailyMinutes(endingAt: date(10), days: 0, calendar: calendar).count, 0)
    }

    func testRecentOpensMostRecentFirstDeduplicatedAndCapped() {
        var log = PracticeLog()
        log.noteOpened(scoreID: a, title: "A", at: date(1))
        log.noteOpened(scoreID: b, title: "B", at: date(2))
        log.noteOpened(scoreID: a, title: "A2", at: date(3))
        XCTAssertEqual(log.recentOpens.map(\.scoreID), [a, b])
        XCTAssertEqual(log.recentOpens.first?.title, "A2")
        for _ in 0..<(PracticeLog.maxRecentOpens + 5) { log.noteOpened(scoreID: UUID(), title: "x", at: date(4)) }
        XCTAssertEqual(log.recentOpens.count, PracticeLog.maxRecentOpens)
        log.forget(scoreID: log.recentOpens[0].scoreID)
        XCTAssertEqual(log.recentOpens.count, PracticeLog.maxRecentOpens - 1)
    }

    func testSessionCapDropsOldest() {
        var log = PracticeLog()
        for i in 0..<(PracticeLog.maxSessions + 3) {
            log.record(scoreID: a, title: "A", mode: .playback, start: Date(timeIntervalSince1970: Double(i)), duration: 10)
        }
        XCTAssertEqual(log.sessionCount, PracticeLog.maxSessions)
        XCTAssertEqual(log.sessions.map(\.start).min(), Date(timeIntervalSince1970: 3))
    }

    func testJSONRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("practice-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("practice.json")
        XCTAssertEqual(PracticeLog.load(from: url), PracticeLog(), "missing file = empty log")

        var log = PracticeLog()
        log.record(scoreID: a, title: "七里香", mode: .follow, start: date(1), duration: 90)
        log.noteOpened(scoreID: b, title: "B", at: date(2))
        try log.save(to: url)
        XCTAssertEqual(PracticeLog.load(from: url), log)

        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(PracticeLog.load(from: url), PracticeLog(), "corrupt file = empty log")
    }

    func testStoreRecordsSessionsWithInjectedClock() throws {
        try MainActor.assumeIsolated { try runStoreTest() }
    }

    @MainActor
    private func runStoreTest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("practice-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("practice.json")
        var clock = date(5)
        let store = PracticeStore(url: url, now: { clock })

        store.begin(scoreID: a, title: "A", mode: .playback)
        XCTAssertTrue(store.isSessionActive)
        clock = clock.addingTimeInterval(61)
        store.end()
        XCTAssertFalse(store.isSessionActive)
        XCTAssertEqual(store.log.sessionCount, 1)
        XCTAssertEqual(store.log.sessions[0].duration, 61, accuracy: 1e-9)

        // too short: dropped
        store.begin(scoreID: a, title: "A", mode: .follow)
        clock = clock.addingTimeInterval(2)
        store.end()
        XCTAssertEqual(store.log.sessionCount, 1)

        // starting a new session closes the previous one; end() without a session is a no-op
        store.begin(scoreID: a, title: "A", mode: .follow)
        clock = clock.addingTimeInterval(30)
        store.begin(scoreID: b, title: "B", mode: .playback)
        clock = clock.addingTimeInterval(20)
        store.end()
        store.end()
        XCTAssertEqual(store.log.sessions.map(\.mode), [.playback, .follow, .playback])

        store.noteOpened(scoreID: b, title: "B")
        let reloaded = PracticeStore(url: url, now: { clock })
        XCTAssertEqual(reloaded.log, store.log, "persisted to practice.json")
    }
}
