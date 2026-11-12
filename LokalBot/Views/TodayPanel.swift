import SwiftUI

/// Sizes the panels share, in points at the unscaled text size.
enum TodayPanelMetric {
    /// Space between a panel's edge and its text.
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
}

/// One section of Today on its own raised surface: a header bar with the
/// section's symbol, name, count and one link; rows under a hairline; and a
/// footer strip for the one extra line a section has.
struct TodayPanel<Link: View, Content: View, Footer: View>: View {
    @Environment(\.appTextScale) private var textScale
    let title: Text
    /// The symbol the section's sidebar destination uses.
    let systemImage: String
    var count: Int?
    /// A red badge beside the count, such as "1 overdue".
    var alert: Text?
    /// Names the panel; its title is `<identifier>.title`.
    let identifier: String
    var showsContent = true
    var showsFooter = true
    @ViewBuilder var link: Link
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsContent {
                Divider()
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsFooter {
                Divider()
                footerStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(AppFont.scaledSystem(size: 13, weight: .semibold))
                .foregroundStyle(Brand.teal)
                .frame(width: 18 * textScale)
                .accessibilityHidden(true)
            // Plain text: selectable text with the header trait loses its
            // words for assistive tools.
            title
                .font(TodayType.panelTitle)
                .lineLimit(1)
                // Before the spacer, which would otherwise take half the bar.
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier + ".title")
            if let count {
                TodayPanelPill(text: Text(count, format: .number), tone: .count)
            }
            if let alert {
                TodayPanelPill(text: alert, tone: .overdue)
            }
            Spacer(minLength: 8)
            link
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, TodayPanelMetric.inset)
        .padding(.trailing, TodayPanelMetric.inset - 2)
        .frame(minHeight: TodayPanelMetric.headerHeight * textScale)
    }

    private var footerStrip: some View {
        let radius = Brand.Radius.panel
        return HStack(alignment: .firstTextBaseline, spacing: 8) { footer }
            .buttonStyle(.workspaceLink)
            .font(AppFont.scaled(.callout))
            // The supporting colour stays above 4.5:1 on the strip's fill.
            .workspaceSupportingForeground()
            .padding(.horizontal, TodayPanelMetric.inset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: TodayPanelMetric.footerHeight * textScale, alignment: .leading)
            .background(
                LBTokens.Palette.groupFill,
                in: UnevenRoundedRectangle(
                    cornerRadii: .init(bottomLeading: radius, bottomTrailing: radius), style: .continuous))
    }
}

extension TodayPanel where Footer == EmptyView {
    init(title: Text, systemImage: String, count: Int? = nil, alert: Text? = nil, identifier: String,
         showsContent: Bool = true,
         @ViewBuilder link: () -> Link, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, alert: alert, identifier: identifier,
                  showsContent: showsContent, showsFooter: false,
                  link: link, content: content, footer: { EmptyView() })
    }
}

/// The count beside a panel's title, or its red "overdue" badge.
struct TodayPanelPill: View {
    enum Tone { case count, overdue }

    @Environment(\.appTextScale) private var textScale
    @Environment(\.colorSchemeContrast) private var contrast
    let text: Text
    let tone: Tone

    var body: some View {
        label
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: 20 * textScale, minHeight: 18 * textScale)
            .background(fill, in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Color.primary.opacity(0.5))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
    }

    @ViewBuilder private var label: some View {
        let sized = text.font(AppFont.scaledSystem(size: 11, weight: .semibold).monospacedDigit())
        switch tone {
        case .count: sized.workspaceSupportingForeground()
        case .overdue: sized.foregroundStyle(LBTokens.Palette.recordingText)
        }
    }

    private var fill: Color {
        switch tone {
        case .count: LBTokens.Palette.quietFill
        case .overdue: LBTokens.Palette.recording.opacity(LBTokens.Palette.statusFillOpacity)
        }
    }
}

extension View {
    /// The words of a panel's footer: they take the strip's width and wrap,
    /// and the link after them keeps to the trailing edge.
    func todayPanelFooterText() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small label over a group inside a panel ("Highlights", "Priorities for
/// today").
struct TodayPanelLabel: View {
    let text: Text

    var body: some View {
        text
            .font(AppFont.scaledSystem(size: 11, weight: .bold))
            .workspaceSupportingForeground()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Columns

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
