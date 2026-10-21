import Foundation

// MARK: - PageTurnController (DESIGN §4.4, item 6)
//
// Alternative to the continuous `ScrollController` (e.g. iPad landscape): the view stays still until the reading line
// passes `turnRatio` of the viewport, then it turns by `pageStep` viewport heights (half a page by default), either
// as a short eased animation (`.setOffset` frames) or as one crossfade `.jump`.

public struct PageTurnConfig: Sendable {
    /// Reading line position (fraction of the viewport from the top) that triggers a turn.
    public var turnRatio: Double = 2.0 / 3.0
    /// Fraction of the viewport the content moves per turn.
    public var pageStep: Double = 0.5
    /// Where the reading line lands after a far jump / backward turn.
    public var landingRatio: Double = 0.15
    public var lowConfidence: Double = 0.35
    /// Minimum time between turns.
    public var minInterval: Double = 0.8
    /// Backward turns need the line to stay above the viewport this long.
    public var backwardConfirmSeconds: Double = 1.5
    public var manualOverrideSeconds: Double = 3
    public var animated: Bool = true
    public var animationSeconds: Double = 0.35
    public init() {}
}

public final class PageTurnController {
    public var config: PageTurnConfig
    public var viewportHeight: Double = 800
    public var contentHeight: Double = 0
    public private(set) var offset: Double = 0

    private var targetY: Double = 0
    private var confidence: Double = 0
    private var hasTarget = false
    private var lastTurn: Double = -.infinity
    private var behindSince: Double?
    private var overrideUntil: Double?
    private var anim: (t0: Double, from: Double, to: Double)?

    public init(config: PageTurnConfig = .init()) { self.config = config }

    private var maxOffset: Double { max(0, contentHeight - viewportHeight) }
    private func clamp(_ y: Double) -> Double { min(max(y, 0), maxOffset) }

    public func setTarget(y: Double, confidence: Double, at time: Double) {
        targetY = y
        self.confidence = confidence
        hasTarget = true
    }

    public func userDidScroll(to offset: Double, at time: Double) {
        self.offset = clamp(offset)
        overrideUntil = time + config.manualOverrideSeconds
        anim = nil
        behindSince = nil
    }

    public func step(now: Double) -> ScrollAction {
        if let until = overrideUntil {
            if now < until { return .none }
            overrideUntil = nil
        }
        if let a = anim {
            let p = min(1, max(0, (now - a.t0) / max(config.animationSeconds, 1e-3)))
            let eased = p * p * (3 - 2 * p)
            offset = a.from + (a.to - a.from) * eased
            if p >= 1 { anim = nil; offset = a.to }
            return .setOffset(offset)
        }
        guard hasTarget, confidence >= config.lowConfidence, now - lastTurn >= config.minInterval else {
            if confidence < config.lowConfidence { behindSince = nil }
            return .none
        }
        let H = max(viewportHeight, 1)
        let r = (targetY - offset) / H          // reading line, viewport fraction
        var newOffset: Double?
        if r > config.turnRatio {
            behindSince = nil
            if r > 1.0 + config.pageStep {
                newOffset = clamp(targetY - config.landingRatio * H)     // far away: land the line near the top
            } else {
                newOffset = clamp(offset + config.pageStep * H)
                // Make sure the line is not still beyond the trigger after a half-page step.
                if let n = newOffset, (targetY - n) / H > config.turnRatio { newOffset = clamp(targetY - config.landingRatio * H) }
            }
        } else if r < 0 {
            if behindSince == nil { behindSince = now }
            if now - (behindSince ?? now) >= config.backwardConfirmSeconds {
                newOffset = clamp(targetY - config.landingRatio * H)
                behindSince = nil
            }
        } else {
            behindSince = nil
        }
        guard let n = newOffset, abs(n - offset) > 1e-6 else { return .none }
        lastTurn = now
        if config.animated && abs(n - offset) <= 1.0 * H {
            anim = (now, offset, n)
            return .setOffset(offset)
        }
        offset = n
        return .jump(to: n)
    }
}
