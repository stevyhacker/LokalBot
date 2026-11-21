import SwiftUI

struct ListColumnSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let identifier: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.scaled(.body))
                .accessibilityLabel(Text(prompt))
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(identifier + ".clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .workspaceControl()
    }
}

struct PageSectionHeading<Trailing: View>: View {
    let title: LocalizedStringKey
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(LBTokens.Typography.section)
            if let count {
                Text(count, format: .number)
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            trailing
            Spacer(minLength: 0)
        }
    }
}

extension PageSectionHeading where Trailing == EmptyView {
    init(title: LocalizedStringKey, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

struct PageDecisionRow: View {
    let text: String
    let link: String
    let linkDescription: String
    var accentLink = false
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(LBTokens.Palette.successText)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if accentLink {
                    Button(action: open) { label }
                        .buttonStyle(.workspaceLink)
                } else {
                    Button(action: open) { label.workspaceSupportingForeground() }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: accentLink ? 260 : 200, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .help(linkDescription)
            .accessibilityLabel(Text(verbatim: linkDescription))
        }
        .padding(.vertical, 4)
    }

    private var label: some View {
        Text(verbatim: link)
            .font(AppFont.scaled(.callout))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct SideColumnBlock<Content: View>: View {
    let title: LocalizedStringKey
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(AppFont.scaled(.callout).weight(.semibold))
                    .workspaceSupportingForeground()
                if let count {
                    Text(count, format: .number)
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PageSideColumnLayout {
    static let sideWidth: CGFloat = 252
    static let pageMinimumWidth: CGFloat = 388

    static func sideWidth(textScale: CGFloat) -> CGFloat {
        (sideWidth * max(1, textScale)).rounded()
    }

    static func placesSideBeside(paneWidth: CGFloat, textScale: CGFloat) -> Bool {
        paneWidth >= ((pageMinimumWidth + sideWidth) * max(1, textScale)).rounded()
    }
}

struct PageWithSideColumn<Main: View, Side: View>: View {
    @Environment(\.appTextScale) private var textScale
    var hasMain = true
    var hasSide = true
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side

    var body: some View {
        GeometryReader { proxy in
            let beside = hasMain && hasSide
                && PageSideColumnLayout.placesSideBeside(paneWidth: proxy.size.width, textScale: textScale)
            ScrollView {
                if beside {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap + 4) { main }
                            .padding(.leading, WorkspaceMetric.pagePadding)
                            .padding(.trailing, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) { side }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 24)
                            .frame(width: PageSideColumnLayout.sideWidth(textScale: textScale), alignment: .topLeading)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(.separator).frame(width: 1).accessibilityHidden(true)
                            }
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap + 4) {
                        if hasMain { main }
                        if hasSide { side }
                    }
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.vertical, 24)
                    .frame(maxWidth: WorkspaceMetric.readingMaxWidth + 2 * WorkspaceMetric.pagePadding,
                           alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

struct LabelChip: View {
    enum Size { case regular, small }

    let text: String
    var attention = false
    var size = Size.regular
    var onSelection = false

    var body: some View {
        Text(verbatim: text)
            .font(size == .regular
                  ? AppFont.scaled(.callout).weight(.semibold)
                  : AppFont.scaled(.subheadline).weight(.medium).monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .regular ? 9 : 7)
            .padding(.vertical, size == .regular ? 3 : 2)
            .background(fill, in: Capsule())
    }

    private var foreground: AnyShapeStyle {
        if onSelection { return AnyShapeStyle(.primary) }
        return attention
            ? AnyShapeStyle(LBTokens.Palette.attentionText)
            : AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting))
    }

    private var fill: AnyShapeStyle {
        if onSelection { return AnyShapeStyle(.primary.opacity(0.16)) }
        return attention
            ? AnyShapeStyle(LBTokens.Palette.attention.opacity(LBTokens.Palette.statusFillOpacity * 1.2))
            : AnyShapeStyle(Color.primary.opacity(0.06))
    }
}
