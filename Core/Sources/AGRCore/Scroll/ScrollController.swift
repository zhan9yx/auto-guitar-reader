import Foundation

// MARK: - ScrollController (DESIGN §4.4)
//
// Pure math, deterministic with an injected clock. Units: points for offsets, seconds for time. `ScrollConfig`
// speeds / accelerations / thresholds are in viewport heights.
//
// Pipeline per `step(now)`:
//  1. manual override (user dragged): hold; afterwards resume with a smooth glide (backward confirmation waived once).
//  2. confidence gating: stale / low-confidence targets are ignored -> coast at the last smoothed reading speed for
//     `coastSeconds`, then decelerate to a stop.
//  3. backward gating: a target behind the current offset is only followed after it stayed behind for
//     `backwardConfirmSeconds`.
//  4. big gap (> jumpThreshold viewports) with a target that has been stable for `jumpStableSeconds` -> `.jump`.
//  5. otherwise a critically damped spring (with feed-forward of the estimated reading speed) tracks the target;
//     acceleration and speed are capped, a stopping-distance guard prevents overshoot, and the spring ignores
//     errors inside the dead zone (no corrective force, so a slowly advancing target glides instead of stepping).

public struct ScrollConfig: Sendable {
    public var anchorRatio: Double = 0.30          // current line position in viewport
    public var maxSpeed: Double = 0.6              // viewport heights / second
    public var maxAcceleration: Double = 1.5       // viewport heights / second^2
    public var deadZone: Double = 0.04             // viewport heights
    public var jumpThreshold: Double = 1.0         // viewport heights; beyond -> crossfade jump
    public var backwardConfirmSeconds: Double = 1.5
    public var lowConfidence: Double = 0.35
    public var coastSeconds: Double = 4
    public var manualOverrideSeconds: Double = 3
    /// Natural frequency of the critically damped spring (rad/s).
    public var stiffness: Double = 4.0
    /// 0...1: how much of the estimated reading speed is fed forward (removes the steady-state lag).
    public var feedForward: Double = 1.0
    /// Time constant of the reading-speed estimate (seconds).
    public var speedSmoothingSeconds: Double = 2.0
    /// Targets older than this are treated as "no information" (coast / stop).
    public var staleSeconds: Double = 1.0
    /// A far target must be stable this long before a crossfade jump.
    public var jumpStableSeconds: Double = 0.5
    /// Target moves smaller than this (viewport heights) do not reset the stability timer.
    public var jumpStableTolerance: Double = 0.15

    public init() {}
}

public struct LineGeometry: Sendable {
    public var lineIndexInDocument: Int
    public var minY: Double
    public var height: Double
    public init(lineIndexInDocument: Int, minY: Double, height: Double) {
        self.lineIndexInDocument = lineIndexInDocument
        self.minY = minY
        self.height = height
    }
}

public enum ScrollAction: Sendable, Equatable {
    case none
    case setOffset(Double)
    /// Crossfade jump (fade out, set offset, fade in, flash the current line).
    case jump(to: Double)
}

public final class ScrollController {
    public var config: ScrollConfig
    public var viewportHeight: Double = 800
    public var contentHeight: Double = 0
    public private(set) var offset: Double = 0
    /// Current scroll velocity (points / second), for diagnostics and tests.
    public private(set) var velocity: Double = 0
    /// True while the controller waits for the user's manual-scroll override to expire.
    public var isManualOverrideActive: Bool { overrideUntil != nil }

    // Target state
    private var targetY: Double = 0
    private var targetConfidence: Double = 0
    private var targetTime: Double = -.infinity
    private var hasTarget = false
    private var lastConfidentTime: Double = -.infinity
    private var lastReadY: Double?
    private var lastReadTime: Double = 0
    private var readSpeed: Double = 0             // points / second, smoothed

    // Gating state
    private var behindSince: Double?
    private var backwardWaived = false
    private var stableSince: Double?
    private var stableRef: Double = 0
    private var overrideUntil: Double?
    private var lastStep: Double?

    public init(config: ScrollConfig = .init()) {
        self.config = config
    }

    private var maxOffset: Double { max(0, contentHeight - viewportHeight) }

    private func clampOffset(_ y: Double) -> Double { min(max(y, 0), maxOffset) }

    /// Offset that places document y `targetY` at the anchor of the viewport.
    public func offsetForTarget(_ y: Double) -> Double { clampOffset(y - config.anchorRatio * viewportHeight) }

    // MARK: input

    /// Target from the follower / playback clock: document y of the current reading position + confidence.
    public func setTarget(y: Double, confidence: Double, at time: Double) {
        if confidence >= config.lowConfidence {
            // Reading-speed estimate from the confident target stream.
            if let ly = lastReadY, time > lastReadTime + 1e-6 {
                let dt = time - lastReadTime
                // Line-to-line steps of the follower are staircases: cap the instantaneous speed sample.
                let cap = 1.5 * config.maxSpeed * viewportHeight
                let inst = min(max((y - ly) / dt, -cap), cap)
                let alpha = 1 - exp(-dt / max(config.speedSmoothingSeconds, 1e-3))
                // Ignore teleports (relocations) in the speed estimate.
                if abs(y - ly) < 0.5 * viewportHeight { readSpeed += alpha * (inst - readSpeed) }
            }
            lastReadY = y
            lastReadTime = time
            lastConfidentTime = time
        }
        targetY = y
        targetConfidence = confidence
        targetTime = time
        hasTarget = true
    }

    /// The user dragged the scroll view to `offset`: pause automation for `manualOverrideSeconds`.
    public func userDidScroll(to offset: Double, at time: Double) {
        self.offset = clampOffset(offset)
        velocity = 0
        overrideUntil = time + config.manualOverrideSeconds
        behindSince = nil
        stableSince = nil
        lastStep = time
    }

    /// Forget the target history (e.g. after `relocate`): the next confident target is taken as-is.
    public func resetTracking() {
        lastReadY = nil
        readSpeed = 0
        behindSince = nil
        stableSince = nil
        backwardWaived = false
    }

    /// Instantly place the scroll position (e.g. restoring a saved position).
    public func setOffset(_ y: Double) {
        offset = clampOffset(y)
        velocity = 0
    }

    // MARK: step

    /// Call every display frame; returns the action to apply to the scroll view.
    public func step(now: Double) -> ScrollAction {
        let H = max(viewportHeight, 1)
        let rawDt = lastStep.map { now - $0 } ?? 0
        lastStep = now
        let dt = min(max(rawDt, 0), 0.1)
        let start = offset

        // 1. Manual override.
        if let until = overrideUntil {
            if now < until { velocity = 0; return .none }
            overrideUntil = nil
            backwardWaived = true          // the user displaced us, this is not a recognition regression
            behindSince = nil
            stableSince = nil
        }
        guard hasTarget, dt > 0 else { return emit(from: start) }

        let vmax = config.maxSpeed * H
        let amax = config.maxAcceleration * H
        let omega = config.stiffness
        let dz = config.deadZone * H

        // 2. Confidence gating.
        let fresh = now - targetTime <= config.staleSeconds
        let confident = fresh && targetConfidence >= config.lowConfidence
        var feedSpeed = max(0, readSpeed) * config.feedForward
        var desired = offsetForTarget(targetY)
        var tracking = confident

        if !confident {
            // Coast then stop.
            if now - lastConfidentTime > config.coastSeconds { feedSpeed = 0 }
            tracking = false
            behindSince = nil
            stableSince = nil
        }

        // At the ends of the document the reading-speed feed-forward must not push into the clamp.
        let rawOffset = targetY - config.anchorRatio * viewportHeight
        if rawOffset >= maxOffset || rawOffset <= 0 { feedSpeed = 0 }

        var e = desired - offset

        if tracking {
            // 3. Backward gating.
            if e < -dz {
                if behindSince == nil { behindSince = now }
                let confirmed = backwardWaived || (now - (behindSince ?? now)) >= config.backwardConfirmSeconds
                if !confirmed {
                    desired = offset
                    e = 0
                    feedSpeed = 0
                }
            } else {
                behindSince = nil
                if e >= 0 { backwardWaived = false }
            }

            // 4. Jump for far targets that have been stable.
            if abs(desired - offset) > config.jumpThreshold * H {
                if stableSince != nil && abs(desired - stableRef) <= config.jumpStableTolerance * H {
                    if now - (stableSince ?? now) >= config.jumpStableSeconds {
                        offset = desired
                        velocity = 0
                        stableSince = nil
                        behindSince = nil
                        backwardWaived = false
                        return .jump(to: offset)
                    }
                } else {
                    stableSince = now
                    stableRef = desired
                }
                // While waiting do not chase the far target (no high-speed scroll).
                desired = offset
                e = 0
                feedSpeed = 0
            } else {
                stableSince = nil
            }
        }

        // 5. Spring with caps.
        var a: Double
        if tracking {
            let eEff: Double = abs(e) <= dz ? 0 : e - (e > 0 ? dz : -dz)
            a = omega * omega * eEff - 2 * omega * (velocity - feedSpeed)
            // Stopping guard: moving toward the target faster than we can brake.
            if velocity * e > 0 && velocity * velocity > 2 * amax * abs(e) * 0.8 {
                a = -amax * (velocity > 0 ? 1 : -1)
            }
        } else {
            // Coast: relax to the feed speed (0 after coastSeconds).
            a = -2 * omega * (velocity - feedSpeed)
        }
        // Wall guard: never run into the ends of the document faster than we can brake.
        let wall = velocity > 0 ? maxOffset - offset : offset
        if abs(velocity) > 0 && velocity * velocity > 1.6 * amax * max(wall, 0) { a = -amax * (velocity > 0 ? 1 : -1) }
        a = min(max(a, -amax), amax)
        velocity += a * dt
        velocity = min(max(velocity, -vmax), vmax)
        if !tracking && feedSpeed == 0 && abs(velocity) < 0.5 { velocity = 0 }
        var next = offset + velocity * dt
        if next <= 0 { next = 0; if velocity < 0 { velocity = 0 } }
        if next >= maxOffset { next = maxOffset; if velocity > 0 { velocity = 0 } }
        offset = next
        return emit(from: start)
    }

    private func emit(from start: Double) -> ScrollAction {
        abs(offset - start) < 1e-9 ? .none : .setOffset(offset)
    }
}
