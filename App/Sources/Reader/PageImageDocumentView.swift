import SwiftUI
import UIKit
import AGRCore

/// Image-mode score renderer: page images stacked vertically at full width, with a
/// highlight band at the current line's `PageAnchor`.
struct PageImageDocumentView: View {
    let score: Score
    /// Aligned with `score.pages` (nil = image missing on disk).
    let images: [UIImage?]
    var highlightedEvent: (line: LineRef, segmentIndex: Int?)? = nil
    var onLineFrames: (([LineRef: CGRect]) -> Void)? = nil
    var onContentSizeChange: ((CGSize) -> Void)? = nil

    private struct AnchoredLine: Identifiable {
        let ref: LineRef
        let anchor: PageAnchor
        var id: LineRef { ref }
    }

    /// Anchored lines grouped by (0-based) page index.
    private var anchorsByPage: [Int: [AnchoredLine]] {
        var all: [AnchoredLine] = []
        for (sectionIndex, section) in score.sections.enumerated() {
            for (lineIndex, line) in section.lines.enumerated() {
                if let anchor = line.anchor {
                    all.append(AnchoredLine(ref: LineRef(sectionIndex: sectionIndex, lineIndex: lineIndex), anchor: anchor))
                }
            }
        }
        // Be tolerant of 1-based page numbers.
        let pageNumbers = all.map { $0.anchor.page }
        var offset = 0
        if let minPage = pageNumbers.min(), let maxPage = pageNumbers.max(),
           minPage >= 1, maxPage == score.pages.count {
            offset = 1
        }
        var grouped: [Int: [AnchoredLine]] = [:]
        for item in all {
            grouped[item.anchor.page - offset, default: []].append(item)
        }
        return grouped
    }

    var body: some View {
        let grouped = anchorsByPage
        VStack(spacing: 0) {
            ForEach(Array(score.pages.indices), id: \.self) { pageIndex in
                pageView(pageIndex, anchored: grouped[pageIndex] ?? [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 96)
        .coordinateSpace(name: ReaderCoordinateSpace.name)
        .reportsContentSize()
        .onPreferenceChange(LineFramePreferenceKey.self) { frames in
            let callback = onLineFrames
            Task { @MainActor in
                callback?(frames)
            }
        }
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            let callback = onContentSizeChange
            Task { @MainActor in
                callback?(size)
            }
        }
    }

    @ViewBuilder
    private func pageView(_ pageIndex: Int, anchored: [AnchoredLine]) -> some View {
        let page = score.pages[pageIndex]
        let image: UIImage? = pageIndex < images.count ? images[pageIndex] : nil
        let aspect: CGFloat = pageAspect(page: page, image: image)
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay {
            GeometryReader { geometry in
                anchorOverlay(
                    anchored: anchored,
                    size: geometry.size,
                    origin: geometry.frame(in: .named(ReaderCoordinateSpace.name)).origin
                )
            }
        }
    }

    private func pageAspect(page: PageImage, image: UIImage?) -> CGFloat {
        if let image = image, image.size.height > 0, image.size.width > 0 {
            return image.size.width / image.size.height
        }
        if page.height > 0, page.width > 0 {
            return CGFloat(page.width) / CGFloat(page.height)
        }
        return 0.707
    }

    private func anchorOverlay(anchored: [AnchoredLine], size: CGSize, origin: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(anchored) { item in
                let y = CGFloat(item.anchor.y) * size.height
                let height = max(CGFloat(item.anchor.height) * size.height, 2)
                let isCurrent: Bool = highlightedEvent?.line == item.ref
                Rectangle()
                    .fill(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear)
                    .frame(width: size.width, height: height)
                    .offset(y: y)
                    .preference(
                        key: LineFramePreferenceKey.self,
                        value: [item.ref: CGRect(x: origin.x, y: origin.y + y, width: size.width, height: height)]
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
