import SwiftUI

func meetingTranscriptEngineDescription(_ engine: String) -> String {
    "Transcribed with \(engine)"
}

/// The transcript as speaker turns: one speaker line per turn, then that
/// turn's lines with a quiet time before each. The line being played is
/// highlighted, and any time plays from there.
struct MeetingTranscriptList: View {
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

    var body: some View {
        if let transcript, !display.segments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !transcript.engine.isEmpty && transcript.engine != "merged" {
                    SearchHighlightedText(
                        meetingTranscriptEngineDescription(transcript.engine),
                        query: searchQuery,
                        activeMatchIndex: activeOccurrence(at: .transcriptEngine))
                        .id(MeetingPageSearchMatch.Location.transcriptEngine)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("transcript.model")
                }

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
            }
            .workspaceReadingWidth()
        } else {
            EmptyWorkspaceRow(
                text: "No transcript yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeOccurrence(at: .emptyState(.transcript)))
            .id(MeetingPageSearchMatch.Location.emptyState(.transcript))
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
                .padding(.leading, MeetingTranscriptList.timeColumnWidth + MeetingTranscriptList.columnGap + 6)
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
            .padding(.horizontal, 6)
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
