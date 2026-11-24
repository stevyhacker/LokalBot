import SwiftUI

struct TodayColumnsLayout: Layout {
    enum Slot: Equatable { case full, leading, trailing }

    var textScale: CGFloat
    var spacing: CGFloat = TodayColumns.gap

    static func frames(slots: [Slot], width: CGFloat, textScale: CGFloat, spacing: CGFloat,
                       height: (Int, CGFloat) -> CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let columns = TodayColumns.count(
            width: width, textScale: textScale,
            hasLeading: slots.contains(.leading), hasTrailing: slots.contains(.trailing))
        let trailingWidth = TodayColumns.trailingWidth(textScale: textScale)
        let leadingWidth = max(0, width - spacing - trailingWidth)
        var frames: [CGRect] = []
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
    func todayColumn(_ slot: TodayColumnsLayout.Slot) -> some View {
        layoutValue(key: TodayColumnSlotKey.self, value: slot)
    }
}

struct YesterdayBriefColumnsLayout: Layout {
    var textScale: CGFloat
    var readingWidth: CGFloat = WorkspaceMetric.readingMaxWidth

    static func frames(
        width: CGFloat,
        textScale: CGFloat,
        readingWidth: CGFloat = WorkspaceMetric.readingMaxWidth,
        primaryHeight: (CGFloat) -> CGFloat,
        secondaryHeight: (CGFloat) -> CGFloat
    ) -> (frames: [CGRect], height: CGFloat) {
        if YesterdayBriefColumns.isTwoColumn(width: width, textScale: textScale) {
            let gap = YesterdayBriefColumns.columnGap
            let dividerWidth = YesterdayBriefColumns.dividerWidth
            let widths = YesterdayBriefColumns.widths(in: width)
            let leftHeight = primaryHeight(widths.primary)
            let rightHeight = secondaryHeight(widths.secondary)
            let totalHeight = max(leftHeight, rightHeight)
            let dividerX = widths.primary + gap
            let rightX = dividerX + dividerWidth + gap
            return ([
                CGRect(x: 0, y: 0, width: widths.primary, height: leftHeight),
                CGRect(x: dividerX, y: 0, width: dividerWidth, height: totalHeight),
                CGRect(x: rightX, y: 0, width: widths.secondary, height: rightHeight),
            ], totalHeight)
        }
        let scaledReading = (readingWidth * TodayColumns.factor(textScale: textScale)).rounded()
        let lineWidth = min(width, scaledReading)
        let leftHeight = primaryHeight(lineWidth)
        let rightHeight = secondaryHeight(lineWidth)
        let spacing = YesterdayBriefColumns.verticalDividerSpacing
        let dividerWidth = YesterdayBriefColumns.dividerWidth
        let dividerY = leftHeight + spacing
        let rightY = dividerY + dividerWidth + spacing
        return ([
            CGRect(x: 0, y: 0, width: lineWidth, height: leftHeight),
            CGRect(x: 0, y: dividerY, width: width, height: dividerWidth),
            CGRect(x: 0, y: rightY, width: lineWidth, height: rightHeight),
        ], rightY + rightHeight)
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        guard subviews.count == 3 else {
            var y: CGFloat = 0
            var frames: [CGRect] = []
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                frames.append(CGRect(x: 0, y: y, width: width, height: height))
                y += height
            }
            return (frames, y)
        }
        return Self.frames(
            width: width,
            textScale: textScale,
            readingWidth: readingWidth,
            primaryHeight: { subviews[0].sizeThatFits(ProposedViewSize(width: $0, height: nil)).height },
            secondaryHeight: { subviews[2].sizeThatFits(ProposedViewSize(width: $0, height: nil)).height }
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? readingWidth
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
