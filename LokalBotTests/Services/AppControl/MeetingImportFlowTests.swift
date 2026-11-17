import XCTest
@testable import LokalBot

/// `lokalbot-cli import` end to end over the control socket: the app reads
/// the files itself, a dry run or a plan with nothing new answers with
/// counts, and anything else waits for the person. Runs against a real
/// `AppState` in a temporary library with a synthetic Otter export.
@MainActor
final class MeetingImportFlowTests: XCTestCase {
    private var root: URL!
    private var exports: URL!
    private var previousRoot: String?
    private var app: AppState!
    private var gate: SettingsControlGate!
    private var handler: AppControlHandler!
    private let agent = AppControlPeer(pid: 42, description: "lokalbot-cli via claude")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-import-flow-\(UUID().uuidString)", isDirectory: true)
        exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("""
            1
            00:00:01,000 --> 00:00:04,000
            Ana: Let's keep the Team plan at fifteen per seat.

            2
            00:00:05,000 --> 00:00:07,000
            Leo: Billed annually.
            """.utf8).write(to: exports.appendingPathComponent("Pricing review.srt"))
        previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.appendingPathComponent("library").path, 1)
        app = AppState()
        app.settings = AppSettings()
        gate = SettingsControlGate(root: app.storage.rootURL)
        try gate.enable()
        handler = AppControlHandler(app: app, gate: gate)
    }

    override func tearDown() async throws {
        gate.disable()
        app.settings = AppSettings()
        handler = nil
        gate = nil
        app = nil
        if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private func importRequest(dryRun: Bool = false, paths: [String]? = nil) async -> AppControlResponse {
        var params: [String: JSONValue] = [
            "source": "otter",
            "paths": .array((paths ?? [exports.path]).map(JSONValue.string)),
        ]
        if dryRun { params["dryRun"] = true }
        return await handler.handle(AppControlRequest(method: .meetingsImport, params: params), from: agent)
    }

    private func importedMeetings() -> [Meeting] {
        app.meetings.filter { $0.importSource?.app == "otter" }
    }

    private func waitForImport() async throws {
        for _ in 0..<200 where importedMeetings().isEmpty || !app.importingRecordings.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testDryRunCountsWithoutAskingOrWriting() async throws {
        let response = await importRequest(dryRun: true)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["newMeetings"]?.intValue, 1)
        XCTAssertEqual(response.result?["dryRun"], true)
        XCTAssertEqual(response.result?["imported"], false)
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
        XCTAssertTrue(importedMeetings().isEmpty)
    }

    func testImportWaitsForApprovalThenSkipsWhatItAlreadyHas() async throws {
        let response = await importRequest()
        XCTAssertEqual(response.error?.code, "needs_approval")
        let id = try XCTUnwrap(UUID(uuidString: response.error?.details?["id"]?.stringValue ?? ""))
        XCTAssertTrue(importedMeetings().isEmpty, "nothing is imported before the person approves")
        let pending = try XCTUnwrap(app.settingsApprovals.request(id))
        XCTAssertEqual(pending.subject, .meetingImport(.init(source: .otter, paths: [exports.path])))
        XCTAssertEqual(pending.changes.first?["newMeetings"]?.intValue, 1)
        XCTAssertEqual(pending.caller, "lokalbot-cli via claude")

        try app.approveSettingsRequest(id)
        try await waitForImport()

        let meeting = try XCTUnwrap(importedMeetings().first)
        XCTAssertEqual(importedMeetings().count, 1)
        XCTAssertEqual(meeting.appName, "Otter")
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(
            contentsOf: meeting.folderURL(in: app.storage).appendingPathComponent("transcript.json")))
        XCTAssertEqual(Set(transcript.speakerAliases.values), ["Ana", "Leo"])
        XCTAssertEqual(app.settingsApprovals.request(id)?.state, .approved)

        let again = await importRequest()
        XCTAssertNil(again.error, "a plan with nothing new doesn't ask the person")
        XCTAssertEqual(again.result?["newMeetings"]?.intValue, 0)
        XCTAssertEqual(again.result?["alreadyImported"]?.intValue, 1)
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
    }

    func testDenyingImportsNothing() async throws {
        let response = await importRequest()
        let id = try XCTUnwrap(UUID(uuidString: response.error?.details?["id"]?.stringValue ?? ""))
        app.settingsApprovals.deny(id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(importedMeetings().isEmpty)
        XCTAssertEqual(app.settingsApprovals.request(id)?.state, .denied)
    }

    func testRequestsMustNameASourceAndAbsolutePaths() async {
        let relative = await importRequest(paths: ["exports/Pricing review.srt"])
        XCTAssertEqual(relative.error?.code, "invalid_request")
        let unknown = await handler.handle(AppControlRequest(method: .meetingsImport, params: [
            "source": "notes-app", "paths": .array([.string(exports.path)]),
        ]), from: agent)
        XCTAssertEqual(unknown.error?.code, "invalid_request")
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
    }

    func testTheSettingsGrantIsRequired() async {
        gate.disable()
        let response = await importRequest(dryRun: true)
        XCTAssertEqual(response.error?.code, "settings_access_disabled")
    }
}
