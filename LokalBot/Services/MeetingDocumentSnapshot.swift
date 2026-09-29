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
    var attributionNeedsRefresh = false
    var captureNeedsAttention = false
    var recoveryNeedsAttention = false
    var screenContext = MeetingScreenContext()

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
        let screenStore = ActivityStore(databaseURL: databaseURL, readOnly: true)
        let text = screenStore.ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        let screenContext = MeetingScreenContext.build(
            meeting: meeting,
            screenshots: screenStore.screenshots(
                forMeeting: meeting.id,
                from: meeting.startedAt.addingTimeInterval(-5),
                to: end.addingTimeInterval(5)))
        return Self(notes: MeetingNotes.load(from: folder), transcript: transcript,
                    partialNotes: partial, partialProjection: projection, summary: summary,
                    speakerNameHints: SpeakerNameHintExtractor.hints(
                        calendarNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name), ocrText: text),
                    transcriptDisplay: Transcript.DisplayIndex(transcript: transcript),
                    speakerPresentation: MeetingSpeakerPresentation(transcript: transcript),
                    attributionNeedsRefresh: MeetingAttributionArtifacts.needsRefresh(in: folder),
                    captureNeedsAttention: RecordingHealthReport.load(in: folder)?.hasCaptureIssues == true,
                    recoveryNeedsAttention: MeetingAudioFiles.recoveryNeedsAttention(in: folder),
                    screenContext: screenContext)
    }
}
