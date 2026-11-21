import AppKit
import SwiftUI

struct QuickRecallRow: View {
    @EnvironmentObject private var app: AppState

    let row: QuickRecallRowModel
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            QuickRecallLeadView(lead: row.lead, isSaved: row.isSaved, selected: selected)
            QuickRecallRowText(title: row.title, qualifier: row.qualifier, trailing: trailing,
                               speaker: row.speaker, snippet: row.snippet, selected: selected)
            QuickRecallReturnHint(visible: selected)
        }
        .quickRecallRowChrome(selected: selected, hovered: hovered)
        .onHover { hovered = $0 }
    }

    private var trailing: String? {
        if let shortcut = row.shortcut { return shortcut }
        let language = app.settings.appLanguage
        return row.timestamp.map {
            QuickRecallDateLabel.string(for: $0, locale: language.locale, localize: language.catalog)
        }
    }
}

struct QuickRecallAskRow: View {
    let query: String
    let detail: String
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.white : LBTokens.Palette.accentText)
                .frame(width: QuickRecallLeadView.size.width, height: QuickRecallLeadView.size.height)
                .background(selected ? Color.white.opacity(0.2) : LBTokens.Palette.accentFill.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Ask about “\(query)”")
                    .font(.scaled(.body).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: detail)
                    .font(.scaled(.callout))
                    .foregroundStyle(selected ? Color.white.opacity(0.88) : Color.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 10)
                Text(verbatim: "⌘↩")
                    .font(.scaled(.callout))
                    .foregroundStyle(selected ? Color.white.opacity(0.88) : Color.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            QuickRecallReturnHint(visible: selected)
        }
        .quickRecallRowChrome(selected: selected, hovered: hovered)
        .onHover { hovered = $0 }
    }
}

struct QuickRecallGroupHeader: View {
    let group: QuickRecallGroup
    let showAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(group.kind.title))
                .font(.scaled(.subheadline).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if group.hasMore {
                Button(action: showAll) {
                    Text("Show all \(group.totalLabel)")
                        .font(.scaled(.subheadline).weight(.medium))
                        .monospacedDigit()
                }
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("quickRecall.showAll.\(group.kind.rawValue)")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 44)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

struct QuickRecallRowText<Accessory: View>: View {
    let title: String
    var qualifier: String?
    var trailing: String?
    var speaker: String?
    var snippet: String?
    var selected = false
    @ViewBuilder var accessory: () -> Accessory

    private var quiet: Color { selected ? Color.white.opacity(0.88) : Color.secondary }
    private var strong: Color { selected ? Color.white : Color.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: title)
                    .font(.scaled(.body).weight(.semibold))
                    .foregroundStyle(strong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                accessory()
                if let qualifier {
                    Text(verbatim: qualifier)
                        .font(.scaled(.callout))
                        .foregroundStyle(quiet)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 10)
                if let trailing {
                    Text(verbatim: trailing)
                        .font(.scaled(.callout).monospacedDigit())
                        .foregroundStyle(quiet)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let snippet {
                matchingLine(snippet)
                    .font(.scaled(.callout))
                    .foregroundStyle(quiet)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func matchingLine(_ snippet: String) -> Text {
        let lead = speaker.map { Text(verbatim: "\($0): ").foregroundStyle(strong) } ?? Text(verbatim: "")
        return SnippetHighlighter.segments(snippet).reduce(lead) { text, segment in
            text + (segment.isMatch
                ? Text(verbatim: segment.text).bold().foregroundStyle(strong)
                : Text(verbatim: segment.text))
        }
    }
}

extension QuickRecallRowText where Accessory == EmptyView {
    init(title: String, qualifier: String? = nil, trailing: String? = nil, speaker: String? = nil,
         snippet: String? = nil, selected: Bool = false) {
        self.init(title: title, qualifier: qualifier, trailing: trailing, speaker: speaker,
                  snippet: snippet, selected: selected) { EmptyView() }
    }
}

struct QuickRecallLeadView: View {
    static let size = CGSize(width: 44, height: 30)

    let lead: QuickRecallRowModel.Lead
    var isSaved = false
    var selected = false

    var body: some View {
        Group {
            switch lead {
            case .thumbnail(let snapshotID):
                ScreenThumbnailView(snapshotID: snapshotID, height: Self.size.height, cornerRadius: 6)
                    .frame(width: Self.size.width)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LBTokens.Palette.groupStroke)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSaved { savedBadge.offset(x: 5, y: 5) }
                    }
            case .symbol(let name):
                tile {
                    Image(systemName: name).font(.system(size: 14, weight: .medium))
                }
            case .file(let path):
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 26, height: 26)
            case .recording:
                tile {
                    Circle().fill(LBTokens.Palette.recording).frame(width: 10, height: 10)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(selected ? Color.white : LBTokens.Palette.accentText)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(selected ? Color.white.opacity(0.2) : LBTokens.Palette.groupFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.clear : LBTokens.Palette.groupStroke)
            }
    }

    private var savedBadge: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 8))
            .foregroundStyle(Brand.amber)
            .frame(width: 15, height: 15)
            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
    }
}

struct QuickRecallReturnHint: View {
    let visible: Bool

    var body: some View {
        Image(systemName: "return")
            .font(.scaled(.caption))
            .foregroundStyle(Color.white)
            .opacity(visible ? 1 : 0)
            .frame(width: 14, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

extension View {
    func quickRecallRowChrome(selected: Bool, hovered: Bool) -> some View {
        modifier(QuickRecallRowChrome(selected: selected, hovered: hovered))
    }
}

private struct QuickRecallRowChrome: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let selected: Bool
    let hovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.row, style: .continuous)
        content
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 40)
            .background(selected ? LBTokens.Palette.accentFill : hovered ? Color.primary.opacity(0.05) : Color.clear,
                        in: shape)
            .overlay {
                shape.strokeBorder(selected && contrast == .increased ? Color.primary : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
    }
}
