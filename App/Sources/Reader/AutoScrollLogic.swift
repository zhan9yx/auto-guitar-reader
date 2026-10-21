import Foundation
import AGRCore

// Framework-free auto-scroll logic. `AutoScrollCoordinator` (CADisplayLink adapter) calls `tick` every display frame;
// everything here is deterministic given `now`, a `ScrollSurface` and a `ReadingSample`, so it is unit-tested with a
// fake clock and fake line frames.

enum AutoScrollStyle: String, CaseIterable, Identifiable {
    /// Continuous glide (critically damped spring, `ScrollController`).
    case smooth
    /// The view stays still and turns by half a page when the reading line passes 2/3 (`PageTurnController`).
    case pageTurn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smooth: return "平滑滚动"
        case .pageTurn: return "翻页"
        }
    }
}

struct AutoScrollSettings {
    var style: AutoScrollStyle = .smooth
    var scroll = ScrollConfig()
    var pageTurn = PageTurnConfig()
}

/// Current reading position, from the follower or from the playback clock.
struct ReadingSample: Equatable {
    var eventIndex: Int
    /// 0...1 inside the event.
    var progressInEvent: Double
    /// Playback passes 1.
    var confidence: Double
}

/// The scroll view as seen by the logic (implemented by an adapter around `ScrollDriver`; a fake in tests).
@MainActor
protocol ScrollSurface: AnyObject {
    var viewportHeight: Double { get }
    var contentHeight: Double { get }
    var contentOffsetY: Double { get }
    /// Frame of a rendered line in content coordinates (nil when not laid out).
    func lineFrame(_ line: LineRef) -> (minY: Double, height: Double)?
    func setContentOffsetY(_ y: Double)
    func crossfadeJump(to y: Double)
}

@MainActor
final class AutoScrollLogic {
    private(set) var timeline: Timeline
    var settings: AutoScrollSettings {
        didSet {
            scroll.config = settings.scroll
            pageTurn.config = settings.pageTurn
        }
    }

    private let scroll: ScrollController
    private let pageTurn: PageTurnController
    private var manualUntil: Double?

    /// True from a user drag until the manual-override time has passed (drives the "回到跟随" button).
    private(set) var isOverridden = false
    var onOverrideChange: ((Bool) -> Void)?
    /// Last document y the reading position mapped to (diagnostics / tests).
    private(set) var lastTargetY: Double?
    private(set) var lastAction: ScrollAction = .none

    init(timeline: Timeline, settings: AutoScrollSettings = AutoScrollSettings()) {
        self.timeline = timeline
        self.settings = settings
        self.scroll = ScrollController(config: settings.scroll)
        self.pageTurn = PageTurnController(config: settings.pageTurn)
    }

    /// Replaces the timeline (the event layout is identical for every transposition, so this is only needed when the
    /// score itself changed).
    func setTimeline(_ timeline: Timeline) {
        self.timeline = timeline
    }

    private var activeOffset: Double {
        settings.style == .smooth ? scroll.offset : pageTurn.offset
    }

    // MARK: Lifecycle

    /// Starts from the surface's current offset with no history.
    func begin(surface: ScrollSurface, now: Double) {
        syncGeometry(surface)
        adoptOffset(surface.contentOffsetY, now: now)
        scroll.resetTracking()
        manualUntil = nil
        lastTargetY = nil
        lastAction = .none
        setOverridden(false)
    }

    // MARK: User interaction

    /// The user dragged the scroll view (also called while it decelerates).
    func userDidScroll(to y: Double, now: Double) {
        scroll.userDidScroll(to: y, at: now)
        pageTurn.userDidScroll(to: y, at: now)
        manualUntil = now + settings.scroll.manualOverrideSeconds
        setOverridden(true)
    }

    /// "回到跟随": end the manual override now; the view glides back (a backward move is not held back).
    func resumeFollowing(surface: ScrollSurface, now: Double) {
        manualUntil = nil
        setOverridden(false)
        expireOverride(offset: surface.contentOffsetY, now: now)
    }

    /// The follower / playback was relocated (double tap, seek): forget the reading history and take the new target
    /// immediately (a far target is reached with a crossfade jump).
    func relocated(surface: ScrollSurface, now: Double) {
        resumeFollowing(surface: surface, now: now)
        scroll.resetTracking()
    }

    // MARK: Frame

    /// One display frame. Applies the resulting action to `surface` and returns it.
    @discardableResult
    func tick(now: Double, reading: ReadingSample?, surface: ScrollSurface) -> ScrollAction {
        syncGeometry(surface)
        if let until = manualUntil, now >= until {
            manualUntil = nil
        }
        setOverridden(manualUntil != nil)

        // The surface moved without us (rotation clamped the offset, restore, ...): follow it.
        let actual = surface.contentOffsetY
        if !isOverridden, abs(actual - activeOffset) > 1.5 {
            adoptOffset(actual, now: now)
        }

        if let r = reading,
           let y = ReadingPosition.documentY(eventIndex: r.eventIndex, progressInEvent: r.progressInEvent,
                                             timeline: timeline, lineFrame: { surface.lineFrame($0) }) {
            scroll.setTarget(y: y, confidence: r.confidence, at: now)
            pageTurn.setTarget(y: y, confidence: r.confidence, at: now)
            lastTargetY = y
        }

        guard surface.viewportHeight > 0, surface.contentHeight > 0 else {
            lastAction = .none
            return .none
        }
        let action = settings.style == .smooth ? scroll.step(now: now) : pageTurn.step(now: now)
        switch action {
        case .none:
            break
        case .setOffset(let y):
            surface.setContentOffsetY(y)
        case .jump(let y):
            surface.crossfadeJump(to: y)
        }
        lastAction = action
        return action
    }

    // MARK: Helpers

    private func syncGeometry(_ surface: ScrollSurface) {
        let vh = surface.viewportHeight, ch = surface.contentHeight
        scroll.viewportHeight = vh
        scroll.contentHeight = ch
        pageTurn.viewportHeight = vh
        pageTurn.contentHeight = ch
    }

    private func setOverridden(_ value: Bool) {
        guard value != isOverridden else { return }
        isOverridden = value
        onOverrideChange?(value)
    }

    /// Makes both controllers start from `y` without a manual override (the controllers only expose the offset
    /// through `userDidScroll`; an override that started long enough ago has already expired at the next step).
    private func adoptOffset(_ y: Double, now: Double) {
        scroll.setOffset(y)
        pageTurn.userDidScroll(to: y, at: now - pageTurn.config.manualOverrideSeconds - 1)
    }

    private func expireOverride(offset: Double, now: Double) {
        scroll.userDidScroll(to: offset, at: now - scroll.config.manualOverrideSeconds)
        pageTurn.userDidScroll(to: offset, at: now - pageTurn.config.manualOverrideSeconds)
    }
}

/// Emits a highlight only when the (line, chord segment) of the current event changes, so SwiftUI is not
/// invalidated every frame.
struct HighlightTracker {
    struct Target: Equatable {
        var line: LineRef
        var segmentIndex: Int?
    }

    enum Change: Equatable {
        case unchanged
        case set(Target)
        case clear
    }

    private(set) var current: Target?

    init() {}

    mutating func update(eventIndex: Int?, timeline: Timeline) -> Change {
        guard let i = eventIndex, timeline.events.indices.contains(i) else {
            return clear()
        }
        let e = timeline.events[i]
        let target = Target(line: e.line, segmentIndex: e.segmentIndex)
        guard target != current else { return .unchanged }
        current = target
        return .set(target)
    }

    mutating func clear() -> Change {
        guard current != nil else { return .unchanged }
        current = nil
        return .clear
    }
}
