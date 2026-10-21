import SwiftUI
import AGRCore

// Shared plumbing between the SwiftUI document views and the UIKit scroll container.

enum ReaderCoordinateSpace {
    /// Name of the coordinate space that equals scroll-view content coordinates.
    static let name = "scoreDocument"
}

/// Frames (in `ReaderCoordinateSpace`) of every rendered line.
struct LineFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LineRef: CGRect] = [:]

    static func reduce(value: inout [LineRef: CGRect], nextValue: () -> [LineRef: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Size of the whole document content.
struct ContentSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Position currently highlighted by playback / follow (next phase).
typealias ReaderHighlight = (line: LineRef, segmentIndex: Int?)

extension View {
    /// Reports the view's size through `ContentSizePreferenceKey`.
    func reportsContentSize() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ContentSizePreferenceKey.self, value: geometry.size)
            }
        }
    }

    /// Reports the view's frame in the reader coordinate space for the given line.
    func reportsLineFrame(_ ref: LineRef) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LineFramePreferenceKey.self,
                    value: [ref: geometry.frame(in: .named(ReaderCoordinateSpace.name))]
                )
            }
        }
    }
}
