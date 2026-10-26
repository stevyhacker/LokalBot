import ArgumentParser
import Foundation

struct BriefCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brief",
        abstract: "Start here: what LokalBot knows that this session may use.",
        discussion: """
            One short read for the start of an agent session: which LokalBot
            sources are on, what the user shared about themselves, their open
            action items, current projects and goals, recent coding-agent work,
            and a timeline of recent days, weeks, and months. Each part appears
            only under the Privacy permission that covers it; with none on, it
            lists the permissions and how to turn them on. Same text as the
            get_briefing MCP tool, except that it names lokalbot-cli commands
            where that names MCP tools.
            """
    )

    func run() async throws {
        let provider = FileLibraryToolProvider(gate: AgentAccessGate()) { _ in .text("") }
        print(provider.briefing(vocabulary: .cli))
    }
}
