import ArgumentParser

@main
struct LokalBotCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lokalbot-cli",
        abstract: "Read your local LokalBot meeting library and inspect app settings.",
        discussion: """
            Intended for coding agents (Claude Code, Codex CLI, Cursor, Gemini)
            and humans alike. The CLI is symlinked at
            ~/.local/bin/lokalbot-cli by the in-app installer (Settings →
            Agent CLI). Output defaults to JSON; pass --table for plain text.
            Library commands need meeting access. config, secret, models,
            permissions, status, doctor, restart, and open need the separate
            settings access in Settings → Privacy; setup start asks the person
            for it.
            """,
        subcommands: [
            BriefCommand.self,
            ListCommand.self,
            GetCommand.self,
            SearchCommand.self,
            AskCommand.self,
            ReplyCommand.self,
            ActionsCommand.self,
            PeopleCommand.self,
            PersonalContextCommand.self,
            PathCommand.self,
            SetupCommand.self,
            ConfigCommand.self,
            SecretCommand.self,
            ModelsCommand.self,
            PermissionsCommand.self,
            StatusCommand.self,
            DoctorCommand.self,
            RestartCommand.self,
            OpenCommand.self,
            MCPCommand.self,
            InstallSkillCommand.self,
        ]
    )
}
