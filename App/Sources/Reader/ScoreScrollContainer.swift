import SwiftUI
import UIKit

/// `UIScrollView` subclass that reports when its bounds *size* changes (rotation, split view, ...).
final class ReaderScrollView: UIScrollView {
    var onBoundsSizeChange: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            onBoundsSizeChange?()
        }
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
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let driver: ScrollDriver
        weak var scrollView: ReaderScrollView?
        var hosting: UIHostingController<Content>?

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

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            doubleTap.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(doubleTap)
        }

        func detach() {
            driver.relayoutHandler = nil
            if driver.scrollView === scrollView {
                driver.scrollView = nil
            }
            hosting?.view.removeFromSuperview()
            hosting = nil
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

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let scrollView = scrollView else { return }
            let point = recognizer.location(in: scrollView)
            driver.didDoubleTap(atContentY: point.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
