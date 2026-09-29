import SwiftUI

struct QuickRecallRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let row: QuickRecallRowModel
    let selected: Bool
    @State private var hovered = false

    private var accent: Color {
        LBTokens.Palette.accentText
    }

    private var background: Color {
        if selected { return LBTokens.Palette.accentFill }
        return hovered ? Color.primary.opacity(0.05) : .clear
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingVisual
                .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.scaled(.callout).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    // Slot is always reserved so selection doesn't reflow the line.
                    Image(systemName: "return")
                        .font(.scaled(.caption))
                        .foregroundStyle(selected ? .white : accent)
                        .opacity(selected ? 1 : 0)
                        .frame(width: 14, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                if let snippet = row.snippet, !snippet.isEmpty {
                    highlighted(snippet)
                        .font(.scaled(.callout))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if let appName = row.appName {
                        QuickRecallApplicationIcon(appName: appName, size: 12)
                    }
                    Text(row.subtitle)
                        .lineLimit(1)
                    if row.captureCount > 1 {
                        Text("· \(row.captureCount) captures")
                            .lineLimit(1)
                    }
                    if let timestamp = row.timestamp {
                        Text("· \(QuickRecallDateLabel.string(for: timestamp))")
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.scaled(.caption))
                .foregroundStyle(selected ? Color.white : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                .strokeBorder(selected && contrast == .increased ? Color.primary : .clear,
                              lineWidth: 2)
        }
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var leadingVisual: some View {
        if let snapshotID = row.snapshotID {
            ZStack(alignment: .bottomTrailing) {
                ScreenThumbnailView(snapshotID: snapshotID, height: 40)
                    .frame(width: 64)
                    .overlay {
                        RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                            .strokeBorder(.quaternary)
                    }
                if row.isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.scaled(.caption2))
                        .foregroundStyle(Brand.amber)
                        .padding(3)
                        .background(.regularMaterial, in: Circle())
                        .padding(2)
                }
            }
        } else {
            Image(systemName: row.icon)
                .font(.scaled(.title3))
                .foregroundStyle(selected ? .white : accent)
                .frame(width: 40, height: 40)
                .background(.quaternary.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        }
    }

    private func highlighted(_ snippet: String) -> Text {
        SnippetHighlighter.segments(snippet).reduce(Text("")) { text, segment in
            text + (segment.isMatch
                ? Text(segment.text).bold().foregroundStyle(selected ? Color.white : Color.primary)
                : Text(segment.text))
        }
    }
}

private struct QuickRecallApplicationIcon: View {
    let appName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = QuickRecallApplicationIconResolver.icon(for: appName) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
        .help(appName)
        .accessibilityHidden(true)
    }
}
