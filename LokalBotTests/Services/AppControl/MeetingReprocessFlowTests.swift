import XCTest
@testable import LokalBot

@MainActor
final class MeetingReprocessFlowTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?
    private var app: AppState!
    private var gate: SettingsControlGate!
    private var handler: AppControlHandler!
    private var transcribed: Meeting!
    private var recordingOnly: Meeting!
    private let agent = AppControlPeer(pid: 42, description: "lokalbot-cli via claude")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-reprocess-flow-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let storage = StorageManager(rootURL: library)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        transcribed = Meeting(
            id: UUID(uuidString: "FB709013-0000-4000-8000-000000000001")!,
            title: "Pricing review", appName: "Zoom",
            startedAt: started, endedAt: started.addingTimeInterval(1260),
            relativePath: try storage.reserveMeetingFolder(title: "Pricing review", startedAt: started))
        try storage.saveMeta(transcribed)
        let transcript = Transcript(segments: [
            .init(start: 0, end: 4, speaker: "me", text: "Let's keep the Team plan at fifteen per seat.", confidence: nil),
        ], engine: "fixture")
        try JSONEncoder().encode(transcript).write(
            to: transcribed.folderURL(in: storage).appendingPathComponent("transcript.json"))
        recordingOnly = Meeting(
            id: UUID(uuidString: "0A11CE00-0000-4000-8000-000000000002")!,
            title: "Hiring sync", appName: "Zoom",
            startedAt: started.addingTimeInterval(-86_400), endedAt: started.addingTimeInterval(-85_000),
            relativePath: try storage.reserveMeetingFolder(title: "Hiring sync", startedAt: started.addingTimeInterval(-86_400)))
        try storage.saveMeta(recordingOnly)

        previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", library.path, 1)
        app = AppState()
        app.settings = AppSettings()
        app.pipeline.setCaptureActive(true)
        gate = SettingsControlGate(root: app.storage.rootURL)
        try gate.enable()
        handler = AppControlHandler(app: app, gate: gate)
    }

    override func tearDown() async throws {
        await app.pipeline.forget(meetingIDs: [transcribed.id, recordingOnly.id])
        gate.disable()
        app.settings = AppSettings()
        handler = nil
        gate = nil
        app = nil
        if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private func send(_ method: AppControlProtocol.Method, _ params: [String: JSONValue]) async -> AppControlResponse {
        await handler.handle(AppControlRequest(method: method, params: params), from: agent)
    }

    func testSummarizeAgainQueuesTheMeetingByItsShortID() async throws {
        let response = await send(.meetingsReprocess, ["id": "fb709013"])

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["id"], "fb709013")
        XCTAssertEqual(response.result?["title"], "Pricing review")
        XCTAssertEqual(response.result?["state"], "queued")
        XCTAssertEqual(app.pipeline.stages[transcribed.id], .queued)

        let status = await send(.meetingsProcessing, ["id": "fb709013"])
        XCTAssertNil(status.error)
        XCTAssertEqual(status.result?["state"], "queued")
        XCTAssertEqual(status.result?["message"], "Queued…")
    }

    func testLatestPicksTheMostRecentMeeting() async throws {
        let response = await send(.meetingsReprocess, ["id": "latest"])

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["id"], "fb709013")
        XCTAssertEqual(app.pipeline.stages[transcribed.id], .queued)
    }

    func testAMeetingWithoutATranscriptNeedsTranscribeFirst() async throws {
        let summarizeOnly = await send(.meetingsReprocess, ["id": "0a11ce00"])
        XCTAssertEqual(summarizeOnly.error?.code, "invalid_request")
        XCTAssertNil(app.pipeline.stages[recordingOnly.id], "nothing is queued for a meeting it can't summarize")

        let transcribe = await send(.meetingsReprocess, ["id": "0a11ce00", "transcribe": true])
        XCTAssertNil(transcribe.error)
        XCTAssertEqual(transcribe.result?["state"], "queued")
    }

    func testRejectsUnknownMeetingsAndEmptyWork() async throws {
        let unknown = await send(.meetingsReprocess, ["id": "deadbeef"])
        XCTAssertEqual(unknown.error?.code, "unknown_meeting")
        let missing = await send(.meetingsReprocess, [:])
        XCTAssertEqual(missing.error?.code, "invalid_request")
        let nothing = await send(.meetingsReprocess, ["id": "fb709013", "summarize": false])
        XCTAssertEqual(nothing.error?.code, "invalid_request")
        let notAFlag = await send(.meetingsReprocess, ["id": "fb709013", "transcribe": "yes"])
        XCTAssertEqual(notAFlag.error?.code, "invalid_request")
        XCTAssertNil(app.pipeline.stages[transcribed.id])
    }

    func testAnIdleMeetingReportsWhenItsNotesWereSaved() async throws {
        let folder = transcribed.folderURL(in: app.storage)
        try Data("# Pricing review\n".utf8).write(to: folder.appendingPathComponent("summary.md"))

        let status = await send(.meetingsProcessing, ["id": "fb709013"])

        XCTAssertEqual(status.result?["state"], "idle")
        XCTAssertNil(status.result?["message"])
        XCTAssertNotNil(status.result?["notesSavedAt"]?.stringValue)
    }

    func testNeedsSettingsAccess() async throws {
        gate.disable()

        let response = await send(.meetingsReprocess, ["id": "fb709013"])

        XCTAssertEqual(response.error?.code, "settings_access_disabled")
        XCTAssertNil(app.pipeline.stages[transcribed.id])
    }
}
