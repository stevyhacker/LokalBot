import ArgumentParser
import Foundation

struct ActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "List meeting action items with saved corrections and status.",
        discussion: """
            Threads repeated commitments across meetings, applies the status,
            text, owner, and due corrections saved in LokalBot, and lists
            overdue and soon-due work first. `due_date` is present only when
            the spoken due phrase resolves unambiguously. JSON by default.
            """
    )

    @Option(name: .long, help: "active (default), open, deferred, done, or all.")
    var status: String = ActionStatusFilter.active.rawValue

    @Option(name: .long, help: "me, others, or a participant name substring.")
    var owner: String?

    @Option(name: .long, help: "Meetings from the last N days (maximum 365).")
    var days: Int = ActionItemsReport.defaultDays

    @Option(name: .long, help: "Limit to one meeting (short id or full UUID).")
    var meeting: String?

    @Option(name: .long, help: "Maximum number of action threads.")
    var limit: Int = 50

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        try AgentAccessGate().requireAuthorized()
        guard let statusFilter = ActionStatusFilter(rawValue: status.lowercased()) else {
            throw ValidationError("--status must be one of all, active, open, deferred, or done.")
        }
        guard (1...ActionItemsReport.maximumDays).contains(days) else {
            throw ValidationError("--days must be between 1 and \(ActionItemsReport.maximumDays).")
        }
        guard (1...ActionItemsReport.maximumEntries).contains(limit) else {
            throw ValidationError("--limit must be between 1 and \(ActionItemsReport.maximumEntries).")
        }
        let meetings = try SessionLookup.loadAllMeetings()
        var filter = ActionItemsReport.Filter(
            status: statusFilter, days: days, owner: .init(owner), limit: limit)
        if let meeting {
            guard let match = try SessionLookup.find(id: meeting, in: meetings) else {
                throw ValidationError("No meeting matches \"\(meeting)\".")
            }
            filter.meetingID = match.id
        }
        let entries = ActionItemsReport.entries(
            meetings: meetings, root: SessionLookup.storageRootURL, filter: filter)
        print(table ? ActionItemsReport.table(entries) : ActionItemsReport.json(entries))
    }
}
