import Foundation

struct ProjectCuration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "tracked.json"

    struct TrackedProject: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        var otherNames: [String]
        let createdAt: Date

        var allNames: [String] { [name] + otherNames }
    }

    var version = currentVersion
    var tracked: [TrackedProject] = []
    var hiddenNames: [String] = []

    func tracked(_ id: UUID) -> TrackedProject? { tracked.first { $0.id == id } }

    func isHidden(_ name: String) -> Bool {
        hiddenNames.contains(PeopleDirectory.normalized(name))
    }

    func trackedProject(named name: String) -> TrackedProject? {
        let key = PeopleDirectory.normalized(name)
        guard !key.isEmpty else { return nil }
        return tracked.first { project in
            project.allNames.contains { PeopleDirectory.normalized($0) == key }
        }
    }

    var trackedNames: [String] { tracked.flatMap(\.allNames) }

    static func load(libraryRoot: URL) -> ProjectCuration? {
        let url = libraryRoot.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectCuration.self, from: data)
    }
}

struct ProjectStatusSummary: Codable, Equatable, Sendable {
    static let fileName = "summaries.json"
    static let localLocation = "this Mac"

    struct Point: Codable, Equatable, Identifiable, Sendable {
        var id: String { text }
        let text: String
        let meetingID: UUID?
        let meetingTitle: String?
        let meetingDate: Date?
    }

    let projectID: UUID
    let overview: String
    let points: [Point]
    let openQuestions: [String]
    let meetingIDs: [UUID]
    let evidenceFingerprint: String
    let generatedAt: Date
    let engineName: String
    let location: String
}
