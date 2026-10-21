import XCTest
@testable import AGRCore

/// Follower behaviour around the extractor's new gate: closing-gate (quiet) frames, long pauses and restarts.
final class FollowResumeTests: XCTestCase {
    typealias T = FollowTest
    let cho = "{title: t}\n{tempo: 120}\n[C] [G] [Am] [F] [C] [G] [Am] [F]"

    private func make(_ config: FollowerConfig = .init()) -> (ScoreFollower, Timeline) {
        let tl = T.timeline(cho, beatsPerChord: 4)
        return (ScoreFollower(timeline: tl, mode: .strumSing, config: config), tl)
    }

    private func feed(_ f: ScoreFollower, _ t: inout Double, frames: Int, notes: [Int], silent: Bool = false, quiet: Bool = false) {
        for k in 0..<frames {
            f.process(T.frame(time: t, notes: silent ? [] : notes, onset: k < 2 ? 3 : 0.1, silent: silent, quiet: quiet))
            t += 1 / T.fc.frameRate
        }
    }

    /// Frames after `t` until the follower reports `event` (nil: not within `limit` frames).
    private func framesToReach(_ f: ScoreFollower, event: Int, notes: [Int], from t: inout Double, limit: Int = 60) -> Int? {
        for k in 0..<limit {
            f.process(T.frame(time: t, notes: notes, onset: k < 2 ? 3 : 0.1))
            t += 1 / T.fc.frameRate
            if f.state.eventIndex == event { return k + 1 }
        }
        return nil
    }

    func testQuietFramesCarryNoEvidenceAndDoNotStartThePauseClock() {
        let (f, tl) = make()
        var t = 0.0
        feed(f, &t, frames: 60, notes: tl.events[0].midiNotes)
        XCTAssertEqual(f.state.eventIndex, 0)
        // 0.25 s of a closing gate whose "chroma" is that of a wrong chord (noise): must not pull the estimate away.
        feed(f, &t, frames: 11, notes: tl.events[3].midiNotes, quiet: true)
        XCTAssertLessThanOrEqual(f.state.eventIndex, 1)
        XCTAssertFalse(f.state.isPaused)
        feed(f, &t, frames: 30, notes: tl.events[0].midiNotes)
        XCTAssertLessThanOrEqual(f.state.eventIndex, 1)
    }

    func testPauseFreezesThenPausesAfterThreeSecondsAndResumeFromEarlierEvent() {
        let (f, tl) = make()
        var t = 0.0
        for e in 0..<3 { feed(f, &t, frames: Int(2 * T.fc.frameRate), notes: tl.events[e].midiNotes) }
        feed(f, &t, frames: 30, notes: tl.events[3].midiNotes)      // event 3 just started
        XCTAssertEqual(f.state.eventIndex, 3)
        // Stop for 5 s: frozen after the (short) grace, paused after 3 s of silence.
        feed(f, &t, frames: Int(1.5 * T.fc.frameRate), notes: [], silent: true)
        XCTAssertFalse(f.state.isPaused)
        feed(f, &t, frames: Int(2 * T.fc.frameRate), notes: [], silent: true)
        XCTAssertTrue(f.state.isPaused)
        let frozen = f.state.eventIndex
        XCTAssertLessThanOrEqual(abs(frozen - 3), 1, "the clock must not run far ahead of a stopped player")
        feed(f, &t, frames: Int(1.5 * T.fc.frameRate), notes: [], silent: true)
        XCTAssertEqual(f.state.eventIndex, frozen, "frozen")
        // The player resumes one event earlier (Am, event 2): re-acquired within 10 frames (0.23 s).
        let n = framesToReach(f, event: 2, notes: tl.events[2].midiNotes, from: &t)
        XCTAssertNotNil(n)
        XCTAssertLessThanOrEqual(n ?? 99, 10)
        XCTAssertFalse(f.state.isPaused)
    }

    func testSilenceGraceBridgesAShortRest() {
        // A 0.4 s rest in the middle of an event: the clock keeps running and the next event is still found.
        let (f, tl) = make()
        var t = 0.0
        feed(f, &t, frames: Int(1.2 * T.fc.frameRate), notes: tl.events[0].midiNotes)
        feed(f, &t, frames: Int(0.4 * T.fc.frameRate), notes: [], silent: true)
        feed(f, &t, frames: Int(0.4 * T.fc.frameRate), notes: tl.events[0].midiNotes)
        feed(f, &t, frames: 16, notes: tl.events[1].midiNotes)
        XCTAssertEqual(f.state.eventIndex, 1)
    }

    func testDefaultsAfterGateRework() {
        let c = FollowerConfig()
        XCTAssertLessThanOrEqual(c.silenceGraceSeconds, 0.6)
        XCTAssertLessThanOrEqual(c.fingerSilenceGraceSeconds, 0.8)
        XCTAssertEqual(c.pauseAfterSilenceSeconds, 3)
        let fc = FeatureConfig()
        XCTAssertEqual(fc.bassMaxMidi, 52)
        XCTAssertGreaterThanOrEqual(fc.gateHoldSeconds, 0.25)
        XCTAssertLessThanOrEqual(fc.gateHoldSeconds, 0.4)
        var set = FeatureConfig()
        XCTAssertTrue(set.set("gateHoldSeconds", 0.3))
        XCTAssertEqual(set.gateHoldSeconds, 0.3)
        XCTAssertFalse(set.set("nonsense", 1))
    }
}
