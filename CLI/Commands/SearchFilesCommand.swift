import ArgumentParser
import Foundation

struct SearchFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-files",
        abstract: "Word search across the folders the user chose under Files.",
        discussion: """
            Searches the text LokalBot read from the user's chosen folders
            (documents, PDF pages, words in screenshots and pictures, and file
            names), best match first, with the passage that matched. Works
            without launching the app. Search by meaning stays in LokalBot's
            Ask. Needs file access: LokalBot → Settings → External Agents,
            with Files ticked. JSON by default.
            """
    )

    @Argument(help: "Words to find.")
    var query: String

    @Option(name: .long, help: "Only this kind: screenshot, image, pdf, doc, audio, or video. Repeatable.")
    var kind: [String] = []

    @Option(name: .long, help: "Only files dated on or after this local day (YYYY-MM-DD).")
    var after: String?

    @Option(name: .long, help: "Only files dated before this local day (YYYY-MM-DD).")
    var before: String?

    @Option(name: .long, help: "Maximum files (1–\(FilesSearchTool.maximumLimit)).")
    var limit: Int = FilesSearchTool.defaultLimit

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        let result = FilesSearchTool.report(
            query: query, kinds: kind.isEmpty ? nil : kind, after: after, before: before, limit: limit,
            gate: FilesAccessGate())
        switch result {
        case .success(let report):
            print(table ? FilesSearchTool.table(report) : FilesSearchTool.json(report))
        case .failure(.invalid(let message)):
            throw ValidationError(message)
        case .failure(let failure):
            throw failure
        }
    }
}
