import SwiftUI

/// Lays Today out as cards that span the page with the panels between them,
/// side by side when `TodayColumns` finds room and stacked in reading order
/// otherwise. One layout for both, so a panel keeps its state when the window
/// crosses the width where the page changes.
struct TodayColumnsLayout: Layout {
    enum Slot: Equatable { case full, leading, trailing }

    var textScale: CGFloat
    var spacing: CGFloat = TodayColumns.gap

    /// Where each subview goes in a page `width` wide. `height` measures the
    /// subview at an index for a width.
    static func frames(slots: [Slot], width: CGFloat, textScale: CGFloat, spacing: CGFloat,
                       height: (Int, CGFloat) -> CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let columns = TodayColumns.count(
            width: width, textScale: textScale,
            hasLeading: slots.contains(.leading), hasTrailing: slots.contains(.trailing))
        let trailingWidth = TodayColumns.trailingWidth(textScale: textScale)
        let leadingWidth = max(0, width - spacing - trailingWidth)
        var frames: [CGRect] = []
        // The next free position below everything placed so far, and inside
        // a run of panels the next free position of each column.
        var bottom: CGFloat = 0
        var leadingY: CGFloat?
        var trailingY: CGFloat?
        func closeColumns() {
            bottom = max(bottom, leadingY ?? bottom, trailingY ?? bottom)
            leadingY = nil
            trailingY = nil
        }
        for (index, slot) in slots.enumerated() {
            if columns == 1 || slot == .full {
                closeColumns()
                let itemHeight = height(index, width)
                frames.append(CGRect(x: 0, y: bottom, width: width, height: itemHeight))
                bottom += itemHeight + spacing
            } else if slot == .leading {
                let top = leadingY ?? bottom
                let itemHeight = height(index, leadingWidth)
                frames.append(CGRect(x: 0, y: top, width: leadingWidth, height: itemHeight))
                leadingY = top + itemHeight + spacing
                trailingY = trailingY ?? bottom
            } else {
                let top = trailingY ?? bottom
                let itemHeight = height(index, trailingWidth)
                frames.append(CGRect(x: leadingWidth + spacing, y: top, width: trailingWidth, height: itemHeight))
                trailingY = top + itemHeight + spacing
                leadingY = leadingY ?? bottom
            }
        }
        closeColumns()
        return (frames, max(0, bottom - spacing))
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        Self.frames(
            slots: subviews.map { $0[TodayColumnSlotKey.self] },
            width: width, textScale: textScale, spacing: spacing
        ) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? TodayColumns.twoColumnMinimumWidth(textScale: textScale)
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct TodayColumnSlotKey: LayoutValueKey {
    static let defaultValue = TodayColumnsLayout.Slot.full
}

extension View {
    /// The column a panel belongs to when Today shows two. Cards without one
    /// span the page.
    func todayColumn(_ slot: TodayColumnsLayout.Slot) -> some View {
        layoutValue(key: TodayColumnSlotKey.self, value: slot)
    }
}
