import ArgumentParser
import Foundation

struct PeopleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "people",
        abstract: "List people from meetings, or show one person's open work and decisions.",
        discussion: """
            Joins calendar attendee names, speaker names applied in LokalBot,
            and action owners. With a name or id, shows what you owe that
            person, what they owe you, decisions made together, and shared
            meetings. Email addresses are never printed. JSON by default.
            """
    )

    @Argument(help: "Optional person id or name.")
    var person: String?

    @Option(name: .long, help: "Filter the list by a name substring.")
    var query: String?

    @Option(name: .long, help: "Maximum number of people to list.")
    var limit: Int = 50

    @Flag(name: .long, help: "Plain-text table instead of JSON (list only).")
    var table: Bool = false

    func run() async throws {
        try AgentAccessGate().requireAuthorized()
        guard (1...PeopleReport.maximumEntries).contains(limit) else {
            throw ValidationError("--limit must be between 1 and \(PeopleReport.maximumEntries).")
        }
        let people = PeopleReport.people(
            meetings: try SessionLookup.loadAllMeetings(), root: SessionLookup.storageRootURL)
        if let person {
            guard let match = PeopleReport.find(person, in: people) else {
                throw ValidationError("No single person matches \"\(person)\". Run `people --query` to list candidates.")
            }
            print(PeopleReport.json(PeopleReport.detail(match)))
            return
        }
        let summaries = PeopleReport.summaries(people, query: query, limit: limit)
        print(table ? PeopleReport.table(summaries) : PeopleReport.json(summaries))
    }
}
