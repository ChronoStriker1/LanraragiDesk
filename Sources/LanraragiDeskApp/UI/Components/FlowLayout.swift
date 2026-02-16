import SwiftUI

/// Simple "tag cloud" wrapping layout: places subviews left-to-right and wraps to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 520
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + sz.width > width {
                totalHeight += lineHeight + lineSpacing
                lineWidth = 0
                lineHeight = 0
            }
            if lineWidth > 0 { lineWidth += spacing }
            lineWidth += sz.width
            lineHeight = max(lineHeight, sz.height)
        }

        totalHeight += lineHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sz.width, height: sz.height))
            x += sz.width + spacing
            lineHeight = max(lineHeight, sz.height)
        }
    }
}

