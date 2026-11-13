import Foundation

extension DailyEvidenceSnapshot {
    /// Shared by generation and validation. Summary-only snapshot callers must
    /// load detailed activity before using this projection as a freshness proof.
    func digestEvidence(calendar: Calendar = .current) -> DayDigestEvidence {
        DayDigestEvidence.build(
            day: day, blocks: activityBlocks, screenContexts: screenContexts,
            meetings: meetings.compactMap { evidence in
                let meeting = evidence.meeting
                guard let endedAt = meeting.endedAt else { return nil }
                return DayDigestMeetingEvidence(
                    id: meeting.id, title: meeting.title, app: meeting.appName,
                    startedAt: meeting.startedAt, endedAt: endedAt,
                    sourceSummary: evidence.summary,
                    outcomes: Self.renderDigestOutcomes(evidence),
                    artifactModifiedAt: evidence.artifactModifiedAt)
            }, codingAgentBursts: codingAgentBursts, calendar: calendar)
    }

    private static func renderDigestOutcomes(_ evidence: DailyEvidenceMeeting) -> String {
        var lines: [String] = []
        if !evidence.actionReferences.isEmpty {
            lines.append("Action items:")
            for reference in evidence.actionReferences {
                var details: [String] = []
                if let owner = reference.owner, !owner.isEmpty { details.append("owner: \(owner)") }
                if let due = reference.due, !due.isEmpty { details.append("due: \(due)") }
                if reference.status == .deferred { details.append("status: deferred") }
                let marker = reference.status == .done ? "x" : " "
                lines.append("- [\(marker)] " + reference.text
                    + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"))
            }
        }
        if !evidence.outcomes.decisions.isEmpty {
            lines.append("Decisions:")
            lines += evidence.outcomes.decisions.map { "- \($0)" }
        }
        if !evidence.outcomes.openQuestions.isEmpty {
            lines.append("Open questions:")
            lines += evidence.outcomes.openQuestions.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

extension DayDigestEvidence {
    /// Content consumed by the digest, excluding filesystem timestamps and
    /// optional daily-summary fields that the digest does not read.
    var contentSignature: String {
        var fields = ["digest-evidence-v1", String(day.timeIntervalSince1970),
                      String(interval.start.timeIntervalSince1970), String(interval.end.timeIntervalSince1970)]
        func appendContext(_ context: DayScreenContext) {
            fields += ["context", String(context.snapshotID), String(context.capturedAt.timeIntervalSince1970),
                       context.app, context.windowTitle, context.text]
        }
        for activity in activities {
            fields += ["activity", String(activity.id), String(activity.start.timeIntervalSince1970),
                       String(activity.end.timeIntervalSince1970), activity.app, activity.title]
            activity.contexts.forEach(appendContext)
        }
        standaloneContexts.forEach(appendContext)
        fields += meetingFields
        // Appended only when present: journals of days without agent work
        // keep matching the signature they were generated with.
        for burst in codingAgentBursts {
            fields += ["agent"] + burst.signatureFields
        }
        return ContentFingerprint.fields(fields)
    }

    var meetingSignature: String { ContentFingerprint.fields(meetingFields) }

    private var meetingFields: [String] {
        meetings.flatMap { meeting in
            ["meeting", meeting.id.uuidString, meeting.title, meeting.app,
             String(meeting.startedAt.timeIntervalSince1970), String(meeting.endedAt.timeIntervalSince1970),
             meeting.sourceSummary, meeting.outcomes]
        }
    }
}
