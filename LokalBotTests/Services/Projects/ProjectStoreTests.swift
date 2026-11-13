import XCTest
@testable import LokalBot

private struct NoteEngine: TextEngine {
    var displayName: String { "Stub" }
    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        #"{"overview": "The pilot passed review.", "points": [{"text": "Passed review.", "source": "M1"}], "open_questions": []}"#
    }
}

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("projects", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func project(_ id: UUID, meetingID: UUID = UUID(), line: String = "Larkspur pilot passed review.") -> ProjectProfile {
        ProjectProfile(
            id: "tracked:" + id.uuidString, name: "Larkspur", kind: .tracked(id), otherNames: [],
            meetings: [.init(id: meetingID, title: "Product Standup", startedAt: Date(),
                             mentions: [.init(text: line, seek: nil)])],
            myActions: [], othersActions: [], olderOthersActions: [], decisions: [], reviewNotes: [],
            days: [], windows: [], people: [], lastActive: nil)
    }

    func testTrackingRenamingMergingAndHidingPersist() throws {
        let store = ProjectStore(directory: directory)
        let larkspur = try XCTUnwrap(store.track(name: "  Larkspur  "))
        XCTAssertEqual(store.track(name: "larkspur"), larkspur, "The same name is not tracked twice")
        let spike = try XCTUnwrap(store.track(name: "Larkspur pilot", otherNames: ["Heron vault", "larkspur pilot", " "]))
        XCTAssertEqual(store.curation.tracked(spike)?.otherNames, ["Heron vault"])

        store.update(larkspur, name: "Larkspur platform", otherNames: ["Larkspur"])
        store.merge(spike, into: larkspur)
        store.hideSuggestion(named: "Labs")
        store.hideSuggestion(named: "labs")

        let reloaded = ProjectStore(directory: directory)
        XCTAssertEqual(reloaded.curation.tracked.map(\.name), ["Larkspur platform"])
        XCTAssertEqual(reloaded.curation.tracked.first?.otherNames, ["Larkspur", "Larkspur pilot", "Heron vault"])
        XCTAssertEqual(reloaded.curation.hiddenNames, ["labs"])
        XCTAssertTrue(reloaded.curation.isHidden("LABS"))
        XCTAssertEqual(reloaded.curation.trackedProject(named: "heron vault")?.id, larkspur)
        XCTAssertEqual(ProjectCuration.load(libraryRoot: root)?.trackedNames,
                       ["Larkspur platform", "Larkspur", "Larkspur pilot", "Heron vault"])
        XCTAssertNil(ProjectCuration.load(libraryRoot: root.appendingPathComponent("missing")))

        // Tracking a hidden name brings it back.
        _ = reloaded.track(name: "Labs")
        XCTAssertFalse(reloaded.curation.isHidden("Labs"))
        reloaded.stopTracking(larkspur)
        XCTAssertEqual(reloaded.curation.tracked.map(\.name), ["Labs"])
    }

    func testNotesAreWithdrawnWithTheirMeetingsAndProjects() async throws {
        let store = ProjectStore(directory: directory)
        let id = try XCTUnwrap(store.track(name: "Larkspur"))
        let meetingID = UUID()
        let profile = project(id, meetingID: meetingID)
        XCTAssertEqual(store.summaryState(for: profile), .missing)

        await store.writeSummary(for: profile, automatic: false, location: "this Mac") { NoteEngine() }
        XCTAssertEqual(store.summaries[id]?.overview, "The pilot passed review.")
        XCTAssertEqual(store.summaries[id]?.points.first?.meetingID, meetingID)
        XCTAssertEqual(store.summaryState(for: profile), .current)
        XCTAssertEqual(store.summaryState(for: project(id, meetingID: meetingID, line: "Larkspur is paused.")), .outdated)
        XCTAssertEqual(ProjectStore(directory: directory).summaries[id]?.overview, "The pilot passed review.")

        store.withdrawSummaries(missingFrom: [meetingID])
        XCTAssertNotNil(store.summaries[id])
        store.withdrawSummaries(citing: [meetingID])
        XCTAssertNil(store.summaries[id])
        XCTAssertNil(ProjectStore(directory: directory).summaries[id])

        await store.writeSummary(for: profile, automatic: false, location: "this Mac") { NoteEngine() }
        store.stopTracking(id)
        XCTAssertNil(store.summaries[id])
    }

    func testAutomaticWritesTryEachEvidenceOnce() async throws {
        let store = ProjectStore(directory: directory)
        let id = try XCTUnwrap(store.track(name: "Larkspur"))
        let profile = project(id)
        XCTAssertTrue(store.shouldWriteAutomatically(profile))

        struct FailingEngine: Error {}
        await store.writeSummary(for: profile, automatic: true, location: "this Mac") { throw FailingEngine() }
        XCTAssertNotNil(store.errors[id])
        XCTAssertFalse(store.shouldWriteAutomatically(profile), "A failed automatic write is not retried on every visit")
        XCTAssertTrue(store.shouldWriteAutomatically(project(id, line: "Larkspur is paused.")))
    }
}
