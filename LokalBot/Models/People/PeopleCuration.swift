import Foundation

struct PeopleCuration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let directoryName = "people"
    static let fileName = "curation.json"

    struct Merge: Codable, Equatable, Sendable {
        let sourceID: String
        let targetID: String
        let sourceName: String
    }

    struct HiddenPerson: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    var version = currentVersion
    var names: [String: String] = [:]
    var merges: [Merge] = []
    var hidden: [HiddenPerson] = []

    var isEmpty: Bool { names.isEmpty && merges.isEmpty && hidden.isEmpty }

    func isHidden(_ id: String) -> Bool { hidden.contains { $0.id == id } }

    static func load(libraryRoot: URL) -> PeopleCuration? {
        let url = libraryRoot.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PeopleCuration.self, from: data)
    }
}
