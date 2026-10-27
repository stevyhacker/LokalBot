import Foundation

/// Hands a meeting's open actions that are the person's to Agent Mode: one
/// task per action, with its prompt in the composer and the meeting's notes
/// attached, so an agent can work on each one on its own.
enum MeetingActionHandoff {
    /// More actions than this from one meeting is more likely a noisy
    /// extraction than a list worth a task each.
    static let maximumActions = 8

    /// Automatic handoffs only follow meetings from the last day, so
    /// importing or summarizing old recordings again never fills Agent Mode.
    static let automaticWindow: TimeInterval = 24 * 60 * 60

    /// Open actions that are the person's, in the order the meeting lists them.
    static func actions(in projection: MeetingOutcomeProjection) -> [OutcomeActionReference] {
        guard projection.meeting.isOwnWork, !projection.isArchived else { return [] }
        return Array(projection.actionReferences
            .filter { $0.isForUser && $0.status == .open }
            .prefix(maximumActions))
    }

    static func handoffs(for projection: MeetingOutcomeProjection,
                         timeZone: TimeZone = .current) -> [AgentHandoff] {
        actions(in: projection).enumerated().map { index, reference in
            handoff(for: reference, number: index + 1, timeZone: timeZone)
        }
    }

    static func handoff(for reference: OutcomeActionReference, number: Int,
                        timeZone: TimeZone = .current) -> AgentHandoff {
        let meetingID = reference.meetingID.uuidString
        let folder = folder(for: reference, number: number, timeZone: timeZone)
        return AgentHandoff(
            source: AgentHandoffSource(meetingID: reference.meetingID, actionID: reference.action.id),
            title: reference.text,
            prompt: prompt(for: reference, folder: folder, timeZone: timeZone),
            attachments: [AgentAttachment(id: "meeting:\(meetingID)", kind: .meeting,
                                          title: reference.meetingTitle, reference: meetingID)],
            folder: folder)
    }

    /// The task's composer text. The meeting's notes travel as an attachment
    /// that Agent Mode reads again when the prompt is sent.
    static func prompt(for reference: OutcomeActionReference, folder: String,
                       timeZone: TimeZone = .current) -> String {
        let time = formatter("EEE yyyy-MM-dd HH:mm", timeZone: timeZone)
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        var text = reference.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > ActionHandoffBrief.maximumTextCharacters {
            text = String(text.prefix(ActionHandoffBrief.maximumTextCharacters - 1)) + "…"
        }
        var lines = [
            "Work on this action item from my meeting “\(reference.meetingTitle)”, "
                + "\(time.string(from: reference.meetingStartedAt)) "
                + "(LokalBot meeting ID \(SessionLookup.shortID(reference.meetingID))).",
            "",
            "Action: \(text)",
        ]
        if let due = reference.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            if let date = reference.resolvedDueDate {
                let resolved = day.string(from: date)
                lines.append(resolved == due ? "Due: \(resolved)" : "Due: \(resolved) (said “\(due)”)")
            } else {
                lines.append("Due: “\(due)”")
            }
        }
        if let evidenceAt = reference.action.citations.first?.start {
            lines.append("It comes up at [\(Transcript.stamp(evidenceAt))] in the meeting.")
        }
        lines += [
            "",
            "Get as far as you can on your own: look things up, and write the drafts, plans, or code it needs. "
                + "Save what you make in `\(folder)/` in this workspace.",
            "Don't send, post, publish, buy, or delete anything. Draft it for me instead.",
            "Finish with a short report: what you did, the files you made, and what is left for me.",
            "",
            "The meeting's notes are attached.",
        ]
        return lines.joined(separator: "\n")
    }

    /// `handoffs/<day>-<meeting>/<number>-<action>`, relative to the workspace.
    static func folder(for reference: OutcomeActionReference, number: Int,
                       timeZone: TimeZone = .current) -> String {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone).string(from: reference.meetingStartedAt)
        let meeting = slug(reference.meetingTitle, limit: 40)
        let action = slug(reference.text, limit: 48)
        return "handoffs/\(day)\(meeting.isEmpty ? "" : "-\(meeting)")/\(number)\(action.isEmpty ? "" : "-\(action)")"
    }

    /// Lowercased letters and digits joined by single dashes.
    static func slug(_ text: String, limit: Int) -> String {
        var result = ""
        var needsDash = false
        for character in text.lowercased() {
            guard character.isLetter || character.isNumber else {
                needsDash = !result.isEmpty
                continue
            }
            if result.count + (needsDash ? 2 : 1) > limit { break }
            if needsDash { result.append("-") }
            needsDash = false
            result.append(character)
        }
        return result
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

extension AppState {
    /// Gives each open action of the person's from `meeting` its own Agent
    /// Mode task. With "Start handoffs automatically" on, the tasks run as
    /// agents free up; otherwise each prompt waits in its composer. Asked
    /// for by hand, an action whose task was archived gets a new one.
    /// Returns the new tasks' IDs, empty when every action already has a task.
    @discardableResult
    func handOffActions(of meeting: Meeting, automatic: Bool = false) -> [UUID] {
        guard let projection = outcomeIndex.projection(for: meeting.id) else { return [] }
        let handoffs = MeetingActionHandoff.handoffs(for: projection)
        guard !handoffs.isEmpty else { return [] }
        let start = settings.startHandoffsAutomatically && agentInstaller.phase == .installed
        let added = agentSessions.handOff(handoffs, start: start, againIfArchived: !automatic)
        if automatic, !added.isEmpty {
            RecordingNotifier.shared.actionsHandedOff(
                count: added.count, meetingTitle: meeting.displayTitle, started: start)
        }
        return added
    }

    /// Called once a meeting's summary is written.
    func handOffActionsAfterSummary(_ meeting: Meeting, now: Date = Date()) {
        guard settings.handOffActionsAfterSummary,
              now.timeIntervalSince(meeting.endedAt ?? meeting.startedAt) < MeetingActionHandoff.automaticWindow
        else { return }
        handOffActions(of: meeting, automatic: true)
    }

    /// The meeting page's "Hand off my actions to Agent Mode": hands them off
    /// and shows the first new task.
    func handOffActionsAndOpenAgent(of meeting: Meeting) {
        let added = handOffActions(of: meeting)
        if let first = added.first { agentSessions.select(first) }
        openAgent()
    }
}
