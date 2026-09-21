import Foundation

/// Value-only result of file validation. The view publishes this after checking
/// task cancellation, so a pipeline update cannot install an older document.
struct MeetingDocumentSnapshot: Sendable {
    var notes: String?
    var transcript: Transcript?
    var partialNotes: MeetingNotesPartial?
    var partialProjection: MeetingOutcomeProjection?
    var summary: String?
    var speakerNameHints: [String]
    var transcriptDisplay: Transcript.DisplayIndex
    var speakerPresentation: MeetingSpeakerPresentation

    static func load(meeting: Meeting, root: URL, template: NoteTemplate, databaseURL: URL) -> Self {
        let folder = root.appendingPathComponent(meeting.relativePath)
        let transcript = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            .flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        let partial = transcript.flatMap { MeetingNotesPartial.load(in: folder, transcript: $0, template: template) }
        let projection = partial?.projection(for: meeting, in: folder)
        let summary: String?
        if let partial, let projection {
            summary = MeetingSummaryOutcomeSynchronizer.synchronize(
                partial.summary, outcomes: projection.correctedOutcomes, template: partial.template)
        } else {
            summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        }
        let fallback = meeting.startedAt.addingTimeInterval(max(meeting.recordedDuration ?? 60, 60))
        let end = meeting.endedAt.map { $0 > meeting.startedAt ? $0 : fallback } ?? fallback
        let text = ActivityStore(databaseURL: databaseURL, readOnly: true)
            .ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        return Self(notes: MeetingNotes.load(from: folder), transcript: transcript,
                    partialNotes: partial, partialProjection: projection, summary: summary,
                    speakerNameHints: SpeakerNameHintExtractor.hints(
                        calendarNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name), ocrText: text),
                    transcriptDisplay: Transcript.DisplayIndex(transcript: transcript),
                    speakerPresentation: MeetingSpeakerPresentation(transcript: transcript))
    }
}
