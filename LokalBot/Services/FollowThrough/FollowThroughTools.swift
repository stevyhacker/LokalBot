import Foundation

/// The action Follow-through works on: one of the person's own commitments,
/// from a meeting's saved actions or from Live Radar.
struct FollowThroughTarget: Equatable, Sendable {
    let meetingID: Meeting.ID
    let meetingTitle: String
    let meetingDate: Date
    /// The saved action, when there is one; Mark Done needs it.
    let actionID: String?
    let text: String
    let owner: String?
    let due: String?
    /// Where it was said: "00:12:09 Me: I'll send the deck to Marko by Friday."
    let evidence: [String]
}

/// A step the model proposes. Nothing happens until the person approves it,
/// and they may edit every field first.
struct FollowThroughProposal: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Opens a draft in the mail app; the person sends it there.
        case email(to: [String], cc: [String], subject: String, body: String)
        /// Opens an invitation in Calendar; the person adds it there.
        case event(title: String, start: Date, minutes: Int, attendees: [String], notes: String)
        /// Fills a prompt into Claude Code or Codex; the person sends it there.
        case codingTask(agent: ActionAgentHandoff, prompt: String)
        case markDone(note: String)
    }

    enum Status: Equatable, Sendable {
        case pending
        case approved(result: String)
        case declined(reason: String)
        case failed(String)
    }

    /// The tool call id, so the result goes back to the right call.
    let id: String
    var kind: Kind
    var rationale: String
    var status: Status = .pending

    var title: String {
        switch kind {
        case .email: "Email draft"
        case .event: "Meeting invitation"
        case .codingTask(let agent, _): "Task for \(agent.rawValue)"
        case .markDone: "Mark the action done"
        }
    }

    var systemImage: String {
        switch kind {
        case .email: "envelope"
        case .event: "calendar.badge.plus"
        case .codingTask: "chevron.left.forwardslash.chevron.right"
        case .markDone: "checkmark.circle"
        }
    }
}

/// Tool schemas and argument checks. Read tools reuse Ask's library tools;
/// the proposal tools only describe a step for the person to approve.
enum FollowThroughTools {
    static let readTools: Set<String> = ["search_meetings", "get_meeting", "get_action_items"]
    static let finishTool = "finish"

    static func definitions(readSpecs: [ChatToolSpec], codingAgents: [ActionAgentHandoff],
                            canMarkDone: Bool) -> [[String: Any]] {
        var tools = readSpecs.filter { readTools.contains($0.name) }.map { spec in
            function(spec.name, spec.summary,
                     properties: Dictionary(uniqueKeysWithValues: spec.arguments.map {
                         ($0.name, ["type": "string", "description": $0.description] as [String: Any])
                     }),
                     required: spec.arguments.filter(\.required).map(\.name))
        }
        let names: [String: Any] = ["type": "array", "items": ["type": "string"]]
        tools.append(function(
            "draft_email",
            "Propose an email for the person to review. LokalBot opens it in their mail app and saves it as the meeting's follow-up draft; it is never sent automatically.",
            properties: [
                "to": names.merging(["description": "Recipient names as said in the meeting. LokalBot adds addresses it knows."]) { $1 },
                "cc": names,
                "subject": ["type": "string"],
                "body": ["type": "string", "description": "Plain text, ready to send. Use [placeholders] for anything unknown."],
                "why": ["type": "string", "description": "One sentence: why this step moves the action forward."],
            ],
            required: ["to", "subject", "body", "why"]))
        tools.append(function(
            "propose_meeting",
            "Propose a calendar invitation. LokalBot opens it in Calendar for the person to add.",
            properties: [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "Local date and time, ISO 8601 without a zone, e.g. 2026-11-03T15:00."],
                "duration_minutes": ["type": "integer"],
                "attendees": names,
                "agenda": ["type": "string"],
                "why": ["type": "string"],
            ],
            required: ["title", "start", "duration_minutes", "attendees", "agenda", "why"]))
        if !codingAgents.isEmpty {
            tools.append(function(
                "hand_off_to_coding_agent",
                "Propose a task for a coding agent on this Mac. LokalBot fills the prompt into it; the person sends it there.",
                properties: [
                    "agent": ["type": "string", "enum": codingAgents.map(\.rawValue)],
                    "prompt": ["type": "string", "description": "A complete task: goal, context from the meeting, and what done looks like."],
                    "why": ["type": "string"],
                ],
                required: ["agent", "prompt", "why"]))
        }
        if canMarkDone {
            tools.append(function(
                "mark_action_done",
                "Propose marking the action done, only when the meeting record shows it is finished.",
                properties: ["note": ["type": "string"], "why": ["type": "string"]],
                required: ["note", "why"]))
        }
        tools.append(function(
            finishTool,
            "End the session with a short summary of what was done and what is left for the person.",
            properties: ["summary": ["type": "string"]],
            required: ["summary"]))
        return tools
    }

    private static func function(_ name: String, _ description: String,
                                 properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function",
         "function": [
             "name": name,
             "description": description,
             "parameters": ["type": "object", "properties": properties, "required": required],
         ] as [String: Any]]
    }

    enum ArgumentError: LocalizedError, Equatable {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "Missing required argument '\(name)'."
            case .invalid(let detail): detail
            }
        }
    }

    /// A proposal from a tool call, or the reason the call was malformed,
    /// which goes back to the model so it can correct itself.
    static func proposal(from call: MuseChatClient.ToolCall, codingAgents: [ActionAgentHandoff],
                         canMarkDone: Bool, calendar: Calendar = .current) throws -> FollowThroughProposal? {
        let arguments = call.decodedArguments
        func text(_ key: String, required: Bool = true) throws -> String {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if required, value.isEmpty { throw ArgumentError.missing(key) }
            return value
        }
        func list(_ key: String) -> [String] {
            let raw = arguments[key] as? [Any] ?? (arguments[key] as? String).map { [$0] } ?? []
            return raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let why = (arguments["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch call.name {
        case "draft_email":
            let to = list("to")
            guard !to.isEmpty else { throw ArgumentError.missing("to") }
            return FollowThroughProposal(
                id: call.id,
                kind: .email(to: to, cc: list("cc"), subject: try text("subject"), body: try text("body")),
                rationale: why)
        case "propose_meeting":
            guard let start = date(try text("start"), calendar: calendar) else {
                throw ArgumentError.invalid("'start' must be a local date and time like 2026-11-03T15:00.")
            }
            let minutes = (arguments["duration_minutes"] as? Int)
                ?? (arguments["duration_minutes"] as? String).flatMap(Int.init) ?? 30
            return FollowThroughProposal(
                id: call.id,
                kind: .event(title: try text("title"), start: start, minutes: min(max(minutes, 5), 480),
                             attendees: list("attendees"), notes: try text("agenda", required: false)),
                rationale: why)
        case "hand_off_to_coding_agent":
            guard let agent = ActionAgentHandoff(rawValue: try text("agent")), codingAgents.contains(agent) else {
                throw ArgumentError.invalid("'agent' must be one of: \(codingAgents.map(\.rawValue).joined(separator: ", ")).")
            }
            return FollowThroughProposal(id: call.id, kind: .codingTask(agent: agent, prompt: try text("prompt")),
                                         rationale: why)
        case "mark_action_done":
            guard canMarkDone else { throw ArgumentError.invalid("This action has no saved record to mark done.") }
            return FollowThroughProposal(id: call.id, kind: .markDone(note: try text("note", required: false)),
                                         rationale: why)
        default:
            return nil
        }
    }

    static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(19))) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Hand-off formats

    /// A `mailto:` link the mail app opens as an unsent draft. Names without
    /// a known address go into the body's greeting instead of the header.
    static func mailtoURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.filter { $0.contains("@") }.joined(separator: ",")
        var items = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        let ccAddresses = cc.filter { $0.contains("@") }
        if !ccAddresses.isEmpty { items.insert(URLQueryItem(name: "cc", value: ccAddresses.joined(separator: ",")), at: 0) }
        components.queryItems = items
        // `+` is a space in some mail clients' query parsing.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// An iCalendar invitation for Calendar to import. Attendees with a known
    /// address are listed; the rest are named in the notes.
    static func icsDocument(title: String, start: Date, minutes: Int, attendees: [String],
                            notes: String, now: Date = Date(), uid: String = UUID().uuidString) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        let unnamed = attendees.filter { !$0.contains("@") }
        let description = unnamed.isEmpty ? notes : notes + "\n\nInvite: " + unnamed.joined(separator: ", ")
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//LokalBot//Follow-through//EN", "BEGIN:VEVENT",
            "UID:\(uid)@lokalbot", "DTSTAMP:\(formatter.string(from: now))",
            "DTSTART:\(formatter.string(from: start))",
            "DTEND:\(formatter.string(from: start.addingTimeInterval(TimeInterval(minutes * 60))))",
            "SUMMARY:\(escape(title))", "DESCRIPTION:\(escape(description))",
        ]
        lines += attendees.filter { $0.contains("@") }.map { "ATTENDEE;RSVP=TRUE:mailto:\($0)" }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
