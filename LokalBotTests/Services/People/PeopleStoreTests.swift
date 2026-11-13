import XCTest
@testable import LokalBot

@MainActor
final class PeopleStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent(PeopleCuration.directoryName, isDirectory: true) }
    private var file: URL { directory.appendingPathComponent(PeopleCuration.fileName) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeopleStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func person(_ id: String, _ name: String, members: [String] = []) -> PersonProfile {
        PersonProfile(id: id, name: name, otherNames: [], memberIDs: [id] + members, meetings: [],
                      theirActions: [], myActions: [], decisions: [])
    }

    func testRenamingMergingAndHidingPersistPrivately() throws {
        let store = PeopleStore(directory: directory)
        let mila = person("person-a", "Mila N")
        let novak = person("person-b", "Mila Novak")

        store.rename(mila, to: "  Mila   Nováková ")
        XCTAssertEqual(store.chosenName(for: mila), "Mila Nováková")
        store.merge(mila, into: novak)
        XCTAssertNil(store.chosenName(for: mila), "The target keeps its own name")
        store.hide(person("person-c", "Room Mic"))

        let reloaded = PeopleStore(directory: directory)
        XCTAssertEqual(reloaded.curation.merges, [.init(sourceID: "person-a", targetID: "person-b", sourceName: "Mila N")])
        XCTAssertEqual(reloaded.curation.hidden.map(\.name), ["Room Mic"])
        XCTAssertEqual(PeopleCuration.load(libraryRoot: root), reloaded.curation)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        // After the merge, the target carries the source's id.
        let merged = person("person-b", "Mila Novak", members: ["person-a"])
        XCTAssertEqual(reloaded.merges(into: merged).map(\.sourceName), ["Mila N"])
        XCTAssertTrue(reloaded.merges(into: novak).isEmpty)
    }

    func testUndoingEverythingRemovesTheFile() throws {
        let store = PeopleStore(directory: directory)
        let ana = person("person-a", "Ana")
        store.rename(ana, to: "Ana Petrović")
        store.hide(person("person-b", "Speakerphone"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.rename(ana, to: " ")
        store.restoreHidden()
        XCTAssertTrue(store.curation.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSeparatingAMergeRemovesOnlyThatMerge() {
        let store = PeopleStore(directory: directory)
        let target = person("person-t", "Ana Petrović")
        store.merge(person("person-a", "Ana P"), into: target)
        store.merge(person("person-b", "Anica"), into: target)
        let merged = person("person-t", "Ana Petrović", members: ["person-a", "person-b"])

        store.separate(store.merges(into: merged)[0])
        XCTAssertEqual(store.curation.merges.map(\.sourceName), ["Anica"])
    }
}
