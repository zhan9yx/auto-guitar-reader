import SwiftUI

/// Wrapping layout: places subviews left-to-right and wraps to a new row when the
/// proposed width is exceeded. Subviews are never split, so callers pass small cells
/// (e.g. one per CJK character) to be able to wrap anywhere.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 0

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> (rows: [Row], sizes: [CGSize]) {
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        for subview in subviews {
            sizes.append(subview.sizeThatFits(.unspecified))
        }

        var rows: [Row] = []
        var current = Row()
        for (index, size) in sizes.enumerated() {
            let advance = current.indices.isEmpty ? size.width : horizontalSpacing + size.width
            if !current.indices.isEmpty && current.width + advance > maxWidth + 0.5 {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width += advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return (rows, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? CGFloat.infinity
        let result = computeRows(subviews: subviews, maxWidth: maxWidth)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in result.rows {
            width = max(width, row.width)
            height += row.height
        }
        if result.rows.count > 1 {
            height += verticalSpacing * CGFloat(result.rows.count - 1)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in result.rows {
            var x = bounds.minX
            for index in row.indices {
                let size = result.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }
}
