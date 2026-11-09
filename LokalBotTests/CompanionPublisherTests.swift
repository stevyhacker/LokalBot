import XCTest
@testable import LokalBot

/// The publisher keeps the host's records equal to what the library shares:
/// it publishes everything, withdraws what disappeared, and rebuilds only
/// what a change touched.
final class CompanionPublisherTests: XCTestCase {
    private var fixture: CompanionFixtureLibrary!
    private var sink: InMemoryCompanionSink!

    override func setUpWithError() throws {
        fixture = try CompanionFixtureLibrary.make()
        sink = InMemoryCompanionSink()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        sink = nil
    }

    private func publisher(_ sharing: CompanionSharing = CompanionSharing()) -> CompanionPublisher {
        CompanionPublisher(
            sink: sink,
            context: .init(root: fixture.root, activityDatabaseURL: fixture.activityDatabaseURL,
                           sharing: sharing, macName: "Test Mac"),
            calendar: fixture.calendar, debounce: .milliseconds(1), clock: { [now = fixture.now] in now })
    }

    private var designKey: String { fixture.designReview.id.uuidString.lowercased() }

    func testReconcilePublishesEveryRecordAndTheManifest() {
        let publisher = publisher()
        publisher.reconcileAll()
        let report = publisher.flush()
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.published, report.changed)
        XCTAssertNotNil(sink.body(.meeting, designKey))
        XCTAssertNotNil(sink.body(.transcript, designKey))
        XCTAssertNotNil(sink.body(.day, fixture.dayKey))
        XCTAssertFalse(sink.records["person", default: [:]].isEmpty)
        XCTAssertNotNil(sink.manifest)

        // Identical bodies are no-ops on the host.
        publisher.reconcileAll()
        XCTAssertEqual(publisher.flush().changed, 0)
    }

    func testNarrowingTheScopeWithdrawsRecords() {
        let publisher = publisher()
        publisher.reconcileAll()
        publisher.flush()
        let olderKey = fixture.olderMeeting.id.uuidString.lowercased()
        XCTAssertNotNil(sink.body(.meeting, olderKey))

        var sharing = CompanionSharing(history: .days30)
        sharing.dataClasses.transcripts = false
        publisher.update(context: .init(root: fixture.root, activityDatabaseURL: fixture.activityDatabaseURL,
                                        sharing: sharing, macName: "Test Mac"))
        let report = publisher.flush()
        XCTAssertGreaterThan(report.removed, 0)
        XCTAssertNil(sink.body(.meeting, olderKey), "out-of-window meetings become tombstones")
        XCTAssertNil(sink.body(.transcript, designKey), "a class turned off is withdrawn")
        XCTAssertNotNil(sink.body(.meeting, designKey))
        XCTAssertTrue(sink.tombstones.contains { $0.kind == "transcript" && $0.key == designKey })
    }

    func testDeletedMeetingBecomesATombstone() throws {
        let publisher = publisher()
        publisher.reconcileAll()
        publisher.flush()
        let storage = StorageManager(rootURL: fixture.root)
        try FileManager.default.removeItem(at: fixture.designReview.folderURL(in: storage))

        publisher.meetingsChanged([fixture.designReview.id], days: [fixture.designReview.startedAt])
        publisher.flush()
        XCTAssertNil(sink.body(.meeting, designKey))
        XCTAssertNil(sink.body(.transcript, designKey))
        let day = try XCTUnwrap(sink.body(.day, fixture.dayKey))
        XCTAssertFalse((day["meetingIds"] as? [String] ?? []).contains(designKey))
    }

    func testStatusChangeIsRepublishedBeforeReturning() throws {
        let publisher = publisher()
        publisher.reconcileAll()
        publisher.flush()
        let folder = fixture.designReview.folderURL(in: StorageManager(rootURL: fixture.root))
        var state = MeetingOutcomeStore.loadState(from: folder)
        state.actions["act-deck"] = .init(status: .done, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: folder)

        XCTAssertTrue(publisher.republishNow(meetingID: fixture.designReview.id))
        let meeting = try XCTUnwrap(sink.body(.meeting, designKey))
        let actions = try XCTUnwrap(meeting["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.first { $0["id"] as? String == "act-deck" }?["status"] as? String, "done")
    }
}
