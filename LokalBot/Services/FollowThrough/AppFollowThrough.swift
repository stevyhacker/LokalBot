import AppKit
import Foundation

/// The library reads and hand-offs behind Follow-through. Reads reuse Ask's
/// meeting tools (never screen memory, which has its own permission).
/// Approved steps open as drafts in the person's own apps.
@MainActor
final class AppFollowThroughEnvironment: FollowThroughEnvironment {
    private weak var app: AppState?

    init(app: AppState) { self.app = app }

    var readToolSpecs: [ChatToolSpec] {
        app?.libraryTools.specs.filter { FollowThroughTools.readTools.contains($0.name) } ?? []
    }

    var codingAgents: [ActionAgentHandoff] { ActionAgentAvailability.installed }

    func runReadTool(_ call: ChatToolCall) async -> ChatToolResult {
        guard let app, FollowThroughTools.readTools.contains(call.name) else {
            return ChatToolResult(text: "Tool not available.", summary: "unavailable")
        }
        return await app.libraryTools.run(call)
    }

    enum PerformError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let detail): detail
            }
        }
    }

    func perform(_ proposal: FollowThroughProposal, for target: FollowThroughTarget) async throws -> String {
        guard let app else { throw PerformError.unavailable("LokalBot is closing.") }
        let meeting = app.meetings.first { $0.id == target.meetingID }
        switch proposal.kind {
        case .email(let to, let cc, let subject, let body):
            let identities = meeting?.resolvedCalendarParticipantIdentities ?? []
            let toAddresses = to.map { Self.address(for: $0, in: identities) ?? $0 }
            let ccAddresses = cc.map { Self.address(for: $0, in: identities) ?? $0 }
            var draft = app.outcomeIndex.projection(for: target.meetingID)?.followUp ?? FollowUpDraft()
            draft.recipient = toAddresses.joined(separator: ", ")
            draft.cc = ccAddresses.joined(separator: ", ")
            draft.subject = subject
            draft.body = body
            draft.reviewed = true
            let saved = app.outcomeIndex.saveFollowUp(draft, meetingID: target.meetingID)
            guard let url = FollowThroughTools.mailtoURL(to: toAddresses, cc: ccAddresses, subject: subject, body: body),
                  NSWorkspace.shared.open(url) else {
                throw PerformError.unavailable("No mail app opened the draft."
                    + (saved ? " It is saved as the meeting's follow-up draft." : ""))
            }
            let missing = toAddresses.filter { !$0.contains("@") }
            return "Opened the draft in the mail app; the person sends it from there."
                + (saved ? " Saved as the meeting's follow-up draft." : "")
                + (missing.isEmpty ? "" : " The person adds the address for \(missing.joined(separator: ", ")).")
        case .event(let title, let start, let minutes, let attendees, let notes):
            let identities = meeting?.resolvedCalendarParticipantIdentities ?? []
            let invitees = attendees.map { Self.address(for: $0, in: identities) ?? $0 }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LokalBot Follow-through", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(Self.fileName(title) + ".ics")
            try FollowThroughTools.icsDocument(title: title, start: start, minutes: minutes,
                                               attendees: invitees, notes: notes)
                .write(to: file, atomically: true, encoding: .utf8)
            guard NSWorkspace.shared.open(file) else {
                throw PerformError.unavailable("Calendar didn't open the invitation.")
            }
            return "Opened the invitation in Calendar; the person adds and sends it there."
        case .codingTask(let agent, let prompt):
            let text = String(prompt.prefix(ActionAgentHandoff.promptCharacterLimit))
            guard let url = ActionAgentAvailability.route(for: agent)?.url(prompt: text),
                  NSWorkspace.shared.open(url) else {
                throw PerformError.unavailable("Couldn't open \(agent.rawValue).")
            }
            return "Filled the task into \(agent.rawValue); the person sends it there."
        case .markDone:
            guard let actionID = target.actionID,
                  app.outcomeIndex.setStatus(.done, actionID: actionID, meetingID: target.meetingID) else {
                throw PerformError.unavailable(app.outcomeIndex.lastError ?? "The action could not be updated.")
            }
            return "Marked the action done in LokalBot."
        }
    }

    /// The calendar address for a name said in the meeting, matched on the
    /// full name or the first name. Addresses never go to the model.
    static func address(for name: String, in identities: [CalendarParticipantIdentity]) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty, !wanted.contains("@") else { return nil }
        let candidates = identities.filter { $0.emailAddress?.contains("@") == true }
        if let exact = candidates.first(where: { $0.suggestedSpeakerName?.lowercased() == wanted }) {
            return exact.emailAddress
        }
        let first = wanted.split(separator: " ").first.map(String.init) ?? wanted
        let byFirstName = candidates.filter {
            $0.suggestedSpeakerName?.lowercased().split(separator: " ").first.map(String.init) == first
        }
        return byFirstName.count == 1 ? byFirstName[0].emailAddress : nil
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Invitation" : String(cleaned.prefix(60))
    }
}

enum FollowThroughBriefing {
    static let maximumSummaryCharacters = 4_000

    /// What Muse is told about the action. Names only: calendar addresses
    /// stay local.
    static func make(target: FollowThroughTarget, meeting: Meeting?, summary: String?,
                     radar: MeetingRadarRecord?, personName: String = "") -> String {
        var sections = ["ACTION: \(target.text)",
                        "Owner: \(target.owner ?? "Me") · Due: \(target.due ?? "not said")"]
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { sections.append("The person (\"Me\") is \(name).") }
        var source = "From: \(target.meetingTitle), \(target.meetingDate.formatted(date: .complete, time: .shortened))"
        if let meeting { source += " (meeting id \(SessionLookup.shortID(meeting.id)))" }
        sections.append(source)
        if !target.evidence.isEmpty {
            sections.append("Where it was said:\n" + target.evidence.map { "- \($0)" }.joined(separator: "\n"))
        }
        let invited = meeting?.resolvedCalendarParticipantIdentities.compactMap(\.suggestedSpeakerName) ?? []
        if !invited.isEmpty { sections.append("Invited: " + invited.joined(separator: ", ")) }
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            let clipped = summary.count > maximumSummaryCharacters
                ? String(summary.prefix(maximumSummaryCharacters)) + "…" : summary
            sections.append("MEETING NOTES (LokalBot's summary):\n" + clipped)
        }
        if let radar, !radar.items.isEmpty {
            sections.append("LIVE RADAR from that meeting:\n" + radar.items.map { item in
                "- \(item.kind.rawValue)\(item.owner.map { " (\($0))" } ?? ""): \(item.text)"
                    + (item.answered ? " [answered]" : "")
            }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

extension AppState {
    /// Opens Follow-through for one saved action.
    func followThrough(_ reference: OutcomeActionReference) {
        let evidence = reference.action.citations.map { citation in
            "\(Transcript.stamp(citation.start)) \(SpeakerDisplayName.label(citation.speaker)): “\(citation.excerpt)”"
        }
        startFollowThrough(FollowThroughTarget(
            meetingID: reference.meetingID, meetingTitle: reference.meetingTitle,
            meetingDate: reference.meetingStartedAt, actionID: reference.action.id,
            text: reference.text, owner: reference.isForUser ? "Me" : reference.owner,
            due: reference.due, evidence: evidence))
    }

    /// Opens Follow-through for a commitment Live Radar caught.
    func followThrough(_ item: RadarItem, in meeting: Meeting) {
        let speaker = item.speaker == "local" || item.speaker == "me" ? "Me" : "Others"
        startFollowThrough(FollowThroughTarget(
            meetingID: meeting.id, meetingTitle: meeting.displayTitle, meetingDate: meeting.startedAt,
            actionID: nil, text: item.text, owner: item.owner, due: item.due,
            evidence: ["\(Transcript.stamp(item.time)) \(speaker): “\(item.quote)”"]))
    }

    private func startFollowThrough(_ target: FollowThroughTarget) {
        let meeting = meetings.first { $0.id == target.meetingID }
        let folder = meeting?.folderURL(in: storage)
        let summary = folder.flatMap { try? String(contentsOf: $0.appendingPathComponent("summary.md"), encoding: .utf8) }
        // The name from Settings → Writing, so drafts are signed.
        let briefing = FollowThroughBriefing.make(target: target, meeting: meeting, summary: summary,
                                                  radar: folder.flatMap(MeetingRadarRecord.load(from:)),
                                                  personName: settings.cotypingUserName)
        let model = settings.museFollowThroughModel
        let session = FollowThroughSession(
            target: target, briefing: briefing, model: model,
            environment: AppFollowThroughEnvironment(app: self),
            call: { [store = settingsStore] messages, tools in
                let client = try MetaModelAPI.client(
                    settings: store.current, model: model, reasoningEffort: "low",
                    maxTokens: 8_000, priority: .agent, purpose: "follow-through")
                return try await client.send(messages: messages, tools: tools)
            })
        followThroughSession = session
    }
}
