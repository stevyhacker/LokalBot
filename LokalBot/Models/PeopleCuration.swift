import Foundation

/// Corrections the person made in People: names they chose, people they
/// merged, and entries hidden as not a person. Saved as
/// `people/curation.json` in the library. Everything else about a person is
/// derived from the library each time it is shown. Keys are the opaque
/// person ids from `PeopleDirectory`, never attendee addresses.
struct PeopleCuration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let directoryName = "people"
    static let fileName = "curation.json"

    struct Merge: Codable, Equatable, Sendable {
        let sourceID: String
        let targetID: String
        /// The merged person's name when merged, to offer "Separate".
        let sourceName: String
    }

    struct HiddenPerson: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    var version = currentVersion
    /// Display names chosen by the person, by person id.
    var names: [String: String] = [:]
    /// Applied in order, after the automatic joins.
    var merges: [Merge] = []
    var hidden: [HiddenPerson] = []

    var isEmpty: Bool { names.isEmpty && merges.isEmpty && hidden.isEmpty }

    func isHidden(_ id: String) -> Bool { hidden.contains { $0.id == id } }

    /// Read-only load for code without the app's store, such as the CLI.
    static func load(libraryRoot: URL) -> PeopleCuration? {
        let url = libraryRoot.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PeopleCuration.self, from: data)
    }
}
