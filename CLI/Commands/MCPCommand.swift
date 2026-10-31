import ArgumentParser
import Foundation

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the meeting library, and optionally screen memory, shared Personal Context, and Files, over MCP.",
        discussion: """
            For GUI agent clients (Claude Desktop, and any MCP-capable app):

              claude mcp add lokalbot -- \
                /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp

            Start with get_briefing: what LokalBot holds and which
            permissions are on, in one read. Meeting tools: list_meetings,
            get_meeting, search_meetings, ask_library, get_action_items,
            list_people, get_person. Screen-memory tools: search_screen,
            get_timeline, get_recent_activity, get_app_usage,
            get_screenshot_detail. Personal context: get_personal_context
            returns only Personal Context items the user shared. Files:
            search_files searches the folders the user chose under Files by
            their words and returns paths, excerpts, and matched passages.
            Read tools work with the app closed; ask_library needs the app
            running (it answers with the local model on localhost:17872).

            Each group needs its box under "Allow external agents to read
            your LokalBot data" in Settings → Privacy → External agents:
            Meetings, Screen memory, What I shared about myself, or Files.
            Screen tools expose only local OCR and metadata — never decrypted
            pixels or screenshot file paths. search_files never changes files.
            The MCP handshake and tools/list work while a permission is off;
            a call returns a structured scope-specific access error with
            enable steps.
            """)

    func run() async throws {
        let gate = AgentAccessGate()
        let engine = AskLibraryEngine(gate: gate)
        let provider = FileLibraryToolProvider(gate: gate) { question in
            await engine.ask(question)
        }
        let dispatcher = MCPDispatcher(
            provider: provider,
            serverVersion: HelperVersion.current())

        FileHandle.standardError.write(Data(
            "lokalbot-cli mcp: serving on stdio (library: \(SessionLookup.storageRootURL.path))\n".utf8))

        var reader = MCPStdioLineReader()
        while true {
            switch try reader.next() {
            case .line(let line):
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if let response = await dispatcher.handle(line: line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            case .oversized:
                let response = MCPResponse.failure(
                    id: nil,
                    code: -32600,
                    message: "Request exceeds the 1 MiB limit")
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            case .end:
                return
            }
        }
    }
}
