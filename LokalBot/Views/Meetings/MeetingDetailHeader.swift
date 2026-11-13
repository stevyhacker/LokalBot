import SwiftUI

/// One searchable fact on the meeting's date line.
struct MeetingDetailMetadataItem {
    let field: MeetingPageSearchMatch.MeetingMetadataField
    let text: String
    /// A capture limitation people should notice, not neutral metadata.
    var warning: String?

    /// When, how long, where, and a mic-only recording's limitation.
    static func items(for meeting: Meeting) -> [Self] {
        var items: [Self] = [
            .init(field: .date, text: MeetingDetailPresentation.dateText(meeting.startedAt)),
            .init(field: .duration, text: meeting.displayDuration),
        ]
        if !meeting.isMergedMeeting { items.append(.init(field: .app, text: meeting.appName)) }
        // An imported file's audio came from neither this Mac's microphone
        // nor its system audio, so it carries no capture limitation.
        if !meeting.hasSystemTrack, !meeting.isImported {
            items.append(.init(
                field: .audioSource, text: "Mic only",
                warning: "Only your microphone was recorded. Other participants are captured only if your mic picked them up."))
        }
        return items
    }
}

/// The meeting's one title: name, a date line, and who spoke. Unnamed voices
/// are named from here.
struct MeetingDetailHeader: View {
    let meeting: Meeting
    let speakers: [MeetingDetailPresentation.Speaker]
    var searchQuery = ""
    var activeMatch: MeetingPageSearchMatch?
    var canNameSpeakers = true
    let onSpeaker: (MeetingDetailPresentation.Speaker) -> Void
    let onNameSpeakers: () -> Void

    private var unnamedCount: Int { speakers.filter(\.needsName).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SearchHighlightedText(
                meeting.displayTitle,
                query: searchQuery,
                activeMatchIndex: activeOccurrence(at: .title))
                .id(MeetingPageSearchMatch.Location.title)
                .font(AppFont.scaledSystem(size: 20, weight: .bold))
                .lineLimit(2)
                .accessibilityIdentifier("detail.title")
            dateLine
            if !speakers.isEmpty {
                MeetingWrappingRow(spacing: 14, lineSpacing: 5) {
                    ForEach(speakers) { speaker in
                        speakerButton(speaker)
                    }
                    if unnamedCount > 0 {
                        Button(action: onNameSpeakers) {
                            if unnamedCount == 1 {
                                Text("Name speaker…")
                            } else {
                                Text("Name \(unnamedCount) speakers…")
                            }
                        }
                        .buttonStyle(MeetingAttentionChipStyle())
                        .disabled(!canNameSpeakers)
                        .accessibilityIdentifier("meeting.reviewSpeakers")
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Speaker names")
                .accessibilityIdentifier("meeting.speakers")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateLine: some View {
        let items = MeetingDetailMetadataItem.items(for: meeting)
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.field) { index, item in
                if index > 0 {
                    Text(verbatim: " · ").accessibilityHidden(true)
                }
                SearchHighlightedText(
                    item.text, query: searchQuery,
                    activeMatchIndex: activeOccurrence(at: .meetingMetadata(item.field)))
                    .id(MeetingPageSearchMatch.Location.meetingMetadata(item.field))
                    .foregroundStyle(Color(nsColor: item.warning == nil
                                           ? WorkspaceTextColor.supporting : WorkspaceTextColor.warning))
                    .help(item.warning ?? "")
                    .accessibilityHint(item.warning ?? "")
            }
        }
        .font(AppFont.scaled(.callout).monospacedDigit())
        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
        .lineLimit(1)
    }

    private func speakerButton(_ speaker: MeetingDetailPresentation.Speaker) -> some View {
        Button { onSpeaker(speaker) } label: {
            HStack(spacing: 6) {
                Circle().fill(LBTokens.Palette.speaker(at: speaker.colorIndex))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: speaker.name)
                    .underline(speaker.needsName, pattern: .dot)
                    .lineLimit(1)
            }
            .font(AppFont.scaled(.callout))
            .foregroundStyle(speaker.needsName ? AnyShapeStyle(.primary)
                             : AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(speaker.needsName ? "Name this speaker" : "Rename speaker: \(speaker.name)")
        .accessibilityLabel(speaker.name)
        .accessibilityHint(speaker.needsName ? "Name this speaker" : "")
        .accessibilityIdentifier("meeting.speaker.\(speaker.id)")
    }

    private func activeOccurrence(at location: MeetingPageSearchMatch.Location) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

/// The small amber control that asks for a missing name or owner.
struct MeetingAttentionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MeetingAttentionChip(configuration: configuration)
    }
}

private struct MeetingAttentionChip: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(AppFont.scaled(.callout).weight(.medium))
            .foregroundStyle(LBTokens.Palette.attentionText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(LBTokens.Palette.attention.opacity(configuration.isPressed ? 0.22 : 0.12), in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? LBTokens.Palette.attentionText
                                   : LBTokens.Palette.attention.opacity(0.4))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
    }
}

/// Lays children out in reading order and wraps to further lines when the row
/// is too narrow, as a row of speaker names or name choices does.
struct MeetingWrappingRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [], current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
