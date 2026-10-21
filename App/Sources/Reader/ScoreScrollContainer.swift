import SwiftUI
import UIKit

/// `UIScrollView` subclass that reports when its bounds *size* changes (rotation, split view, ...).
final class ReaderScrollView: UIScrollView {
    var onBoundsSizeChange: (() -> Void)?
    /// Called with `true` when the view enters a window and `false` when it leaves one.
    var onMoveToWindow: ((Bool) -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?(window != nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            onBoundsSizeChange?()
        }
    }
}

/// Target / delegate of the double-tap recognizer. A non-generic type, because Objective-C selectors are not
/// supported on classes nested in the generic `ScoreScrollContainer`.
@MainActor
final class DoubleTapTarget: NSObject, UIGestureRecognizerDelegate {
    var onDoubleTap: ((UITapGestureRecognizer) -> Void)?

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        onDoubleTap?(recognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Hosts a SwiftUI document view inside a `UIScrollView` so the next phase can drive the
/// content offset every display-link frame (see `ScrollDriver`).
///
/// The hosted view is measured with `sizeThatFits` for the current width (frame-based layout,
/// no Auto Layout), and re-measured whenever the container size changes, the root view is
/// updated, or the document reports a new content size via `ScrollDriver.requestRelayout()`.
struct ScoreScrollContainer<Content: View>: UIViewRepresentable {
    let driver: ScrollDriver
    let content: Content

    init(driver: ScrollDriver, @ViewBuilder content: () -> Content) {
        self.driver = driver
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(driver: driver)
    }

    func makeUIView(context: Context) -> ReaderScrollView {
        let scrollView = ReaderScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator

        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        scrollView.addSubview(hosting.view)

        context.coordinator.attach(scrollView: scrollView, hosting: hosting)
        scrollView.onBoundsSizeChange = { [weak coordinator = context.coordinator] in
            coordinator?.relayout()
        }
        scrollView.onMoveToWindow = { [weak coordinator = context.coordinator] attached in
            coordinator?.windowChanged(attached: attached)
        }
        return scrollView
    }

    func updateUIView(_ uiView: ReaderScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
        context.coordinator.relayout()
    }

    static func dismantleUIView(_ uiView: ReaderScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let driver: ScrollDriver
        weak var scrollView: ReaderScrollView?
        var hosting: UIHostingController<Content>?
        /// Strong reference: gesture recognizers only hold their target weakly.
        private let doubleTapTarget = DoubleTapTarget()

        init(driver: ScrollDriver) {
            self.driver = driver
            super.init()
        }

        func attach(scrollView: ReaderScrollView, hosting: UIHostingController<Content>) {
            self.scrollView = scrollView
            self.hosting = hosting
            driver.scrollView = scrollView
            driver.relayoutHandler = { [weak self] in
                self?.relayout()
            }

            doubleTapTarget.onDoubleTap = { [weak self] recognizer in
                self?.handleDoubleTap(recognizer)
            }
            let doubleTap = UITapGestureRecognizer(target: doubleTapTarget, action: #selector(DoubleTapTarget.handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = doubleTapTarget
            doubleTap.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(doubleTap)
        }

        func detach() {
            driver.relayoutHandler = nil
            if driver.scrollView === scrollView {
                driver.scrollView = nil
            }
            if let hosting = hosting, hosting.parent != nil {
                hosting.willMove(toParent: nil)
                hosting.removeFromParent()
            }
            hosting?.view.removeFromSuperview()
            hosting = nil
        }

        /// Keeps the hosting controller in the view-controller hierarchy while the scroll view is on screen,
        /// so SwiftUI appearance / trait / environment propagation works as for any hosted view.
        func windowChanged(attached: Bool) {
            guard let hosting = hosting, let scrollView = scrollView else { return }
            if attached {
                guard hosting.parent == nil, let parent = Self.parentViewController(of: scrollView) else { return }
                parent.addChild(hosting)
                hosting.didMove(toParent: parent)
            } else if hosting.parent != nil {
                hosting.willMove(toParent: nil)
                hosting.removeFromParent()
            }
        }

        private static func parentViewController(of view: UIView) -> UIViewController? {
            var responder: UIResponder? = view.next
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        /// Measures the hosted SwiftUI content for the current width and updates frame / contentSize.
        func relayout() {
            guard let scrollView = scrollView, let hosting = hosting else { return }
            let width = scrollView.bounds.width
            guard width > 1 else { return }
            let fitted = hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            let height = max(ceil(fitted.height), 1)
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            if hosting.view.frame != frame {
                hosting.view.frame = frame
            }
            let size = CGSize(width: width, height: height)
            if scrollView.contentSize != size {
                scrollView.contentSize = size
            }
            driver.updateGeometry(viewportHeight: scrollView.bounds.height, contentHeight: height)
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            driver.scrollViewDidScroll(scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            driver.scrollViewWillBeginDragging(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            driver.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            driver.scrollViewDidEndDecelerating(scrollView)
        }

        // MARK: Gestures

        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let scrollView = scrollView else { return }
            // Location in a scroll view's own coordinate space = content coordinates (bounds.origin is the offset).
            let point = recognizer.location(in: scrollView)
            driver.didDoubleTap(atContentY: point.y)
        }
    }
}
