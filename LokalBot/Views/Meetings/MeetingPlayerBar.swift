import SwiftUI

struct MeetingPlayerBar: View {
    private static let selectionYellow = Color(red: 0.96, green: 0.76, blue: 0.14)

    @ObservedObject var player: MeetingPlayer
    @ObservedObject private var clock: MeetingPlaybackClock
    let folder: URL
    let playhead: MeetingDetailPresentation.PlayheadIndex
    let speakerName: (String) -> String
    let speakerColorIndex: (String) -> Int
    @Binding var selection: Meeting.ContentRange?
    var isBusy = false
    var hasTrimmedBoundaries = false
    let onShowInTranscript: (MeetingDetailPresentation.Caption) -> Void
    let onTrimSelection: (Meeting.ContentRange) -> Void
    let onRestoreFullRecording: () -> Void

    init(
        player: MeetingPlayer,
        folder: URL,
        playhead: MeetingDetailPresentation.PlayheadIndex,
        speakerName: @escaping (String) -> String,
        speakerColorIndex: @escaping (String) -> Int,
        selection: Binding<Meeting.ContentRange?>,
        isBusy: Bool = false,
        hasTrimmedBoundaries: Bool = false,
        onShowInTranscript: @escaping (MeetingDetailPresentation.Caption) -> Void,
        onTrimSelection: @escaping (Meeting.ContentRange) -> Void,
        onRestoreFullRecording: @escaping () -> Void
    ) {
        self.player = player
        self.clock = player.clock
        self.folder = folder
        self.playhead = playhead
        self.speakerName = speakerName
        self.speakerColorIndex = speakerColorIndex
        _selection = selection
        self.isBusy = isBusy
        self.hasTrimmedBoundaries = hasTrimmedBoundaries
        self.onShowInTranscript = onShowInTranscript
        self.onTrimSelection = onTrimSelection
        self.onRestoreFullRecording = onRestoreFullRecording
    }

    var body: some View {
        let caption = playhead.caption(at: clock.currentTime)
        let activeEnd = player.windowEnd > player.windowStart ? player.windowEnd : player.duration
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Brand.tealFill, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (Space)")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("meeting.playPause")
                VStack(alignment: .leading, spacing: 4) {
                    if let caption {
                        captionRow(caption)
                    }
                    WaveformView(
                        sources: player.waveformSources,
                        currentTime: clock.currentTime,
                        duration: player.duration,
                        windowStart: player.windowStart,
                        windowEnd: player.windowEnd > player.windowStart ? player.windowEnd : nil,
                        height: caption == nil ? 60 : 36,
                        selection: $selection,
                        isBusy: isBusy,
                        hasTrimmedBoundaries: hasTrimmedBoundaries,
                        onSeek: { player.seek(to: $0) },
                        onTrimSelection: onTrimSelection,
                        onRestoreFullRecording: onRestoreFullRecording)
                        .id(folder)
                }
                Text(verbatim: "\(Transcript.shortStamp(clock.currentTime)) / \(Transcript.shortStamp(activeEnd))")
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                    .fixedSize()
                    .accessibilityIdentifier("meeting.playbackTime")
                WorkspaceMenu(title: "\(player.speed.formatted())x", label: "Playback speed",
                              identifier: "meeting.playbackSpeed", items:
                    [0.75, 1, 1.25, 1.5, 1.75, 2.0].map { speed in
                        .init(title: "\(speed.formatted())x", selected: player.speed == Float(speed),
                              action: { player.speed = Float(speed) })
                    } + [.separator, .init(title: "Reset to 1x", action: { player.speed = 1 })])
            }
            if let selection {
                selectionActionBar(selection)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting playback")
        .accessibilityIdentifier("meeting.audioPlayer")
    }

    private func captionRow(_ caption: MeetingDetailPresentation.Caption) -> some View {
        Button {
            onShowInTranscript(caption)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(LBTokens.Palette.speaker(at: speakerColorIndex(caption.speakerKey)))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: speakerName(caption.speakerKey))
                    .font(AppFont.scaled(.callout).weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: caption.text)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentLayoutDirection(of: caption.text)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in transcript")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerName(caption.speakerKey)): \(caption.text)")
        .accessibilityIdentifier("meeting.player.caption")
    }

    private func selectionActionBar(_ range: Meeting.ContentRange) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Self.selectionYellow)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: "\(Transcript.stamp(range.start)) – \(Transcript.stamp(range.end))")
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.selection.range")
            Spacer(minLength: 8)
            Button("Trim to Selection") {
                onTrimSelection(range)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.tealFill)
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityIdentifier("meeting.selection.trim")
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear Selection")
            .accessibilityLabel("Clear Selection")
            .accessibilityIdentifier("meeting.selection.clear")
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.selection.bar")
    }
}
