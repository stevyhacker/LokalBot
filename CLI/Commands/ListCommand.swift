import ArgumentParser
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings, newest first.",
        discussion: """
            JSON by default — one object per meeting with id, title, date,
            duration, `has_system_track`, `has_summary`, `has_transcript`.
            --include summary adds each meeting's `summary`. The summaries
            share \(SessionFormatter.listSummaryBudget) characters; a cut one has `summary_truncated`,
            and `get` reads it whole. With it, --limit defaults to \(SessionFormatter.defaultSummaryListCount)
            and is at most \(SessionFormatter.maximumSummaryListCount). Use --table for human-readable output.
            """
    )

    @Option(name: .long, help: "Only include meetings on or after this local day (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long, help: "Only include meetings on or before this local day (YYYY-MM-DD).")
    var until: String?

    @Option(name: .long, help: "Substring match against the title (case-insensitive).")
    var query: String?

    @Option(name: .long, help: "Maximum number of meetings to return.")
    var limit: Int?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Add each meeting's summary: --include summary.",
            discussion: "Read transcripts one meeting at a time with `get <id> --include transcript`."
        )
    )
    var include: String = "metadata"

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        try AgentAccessGate().requireAuthorized()
        let sinceDate = try since.map { try Self.requireDate($0, option: "--since") }
        let untilDate = try until.map { try Self.requireDate($0, option: "--until") }
        let includeSummary: Bool
        do {
            includeSummary = try SessionFormatter.listIncludesSummary(include)
        } catch SessionFormatter.ListIncludeError.transcript {
            throw ValidationError(
                "list doesn't include transcripts. Read one meeting's with `get <id> --include transcript`.")
        } catch SessionFormatter.ListIncludeError.unknown(let values) {
            throw ValidationError(
                "Unknown --include value(s): \(values.joined(separator: ", ")). list takes summary.")
        }
        let maximum = includeSummary
            ? SessionFormatter.maximumSummaryListCount
            : LibraryInputPolicy.maximumMeetingCount
        if let limit, !(1...maximum).contains(limit) {
            throw ValidationError(includeSummary
                ? "--limit must be between 1 and \(maximum) with --include summary."
                : "--limit must be between 1 and \(maximum).")
        }
        var meetings = try SessionLookup.loadAllMeetings()

        if let date = sinceDate {
            meetings = meetings.filter { $0.startedAt >= date }
        }
        if let date = untilDate {
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: date)
                ?? date.addingTimeInterval(86_400)
            meetings = meetings.filter { $0.startedAt < endOfDay }
        }
        if let query {
            meetings = meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if let limit = limit ?? (includeSummary ? SessionFormatter.defaultSummaryListCount : nil) {
            meetings = Array(meetings.prefix(limit))
        }

        print(table
            ? SessionFormatter.listTable(meetings, includeSummary: includeSummary)
            : SessionFormatter.listJSON(meetings, includeSummary: includeSummary))
    }

    private static func requireDate(_ value: String, option: String) throws -> Date {
        guard let date = LibraryInputPolicy.localDay(value) else {
            throw ValidationError("\(option) must be a real local day formatted YYYY-MM-DD, got '\(value)'.")
        }
        return date
    }
}
