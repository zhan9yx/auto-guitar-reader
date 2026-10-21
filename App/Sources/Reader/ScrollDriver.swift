import SwiftUI
import UIKit
import AGRCore

/// Bridge between the reader UI and its `UIScrollView`.
///
/// Owned by the reader. The next phase (follow / playback) drives it like this:
///   - read `lineFrames` (content coordinates), `viewportHeight`, `contentHeight` to compute a target offset
///   - every display-link frame call `setContentOffsetY(_:)` (no animation) or, for far jumps, `crossfadeJump(to:)`
///   - listen to `onUserScroll` to pause auto-scroll while the user drags
///   - listen to `onDoubleTapLine` to relocate the follower
///
/// None of the properties are `@Published` on purpose: they change every frame and must not
/// invalidate SwiftUI views.
@MainActor
final class ScrollDriver: ObservableObject {
    /// Frame of every rendered line in scroll-content coordinates.
    var lineFrames: [LineRef: CGRect] = [:] {
        didSet { onGeometryChange?() }
    }
    /// Visible height of the scroll view.
    var viewportHeight: CGFloat = 0
    /// Total height of the hosted document.
    var contentHeight: CGFloat = 0
    /// Current vertical content offset (live value from the scroll view).
    var contentOffsetY: CGFloat { scrollView?.contentOffset.y ?? lastKnownOffsetY }

    /// Called with the new offset while the user is dragging / the scroll view is decelerating.
    var onUserScroll: ((CGFloat) -> Void)?
    /// Called when the user double-taps a rendered line.
    var onDoubleTapLine: ((LineRef) -> Void)?
    /// Called whenever line frames, content height or viewport height change.
    var onGeometryChange: (() -> Void)?

    /// True while the user's finger is on the scroll view or it is decelerating.
    private(set) var isUserInteracting: Bool = false

    weak var scrollView: UIScrollView?
    /// Installed by the scroll container so SwiftUI content-size changes can trigger a re-measure.
    var relayoutHandler: (() -> Void)?

    private var lastKnownOffsetY: CGFloat = 0
    fileprivate var isApplyingProgrammaticOffset = false

    // MARK: Driving

    /// Largest valid offset for the current content / viewport.
    var maxOffsetY: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    func clampedOffset(_ y: CGFloat) -> CGFloat {
        min(max(0, y), maxOffsetY)
    }

    /// Direct set, no animation. Safe to call every display-link frame.
    func setContentOffsetY(_ y: CGFloat) {
        guard let scrollView = scrollView else {
            lastKnownOffsetY = clampedOffset(y)
            return
        }
        let target = clampedOffset(y)
        if abs(scrollView.contentOffset.y - target) < 0.01 { return }
        isApplyingProgrammaticOffset = true
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        isApplyingProgrammaticOffset = false
        lastKnownOffsetY = target
    }

    /// Snapshot fade (0.3 s): old content fades out over the new position.
    func crossfadeJump(to y: CGFloat) {
        guard let scrollView = scrollView else {
            lastKnownOffsetY = clampedOffset(y)
            return
        }
        guard let container = scrollView.superview,
              let snapshot = scrollView.snapshotView(afterScreenUpdates: false) else {
            setContentOffsetY(y)
            return
        }
        snapshot.frame = scrollView.frame
        snapshot.isUserInteractionEnabled = false
        container.insertSubview(snapshot, aboveSubview: scrollView)
        setContentOffsetY(y)
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: { snapshot.alpha = 0 },
            completion: { _ in snapshot.removeFromSuperview() }
        )
    }

    /// Asks the container to re-measure the hosted SwiftUI content.
    func requestRelayout() {
        relayoutHandler?()
    }

    /// Vertical range `(minY, maxY)` of a line, if it has been rendered.
    func yRange(of line: LineRef) -> (minY: CGFloat, height: CGFloat)? {
        guard let frame = lineFrames[line] else { return nil }
        return (frame.minY, frame.height)
    }

    /// Hit test for double taps: the line whose vertical extent contains `y` (nearest one if in a gap).
    func line(atContentY y: CGFloat) -> LineRef? {
        var best: (ref: LineRef, distance: CGFloat)?
        for (ref, frame) in lineFrames {
            if y >= frame.minY && y <= frame.maxY { return ref }
            let distance = min(abs(y - frame.minY), abs(y - frame.maxY))
            if distance <= 12, best == nil || distance < best!.distance {
                best = (ref, distance)
            }
        }
        return best?.ref
    }

    // MARK: Called by the scroll container

    func updateGeometry(viewportHeight: CGFloat, contentHeight: CGFloat) {
        let changed = self.viewportHeight != viewportHeight || self.contentHeight != contentHeight
        self.viewportHeight = viewportHeight
        self.contentHeight = contentHeight
        if changed { onGeometryChange?() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        lastKnownOffsetY = scrollView.contentOffset.y
        guard !isApplyingProgrammaticOffset else { return }
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            onUserScroll?(scrollView.contentOffset.y)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserInteracting = true
        onUserScroll?(scrollView.contentOffset.y)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isUserInteracting = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isUserInteracting = false
    }

    func didDoubleTap(atContentY y: CGFloat) {
        if let line = line(atContentY: y) {
            onDoubleTapLine?(line)
        }
    }
}
