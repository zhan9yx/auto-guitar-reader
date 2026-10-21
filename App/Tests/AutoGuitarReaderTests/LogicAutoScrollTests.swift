import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

/// A scroll view stand-in with fake line frames (line i at y = 60 i, 56 pt high).
@MainActor
final class FakeSurface: ScrollSurface {
    var viewportHeight = 600.0
    var contentHeight = 2400.0
    var contentOffsetY = 0.0
    var frames: [LineRef: (minY: Double, height: Double)] = [:]
    var jumps: [Double] = []
    var setCount = 0

    init(lines: Int) {
        for i in 0..<lines { frames[LineRef(sectionIndex: 0, lineIndex: i)] = (Double(i) * 60, 56) }
        contentHeight = Double(lines) * 60 + 100
    }

    @MainActor
    func lineFrame(_ line: LineRef) -> (minY: Double, height: Double)? { frames[line] }

    var maxOffset: Double { max(0, contentHeight - viewportHeight) }

    @MainActor
    func setContentOffsetY(_ y: Double) {
        contentOffsetY = min(max(y, 0), maxOffset)
        setCount += 1
    }

    @MainActor
    func crossfadeJump(to y: Double) {
        jumps.append(y)
        setContentOffsetY(y)
    }
}

final class LogicAutoScrollTests: XCTestCase {
    private let lines = 40

    /// One verse of 40 lyric lines, two chords each: event 2i / 2i+1 on line i.
    @MainActor
    private func makeTimeline() throws -> Timeline {
        var cho = "{title: t}\n{tempo: 120}\n{start_of_verse}\n"
        for i in 0..<lines { cho += "[C]第\(i)行[G]歌词\n" }
        cho += "{end_of_verse}\n"
        let score = try ChordProParser.parse(cho)
        return Timeline.build(from: score)
    }

    @MainActor
    private func reading(atSeconds t: Double, eventSeconds: Double = 0.5, events: Int) -> ReadingSample {
        let e = min(Int(t / eventSeconds), events - 1)
        let p = min(max((t - Double(e) * eventSeconds) / eventSeconds, 0), 1)
        return ReadingSample(eventIndex: e, progressInEvent: p, confidence: 1)
    }

    /// Runs `seconds` at 60 fps, returns per-frame offsets.
    @discardableResult
    @MainActor
    private func run(_ logic: AutoScrollLogic, _ surface: FakeSurface, from t0: Double, seconds: Double,
                     reading r: (Double) -> ReadingSample?) -> [Double] {
        var offsets: [Double] = []
        var t = t0
        let end = t0 + seconds
        while t < end {
            logic.tick(now: t, reading: r(t), surface: surface)
            offsets.append(surface.contentOffsetY)
            t += 1.0 / 60
        }
        return offsets
    }

    func testPlaybackClockKeepsTheCurrentLineAtTheAnchorWithinSpeedLimits() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            // 1 line per second (2 events of 0.5 s).
            let offsets = run(logic, surface, from: 0, seconds: 30) { self.reading(atSeconds: $0, events: tl.events.count) }

            let anchor = logic.settings.scroll.anchorRatio * surface.viewportHeight
            let targetY = 30.0 * 60 + 0   // line 30 starts at y = 1800 after 30 s
            XCTAssertEqual(surface.contentOffsetY, targetY - anchor, accuracy: 60)
            let vmax = logic.settings.scroll.maxSpeed * surface.viewportHeight
            var worst = 0.0, backward = 0.0
            for (a, b) in zip(offsets, offsets.dropFirst()) {
                worst = max(worst, abs(b - a) * 60)
                backward = min(backward, b - a)
            }
            XCTAssertLessThanOrEqual(worst, vmax * 1.05)
            XCTAssertGreaterThan(backward, -0.5, "never scrolls backwards while playing forward")
            XCTAssertTrue(surface.jumps.isEmpty, "a smooth glide needs no crossfade jump")
            XCTAssertFalse(logic.isOverridden)
            XCTAssertNotNil(logic.lastTargetY)
        }
    }

    func testNoReadingMeansNoMovement() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 2) { _ in nil }
            XCTAssertEqual(surface.contentOffsetY, 0)
            XCTAssertEqual(surface.setCount, 0)
        }
    }

    func testManualScrollPausesAutomationThenFarTargetCrossfades() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            var settings = AutoScrollSettings()
            settings.scroll.manualOverrideSeconds = 3
            let logic = AutoScrollLogic(timeline: tl, settings: settings)
            var flips: [Bool] = []
            logic.onOverrideChange = { flips.append($0) }
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 5) { self.reading(atSeconds: $0, events: tl.events.count) }

            // The user drags far down the document.
            surface.contentOffsetY = 1700
            logic.userDidScroll(to: 1700, now: 5)
            XCTAssertTrue(logic.isOverridden)
            XCTAssertEqual(flips, [true])
            let sets = surface.setCount
            run(logic, surface, from: 5, seconds: 2.8) { self.reading(atSeconds: $0, events: tl.events.count) }
            XCTAssertEqual(surface.contentOffsetY, 1700, "automation is paused during the override")
            XCTAssertEqual(surface.setCount, sets)

            run(logic, surface, from: 7.8, seconds: 3) { self.reading(atSeconds: $0, events: tl.events.count) }
            XCTAssertFalse(logic.isOverridden)
            XCTAssertEqual(flips, [true, false])
            XCTAssertEqual(surface.jumps.count, 1, "a target more than a screen away is reached with one crossfade")
            let t = 10.8
            let anchor = logic.settings.scroll.anchorRatio * surface.viewportHeight
            XCTAssertEqual(surface.contentOffsetY, t / 1.0 * 60 - anchor, accuracy: 120)
        }
    }

    func testResumeFollowingEndsTheOverrideAtOnce() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 4) { self.reading(atSeconds: $0, events: tl.events.count) }
            // Scroll a little ahead (within a screen) and press "回到跟随" one second later.
            surface.contentOffsetY += 200
            logic.userDidScroll(to: surface.contentOffsetY, now: 4)
            run(logic, surface, from: 4, seconds: 1) { self.reading(atSeconds: $0, events: tl.events.count) }
            let ahead = surface.contentOffsetY
            logic.resumeFollowing(surface: surface, now: 5)
            XCTAssertFalse(logic.isOverridden)
            run(logic, surface, from: 5, seconds: 4) { self.reading(atSeconds: $0, events: tl.events.count) }
            let anchor = logic.settings.scroll.anchorRatio * surface.viewportHeight
            XCTAssertLessThan(surface.contentOffsetY, ahead + 60 * 4)           // it came back
            XCTAssertEqual(surface.contentOffsetY, 9.0 * 60 - anchor, accuracy: 80)
        }
    }

    func testRelocationFarAwayUsesOneCrossfadeJump() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 2) { self.reading(atSeconds: $0, events: tl.events.count) }
            logic.relocated(surface: surface, now: 2)
            // Reading jumps to line 30.
            run(logic, surface, from: 2, seconds: 2) { _ in ReadingSample(eventIndex: 60, progressInEvent: 0, confidence: 0.9) }
            XCTAssertEqual(surface.jumps.count, 1)
            let anchor = logic.settings.scroll.anchorRatio * surface.viewportHeight
            XCTAssertEqual(surface.contentOffsetY, 30 * 60 - anchor, accuracy: 30)
        }
    }

    func testLowConfidenceStopsScrolling() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 6) { self.reading(atSeconds: $0, events: tl.events.count) }
            // Lost: events keep advancing but the confidence is low -> coast for a few seconds, then stop.
            run(logic, surface, from: 6, seconds: 8) { t in
                var r = self.reading(atSeconds: t, events: tl.events.count)
                r.confidence = 0.1
                return r
            }
            let stopped = surface.contentOffsetY
            run(logic, surface, from: 14, seconds: 2) { t in
                var r = self.reading(atSeconds: t, events: tl.events.count)
                r.confidence = 0.1
                return r
            }
            XCTAssertEqual(surface.contentOffsetY, stopped, accuracy: 0.5)
            XCTAssertLessThan(stopped, 14 * 60, "did not follow the low-confidence reading")
        }
    }

    func testPageTurnModeTurnsOnlyWhenTheLinePassesTwoThirds() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            var settings = AutoScrollSettings()
            settings.style = .pageTurn
            let logic = AutoScrollLogic(timeline: tl, settings: settings)
            logic.begin(surface: surface, now: 0)
            // Reading line at y = 60 t. Turn ratio 2/3 of 600 = 400 pt -> ~6.7 s.
            let early = run(logic, surface, from: 0, seconds: 6) { self.reading(atSeconds: $0, events: tl.events.count) }
            XCTAssertTrue(early.allSatisfy { $0 == 0 }, "the page stays still while the line is in the upper two thirds")
            run(logic, surface, from: 6, seconds: 3) { self.reading(atSeconds: $0, events: tl.events.count) }
            XCTAssertGreaterThan(surface.contentOffsetY, 100, "turned the page")
            let offsetAfterTurn = surface.contentOffsetY
            // Afterwards the reading line is back inside the viewport.
            let lineY = 9 * 60.0 - offsetAfterTurn
            XCTAssertGreaterThan(lineY, 0)
            XCTAssertLessThan(lineY, surface.viewportHeight)
            // Run on: the line always stays visible.
            var minLine = Double.infinity, maxLine = -Double.infinity
            var t = 9.0
            while t < 40 {
                logic.tick(now: t, reading: reading(atSeconds: t, events: tl.events.count), surface: surface)
                let y = t * 60 - surface.contentOffsetY
                minLine = min(minLine, y); maxLine = max(maxLine, y)
                t += 1.0 / 60
            }
            XCTAssertGreaterThan(minLine, -1)
            XCTAssertLessThan(maxLine, surface.viewportHeight + 1)
        }
    }

    func testExternalOffsetChangeIsAdoptedWithoutTeleporting() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            run(logic, surface, from: 0, seconds: 3) { self.reading(atSeconds: $0, events: tl.events.count) }
            let before = surface.contentOffsetY
            surface.contentOffsetY = before + 150      // e.g. a layout change moved the content
            logic.tick(now: 3.0, reading: reading(atSeconds: 3.0, events: tl.events.count), surface: surface)
            XCTAssertEqual(surface.contentOffsetY, before + 150, accuracy: 15)
            XCTAssertTrue(surface.jumps.isEmpty)
        }
    }

    func testGeometryIsSyncedFromTheSurface() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            let surface = FakeSurface(lines: lines)
            let logic = AutoScrollLogic(timeline: tl)
            logic.begin(surface: surface, now: 0)
            // Rotation: shorter viewport -> the anchor is relative to the new height.
            surface.viewportHeight = 300
            run(logic, surface, from: 0, seconds: 12) { self.reading(atSeconds: $0, events: tl.events.count) }
            let anchor = logic.settings.scroll.anchorRatio * 300
            XCTAssertEqual(surface.contentOffsetY, 12.0 * 60 - anchor, accuracy: 60)
        }
    }

    func testHighlightTrackerReportsOnlyChanges() throws {
        try MainActor.assumeIsolated {
            let tl = try makeTimeline()
            var tracker = HighlightTracker()
            XCTAssertEqual(tracker.update(eventIndex: nil, timeline: tl), .unchanged)
            let first = tracker.update(eventIndex: 0, timeline: tl)
            XCTAssertEqual(first, .set(HighlightTracker.Target(line: LineRef(sectionIndex: 0, lineIndex: 0), segmentIndex: tl.events[0].segmentIndex)))
            XCTAssertEqual(tracker.update(eventIndex: 0, timeline: tl), .unchanged)
            let second = tracker.update(eventIndex: 1, timeline: tl)
            XCTAssertNotEqual(second, .unchanged, "the second chord of the line is a different segment")
            XCTAssertEqual(tracker.update(eventIndex: 1, timeline: tl), .unchanged)
            XCTAssertEqual(tracker.update(eventIndex: 3, timeline: tl), .set(HighlightTracker.Target(line: LineRef(sectionIndex: 0, lineIndex: 1), segmentIndex: tl.events[3].segmentIndex)))
            XCTAssertEqual(tracker.update(eventIndex: 9999, timeline: tl), .clear)
            XCTAssertEqual(tracker.clear(), .unchanged)

            // Counting changes over a run at 60 fps: one per event, not one per frame.
            var tracker2 = HighlightTracker()
            var changes = 0
            var t = 0.0
            while t < 10 {
                if tracker2.update(eventIndex: reading(atSeconds: t, events: tl.events.count).eventIndex, timeline: tl) != .unchanged { changes += 1 }
                t += 1.0 / 60
            }
            XCTAssertEqual(changes, 20)
        }
    }
}
