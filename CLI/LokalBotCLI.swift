import ArgumentParser

@main
struct LokalBotCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lokalbot-cli",
        abstract: "Read-only access to your local LokalBot meeting library.",
        discussion: """
            Intended for coding agents (Claude Code, Codex CLI, Cursor, Gemini)
            and humans alike. The CLI is symlinked at
            ~/.local/bin/lokalbot-cli by the in-app installer (Settings →
            Agent CLI). Output defaults to JSON; pass --table for plain text.
            """,
        subcommands: [
            ListCommand.self,
            GetCommand.self,
            SearchCommand.self,
            ActionsCommand.self,
            PeopleCommand.self,
            PathCommand.self,
            MCPCommand.self,
            InstallSkillCommand.self,
        ]
    )
}
