import Foundation

/// The projects the person chose to follow and the suggestions they turned
/// down. Saved as `projects/tracked.json` in the library. Everything else on
/// a project page is derived from the library each time it is shown.
struct ProjectCuration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "tracked.json"

    struct TrackedProject: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        /// Other names for the same work, matched like the name: a merged
        /// project's names, a codename, a client.
        var otherNames: [String]
        let createdAt: Date

        var allNames: [String] { [name] + otherNames }
    }

    var version = currentVersion
    var tracked: [TrackedProject] = []
    /// Normalized names of suggestions marked "Not a Project".
    var hiddenNames: [String] = []

    func tracked(_ id: UUID) -> TrackedProject? { tracked.first { $0.id == id } }

    func isHidden(_ name: String) -> Bool {
        hiddenNames.contains(PeopleDirectory.normalized(name))
    }

    /// The tracked project already known by this name, if any.
    func trackedProject(named name: String) -> TrackedProject? {
        let key = PeopleDirectory.normalized(name)
        guard !key.isEmpty else { return nil }
        return tracked.first { project in
            project.allNames.contains { PeopleDirectory.normalized($0) == key }
        }
    }

    /// Names the person confirmed, for speech-model vocabulary.
    var trackedNames: [String] { tracked.flatMap(\.allNames) }

    /// Read-only load for code without the app's store, such as the
    /// processing pipeline's transcription vocabulary.
    static func load(libraryRoot: URL) -> ProjectCuration? {
        let url = libraryRoot.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectCuration.self, from: data)
    }
}

/// A short "Where it stands" note for one tracked project, written by the
/// Think model from the project's meetings and overnight review notes.
/// Saved in `projects/summaries.json`; withdrawn when a meeting it used is
/// deleted, and marked out of date when its evidence changes.
struct ProjectStatusSummary: Codable, Equatable, Sendable {
    static let fileName = "summaries.json"

    struct Point: Codable, Equatable, Identifiable, Sendable {
        var id: String { text }
        let text: String
        /// The meeting the point came from; nil for overnight review notes.
        let meetingID: UUID?
        let meetingTitle: String?
        let meetingDate: Date?
    }

    let projectID: UUID
    let overview: String
    let points: [Point]
    let openQuestions: [String]
    /// Every meeting whose evidence was in the prompt.
    let meetingIDs: [UUID]
    /// Hash of the prompt evidence; a different hash means newer evidence.
    let evidenceFingerprint: String
    let generatedAt: Date
    let engineName: String
    /// Where the model ran: "this Mac" or the server's host.
    let location: String
}
