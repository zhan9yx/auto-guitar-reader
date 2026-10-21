import Foundation
import UIKit
import QuartzCore
import AGRCore

/// Adapts `ScrollDriver` (UIKit, CGFloat) to the framework-free `ScrollSurface`.
@MainActor
final class ScrollDriverSurface: ScrollSurface {
    private let driver: ScrollDriver

    init(driver: ScrollDriver) {
        self.driver = driver
    }

    var viewportHeight: Double { Double(driver.viewportHeight) }
    var contentHeight: Double { Double(driver.contentHeight) }
    var contentOffsetY: Double { Double(driver.contentOffsetY) }

    func lineFrame(_ line: LineRef) -> (minY: Double, height: Double)? {
        guard let frame = driver.lineFrames[line] else { return nil }
        return (Double(frame.minY), Double(frame.height))
    }

    func setContentOffsetY(_ y: Double) {
        driver.setContentOffsetY(CGFloat(y))
    }

    func crossfadeJump(to y: Double) {
        driver.crossfadeJump(to: CGFloat(y))
    }
}

/// Target of the `CADisplayLink`. The link retains its target, so this tiny proxy holds the coordinator weakly:
/// no retain cycle, and `invalidate()` releases the proxy.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: AutoScrollCoordinator?

    @objc func step(_ link: CADisplayLink) {
        owner?.handleFrame()
    }
}

/// Display-link loop that turns a reading position into scroll movement:
/// `source(now)` (playback clock or follower) -> `AutoScrollLogic.tick` -> `ScrollDriver`.
///
/// `source` is also the conductor's per-frame hook (highlight, playback end detection ...), so everything runs
/// on one clock.
@MainActor
final class AutoScrollCoordinator {
    private let driver: ScrollDriver
    private let surface: ScrollDriverSurface
    private let logic: AutoScrollLogic
    private let settingsProvider: () -> AutoScrollSettings

    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var source: ((Double) -> ReadingSample?)?
    private(set) var isRunning = false

    /// Fires when the manual-override state flips (shows / hides "回到跟随").
    var onOverrideChange: ((Bool) -> Void)? {
        didSet { logic.onOverrideChange = onOverrideChange }
    }

    init(driver: ScrollDriver, timeline: Timeline, settingsProvider: @escaping () -> AutoScrollSettings) {
        self.driver = driver
        self.surface = ScrollDriverSurface(driver: driver)
        self.settingsProvider = settingsProvider
        self.logic = AutoScrollLogic(timeline: timeline, settings: settingsProvider())
    }

    func setTimeline(_ timeline: Timeline) {
        logic.setTimeline(timeline)
    }

    func start(source: @escaping (Double) -> ReadingSample?) {
        stop()
        self.source = source
        logic.settings = settingsProvider()
        logic.begin(surface: surface, now: CACurrentMediaTime())
        driver.onUserScroll = { [weak self] y in
            self?.logic.userDidScroll(to: Double(y), now: CACurrentMediaTime())
        }

        let proxy = DisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
        isRunning = true
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy?.owner = nil
        proxy = nil
        source = nil
        driver.onUserScroll = nil
        isRunning = false
        if logic.isOverridden { logic.onOverrideChange?(false) }
    }

    /// "回到跟随".
    func resumeFollowing() {
        logic.resumeFollowing(surface: surface, now: CACurrentMediaTime())
    }

    /// After a relocation (double tap): take the new target at once.
    func relocated() {
        logic.relocated(surface: surface, now: CACurrentMediaTime())
    }

    fileprivate func handleFrame() {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        logic.settings = settingsProvider()
        let reading = source?(now)
        guard isRunning else { return }   // `source` may have stopped the session
        logic.tick(now: now, reading: reading, surface: surface)
    }
}
