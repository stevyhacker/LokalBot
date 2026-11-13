import SwiftUI

/// One meeting's mention of an action in the Actions details pane: the
/// meeting and its day, then what was said. The meeting name opens the
/// meeting at the quote; the time plays the passage here.
struct ActionEvidencePassages: View {
    @EnvironmentObject private var app: AppState
    let reference: OutcomeActionReference
    @StateObject private var player = MeetingPlayer()
    @State private var playingCitationID: String?

    var body: some View {
        let citations = reference.action.citations
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    player.pause()
                    app.openMeeting(reference.meetingID, seek: citations.first?.start)
                } label: {
                    Text(verbatim: reference.meetingTitle)
                        .font(AppFont.scaled(.callout).weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.workspaceLink)
                .help("Show Passage in Meeting")
                .accessibilityIdentifier("actions.passage.meeting.\(reference.id)")
                Text(verbatim: ActionListWording.day(
                    reference.meetingStartedAt, locale: app.settings.appLanguage.locale,
                    localize: app.settings.appLanguage.catalog))
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let first = citations.first {
                    playButton(first).layoutPriority(1)
                }
            }
            if citations.isEmpty {
                Text("No supporting passage was stored.")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
            }
            ForEach(citations) { citation in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "“" + citation.excerpt + "”")
                        .font(.scaled(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if citation.id != citations.first?.id { playButton(citation) }
                }
            }
            if reference.textWasCorrected {
                // A correction never replaces what was extracted.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Original Wording")
                        .font(AppFont.scaled(.callout).weight(.semibold))
                    Text(verbatim: reference.action.displayText)
                        .font(AppFont.scaled(.callout))
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reference.meetingID) {
            guard let meeting = app.meetings.first(where: { $0.id == reference.meetingID }) else { return }
            await player.loadInBackground(folder: meeting.folderURL(in: app.storage), hasSystemTrack: meeting.hasSystemTrack)
        }
        .onDisappear { player.stop() }
    }

    private func playButton(_ citation: OutcomeSourceCitation) -> some View {
        let isPlaying = player.isPlaying && playingCitationID == citation.id
        let stamp = Transcript.shortStamp(citation.start)
        return Button {
            if isPlaying {
                player.pause()
            } else {
                playingCitationID = citation.id
                player.playExcerpt(from: citation.start, to: citation.end)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 7))
                    .accessibilityHidden(true)
                Text(verbatim: stamp)
            }
            .font(AppFont.scaled(.callout).monospacedDigit())
            .foregroundStyle(LBTokens.Palette.accentText)
            // A comfortable click target around the small timestamp.
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!player.isLoaded || citation.end <= citation.start)
        .help(citation.excerpt)
        .accessibilityLabel(isPlaying ? "Pause" : "Play from \(stamp)")
        .accessibilityIdentifier("actions.passage.play.\(citation.id)")
    }
}
