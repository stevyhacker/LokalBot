import SwiftUI

/// The meeting's player: one slim bar under the header on every tab. It shows
/// who is speaking and what is being said at the playhead, so a time played
/// from the summary can be followed without leaving the summary.
struct MeetingPlayerBar: View {
    @ObservedObject var player: MeetingPlayer
    @ObservedObject private var clock: MeetingPlaybackClock
    let folder: URL
    let playhead: MeetingDetailPresentation.PlayheadIndex
    let speakerName: (String) -> String
    let speakerColorIndex: (String) -> Int
    /// The transcript tab already shows the line, so the link is left out there.
    var showsTranscriptLink = true
    let onShowInTranscript: (MeetingDetailPresentation.Caption) -> Void

    init(player: MeetingPlayer, folder: URL, playhead: MeetingDetailPresentation.PlayheadIndex,
         speakerName: @escaping (String) -> String, speakerColorIndex: @escaping (String) -> Int,
         showsTranscriptLink: Bool = true,
         onShowInTranscript: @escaping (MeetingDetailPresentation.Caption) -> Void) {
        self.player = player
        self.clock = player.clock
        self.folder = folder
        self.playhead = playhead
        self.speakerName = speakerName
        self.speakerColorIndex = speakerColorIndex
        self.showsTranscriptLink = showsTranscriptLink
        self.onShowInTranscript = onShowInTranscript
    }

    var body: some View {
        let caption = playhead.caption(at: clock.currentTime)
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
                    height: caption == nil ? 40 : 24,
                    onSeek: { player.seek(to: $0) })
                    .id(folder)
            }
            Text(verbatim: "\(Transcript.shortStamp(clock.currentTime)) / \(Transcript.shortStamp(player.duration))")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .lbGroupedSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting playback")
        .accessibilityIdentifier("meeting.audioPlayer")
    }

    private func captionRow(_ caption: MeetingDetailPresentation.Caption) -> some View {
        HStack(spacing: 6) {
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
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meeting.player.caption")
            Spacer(minLength: 6)
            if showsTranscriptLink {
                Button("Show in transcript") { onShowInTranscript(caption) }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .fixedSize()
                    .accessibilityIdentifier("meeting.player.showInTranscript")
            }
        }
    }
}
