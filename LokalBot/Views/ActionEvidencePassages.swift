import SwiftUI

struct ActionEvidencePassages: View {
    @EnvironmentObject private var app: AppState
    let reference: OutcomeActionReference
    @StateObject private var player = MeetingPlayer()
    @State private var playingCitationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(reference.action.citations) { citation in
                VStack(alignment: .leading, spacing: 10) {
                    Text("“" + citation.excerpt + "”").textSelection(.enabled)
                    HStack {
                        Button {
                            if player.isPlaying && playingCitationID == citation.id {
                                player.pause()
                            } else {
                                playingCitationID = citation.id
                                player.playExcerpt(from: citation.start, to: citation.end)
                            }
                        } label: {
                            Label(player.isPlaying && playingCitationID == citation.id ? "Pause" : "Play Passage",
                                  systemImage: player.isPlaying && playingCitationID == citation.id ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!player.isLoaded || citation.end <= citation.start)
                        .accessibilityIdentifier("actions.passage.play.\(citation.id)")
                        Text(Transcript.stamp(citation.start)).font(.scaled(.callout).monospacedDigit())
                    }
                    Button("Show Passage in Meeting") {
                        player.pause()
                        app.openMeeting(reference.meetingID, seek: citation.start)
                    }
                    .buttonStyle(.workspaceLink)
                }
                .padding(12).lbGroupedSurface()
            }
        }
        .task(id: reference.meetingID) {
            guard let meeting = app.meetings.first(where: { $0.id == reference.meetingID }) else { return }
            await player.loadInBackground(folder: meeting.folderURL(in: app.storage), hasSystemTrack: meeting.hasSystemTrack)
        }
        .onDisappear { player.stop() }
    }
}
