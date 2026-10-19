import ArgumentParser
import Foundation

struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Answer a question from the meeting library with LokalBot's local model.",
        discussion: """
            The same answer as the ask_library MCP tool: LokalBot's local model
            reads the meetings that match the question and answers, citing the
            meetings it used. Needs the LokalBot app running; the first question
            after a cold start can take up to a minute while the model loads.

            JSON by default: {"status", "text", "sources"}, where status is
            answered, not_found, or error (with "code"). Pass --table for the
            answer and its sources as text. Errors exit with status 1 after
            printing.
            """
    )

    @Argument(help: "The question to answer.")
    var question: String

    @Flag(name: .long, help: "Plain text instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let outcome = await AskLibraryEngine(gate: AgentAccessGate()).answer(question)
        try printAskOutcome(outcome, table: table)
    }
}

struct ReplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Draft a reply to a message from what your meetings say.",
        discussion: """
            LokalBot's local model reads the meetings that match the message
            and drafts the user's reply from them, without inventing facts the
            meetings do not support. A message no meeting matches gets no
            draft (status not_found). Pass the message as an argument, or omit
            it to read the message from standard input.

            Output and errors work as in `ask`; in JSON, "text" is the draft
            alone and "sources" lists the meetings it drew on.
            """
    )

    @Argument(help: "The message to reply to. Omit it to read standard input.")
    var message: String?

    @Option(name: .long, help: "Extra direction for the draft, such as \"decline politely\".")
    var instruction: String?

    @Flag(name: .long, help: "Plain text instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let text = try message ?? readMessageFromStandardInput()
        let outcome = await AskLibraryEngine(gate: AgentAccessGate())
            .draftReply(to: text, instruction: instruction)
        try printAskOutcome(outcome, table: table)
    }

    private func readMessageFromStandardInput() throws -> String {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        // The engine checks the character limit; this only bounds memory.
        guard data.count <= LibraryInputPolicy.maximumQuestionCharacters * 4 else {
            throw ValidationError(
                "The message is limited to \(LibraryInputPolicy.maximumQuestionCharacters) characters.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Prints JSON or text on standard output; failures exit with status 1 so
/// scripts notice, after the JSON that says why.
func printAskOutcome(_ outcome: AskLibraryOutcome, table: Bool) throws {
    if table {
        if outcome.isFailure {
            FileHandle.standardError.write(Data((outcome.plainText + "\n").utf8))
        } else {
            print(outcome.plainText)
        }
    } else {
        print(outcome.json)
    }
    if outcome.isFailure { throw ExitCode.failure }
}
