import ArgumentParser
import Foundation

struct SearchNotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-notes",
        abstract: "Word search across the notes the user's coding agents saved for themselves.",
        discussion: """
            Searches the notes Claude Code and Codex keep for their own later
            sessions (project decisions, how-tos, preferences, pointers), as
            LokalBot saved them, best match first, with each note's text.
            Use it to find what another agent or an earlier session already
            learned. A note is an agent's record, not a verified fact. Works
            without launching the app. Needs agent-notes access: LokalBot →
            Settings → External Agents, with Agent notes ticked. JSON by
            default.
            """
    )

    @Argument(help: "Words to find.")
    var query: String

    @Option(name: .long, help: "Only this agent's notes: claude-code or codex.")
    var agent: String?

    @Option(name: .long, help: "Maximum notes (1–\(AgentNotesSearchTool.maximumLimit)).")
    var limit: Int = AgentNotesSearchTool.defaultLimit

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let result = AgentNotesSearchTool.report(
            query: query, agent: agent, limit: limit, gate: AgentNotesAccessGate())
        switch result {
        case .success(let report):
            print(table ? AgentNotesSearchTool.table(report) : AgentNotesSearchTool.json(report))
        case .failure(.invalid(let message)):
            throw ValidationError(message)
        case .failure(let failure):
            // A switch that is off prints its code, as the MCP tools do.
            if let coded = failure.commandError { throw coded }
            throw failure
        }
    }
}
