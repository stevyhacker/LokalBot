import XCTest
@testable import LokalBot

@MainActor
final class RecallSourceScopeTests: XCTestCase {
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
        let meetingResult = await RecallSearch.search("Redis", state: state, day: nil, app: app)
        XCTAssertEqual(meetingResult.meetings.map(\.id), [meetingID])
        XCTAssertTrue(meetingResult.screens.isEmpty)

        state.sources = [.screen]
        let screenResult = await RecallSearch.search("Redis", state: state, day: nil, app: app)
        XCTAssertTrue(screenResult.meetings.isEmpty)
        XCTAssertEqual(screenResult.screens.flatMap(\.matches).map(\.snapshotID), [screenID])

        state.sources = [.today]
        let activityResult = await RecallSearch.search("Redis", state: state, day: nil, app: app)
        XCTAssertTrue(activityResult.meetings.isEmpty)
        XCTAssertTrue(activityResult.screens.isEmpty)

        state.sources = [.meetings, .screen]
        state.meetingIDs = []
        state.screenIDs = []
        let bounded = await RecallSearch.search("Redis", state: state, day: nil, app: app)
        XCTAssertTrue(bounded.meetings.isEmpty, "An empty reviewed scope must not widen to the library")
        XCTAssertTrue(bounded.screens.isEmpty)
    }
}
