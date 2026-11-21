import SwiftUI

enum SectionPanelMetric {
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 36
    static let bandHeight: CGFloat = 28
    static var titleFont: AppFont { AppFont.scaledSystem(size: 14, weight: .bold) }
}

struct SectionPanelDisclosure {
    let isExpanded: Bool
    let identifier: String
    let toggle: () -> Void
}

struct SectionPanel<Link: View, Content: View, Footer: View>: View {
    @Environment(\.appTextScale) private var textScale
    let title: Text
    let systemImage: String
    var count: Int?
    var alert: Text?
    var status: SectionPanelPill?
    let identifier: String
    var showsContent = true
    var showsFooter = true
    var titleID: AnyHashable?
    var trailingFills = false
    var titleLineLimit = 1
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
            titleText
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier + ".title")
            if let count {
                SectionPanelPill(text: Text(count, format: .number), tone: .count)
            }
            if let alert {
                SectionPanelPill(text: alert, tone: .overdue)
            }
            if let status { status }
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
            .lineLimit(titleLineLimit)
            .fixedSize(horizontal: false, vertical: titleLineLimit > 1)
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
    init(title: Text, systemImage: String, count: Int? = nil, alert: Text? = nil,
         status: SectionPanelPill? = nil, identifier: String,
         showsContent: Bool = true, titleID: AnyHashable? = nil, titleLineLimit: Int = 1,
         disclosure: SectionPanelDisclosure? = nil,
         @ViewBuilder link: () -> Link, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, alert: alert, status: status,
                  identifier: identifier,
                  showsContent: showsContent, showsFooter: false, titleID: titleID,
                  titleLineLimit: titleLineLimit, disclosure: disclosure,
                  link: link, content: content, footer: { EmptyView() })
    }
}

extension SectionPanel where Footer == EmptyView, Link == EmptyView {
    init(title: Text, systemImage: String, count: Int? = nil, identifier: String,
         showsContent: Bool = true, titleID: AnyHashable? = nil, disclosure: SectionPanelDisclosure? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, identifier: identifier,
                  showsContent: showsContent, showsFooter: false, titleID: titleID, disclosure: disclosure,
                  link: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

struct SectionPanelLead<Content: View, Below: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(.horizontal, SectionPanelMetric.inset + 2)
                .padding(.top, 15)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Below.self != EmptyView.self {
                Divider()
                below
                    .clipShape(UnevenRoundedRectangle(
                        cornerRadii: .init(bottomLeading: Brand.Radius.panel, bottomTrailing: Brand.Radius.panel),
                        style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
    }
}

extension SectionPanelLead where Below == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, below: { EmptyView() })
    }
}

struct SectionPanelPill: View {
    enum Tone { case count, overdue, done }

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
        case .done: sized.foregroundStyle(LBTokens.Palette.accentText)
        }
    }

    private var fill: Color {
        switch tone {
        case .count: LBTokens.Palette.quietFill
        case .overdue: LBTokens.Palette.recording.opacity(LBTokens.Palette.statusFillOpacity)
        case .done: LBTokens.Palette.accentFill.opacity(LBTokens.Palette.statusFillOpacity)
        }
    }
}

extension View {
    func sectionPanelFooterText() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionPanelLabel: View {
    let text: Text

    var body: some View {
        text
            .font(AppFont.scaledSystem(size: 11, weight: .bold))
            .workspaceSupportingForeground()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionPanelBand: View {
    @Environment(\.appTextScale) private var textScale
    let text: Text
    var followsRows = false

    var body: some View {
        VStack(spacing: 0) {
            if followsRows { Divider() }
            text
                .font(AppFont.scaledSystem(size: 11, weight: .bold))
                .workspaceSupportingForeground()
                .lineLimit(1)
                .padding(.horizontal, SectionPanelMetric.inset)
                .frame(maxWidth: .infinity, minHeight: SectionPanelMetric.bandHeight * textScale, alignment: .leading)
                .background(LBTokens.Palette.groupFill)
            Divider()
        }
    }
}
