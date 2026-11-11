import SwiftUI

// Building blocks of a list beside a page (People; Projects has the same
// shape): the list column's search header, a page section's heading, a page
// with a side column of reference blocks, and a small label chip.

/// The search field that heads a list column.
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

/// A page section's heading: its name, how many rows follow, and one link.
struct PageSectionHeading<Trailing: View>: View {
    let title: LocalizedStringKey
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // No header trait: a header becomes a different accessibility
            // element, which static-text queries no longer find.
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

/// One block of the side column: a quiet heading over a few links or rows.
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

/// Where the side column goes: beside the page while the pane has room for
/// both, under it otherwise. Both widths grow with the text size.
enum PageSideColumnLayout {
    static let sideWidth: CGFloat = 252
    /// The page keeps at least this much beside the column.
    static let pageMinimumWidth: CGFloat = 388

    static func sideWidth(textScale: CGFloat) -> CGFloat {
        (sideWidth * max(1, textScale)).rounded()
    }

    static func placesSideBeside(paneWidth: CGFloat, textScale: CGFloat) -> Bool {
        paneWidth >= ((pageMinimumWidth + sideWidth) * max(1, textScale)).rounded()
    }
}

/// A scrolling page with a side column of reference blocks at its trailing
/// edge, divided by a line that runs the pane's height. A narrow pane puts
/// the blocks under the page. With nothing for the page itself, the blocks
/// are the page.
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

/// A capsule label: amber for what needs the reader, quiet otherwise. On a
/// selected list row it takes the row's own foreground.
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
