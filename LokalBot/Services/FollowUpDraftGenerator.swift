import Foundation

/// Writes a follow-up email draft from one meeting's own outcomes with the
/// on-device Think model. It is explicit (the user asks for it), grounded
/// (only the meeting's recap, decisions, corrected actions, and open
/// questions), and never sends anything.
enum FollowUpDraftGenerator {
    struct Evidence: Equatable, Sendable {
        struct Action: Equatable, Sendable {
            let text: String
            let owner: String?
            let due: String?
        }

        let meetingTitle: String
        let meetingDate: Date
        let recap: String?
        let decisions: [String]
        let actions: [Action]
        let openQuestions: [String]
        /// Calendar display names only, for the greeting.
        let participantNames: [String]

        var isEmpty: Bool {
            (recap ?? "").isEmpty && decisions.isEmpty && actions.isEmpty && openQuestions.isEmpty
        }
    }

    enum GenerationError: LocalizedError {
        case emptyEvidence
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .emptyEvidence: "This meeting has no recap or outcomes to follow up on yet."
            case .unreadableResponse: "The local model returned an unreadable draft. The outline is unchanged."
            }
        }
    }

    static func evidence(for projection: MeetingOutcomeProjection, summary: String?) -> Evidence {
        let meeting = projection.meeting
        let actions = projection.actionReferences
            .filter { $0.status != .done }
            .map { reference in
                Evidence.Action(
                    text: reference.text,
                    owner: reference.isForUser ? "Me" : reference.owner,
                    due: reference.due.map { due in
                        reference.resolvedDueDate.map {
                            $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        } ?? due
                    })
            }
        return Evidence(
            meetingTitle: meeting.displayTitle,
            meetingDate: meeting.startedAt,
            recap: summary.flatMap { SummaryPresentation.recap(SummaryPresentation.meetingBody($0, meeting: meeting)) },
            decisions: projection.outcomes.decisionRecords.map(\.text),
            actions: actions,
            openQuestions: projection.outcomes.openQuestions,
            participantNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name))
    }

    static func promptContext(_ evidence: Evidence) -> String {
        var sections = [
            "Meeting: \(evidence.meetingTitle) on "
                + evidence.meetingDate.formatted(date: .long, time: .omitted),
        ]
        if !evidence.participantNames.isEmpty {
            sections.append("Invited participants: " + evidence.participantNames.prefix(12).joined(separator: ", "))
        }
        if let recap = evidence.recap, !recap.isEmpty { sections.append("Recap:\n" + recap) }
        if !evidence.decisions.isEmpty {
            sections.append("Decisions:\n" + evidence.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !evidence.actions.isEmpty {
            sections.append("Open actions:\n" + evidence.actions.map { action in
                var metadata: [String] = []
                if let owner = action.owner { metadata.append(owner == "Me" ? "owner: the sender" : "owner: \(owner)") }
                if let due = action.due { metadata.append("due: \(due)") }
                return "- \(action.text)" + (metadata.isEmpty ? "" : " (\(metadata.joined(separator: ", ")))")
            }.joined(separator: "\n"))
        }
        if !evidence.openQuestions.isEmpty {
            sections.append("Open questions:\n" + evidence.openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        return PromptContextSanitizer.sanitize(sections.joined(separator: "\n\n"), maxCharacters: 8_000)
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": ["subject": ["type": "string"], "body": ["type": "string"]],
        "required": ["subject", "body"],
        "additionalProperties": false,
    ]

    private struct Draft: Decodable {
        let subject: String
        let body: String
    }

    static let system = """
        You write a short follow-up email the sender will review and send themselves.
        Use only the supplied meeting evidence. Do not invent decisions, owners, dates, numbers, or commitments.
        Greet invited participants by first name when there are only a few; otherwise use a general greeting.
        Thank them briefly, summarize what was decided, list next steps with their owners and due dates, and
        mention open questions. Write "I" for actions owned by the sender. Use plain text with simple "- " bullets.
        Do not include a signature name, email addresses, or links. Return only the requested JSON object.
        """

    static func generate(evidence: Evidence, engine: TextEngine) async throws -> (subject: String, body: String) {
        guard !evidence.isEmpty else { throw GenerationError.emptyEvidence }
        let output = try await engine.generate(
            system: system,
            prompt: "Draft the follow-up email for \(evidence.meetingTitle).",
            context: [promptContext(evidence)],
            schema: schema,
            options: TextGenerationOptions(maxTokens: 900, reasoningBudgetTokens: 256, temperature: 0.3))
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let draft = try? JSONDecoder().decode(Draft.self, from: Data(json.utf8)) else {
            throw GenerationError.unreadableResponse
        }
        let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ScreenContextPrivacy.redact(draft.body).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw GenerationError.unreadableResponse }
        return (subject.isEmpty ? "Follow-up: \(evidence.meetingTitle)" : subject, body)
    }
}
