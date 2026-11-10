import ArgumentParser
import Foundation

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Word search across titles, summaries, and transcripts.",
        discussion: """
            Returns up to 50 hits. A meeting matches when it contains every
            query word, in any order, ignoring case and accents; when none
            does, meetings with the most words follow. Rare words weigh more
            than common ones, exact-phrase hits come first, ties keep meeting
            recency, and one meeting contributes at most five transcript
            hits. Words of up to three letters or digits ("API", "Q3")
            match only whole words. Quote the query ("…") to match only the
            exact phrase. JSON by default; pass --table for a quick scan.

            This search walks the on-disk artifacts, so it works without
            launching the app.
            """
    )

    @Argument(help: "Words to find in any order; quote for an exact phrase.")
    var query: String

    @Option(name: .long, help: "Maximum number of hits to return.")
    var limit: Int = LibrarySearch.defaultLimit

    @Flag(name: .long, help: "Plain-text table instead of JSON.")
    var table: Bool = false

    func run() async throws {
        try AgentAccessGate().requireCommandAccess()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw ValidationError("Query must not be empty.")
        }
        guard normalizedQuery.count <= LibraryInputPolicy.maximumQueryCharacters else {
            throw ValidationError(
                "Query must be at most \(LibraryInputPolicy.maximumQueryCharacters) characters.")
        }
        guard (1...LibraryInputPolicy.maximumSearchHits).contains(limit) else {
            throw ValidationError(
                "--limit must be between 1 and \(LibraryInputPolicy.maximumSearchHits).")
        }
        let hits = try LibrarySearch.hits(query: normalizedQuery, limit: limit)
        print(table
            ? SessionFormatter.searchTable(hits)
            : SessionFormatter.searchJSON(hits))
    }
}
