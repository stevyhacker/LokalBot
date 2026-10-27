import Foundation

/// The person's corrections in People — chosen names, merges, and entries
/// hidden as not a person — saved as `people/curation.json` in the library.
/// A small JSON file, written on the main actor.
@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var curation = PeopleCuration()
    @Published private(set) var lastError: String?

    let directory: URL

    init(directory: URL) {
        self.directory = directory
        load()
    }

    private var curationURL: URL { directory.appendingPathComponent(PeopleCuration.fileName) }

    // MARK: - Names

    func chosenName(for person: PersonProfile) -> String? {
        person.memberIDs.lazy.compactMap { self.curation.names[$0] }.first
    }

    /// Shows the person under a name of the person's choosing. An empty
    /// name goes back to the name from meetings.
    func rename(_ person: PersonProfile, to name: String) {
        let cleaned: String = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var updated = curation
        for id in person.memberIDs + [person.id] { updated.names[id] = nil }
        if !PeopleDirectory.normalized(cleaned).isEmpty { updated.names[person.id] = cleaned }
        save(updated)
    }

    // MARK: - Merges

    /// Folds one person into another; the target keeps its name.
    func merge(_ source: PersonProfile, into target: PersonProfile) {
        guard source.id != target.id else { return }
        var updated = curation
        for id in source.memberIDs + [source.id] { updated.names[id] = nil }
        updated.merges.append(.init(sourceID: source.id, targetID: target.id, sourceName: source.name))
        save(updated)
    }

    /// Merges the person chose that folded someone into this person.
    func merges(into person: PersonProfile) -> [PeopleCuration.Merge] {
        let ids = Set(person.memberIDs + [person.id])
        return curation.merges.filter { ids.contains($0.targetID) && ids.contains($0.sourceID) }
    }

    func separate(_ merge: PeopleCuration.Merge) {
        var updated = curation
        updated.merges.removeAll { $0 == merge }
        save(updated)
    }

    // MARK: - Hidden

    /// "Not a Person": the entry no longer appears in People, Projects, or
    /// the CLI.
    func hide(_ person: PersonProfile) {
        guard !curation.isHidden(person.id) else { return }
        var updated = curation
        updated.hidden.append(.init(id: person.id, name: person.name))
        save(updated)
    }

    func restoreHidden() {
        guard !curation.hidden.isEmpty else { return }
        var updated = curation
        updated.hidden = []
        save(updated)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: curationURL) else { return }
        do {
            curation = try JSONDecoder().decode(PeopleCuration.self, from: data)
        } catch {
            lastError = "Could not read People corrections: \(error.localizedDescription)"
        }
    }

    private func save(_ updated: PeopleCuration) {
        do {
            let fileManager = FileManager.default
            if updated.isEmpty {
                try? fileManager.removeItem(at: curationURL)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                try encoder.encode(updated).write(to: curationURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: curationURL.path)
            }
            curation = updated
            lastError = nil
        } catch {
            lastError = "Could not save People corrections: \(error.localizedDescription)"
        }
    }
}
