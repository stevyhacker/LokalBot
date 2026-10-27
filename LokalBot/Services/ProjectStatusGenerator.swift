import CryptoKit
import Foundation

/// Writes a tracked project's "Where it stands" note with the Think model
/// from the lines of its recent meetings that name it, the decisions and
/// actions that name it, and its overnight review notes. Grounded (only that
/// evidence), cited (each point names its meeting), and explicit about
/// staleness: the evidence hash shows when newer evidence exists.
enum ProjectStatusGenerator {
    static let maximumMeetings = 10
    static let maximumPoints = 5
    static let maximumQuestions = 3
    static let maximumContextCharacters = 9_000

    struct Evidence: Equatable, Sendable {
        struct MeetingEvidence: Equatable, Sendable {
            let id: UUID
            /// "M1" is the newest meeting.
            let label: String
            let title: String
            let date: Date
            let lines: [String]
            let decisions: [String]
            let actions: [String]
        }

        let projectName: String
        let otherNames: [String]
        let meetings: [MeetingEvidence]
        /// Open actions from meetings older than the ones listed.
        let otherActions: [String]
        let reviewNotes: [String]

        var isEmpty: Bool { meetings.isEmpty && reviewNotes.isEmpty }
        var meetingIDs: [UUID] { meetings.map(\.id) }
    }

    enum GenerationError: LocalizedError {
        case emptyEvidence
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .emptyEvidence:
                "No meetings or overnight review notes name this project yet."
            case .unreadableResponse:
                "The model returned an unreadable summary. The previous one is unchanged."
            }
        }
    }

    static func evidence(for project: ProjectProfile) -> Evidence {
        var decisionsByMeeting: [UUID: [String]] = [:]
        for decision in project.decisions {
            decisionsByMeeting[decision.meetingID, default: []].append(decision.text)
        }
        var actionsByMeeting: [UUID: [String]] = [:]
        var threads: [ActionThread] = project.myActions
        threads.append(contentsOf: project.othersActions)
        threads.append(contentsOf: project.olderOthersActions)
        for thread in threads {
            actionsByMeeting[thread.latestReference.meetingID, default: []].append(actionLine(thread))
        }
        var meetings: [Evidence.MeetingEvidence] = []
        var listed: Set<UUID> = []
        for (index, meeting) in project.meetings.prefix(maximumMeetings).enumerated() {
            listed.insert(meeting.id)
            meetings.append(Evidence.MeetingEvidence(
                id: meeting.id, label: "M\(index + 1)", title: meeting.title, date: meeting.startedAt,
                lines: meeting.mentions.map(\.text),
                decisions: decisionsByMeeting[meeting.id] ?? [],
                actions: actionsByMeeting[meeting.id] ?? []))
        }
        var otherActions: [String] = []
        for (meetingID, actions) in actionsByMeeting where !listed.contains(meetingID) {
            otherActions.append(contentsOf: actions)
        }
        let notes: [String] = project.reviewNotes.map { note in
            "\(note.name) (last active \(note.lastActiveDay)): \(note.status)"
        }
        return Evidence(projectName: project.name, otherNames: project.otherNames,
                        meetings: meetings, otherActions: otherActions.sorted(), reviewNotes: notes)
    }

    private static func actionLine(_ thread: ActionThread) -> String {
        var details: [String] = []
        if thread.isForUser {
            details.append("owner: the user")
        } else if let owner = thread.owner {
            details.append("owner: " + SpeakerDisplayName.label(owner))
        }
        if let due = thread.due { details.append("due: " + due) }
        details.append(thread.status == .deferred ? "deferred" : "open")
        return thread.text + " (" + details.joined(separator: ", ") + ")"
    }

    /// The evidence as prompt text. It carries no date of its own, so its
    /// hash changes only when the evidence does.
    static func promptContext(_ evidence: Evidence) -> String {
        var sections: [String] = []
        var header: String = "Project: " + evidence.projectName
        if !evidence.otherNames.isEmpty {
            header += " (also called " + evidence.otherNames.joined(separator: ", ") + ")"
        }
        sections.append(header)
        for meeting in evidence.meetings {
            var lines: [String] = [
                "\(meeting.label) · \(meeting.title) · "
                    + meeting.date.formatted(.dateTime.day().month(.abbreviated).year()),
            ]
            for line in meeting.lines { lines.append("- " + line) }
            if !meeting.decisions.isEmpty {
                lines.append("Decisions:")
                for decision in meeting.decisions { lines.append("- " + decision) }
            }
            if !meeting.actions.isEmpty {
                lines.append("Actions:")
                for action in meeting.actions { lines.append("- " + action) }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if !evidence.otherActions.isEmpty {
            var lines: [String] = ["Open actions from older meetings:"]
            for action in evidence.otherActions { lines.append("- " + action) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !evidence.reviewNotes.isEmpty {
            var lines: [String] = ["Overnight review notes (label: review):"]
            for note in evidence.reviewNotes { lines.append("- " + note) }
            sections.append(lines.joined(separator: "\n"))
        }
        return PromptContextSanitizer.sanitize(sections.joined(separator: "\n\n"),
                                               maxCharacters: maximumContextCharacters)
    }

    static func fingerprint(_ evidence: Evidence) -> String {
        let digest = SHA256.hash(data: Data(promptContext(evidence).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static let system = """
        You write a short status note on one project for the person who works on it.
        Use only the supplied evidence from their meetings and overnight work review.
        Say where the project stands now: the latest state, what changed recently, decisions, concerns,
        and what is still open. When meetings disagree, prefer the newest one (M1 is the newest).
        Do not invent owners, dates, numbers, or commitments. "Speaker 4" and similar labels are unnamed
        participants; keep them unnamed. "The user" is the person reading the note; address them as "you".
        overview: one or two plain sentences on where it stands. points: at most five short points, newest
        first, each with the label of the meeting it comes from, or "review" for an overnight review note.
        open_questions: at most three questions the evidence leaves open; an empty list when there are none.
        Return only the requested JSON object.
        """

    static func schema(labels: [String], enumLimit: Int?) -> [String: Any] {
        let sources: [String] = labels + ["review"]
        var source: [String: Any] = ["type": "string"]
        if enumLimit.map({ sources.count <= $0 }) ?? true { source["enum"] = sources }
        let point: [String: Any] = [
            "type": "object",
            "properties": ["text": ["type": "string"], "source": source],
            "required": ["text", "source"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "overview": ["type": "string"],
                "points": ["type": "array", "items": point],
                "open_questions": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["overview", "points", "open_questions"],
            "additionalProperties": false,
        ]
    }

    private struct Reply: Decodable {
        struct Point: Decodable {
            let text: String
            let source: String?
        }

        let overview: String
        let points: [Point]?
        let openQuestions: [String]?

        enum CodingKeys: String, CodingKey {
            case overview, points
            case openQuestions = "open_questions"
        }
    }

    static func generate(evidence: Evidence, projectID: UUID, engine: TextEngine,
                         location: String, now: Date = Date()) async throws -> ProjectStatusSummary {
        guard !evidence.isEmpty else { throw GenerationError.emptyEvidence }
        let today: String = now.formatted(.dateTime.day().month(.abbreviated).year())
        let output: String = try await engine.generate(
            system: system,
            prompt: "Today is \(today). Write the status note for \(evidence.projectName).",
            context: [promptContext(evidence)],
            schema: schema(labels: evidence.meetings.map(\.label), enumLimit: engine.structuredOutputEnumLimit),
            options: TextGenerationOptions(maxTokens: 1_000 + engine.minimumStructuredOutputTokens,
                                           reasoningBudgetTokens: 256, temperature: 0.2))
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else {
            throw GenerationError.unreadableResponse
        }
        let overview: String = clean(reply.overview)
        guard !overview.isEmpty else { throw GenerationError.unreadableResponse }
        var meetingsByLabel: [String: Evidence.MeetingEvidence] = [:]
        for meeting in evidence.meetings { meetingsByLabel[meeting.label] = meeting }
        var points: [ProjectStatusSummary.Point] = []
        for point in reply.points ?? [] {
            let text: String = clean(point.text)
            guard !text.isEmpty, !points.contains(where: { $0.text == text }) else { continue }
            let label: String = (point.source ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            let meeting: Evidence.MeetingEvidence? = meetingsByLabel[label]
            points.append(ProjectStatusSummary.Point(
                text: text, meetingID: meeting?.id, meetingTitle: meeting?.title, meetingDate: meeting?.date))
            if points.count == maximumPoints { break }
        }
        let questions: [String] = (reply.openQuestions ?? []).map(clean).filter { !$0.isEmpty }
        return ProjectStatusSummary(
            projectID: projectID, overview: overview, points: points,
            openQuestions: Array(questions.prefix(maximumQuestions)),
            meetingIDs: evidence.meetingIDs, evidenceFingerprint: fingerprint(evidence),
            generatedAt: now, engineName: engine.displayName, location: location)
    }

    private static func clean(_ text: String) -> String {
        ScreenContextPrivacy.redact(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
