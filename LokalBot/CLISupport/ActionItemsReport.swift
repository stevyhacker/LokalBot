import Foundation

/// Read-only action threads for the CLI and MCP server. It uses the app's
/// projection and thread clustering, so saved corrections, completion, and
/// deferral apply here exactly as they do in LokalBot. Owners are the names
/// written into outcomes; attendee emails and speaker evidence never appear.
enum ActionItemsReport {
    static let defaultDays = 30
    static let maximumDays = 365
    static let maximumEntries = 200

    enum OwnerFilter: Equatable {
        case anyone
        case me
        case others
        case named(String)

        init(_ raw: String?) {
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch value.lowercased() {
            case "", "any", "anyone", "all": self = .anyone
            case "me", "mine", "user": self = .me
            case "others", "other": self = .others
            default: self = .named(value)
            }
        }

        func includes(_ thread: ActionThread) -> Bool {
            switch self {
            case .anyone: true
            case .me: thread.isForUser
            case .others: !thread.isForUser
            case .named(let name):
                !thread.isForUser && (thread.owner?.localizedCaseInsensitiveContains(name) ?? false)
            }
        }
    }

    struct Filter: Equatable {
        var status: ActionStatusFilter = .active
        var days = ActionItemsReport.defaultDays
        var owner: OwnerFilter = .anyone
        var meetingID: UUID?
        var limit = 50
    }

    struct MeetingRef: Encodable, Equatable {
        let id: String
        let title: String
        let date: String
    }

    struct Entry: Encodable, Equatable {
        let text: String
        let owner: String?
        let for_user: Bool
        let due: String?
        let due_date: String?
        let overdue: Bool
        let status: String
        let mention_count: Int
        let meetings: [MeetingRef]
    }

    static func entries(meetings: [Meeting], root: URL, filter: Filter,
                        now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        let cutoff = calendar.date(byAdding: .day, value: -max(1, filter.days), to: now) ?? now
        let scoped = meetings.filter { meeting in
            if let meetingID = filter.meetingID { return meeting.id == meetingID }
            return meeting.startedAt >= cutoff
        }
        let references = scoped
            .compactMap { MeetingOutcomeProjection.load(for: $0, root: root) }
            .flatMap(\.actionReferences)
        let threads = ActionThreadClusterer.cluster(references)
            .filter(filter.status.includes)
            .filter(filter.owner.includes)
        return ActionAttentionOrder.sorted(threads, now: now, calendar: calendar)
            .prefix(max(1, min(filter.limit, maximumEntries)))
            .map { entry(for: $0, now: now, calendar: calendar) }
    }

    static func entry(for thread: ActionThread, now: Date, calendar: Calendar = .current) -> Entry {
        var seen = Set<UUID>()
        let meetings = thread.references.compactMap { reference -> MeetingRef? in
            guard seen.insert(reference.meetingID).inserted else { return nil }
            return MeetingRef(
                id: SessionLookup.shortID(reference.meetingID),
                title: reference.meetingTitle,
                date: SessionFormatter.iso8601.string(from: reference.meetingStartedAt))
        }
        return Entry(
            text: thread.text,
            owner: thread.isForUser ? "Me" : thread.owner,
            for_user: thread.isForUser,
            due: thread.due,
            due_date: thread.resolvedDueDate.map { dayKey($0, calendar: calendar) },
            overdue: thread.isOverdue(now: now, calendar: calendar),
            status: thread.hasMixedStatus ? "mixed" : thread.status.rawValue,
            mention_count: thread.mentionCount,
            meetings: meetings)
    }

    static func json(_ entries: [Entry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(entries), encoding: .utf8)) ?? "[]"
    }

    static func table(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "(no action items)" }
        let rows = entries.map { entry in
            [
                entry.overdue ? "overdue" : entry.status,
                entry.due_date ?? entry.due ?? "",
                entry.owner ?? "unclear",
                entry.text,
                entry.meetings.first.map { "\($0.id) \($0.title)" } ?? "",
            ]
        }
        return SessionFormatter.renderTable(
            header: ["Status", "Due", "Owner", "Action", "Meeting"], rows: rows)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
