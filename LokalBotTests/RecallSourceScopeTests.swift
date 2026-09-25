import XCTest
@testable import LokalBot

@MainActor
final class RecallSourceScopeTests: XCTestCase {
    func testRemovingOrClearingPinsRestoresPreviousEvidenceBoundary() {
        for original in [nil, Set<Int64>([41, 42])] {
            var state = RecallWorkspaceState()
            state.chooseSources([.meetings])
            state.screenIDs = original
            state.beginPinning()
            state.pins = [ScreenAskContext(hit: .init(snapshotID: 42, ts: Date(), app: "Editor", windowTitle: "Notes", snippet: "Evidence"))]
            state.reconcilePins()
            XCTAssertEqual(state.screenIDs, [42])
            XCTAssertTrue(state.sources.contains(.screen))
            state.removePin(42)
            XCTAssertEqual(state.screenIDs, original)
            XCTAssertEqual(state.sources, [.meetings])

            state.beginPinning()
            state.pins = [ScreenAskContext(hit: .init(snapshotID: 42, ts: Date(), app: "Editor", windowTitle: "Notes", snippet: "Evidence"))]
            state.reconcilePins()
            state.clearPins(restoringScope: true)
            XCTAssertEqual(state.screenIDs, original)
        }
    }

    func testDateFilteringLastPinRestoresScopeWithoutWideningSelectedEvidence() {
        var state = RecallWorkspaceState()
        state.selectEvidence(meetingIDs: [], screenIDs: [41, 42])
        state.beginPinning()
        state.pins = [ScreenAskContext(hit: .init(snapshotID: 42, ts: Date(), app: "Editor", windowTitle: "Notes", snippet: "Evidence"))]
        state.reconcilePins(dateScope: AskDateScope(day: .distantPast))
        XCTAssertTrue(state.pins.isEmpty)
        XCTAssertEqual(state.screenIDs, [41, 42])
        XCTAssertEqual(state.meetingIDs, [])
        XCTAssertEqual(state.sources, [.screen])
    }
    func testClearingResultEvidenceRestoresExplicitSourceChoice() {
        var state = RecallWorkspaceState()
        state.chooseSources([.meetings, .screen])
        state.selectEvidence(meetingIDs: [UUID()], screenIDs: [])
        XCTAssertEqual(state.sources, [.meetings])
        // A second handoff or a restored conversation must retain the original choice.
        state.selectEvidence(meetingIDs: [], screenIDs: [42], sources: [.screen])
        state.clearEvidence()
        XCTAssertEqual(state.sources, [.meetings, .screen])
        XCTAssertNil(state.meetingIDs)
        XCTAssertNil(state.screenIDs)
        XCTAssertNil(state.sourcesBeforeEvidence)
    }

    func testSourceChoiceDuringReviewSupersedesTheEarlierChoice() {
        var state = RecallWorkspaceState()
        state.selectEvidence(meetingIDs: [UUID()], screenIDs: [])
        state.chooseSources([.meetings, .today])
        state.clearEvidence()
        XCTAssertEqual(state.sources, [.meetings, .today])
    }

    func testUnboundedHandoffRestoresScopeWithoutGrantingExtraSources() {
        var state = RecallWorkspaceState()
        state.chooseSources([.screen])
        state.selectEvidence(meetingIDs: [UUID()], screenIDs: nil)
        state.selectEvidence(meetingIDs: nil, screenIDs: nil)
        XCTAssertEqual(state.sources, [.screen])
    }

    func testSearchHonorsSourcesAndExplicitEvidenceBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-scope-\(UUID())")
        let previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Redis review", startedAt: Date(),
                  summary: "Redis decision", transcriptLines: ["Redis was selected."])
        ], under: root)
        let app = AppState()
        let meetings = app.storage.loadMeetings()
        app.searchIndex.reindexAll(meetings, storage: app.storage)
        let screenID = try app.activityStore.insertScreenshot(
            ts: Date(), path: "/tmp/synthetic-screen.enc", app: "Editor",
            windowTitle: "Redis notes", ocr: "Redis evidence")
        var state = RecallWorkspaceState()
        state.sources = [.meetings]
        let meetingResult = await RecallSearch.search("Redis", state: state, dateScope: nil, app: app)
        XCTAssertEqual(meetingResult.meetings.map(\.id), [meetingID])
        XCTAssertTrue(meetingResult.screens.isEmpty)

        state.sources = [.screen]
        let screenResult = await RecallSearch.search("Redis", state: state, dateScope: nil, app: app)
        XCTAssertTrue(screenResult.meetings.isEmpty)
        XCTAssertEqual(screenResult.screens.flatMap(\.matches).map(\.snapshotID), [screenID])

        state.sources = [.today]
        let activityResult = await RecallSearch.search("Redis", state: state, dateScope: nil, app: app)
        XCTAssertTrue(activityResult.meetings.isEmpty)
        XCTAssertTrue(activityResult.screens.isEmpty)

        state.sources = [.meetings, .screen]
        state.meetingIDs = []
        state.screenIDs = []
        let bounded = await RecallSearch.search("Redis", state: state, dateScope: nil, app: app)
        XCTAssertTrue(bounded.meetings.isEmpty, "An empty reviewed scope must not widen to the library")
        XCTAssertTrue(bounded.screens.isEmpty)

        app.recallState = state
        app.askDayScope = Date.distantPast
        let quickRecall = await RecallSearch.search("Redis", state: RecallWorkspaceState(), dateScope: nil, app: app)
        XCTAssertEqual(quickRecall.meetings.map(\.id), [meetingID])
        XCTAssertEqual(quickRecall.screens.flatMap(\.matches).map(\.snapshotID), [screenID])
        XCTAssertEqual(app.recallState.meetingIDs, [], "Quick Recall must not mutate the full workspace scope")
    }
}
