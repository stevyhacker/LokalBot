import SwiftUI

/// Sizes the panels share, in points at the unscaled text size.
enum SectionPanelMetric {
    /// Space between a panel's edge and its text.
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    static let bandHeight: CGFloat = 28
    /// Panel titles sit one step above the 13 pt headline.
    static var titleFont: AppFont { AppFont.scaledSystem(size: 14, weight: .bold) }
}

/// Makes a panel's header the control that opens and closes its body: the
/// chevron takes the symbol's place and the whole bar is one button.
struct SectionPanelDisclosure {
    let isExpanded: Bool
    /// Names the header button.
    let identifier: String
    let toggle: () -> Void
}

/// One section of a page on its own raised surface: a header bar with the
/// section's symbol, name, count and one link; rows under a hairline; and a
/// footer strip for the one extra line a section has. Today, and a meeting's
/// Summary, Transcript and Notes, are made of these.
struct SectionPanel<Link: View, Content: View, Footer: View>: View {
    @Environment(\.appTextScale) private var textScale
    let title: Text
    /// The symbol beside the title; for a section with a sidebar destination,
    /// that destination's symbol.
    let systemImage: String
    var count: Int?
    /// A red badge beside the count, such as "1 overdue".
    var alert: Text?
    /// Names the panel; its title is `<identifier>.title`.
    let identifier: String
    var showsContent = true
    var showsFooter = true
    /// Where a scroll to the section's heading lands.
    var titleID: AnyHashable?
    /// The trailing control is a field: it takes the room the title leaves,
    /// up to its own maximum, where a link keeps its own width.
    var trailingFills = false
    var disclosure: SectionPanelDisclosure?
    @ViewBuilder var link: Link
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let disclosure {
                disclosureHeader(disclosure)
            } else {
                header
            }
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
            titleText
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier + ".title")
            if let count {
                SectionPanelPill(text: Text(count, format: .number), tone: .count)
            }
            if let alert {
                SectionPanelPill(text: alert, tone: .overdue)
            }
            Spacer(minLength: 8)
            if trailingFills {
                link.layoutPriority(1)
            } else {
                link
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, SectionPanelMetric.inset)
        .padding(.trailing, SectionPanelMetric.inset - 2)
        .frame(minHeight: SectionPanelMetric.headerHeight * textScale)
    }

    /// The header as one button. It keeps the button's role, so it is named
    /// by its title and says whether the body is open.
    private func disclosureHeader(_ disclosure: SectionPanelDisclosure) -> some View {
        Button(action: disclosure.toggle) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: disclosure.isExpanded ? "chevron.down" : "chevron.forward")
                    .font(AppFont.scaledSystem(size: 11, weight: .semibold))
                    .workspaceSupportingForeground()
                    .frame(width: 18 * textScale)
                    .accessibilityHidden(true)
                titleText
                Spacer(minLength: 8)
            }
            .padding(.leading, SectionPanelMetric.inset)
            .padding(.trailing, SectionPanelMetric.inset - 2)
            .frame(maxWidth: .infinity, minHeight: SectionPanelMetric.headerHeight * textScale, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(disclosure.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(disclosure.identifier)
    }

    @ViewBuilder private var titleText: some View {
        let styled = title
            .font(SectionPanelMetric.titleFont)
            .lineLimit(1)
            // Before the spacer, which would otherwise take half the bar.
            .layoutPriority(1)
        if let titleID {
            styled.id(titleID)
        } else {
            styled
        }
    }

    private var footerStrip: some View {
        let radius = Brand.Radius.panel
        return HStack(alignment: .firstTextBaseline, spacing: 8) { footer }
            .buttonStyle(.workspaceLink)
            .font(AppFont.scaled(.callout))
            // The supporting colour stays above 4.5:1 on the strip's fill.
            .workspaceSupportingForeground()
            .padding(.horizontal, SectionPanelMetric.inset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: SectionPanelMetric.footerHeight * textScale, alignment: .leading)
            .background(
                LBTokens.Palette.groupFill,
                in: UnevenRoundedRectangle(
                    cornerRadii: .init(bottomLeading: radius, bottomTrailing: radius), style: .continuous))
    }
}

extension SectionPanel where Footer == EmptyView {
    init(title: Text, systemImage: String, count: Int? = nil, alert: Text? = nil, identifier: String,
         showsContent: Bool = true, titleID: AnyHashable? = nil, disclosure: SectionPanelDisclosure? = nil,
         @ViewBuilder link: () -> Link, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, alert: alert, identifier: identifier,
                  showsContent: showsContent, showsFooter: false, titleID: titleID, disclosure: disclosure,
                  link: link, content: content, footer: { EmptyView() })
    }
}

extension SectionPanel where Footer == EmptyView, Link == EmptyView {
    /// A panel with nothing at the header's trailing edge and no footer.
    init(title: Text, systemImage: String, count: Int? = nil, identifier: String,
         showsContent: Bool = true, titleID: AnyHashable? = nil, disclosure: SectionPanelDisclosure? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, identifier: identifier,
                  showsContent: showsContent, showsFooter: false, titleID: titleID, disclosure: disclosure,
                  link: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

/// A panel with no header bar: the text a page leads with, such as a
/// meeting's recap.
struct SectionPanelLead<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, SectionPanelMetric.inset + 2)
            .padding(.top, 15)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .todayCardSurface()
    }
}

/// The count beside a panel's title, or its red "overdue" badge.
struct SectionPanelPill: View {
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
    func sectionPanelFooterText() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small label over a group inside a panel ("Highlights", "Priorities for
/// today").
struct SectionPanelLabel: View {
    let text: Text

    var body: some View {
        text
            .font(AppFont.scaledSystem(size: 11, weight: .bold))
            .workspaceSupportingForeground()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled band across a panel's body, over a group of its rows ("For
/// you · 2"). It carries the footer strip's fill and a hairline under it; a
/// band after rows also draws the hairline above.
struct SectionPanelBand: View {
    @Environment(\.appTextScale) private var textScale
    let text: Text
    var followsRows = false

    var body: some View {
        VStack(spacing: 0) {
            if followsRows { Divider() }
            text
                .font(AppFont.scaledSystem(size: 11, weight: .bold))
                // The supporting colour stays above 4.5:1 on the band's fill.
                .workspaceSupportingForeground()
                .lineLimit(1)
                .padding(.horizontal, SectionPanelMetric.inset)
                .frame(maxWidth: .infinity, minHeight: SectionPanelMetric.bandHeight * textScale, alignment: .leading)
                .background(LBTokens.Palette.groupFill)
            Divider()
        }
    }
}
