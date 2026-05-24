import SwiftUI

/// Wrapping HStack — items flow onto the next row when they don't
/// fit. Built because SwiftUI's HStack doesn't reflow, the
/// `ViewThatFits` width-bucket approach re-measures every variant
/// on every parent body recompute (chat-pane sampled cascade
/// pinned `LazyVStack.lengthAndSpacing` from inner-HStack
/// measurement), and `Flow` isn't a built-in primitive on macOS 26.
///
/// One sizeThatFits pass + one placement pass per row. Items keep
/// their intrinsic sizes; rows wrap when the running x position
/// plus the next item's width would exceed the proposed container
/// width. Empty proposals fall back to a single row (best-effort).
///
/// Shared by the chat surface's wrapping citation chip strip
/// (`FlowingCitationRow`) and the Concepts sidebar's related-
/// concepts chip row (`ConceptDetailView`). Promoted out of the
/// Concepts file into Theme so both consumers can use the same
/// implementation.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
