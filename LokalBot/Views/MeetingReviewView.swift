import SwiftUI

struct MeetingSpeakerReviewSection: View {
    let speakers: [MeetingSpeakerReviewItem]
    let canPlay: Bool
    let onPlay: (Transcript.Segment) -> Void
    let onReview: (String) -> Void

    var body: some View {
        WorkspaceSection(title: "1. Review speakers", icon: "person.2") {
            Text("Listen to a short excerpt, then confirm a name or whether the speaker is you. Leave uncertain voices unresolved.")
                .workspaceTextRole(.supporting)
            if speakers.isEmpty {
                Text("No transcript speakers are available yet.").workspaceTextRole(.supporting)
            }
            ForEach(speakers) { speaker in
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
                        Text(sample.text).font(WorkspaceTypography.body)
                            .lineLimit(3).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(speaker.name)
                if speaker.id != speakers.last?.id { Divider() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review speakers")
        .accessibilityIdentifier("meeting.review.speakers")
    }

    private func speakerLabel(_ speaker: MeetingSpeakerReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker.name).font(WorkspaceTypography.bodyEmphasis)
            Text(speaker.status).workspaceTextRole(.supporting)
        }
    }

    private func controls(_ speaker: MeetingSpeakerReviewItem) -> some View {
        HStack(spacing: 8) {
            if let sample = speaker.sample {
                Button { onPlay(sample) } label: {
                    Label("Listen", systemImage: "play.fill")
                }
                .disabled(!canPlay)
                .accessibilityLabel("Listen to an excerpt from \(speaker.name)")
                .accessibilityIdentifier("meeting.review.listen.\(speaker.id)")
            }
            Button(speaker.isNamed || !speaker.canConfirm ? "Review name…" : "Confirm speaker…") { onReview(speaker.id) }
                .accessibilityLabel("Review speaker \(speaker.name)")
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
        WorkspaceSection(title: "3. Refresh derived notes", icon: "arrow.trianglehead.2.clockwise") {
            Label(needsRefresh ? "Notes need a refresh" : hasNotes ? "Notes use the latest saved speaker details" : "No derived notes yet",
                  systemImage: needsRefresh ? "exclamationmark.triangle" : hasNotes ? "checkmark.circle" : "doc.text")
                .font(WorkspaceTypography.bodyEmphasis)
                .accessibilityIdentifier("meeting.review.freshness")
            Text("Refresh the summary and extracted owners after reviewing speakers. Saved action corrections stay separate; unmatched edits remain available for review.")
                .workspaceTextRole(.supporting)
            InferenceDisclosure(
                settings: settings,
                localText: "Refreshing processes the transcript on this Mac.",
                remoteText: "Refreshing sends the transcript and confirmed names to your approved model server.")
            Button(isProcessing ? "Processing…" : "Refresh notes and owners", action: onRefresh)
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || !canRefresh)
                .accessibilityIdentifier("meeting.review.refresh")
        }
    }
}
