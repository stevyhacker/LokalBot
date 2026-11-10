import ArgumentParser
import Foundation

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one meeting as Markdown (default) or JSON.",
        discussion: """
            ID comes from `list` output, or the literal `latest` to pick the
            most recent meeting. By default the Markdown includes metadata,
            summary, and transcript. Restrict with --include.
            """
    )

    @Argument(help: "Meeting ID from `list`, or 'latest' for the most recent.")
    var id: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Comma-separated parts to include.",
            discussion: "Choose any of: metadata, summary, transcript. Default is all three."
        )
    )
    var include: String = "metadata,summary,transcript"

    @Option(name: .long, help: "Output format: md (default) or json.")
    var format: String = "md"

    func run() async throws {
        try AgentAccessGate().requireCommandAccess()
        let options = try parseOptions()
        let normalizedFormat = format.lowercased()
        guard normalizedFormat == "md" || normalizedFormat == "json" else {
            throw ValidationError("Unknown format '\(format)'. Use 'md' or 'json'.")
        }
        guard let meeting = try SessionLookup.find(id: id) else {
            throw ValidationError("No meeting with id '\(id)'. Run `list` to see available IDs.")
        }
        switch normalizedFormat {
        case "md":
            print(SessionFormatter.getMarkdown(meeting, options: options))
        case "json":
            print(SessionFormatter.getJSON(meeting, options: options))
        default: break
        }
    }

    private func parseOptions() throws -> SessionFormatter.GetOptions {
        let parts = include.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let allowed = Set(["metadata", "summary", "transcript"])
        let unknown = Set(parts).subtracting(allowed)
        guard !parts.isEmpty, unknown.isEmpty else {
            let detail = unknown.sorted().joined(separator: ", ")
            throw ValidationError(detail.isEmpty
                ? "--include must contain metadata, summary, or transcript."
                : "Unknown --include value(s): \(detail).")
        }
        return SessionFormatter.GetOptions(
            includeSummary: parts.contains("summary"),
            includeTranscript: parts.contains("transcript"),
            includeMetadata: parts.contains("metadata"))
    }
}
