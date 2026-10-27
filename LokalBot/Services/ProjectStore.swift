import Foundation

/// The person's tracked projects, the suggestions they turned down, and the
/// "Where it stands" notes written for tracked projects, saved under
/// `projects/` in the library. Small JSON files, written on the main actor.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var curation = ProjectCuration()
    @Published private(set) var summaries: [UUID: ProjectStatusSummary] = [:]
    /// Tracked projects whose note is being written.
    @Published private(set) var writing: Set<UUID> = []
    /// The last failure per project, cleared by the next attempt.
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var lastError: String?

    let directory: URL
    /// Automatic writes already tried this session, by project and evidence,
    /// so a failing model is not asked again on every visit.
    private var automaticAttempts: Set<String> = []

    init(directory: URL) {
        self.directory = directory
        load()
    }

    private var curationURL: URL { directory.appendingPathComponent(ProjectCuration.fileName) }
    private var summariesURL: URL { directory.appendingPathComponent(ProjectStatusSummary.fileName) }

    // MARK: - Tracking

    /// Starts tracking a project, or returns the tracked project already
    /// known by that name.
    @discardableResult
    func track(name: String, otherNames: [String] = []) -> UUID? {
        let cleaned: String = Self.cleanName(name)
        guard !cleaned.isEmpty else { return nil }
        if let existing = curation.trackedProject(named: cleaned) { return existing.id }
        var updated = curation
        let project = ProjectCuration.TrackedProject(
            id: UUID(), name: cleaned, otherNames: Self.cleanOtherNames(otherNames, excluding: cleaned),
            createdAt: Date())
        updated.tracked.append(project)
        updated.hiddenNames.removeAll { $0 == PeopleDirectory.normalized(cleaned) }
        save(curation: updated)
        return project.id
    }

    func update(_ id: UUID, name: String, otherNames: [String]) {
        let cleaned: String = Self.cleanName(name)
        guard !cleaned.isEmpty, let index = curation.tracked.firstIndex(where: { $0.id == id }) else { return }
        var updated = curation
        updated.tracked[index].name = cleaned
        updated.tracked[index].otherNames = Self.cleanOtherNames(otherNames, excluding: cleaned)
        save(curation: updated)
    }

    /// Folds one tracked project into another: its names become the
    /// target's other names, and its note is discarded.
    func merge(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let source = curation.tracked(sourceID),
              let index = curation.tracked.firstIndex(where: { $0.id == targetID }) else { return }
        var updated = curation
        let target = updated.tracked[index]
        updated.tracked[index].otherNames = Self.cleanOtherNames(
            target.otherNames + source.allNames, excluding: target.name)
        updated.tracked.removeAll { $0.id == sourceID }
        save(curation: updated)
        removeSummary(for: sourceID)
    }

    /// Adds a suggestion's name to a tracked project.
    func addName(_ name: String, to id: UUID) {
        guard let project = curation.tracked(id) else { return }
        update(id, name: project.name, otherNames: project.otherNames + [name])
    }

    func stopTracking(_ id: UUID) {
        guard curation.tracked(id) != nil else { return }
        var updated = curation
        updated.tracked.removeAll { $0.id == id }
        save(curation: updated)
        removeSummary(for: id)
    }

    /// "Not a Project": the name is no longer suggested.
    func hideSuggestion(named name: String) {
        let key: String = PeopleDirectory.normalized(name)
        guard !key.isEmpty, !curation.hiddenNames.contains(key) else { return }
        var updated = curation
        updated.hiddenNames.append(key)
        save(curation: updated)
    }

    func restoreHiddenSuggestions() {
        guard !curation.hiddenNames.isEmpty else { return }
        var updated = curation
        updated.hiddenNames = []
        save(curation: updated)
    }

    // MARK: - Where it stands

    enum SummaryState: Equatable {
        case missing
        case current
        /// Newer or changed evidence since the note was written.
        case outdated
    }

    func summaryState(for project: ProjectProfile) -> SummaryState {
        guard let id = project.trackedID, let summary = summaries[id] else { return .missing }
        let evidence = ProjectStatusGenerator.evidence(for: project)
        return summary.evidenceFingerprint == ProjectStatusGenerator.fingerprint(evidence) ? .current : .outdated
    }

    /// Whether an automatic refresh may run for this project's evidence now.
    func shouldWriteAutomatically(_ project: ProjectProfile) -> Bool {
        guard let id = project.trackedID, !writing.contains(id) else { return false }
        let evidence = ProjectStatusGenerator.evidence(for: project)
        guard !evidence.isEmpty, summaryState(for: project) != .current else { return false }
        return !automaticAttempts.contains(id.uuidString + ProjectStatusGenerator.fingerprint(evidence))
    }

    func writeSummary(for project: ProjectProfile, automatic: Bool, location: String,
                      makeEngine: @escaping @MainActor () async throws -> TextEngine) async {
        guard let id = project.trackedID, !writing.contains(id) else { return }
        let evidence = ProjectStatusGenerator.evidence(for: project)
        if automatic { automaticAttempts.insert(id.uuidString + ProjectStatusGenerator.fingerprint(evidence)) }
        writing.insert(id)
        errors[id] = nil
        defer { writing.remove(id) }
        do {
            let engine = try await makeEngine()
            let summary = try await ProjectStatusGenerator.generate(
                evidence: evidence, projectID: id, engine: engine, location: location)
            // The project may have been dropped while the model wrote.
            guard curation.tracked(id) != nil else { return }
            var updated = summaries
            updated[id] = summary
            save(summaries: updated)
        } catch is CancellationError {
            return
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    /// A deleted meeting takes every note that used it along (PRIVACY.md).
    func withdrawSummaries(citing meetingIDs: Set<UUID>) {
        guard !meetingIDs.isEmpty else { return }
        let kept = summaries.filter { $0.value.meetingIDs.allSatisfy { !meetingIDs.contains($0) } }
        guard kept.count != summaries.count else { return }
        save(summaries: kept)
    }

    /// Safety net for meetings removed outside the app's delete path.
    func withdrawSummaries(missingFrom library: Set<UUID>) {
        let cited: Set<UUID> = Set(summaries.values.flatMap(\.meetingIDs))
        withdrawSummaries(citing: cited.subtracting(library))
    }

    private func removeSummary(for id: UUID) {
        guard summaries[id] != nil else { return }
        var updated = summaries
        updated[id] = nil
        save(summaries: updated)
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: curationURL) {
            do {
                curation = try decoder.decode(ProjectCuration.self, from: data)
            } catch {
                lastError = "Could not read tracked projects: \(error.localizedDescription)"
            }
        }
        if let data = try? Data(contentsOf: summariesURL),
           let list = try? decoder.decode([ProjectStatusSummary].self, from: data) {
            let trackedIDs: Set<UUID> = Set(curation.tracked.map(\.id))
            for summary in list where trackedIDs.contains(summary.projectID) { summaries[summary.projectID] = summary }
        }
    }

    private func save(curation updated: ProjectCuration) {
        do {
            try write(updated, to: curationURL)
            curation = updated
            lastError = nil
        } catch {
            lastError = "Could not save tracked projects: \(error.localizedDescription)"
        }
    }

    private func save(summaries updated: [UUID: ProjectStatusSummary]) {
        do {
            let list = updated.values.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
            if list.isEmpty {
                try? FileManager.default.removeItem(at: summariesURL)
            } else {
                try write(list, to: summariesURL)
            }
            summaries = updated
        } catch {
            lastError = "Could not save project summaries: \(error.localizedDescription)"
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cleanName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cleanOtherNames(_ names: [String], excluding name: String) -> [String] {
        var seen: Set<String> = [PeopleDirectory.normalized(name)]
        var result: [String] = []
        for raw in names {
            let cleaned = cleanName(raw)
            let key = PeopleDirectory.normalized(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }
}
