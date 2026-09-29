import SwiftUI

struct MeetingSpeakerReviewSection: View {
    let speakers: [MeetingSpeakerReviewItem]
    let presentation: MeetingSpeakerPresentation
    let canPlay: Bool
    let onPlay: (Transcript.Segment) -> Void
    let onReview: (String) -> Void
    @State private var showsAllSpeakers = false

    private var visibleSpeakers: [MeetingSpeakerReviewItem] {
        showsAllSpeakers ? speakers : Array(speakers.prefix(5))
    }

    var body: some View {
        WorkspaceSection(title: "Review Speakers", icon: "person.2") {
            Text("Listen to a short excerpt, then confirm a name or whether the speaker is you. Leave uncertain voices unresolved.")
                .workspaceTextRole(.supporting)
            if speakers.isEmpty {
                Text("No transcript speakers are available yet.").workspaceTextRole(.supporting)
            }
            ForEach(visibleSpeakers) { speaker in
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            speakerLabel(speaker)
                            Spacer()
                            controls(speaker)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            speakerLabel(speaker)
                            controls(speaker)
                        }
                    }
                    if let sample = speaker.sample {
                        Text("“" + sample.text + "”").font(.scaled(.body)).foregroundStyle(.secondary)
                            .lineLimit(3).textSelection(.enabled)
                    } else {
                        Text("No clear voice excerpt available. Review the transcript before assigning a name.")
                            .workspaceTextRole(.supporting)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(SpeakerDisplayName.label(speaker.name))
                if speaker.id != visibleSpeakers.last?.id { Divider() }
            }
            if speakers.count > 5 {
                Button(showsAllSpeakers ? "Show Fewer Speakers" : "Show \(speakers.count - 5) More Speakers") {
                    showsAllSpeakers.toggle()
                }
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("meeting.review.moreSpeakers")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review speakers")
        .accessibilityIdentifier("meeting.review.speakers")
        .onChange(of: speakers.map(\.id)) { showsAllSpeakers = false }
    }

    private func speakerLabel(_ speaker: MeetingSpeakerReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(LBTokens.Palette.speaker(at: presentation.colorIndex(for: speaker.id)))
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                Text(SpeakerDisplayName.label(speaker.name)).font(.scaled(.body).weight(.semibold))
            }
            Text(speaker.status).workspaceTextRole(.supporting)
            if speaker.actionCount > 0 {
                Text("Linked to \(speaker.actionCount) action\(speaker.actionCount == 1 ? "" : "s")")
                    .workspaceTextRole(.supporting)
            }
        }
    }

    private func controls(_ speaker: MeetingSpeakerReviewItem) -> some View {
        HStack(spacing: 8) {
            if let sample = speaker.sample {
                Button { onPlay(sample) } label: {
                    Label("Listen", systemImage: "play.fill")
                }
                .disabled(!canPlay)
                .accessibilityLabel("Listen to an excerpt from \(SpeakerDisplayName.label(speaker.name))")
                .accessibilityIdentifier("meeting.review.listen.\(speaker.id)")
            }
            Button(speaker.isNamed ? "Review Name…" : "Name Speaker…") { onReview(speaker.id) }
                .accessibilityLabel("Review speaker \(SpeakerDisplayName.label(speaker.name))")
                .accessibilityIdentifier("meeting.review.speaker.\(speaker.id)")
        }
        .fixedSize()
    }
}

struct MeetingNotesRefreshSection: View {
    let needsRefresh: Bool
    let hasNotes: Bool
    let isProcessing: Bool
    let canRefresh: Bool
    let settings: AppSettings
    let onRefresh: () -> Void

    var body: some View {
        WorkspaceSection(title: "Refresh Notes", icon: "arrow.trianglehead.2.clockwise") {
            Label(needsRefresh ? "Notes need a refresh" : hasNotes ? "Notes use the latest saved speaker details" : "No derived notes yet",
                  systemImage: needsRefresh ? "exclamationmark.triangle" : hasNotes ? "checkmark.circle" : "doc.text")
                .font(Font.scaled(.body).weight(.semibold))
                .accessibilityIdentifier("meeting.review.freshness")
            Text("Refresh the summary and extracted owners after reviewing speakers. Saved action corrections stay separate; unmatched edits remain available for review.")
                .workspaceTextRole(.supporting)
            InferenceDisclosure(
                settings: settings,
                localText: "Refreshing processes the transcript on this Mac.",
                remoteText: "Refreshing sends the transcript and confirmed names to your approved model server.")
            Button(isProcessing ? "Processing…" : "Refresh Notes and Owners", action: onRefresh)
                .primaryActionButton()
                .disabled(isProcessing || !canRefresh)
                .accessibilityIdentifier("meeting.review.refresh")
        }
    }
}
