import XCTest
@testable import AGRCore

final class ScrollTests: XCTestCase {
    private let H = 800.0
    private let dt = 1.0 / 60

    private func controller(content: Double = 20000, config: ScrollConfig = .init()) -> ScrollController {
        let c = ScrollController(config: config)
        c.viewportHeight = H
        c.contentHeight = content
        return c
    }

    /// Runs the controller with a target function; returns (offsets, actions).
    @discardableResult
    private func run(_ c: ScrollController, from t0: Double = 0, seconds: Double,
                     target: (Double) -> (y: Double, conf: Double)?, feedEvery: Int = 1,
                     onStep: ((Double, ScrollAction) -> Void)? = nil) -> [Double] {
        var offsets: [Double] = []
        var t = t0
        let n = Int(seconds / dt)
        for i in 0..<n {
            if i % feedEvery == 0, let tg = target(t) { c.setTarget(y: tg.y, confidence: tg.conf, at: t) }
            let a = c.step(now: t)
            onStep?(t, a)
            offsets.append(c.offset)
            t += dt
        }
        return offsets
    }

    private func speeds(_ o: [Double]) -> [Double] { zip(o.dropFirst(), o).map { ($0 - $1) / dt } }

    // MARK: kinematics

    func testSpeedNeverExceedsCapAndReachesTarget() {
        let c = controller()
        let goal = c.offsetForTarget(600 + 0.3 * H)            // 600 pt below: less than one viewport
        let o = run(c, seconds: 6) { _ in (y: 600 + 0.3 * H, conf: 1) }
        let v = speeds(o)
        XCTAssertLessThanOrEqual(v.map(abs).max()!, 0.6 * H + 1e-6)
        XCTAssertEqual(o.last!, goal, accuracy: 0.045 * H, "settles at the dead zone of the target")
        XCTAssertGreaterThan(v.map(abs).max()!, 0.3 * H, "it does actually move at a decent speed")
    }

    func testAccelerationNeverExceedsCap() {
        let c = controller()
        var prev: Double?
        var worst = 0.0
        var last = c.offset
        run(c, seconds: 12, target: { t in (y: 100 + 500 * min(t, 4) + (t > 7 ? 600 : 0), conf: 1) }) { _, _ in
            let v = (c.offset - last) / self.dt
            if let p = prev { worst = max(worst, abs(v - p) / self.dt) }
            prev = v; last = c.offset
        }
        XCTAssertLessThanOrEqual(worst, 1.5 * H * 1.001)
    }

    func testDeadZoneSuppressesTinyMoves() {
        let c = controller()
        c.setOffset(1000)
        // Target within 2 % of the viewport from the current offset.
        let y = 1000 + 0.3 * H + 0.02 * H
        var actions: [ScrollAction] = []
        run(c, seconds: 3, target: { _ in (y: y, conf: 1) }) { _, a in actions.append(a) }
        XCTAssertTrue(actions.allSatisfy { $0 == .none })
        XCTAssertEqual(c.offset, 1000)
    }

    func testTracksSlowRampSmoothlyWithoutBackwardMotionOrLag() {
        let c = controller()
        let rate = 0.1 * H                                      // 0.1 viewport / s
        var offs: [Double] = []
        run(c, seconds: 30, target: { t in (y: 200 + rate * t, conf: 1) }, feedEvery: 3) { _, _ in offs.append(c.offset) }
        let v = speeds(offs)
        XCTAssertGreaterThanOrEqual(v.min()!, -1e-6, "never moves backward on a forward ramp")
        let t = 30.0
        let lag = (200 + rate * t - 0.3 * H) - c.offset
        XCTAssertLessThan(abs(lag), 0.08 * H)
        // Steady state speed equals the ramp speed.
        XCTAssertEqual(v.suffix(120).reduce(0, +) / 120, rate, accuracy: 0.2 * rate)
    }

    func testOffsetForTargetUsesAnchorRatio() {
        let c = controller()
        XCTAssertEqual(c.offsetForTarget(2000), 2000 - 0.3 * H)
        var cfg = ScrollConfig(); cfg.anchorRatio = 0.5
        let c2 = controller(config: cfg)
        XCTAssertEqual(c2.offsetForTarget(2000), 2000 - 0.5 * H)
    }

    // MARK: jump

    func testFarTargetCausesCrossfadeJumpOnlyAfterItIsStable() {
        let c = controller()
        let y = 5000.0
        var firstJump: Double?
        var jumpTarget: Double?
        run(c, seconds: 3, target: { _ in (y: y, conf: 1) }) { t, a in
            if case .jump(let to) = a, firstJump == nil { firstJump = t; jumpTarget = to }
        }
        let jt = try! XCTUnwrap(firstJump)
        XCTAssertGreaterThanOrEqual(jt, 0.5 - 1e-9, "target must be stable for 0.5 s first")
        XCTAssertLessThan(jt, 0.8)
        XCTAssertEqual(jumpTarget!, c.offsetForTarget(y), accuracy: 1e-9)
        XCTAssertEqual(c.offset, c.offsetForTarget(y), accuracy: 1e-9)
        XCTAssertEqual(c.velocity, 0)
    }

    func testNoHighSpeedChaseOfFarTarget() {
        let c = controller()
        // A moving far target never becomes stable: no jump, and the offset does not run away.
        var jumps = 0
        var maxOff = 0.0
        run(c, seconds: 2, target: { t in (y: 3000 + 900 * t, conf: 1) }) { _, a in
            if case .jump = a { jumps += 1 }
            maxOff = max(maxOff, c.offset)
        }
        XCTAssertEqual(jumps, 0)
        XCTAssertLessThan(maxOff, 1.0)
    }

    func testTargetWithinThresholdScrollsInsteadOfJumping() {
        let c = controller()
        var jumps = 0
        run(c, seconds: 4, target: { _ in (y: 0.3 * 800 + 700, conf: 1) }) { _, a in if case .jump = a { jumps += 1 } }
        XCTAssertEqual(jumps, 0)
        XCTAssertEqual(c.offset, 700, accuracy: 0.05 * H)
    }

    // MARK: backward

    func testBackwardMotionNeedsConfirmation() {
        let c = controller()
        c.setOffset(3000)
        var firstBack: Double?
        run(c, seconds: 4, target: { _ in (y: 3000 + 0.3 * H - 300, conf: 1) }) { t, _ in
            if firstBack == nil && c.offset < 3000 - 1 { firstBack = t }
        }
        let fb = try! XCTUnwrap(firstBack)
        XCTAssertGreaterThanOrEqual(fb, 1.5 - 0.05)
        XCTAssertEqual(c.offset, 2700, accuracy: 0.05 * H)
    }

    func testShortBackwardBlipIsIgnored() {
        let c = controller()
        c.setOffset(3000)
        run(c, seconds: 3, target: { t in (y: 3000 + 0.3 * H - (t > 0.5 && t < 1.5 ? 300 : 0), conf: 1) })
        XCTAssertEqual(c.offset, 3000, accuracy: 0.04 * H, "a 1 s dip of the target must not move the view")
    }

    // MARK: confidence, coast

    func testLowConfidenceStartIgnoresTarget() {
        let c = controller()
        run(c, seconds: 3) { _ in (y: 1500, conf: 0.1) }
        XCTAssertEqual(c.offset, 0)
    }

    func testCoastsAtLastSpeedThenStops() {
        let c = controller()
        let rate = 100.0                                         // pt/s
        // 6 s confident ramp, then confidence drops.
        var tDrop = 0.0
        var offs: [(Double, Double)] = []
        run(c, seconds: 20, target: { t in
            if t < 6 { tDrop = t; return (y: 400 + rate * t, conf: 1) }
            return (y: 400 + rate * t, conf: 0.1)
        }, onStep: { t, _ in offs.append((t, c.offset)) })
        func offset(at t: Double) -> Double { offs.min { abs($0.0 - t) < abs($1.0 - t) }!.1 }
        // During the coast (6...10 s) the view keeps moving forward at about the reading speed.
        let coastSpeed = (offset(at: 9) - offset(at: 7)) / 2
        XCTAssertEqual(coastSpeed, rate, accuracy: 0.35 * rate)
        // After coastSeconds it has stopped.
        let late = offset(at: 19) - offset(at: 14)
        XCTAssertEqual(late, 0, accuracy: 1.0)
        XCTAssertEqual(c.velocity, 0, accuracy: 1e-6)
        _ = tDrop
    }

    func testStaleTargetBehavesLikeLowConfidence() {
        let c = controller()
        // Confident for 3 s, then no more setTarget calls at all.
        var last = 0.0
        run(c, seconds: 12, target: { t in t < 3 ? (y: 300 + 80 * t, conf: 1) : nil }, onStep: { t, _ in if t > 9 { last = c.offset } })
        let end = c.offset
        XCTAssertEqual(end, last, accuracy: 1.0, "stopped after the coast window")
        XCTAssertGreaterThan(end, 0)
    }

    // MARK: manual override

    func testManualOverridePausesThenResumesSmoothly() {
        let c = controller()
        // Follow a ramp for a while.
        var t = 0.0
        while t < 3 {
            c.setTarget(y: 300 + 100 * t, confidence: 1, at: t)
            _ = c.step(now: t); t += dt
        }
        let before = c.offset
        // User drags the page 300 pt further down.
        c.userDidScroll(to: before + 300, at: t)
        XCTAssertTrue(c.isManualOverrideActive)
        let tUser = t
        var held = true
        var maxStep = 0.0
        var prev = c.offset
        var resumed = false
        while t < tUser + 10 {
            c.setTarget(y: 300 + 100 * t, confidence: 1, at: t)
            let a = c.step(now: t)
            if t < tUser + 3 - dt, a != .none || c.offset != before + 300 { held = false }
            maxStep = max(maxStep, abs(c.offset - prev))
            if t > tUser + 3.2, abs(c.offset - prev) > 0 { resumed = true }
            prev = c.offset
            t += dt
        }
        XCTAssertTrue(held, "no automatic movement during the override")
        XCTAssertTrue(resumed)
        XCTAssertLessThanOrEqual(maxStep, 0.6 * H * dt + 1e-6, "no snap on resume")
        // It has glided back to the reading position (the user was 300 pt ahead, i.e. behind the target).
        let want = c.offsetForTarget(300 + 100 * (t - dt))
        XCTAssertEqual(c.offset, want, accuracy: 0.1 * H)
    }

    func testUserScrollIsClamped() {
        let c = controller(content: 3000)
        c.userDidScroll(to: -50, at: 0)
        XCTAssertEqual(c.offset, 0)
        c.userDidScroll(to: 99999, at: 1)
        XCTAssertEqual(c.offset, 3000 - H)
    }

    // MARK: clamping

    func testOffsetStaysInsideDocument() {
        let c = controller(content: 2000)
        var lo = Double.infinity, hi = -Double.infinity
        run(c, seconds: 10, target: { t in (y: t < 5 ? 5000 : -2000, conf: 1) }) { _, _ in
            lo = min(lo, c.offset); hi = max(hi, c.offset)
        }
        XCTAssertGreaterThanOrEqual(lo, 0)
        XCTAssertLessThanOrEqual(hi, 2000 - H + 1e-9)
    }

    func testShortDocumentNeverScrolls() {
        let c = controller(content: 500)
        run(c, seconds: 3) { _ in (y: 400, conf: 1) }
        XCTAssertEqual(c.offset, 0)
    }

    func testDeterministic() {
        func trace() -> [Double] {
            let c = controller()
            return run(c, seconds: 8) { t in (y: 300 + 130 * t + 60 * sin(t * 3), conf: t > 5 ? 0.2 : 1) }
        }
        XCTAssertEqual(trace(), trace())
    }

    // MARK: ReadingPosition

    private func readingTimeline() -> Timeline {
        let cho = "{title: t}\n{tempo: 100}\n[C]aaaa[G]bbbb\n[Am]cccc[F]dddd"
        return Timeline.build(from: try! ChordProParser.parse(cho))
    }

    func testReadingPositionInterpolatesInsideTheLine() {
        let tl = readingTimeline()
        let frames: [LineRef: (minY: Double, height: Double)] = [
            LineRef(sectionIndex: 0, lineIndex: 0): (100, 50), LineRef(sectionIndex: 0, lineIndex: 1): (150, 50),
        ]
        let f: (LineRef) -> (minY: Double, height: Double)? = { frames[$0] }
        func y(_ e: Int, _ p: Double) -> Double? {
            ReadingPosition.documentY(state: FollowState(eventIndex: e, progressInEvent: p), timeline: tl, lineFrame: f)
        }
        // Two equally wide events per line: first event covers 0...0.5 of the line.
        XCTAssertEqual(y(0, 0)!, 100, accuracy: 1e-9)
        XCTAssertEqual(y(0, 1)!, 125, accuracy: 1e-9)
        XCTAssertEqual(y(1, 0)!, 125, accuracy: 1e-9)
        XCTAssertEqual(y(1, 1)!, 150, accuracy: 1e-9)
        XCTAssertEqual(y(2, 0.5)!, 162.5, accuracy: 1e-9)
        // Monotonic across all events.
        var last = -Double.infinity
        for e in 0..<tl.events.count { for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            let v = y(e, p)!
            XCTAssertGreaterThanOrEqual(v, last - 1e-9); last = v
        } }
    }

    func testReadingPositionNilCases() {
        let tl = readingTimeline()
        let none: (LineRef) -> (minY: Double, height: Double)? = { _ in nil }
        XCTAssertNil(ReadingPosition.documentY(state: FollowState(eventIndex: 0), timeline: tl, lineFrame: none))
        XCTAssertNil(ReadingPosition.documentY(state: FollowState(eventIndex: 99), timeline: tl, lineFrame: { _ in (0, 10) }))
        XCTAssertNil(ReadingPosition.documentY(state: FollowState(eventIndex: -1), timeline: tl, lineFrame: { _ in (0, 10) }))
        // Out-of-range progress is clamped.
        let y = ReadingPosition.documentY(state: FollowState(eventIndex: 0, progressInEvent: 5), timeline: tl, lineFrame: { _ in (0, 100) })
        XCTAssertEqual(y!, 50, accuracy: 1e-9)
    }

    // MARK: page turn

    func testPageTurnWaitsForTwoThirdsThenTurnsHalfAPage() {
        let p = PageTurnController()
        p.viewportHeight = H; p.contentHeight = 20000
        p.config.animated = false
        // Reading line at 60 % of the viewport: no turn.
        p.setTarget(y: 0.6 * H, confidence: 1, at: 0)
        XCTAssertEqual(p.step(now: 0), .none)
        // At 70 %: turn by half a page.
        p.setTarget(y: 0.7 * H, confidence: 1, at: 1)
        XCTAssertEqual(p.step(now: 1), .jump(to: 0.5 * H))
        XCTAssertEqual(p.offset, 0.5 * H)
        // The line is now at 20 % of the viewport: quiet; minimum interval respected.
        p.setTarget(y: 0.5 * H + 0.9 * H, confidence: 1, at: 1.1)
        XCTAssertEqual(p.step(now: 1.1), .none)
    }

    func testPageTurnAnimationEndsAtTarget() {
        let p = PageTurnController()
        p.viewportHeight = H; p.contentHeight = 20000
        p.setTarget(y: 0.8 * H, confidence: 1, at: 0)
        var t = 0.0
        var offsets: [Double] = []
        for _ in 0..<60 {
            if case .setOffset(let o) = p.step(now: t) { offsets.append(o) }
            t += dt
        }
        XCTAssertEqual(p.offset, 0.5 * H, accuracy: 1e-6)
        XCTAssertEqual(offsets, offsets.sorted(), "eased, monotonic")
        XCTAssertGreaterThan(offsets.count, 10)
    }

    func testPageTurnFarJumpLandsNearTopAndLowConfidenceIsIgnored() {
        let p = PageTurnController()
        p.viewportHeight = H; p.contentHeight = 20000
        p.setTarget(y: 5000, confidence: 0.1, at: 0)
        XCTAssertEqual(p.step(now: 0), .none)
        p.setTarget(y: 5000, confidence: 0.9, at: 1)
        XCTAssertEqual(p.step(now: 1), .jump(to: 5000 - 0.15 * H))
    }

    func testPageTurnBackwardNeedsConfirmationAndManualOverridePauses() {
        let p = PageTurnController()
        p.viewportHeight = H; p.contentHeight = 20000
        p.config.animated = false
        p.userDidScroll(to: 4000, at: 0)
        p.setTarget(y: 4000 + 0.9 * H, confidence: 1, at: 0.5)
        XCTAssertEqual(p.step(now: 0.5), .none, "override active")
        XCTAssertEqual(p.step(now: 3.1), .jump(to: 4000 + 0.5 * H), "override over: normal half-page turn")
        // Backward: the reading line is above the viewport; turn only after it stayed there for 1.5 s.
        p.setTarget(y: 3000, confidence: 1, at: 5)
        XCTAssertEqual(p.step(now: 5), .none)
        XCTAssertEqual(p.step(now: 5.8), .none)
        XCTAssertEqual(p.step(now: 6.6), .jump(to: 3000 - 0.15 * H))
    }
}
