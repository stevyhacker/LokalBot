import SwiftUI

func meetingTranscriptEngineDescription(_ engine: String) -> String {
    "Transcribed with \(engine)"
}

/// Which model wrote the transcript, in the Transcript panel's footer. A
/// merged meeting's transcript has no single model to name.
struct MeetingTranscriptEngineLine: View {
    let text: String
    var searchQuery = ""
    var activeMatchIndex: Int?

    static func text(for transcript: Transcript) -> String? {
        guard !transcript.segments.isEmpty, !transcript.engine.isEmpty, transcript.engine != "merged" else {
            return nil
        }
        return meetingTranscriptEngineDescription(transcript.engine)
    }

    var body: some View {
        SearchHighlightedText(text, query: searchQuery, activeMatchIndex: activeMatchIndex)
            .id(MeetingPageSearchMatch.Location.transcriptEngine)
            .textSelection(.enabled)
            .sectionPanelFooterText()
            .accessibilityIdentifier("transcript.model")
    }
}

/// The transcript as speaker turns on its panel's surface: one speaker line
/// per turn, then that turn's lines with a quiet time before each. The line
/// being played is highlighted, and any time plays from there.
struct MeetingTranscriptList: View {
    @Environment(\.appTextScale) private var textScale
    let transcript: Transcript?
    let display: Transcript.DisplayIndex
    @ObservedObject var player: MeetingPlayer
    let speakerPresentation: MeetingSpeakerPresentation
    let unnamedSpeakers: Set<String>
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let evidenceSegment: Int?
    let onRenameSpeaker: (String) -> Void

    /// Wide enough for "1:02:09" at the trailing edge of the time column.
    static let timeColumnWidth: CGFloat = 52
    static let columnGap: CGFloat = 12
    /// A line's highlight reaches this far past its text on each side.
    static let lineInset: CGFloat = 6

    var body: some View {
        if let transcript, !display.segments.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(display.segments) { row in
                    MeetingTranscriptLine(
                        row: row,
                        speakerName: speakerPresentation.speaker(row.segment.speaker, in: transcript),
                        speakerColorIndex: speakerPresentation.colorIndex(for: row.segment.speaker),
                        speakerNeedsName: unnamedSpeakers.contains(row.speakerKey),
                        clock: player.clock,
                        isPlaying: player.isPlaying,
                        isEvidence: evidenceSegment == row.id,
                        searchQuery: searchQuery,
                        activeMatch: activeMatch,
                        onPlay: { player.play(at: row.segment.start) },
                        onRenameSpeaker: { onRenameSpeaker(row.segment.speaker) })
                }
            }
            // What was said keeps a reading measure beside the time column.
            .frame(maxWidth: MeetingDetailLayout.proseWidth(textScale: textScale)
                   + Self.timeColumnWidth + Self.columnGap + 2 * Self.lineInset, alignment: .leading)
            .padding(.horizontal, SectionPanelMetric.inset - Self.lineInset)
            .padding(.top, 2)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyWorkspaceRow(
                text: "No transcript yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .emptyState(.transcript)))
            .id(MeetingPageSearchMatch.Location.emptyState(.transcript))
            .padding(.horizontal, SectionPanelMetric.inset)
        }
    }

    private func activeOccurrence(at location: MeetingPageSearchMatch.Location) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

private struct MeetingTranscriptLine: View {
    let row: Transcript.DisplaySegment
    let speakerName: String
    let speakerColorIndex: Int
    let speakerNeedsName: Bool
    let clock: MeetingPlaybackClock
    let isPlaying: Bool
    let isEvidence: Bool
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onPlay: () -> Void
    let onRenameSpeaker: () -> Void
    @State private var containsPlayhead = false

    private var isCurrent: Bool { isEvidence || (isPlaying && containsPlayhead) }

    var body: some View {
        let index = row.id
        let segment = row.segment
        let stamp = Transcript.shortStamp(segment.start)
        VStack(alignment: .leading, spacing: 1) {
            if row.beginsSpeakerTurn {
                HStack(spacing: 6) {
                    Circle()
                        .fill(LBTokens.Palette.speaker(at: speakerColorIndex))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    TranscriptSpeakerButton(
                        title: speakerName,
                        query: searchQuery,
                        activeMatchIndex: activeOccurrence(at: .transcript(segmentIndex: index, field: .speaker)),
                        identifier: "transcript.segment.\(index).speaker",
                        isUnnamed: speakerNeedsName,
                        action: onRenameSpeaker)
                }
                .id(MeetingPageSearchMatch.Location.transcript(segmentIndex: index, field: .speaker))
                .frame(height: 20, alignment: .leading)
                .padding(.leading, MeetingTranscriptList.timeColumnWidth + MeetingTranscriptList.columnGap
                         + MeetingTranscriptList.lineInset)
                .padding(.top, 12)
            }
            HStack(alignment: .firstTextBaseline, spacing: MeetingTranscriptList.columnGap) {
                Button(action: onPlay) {
                    HStack(spacing: 3) {
                        if isCurrent {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                                .accessibilityHidden(true)
                        }
                        SearchHighlightedText(
                            stamp,
                            query: searchQuery,
                            activeMatchIndex: activeOccurrence(at: .transcript(segmentIndex: index, field: .timestamp)))
                            .id(MeetingPageSearchMatch.Location.transcript(segmentIndex: index, field: .timestamp))
                    }
                    .font(isCurrent ? AppFont.scaled(.callout).monospacedDigit().weight(.semibold)
                          : AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(LBTokens.Palette.accentText)
                                     : AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting)))
                    .lineLimit(1)
                    .frame(width: MeetingTranscriptList.timeColumnWidth, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play from \(stamp)")
                .accessibilityLabel("Play from \(stamp)")
                .accessibilityIdentifier("transcript.segment.\(index).play")
                SearchHighlightedText(
                    row.text,
                    query: searchQuery,
                    activeMatchIndex: activeOccurrence(at: .transcript(segmentIndex: index, field: .text)))
                    .font(LBTokens.Typography.reading)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentLayoutDirection(of: row.text)
                    .textSelection(.enabled)
                    .help("Select text and press Command-C to copy")
                    .accessibilityIdentifier("transcript.segment.\(index).text")
            }
            .padding(.vertical, 3)
            .padding(.horizontal, MeetingTranscriptList.lineInset)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Brand.teal.opacity(0.14) : Color.clear)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .id(MeetingPageSearchMatch.Location.transcript(segmentIndex: index, field: .text))
        }
        .onReceive(clock.$currentTime
            .map { $0 >= segment.start && $0 < max(segment.end, segment.start + 0.5) }
            .removeDuplicates()) {
            containsPlayhead = $0
        }
    }

    private func activeOccurrence(at location: MeetingPageSearchMatch.Location) -> Int? {
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}
