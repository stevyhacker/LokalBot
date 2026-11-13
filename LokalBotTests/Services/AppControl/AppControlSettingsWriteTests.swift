import XCTest
@testable import LokalBot

/// `settings.set` against a real `AppState`: what applies, what is refused,
/// and that the audit log and Undo see every applied change.
@MainActor
final class AppControlSettingsWriteTests: XCTestCase {
    private var app: AppState!
    private var gate: SettingsControlGate!
    private var handler: AppControlHandler!
    private let agent = AppControlPeer(pid: 42, description: "lokalbot-cli via claude")

    override func setUp() async throws {
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
    }

    private func set(_ changes: [String: JSONValue] = [:], reset: [String] = [], dryRun: Bool = false) async -> AppControlResponse {
        await handler.handle(
            AppControlRequest(method: .settingsSet, params: SettingsChangeRequest(changes: changes, reset: reset, dryRun: dryRun).params),
            from: agent)
    }

    func testAppliesPreferencesAndRecordsTheCaller() async {
        let response = await set(["noteTemplate": "lecture", "dayDigestHour": 20])
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["applied"], true)
        XCTAssertEqual(app.settings.noteTemplate, .lecture)
        XCTAssertEqual(app.settings.dayDigestHour, 20)
        let recent = app.agentSettingsChanges.recent.prefix(2)
        XCTAssertEqual(Set(recent.map(\.key)), ["noteTemplate", "dayDigestHour"])
        XCTAssertTrue(recent.allSatisfy { $0.caller == "lokalbot-cli via claude" })
    }

    func testWideningChangesWaitForApprovalAndApplyNothing() async {
        let response = await set(["noteTemplate": "lecture", "screenContextCaptureMode": "visualContext"])
        XCTAssertEqual(response.error?.code, "needs_approval")
        guard case .array(let changes)? = response.error?.details?["changes"] else { return XCTFail("no changes") }
        XCTAssertEqual(Set(changes.compactMap { $0["key"]?.stringValue }), ["noteTemplate", "screenContextCaptureMode"])
        XCTAssertEqual(response.error?.details?["state"], "pending")
        XCTAssertEqual(app.settingsApprovals.pending.count, 1)
        XCTAssertEqual(app.settings.noteTemplate, .meeting)
        XCTAssertEqual(app.settings.screenContextCaptureMode, .activityOnly)
    }

    func testNarrowingAppliesWithTheSameCouplingsAsSettings() async {
        var settings = app.settings
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .visualContext
        settings.screenshotsEnabled = true
        app.settings = settings

        let lowered = await set(["screenContextCaptureMode": "accessibleText"])
        XCTAssertNil(lowered.error)
        XCTAssertEqual(app.settings.screenContextCaptureMode, .accessibleText)
        XCTAssertFalse(app.settings.screenshotsEnabled)

        let off = await set(["trackingEnabled": false])
        XCTAssertNil(off.error)
        XCTAssertFalse(app.settings.trackingEnabled)
        XCTAssertEqual(app.settings.screenContextCaptureMode, .activityOnly)
    }

    func testDreamingKeepsItsStartDayInStep() async {
        _ = await set(["dreamingEnabled": false])
        XCTAssertFalse(app.settings.dreamingEnabled)
        XCTAssertNil(app.settings.dreamingFirstEligibleDayKey)
        _ = await set(["dreamingEnabled": true])
        XCTAssertTrue(app.settings.dreamingEnabled)
        XCTAssertEqual(app.settings.dreamingFirstEligibleDayKey, AppState.dreamingFirstEligibleDayKey(enabled: true))
    }

    func testRejectsReadOnlyInvalidAndUnknownKeys() async {
        let readOnly = await set(["customBuiltInModels": [["id": "x"]]])
        XCTAssertEqual(readOnly.error?.code, "read_only")
        let range = await set(["dayDigestHour": 30])
        XCTAssertEqual(range.error?.code, "invalid_value")
        let decoder = await set(["transcriptionLanguage": "not-a-language"])
        XCTAssertEqual(decoder.error?.code, "invalid_value")
        let unknown = await set(["noSuchSetting": true])
        XCTAssertEqual(unknown.error?.code, "unknown_key")
        XCTAssertEqual(app.settings, AppSettings())
    }

    func testDryRunReportsWithoutChanging() async {
        let response = await set(["noteTemplate": "lecture", "trackingEnabled": false], dryRun: true)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["applied"], false)
        XCTAssertEqual(response.result?["dryRun"], true)
        XCTAssertEqual(app.settings.noteTemplate, .meeting)
        XCTAssertTrue(app.settings.trackingEnabled)
    }

    func testResetRestoresDefaults() async {
        var settings = app.settings
        settings.dayDigestHour = 21
        app.settings = settings
        let response = await set(reset: ["dayDigestHour"])
        XCTAssertNil(response.error)
        XCTAssertEqual(app.settings.dayDigestHour, AppSettings().dayDigestHour)
    }

    func testUndoRestoresTheEarlierValueOnce() async throws {
        _ = await set(["noteTemplate": "podcast"])
        let entry = try XCTUnwrap(app.agentSettingsChanges.recent.first { $0.key == "noteTemplate" })
        XCTAssertTrue(app.agentSettingsChanges.canUndo(entry, in: app.settings))
        try app.agentSettingsChanges.undo(entry, in: app)
        XCTAssertEqual(app.settings.noteTemplate, .meeting)
        XCTAssertFalse(app.agentSettingsChanges.canUndo(entry, in: app.settings))
        XCTAssertEqual(app.agentSettingsChanges.recent.first?.caller, "You (Undo)")
    }

    func testStatusReportsModelsAndOnboarding() async throws {
        let status = await handler.handle(AppControlRequest(method: .status))
        let result = try XCTUnwrap(status.result)
        XCTAssertNotNil(result["models"]?["meetingReady"])
        XCTAssertNotNil(result["models"]?["roles"]?["transcribe"]?["state"])
        XCTAssertNotNil(result["onboarding"]?["completed"])
    }

    func testOpenRefusesUnknownSections() async {
        let response = await handler.handle(AppControlRequest(
            method: .open, params: ["target": "settings", "key": "noSuchSection"]))
        XCTAssertEqual(response.error?.code, "unknown_key")
    }
}

@MainActor
final class AgentSettingsChangesTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-agent-changes-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLogSurvivesReloadAndIsPrivate() throws {
        let changes = AgentSettingsChanges(root: root)
        let spec = try XCTUnwrap(SettingRegistry.spec(for: "noteTemplate"))
        changes.record([SettingsChangePlan.Item(spec: spec, previous: "meeting", stored: "lecture", change: .preference)],
                       caller: "lokalbot-cli")
        XCTAssertEqual(changes.recent.first?.value, "lecture")

        let reloaded = AgentSettingsChanges(root: root)
        XCTAssertEqual(reloaded.recent.first?.key, "noteTemplate")
        XCTAssertEqual(reloaded.recent.first?.previous, "meeting")
        let attributes = try FileManager.default.attributesOfItem(atPath: reloaded.logURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRecentListIsBounded() throws {
        let changes = AgentSettingsChanges(root: root)
        let spec = try XCTUnwrap(SettingRegistry.spec(for: "dayDigestHour"))
        for hour in 0..<(AgentSettingsChanges.recentLimit + 5) {
            changes.record([SettingsChangePlan.Item(spec: spec, previous: 18, stored: .number(Double(hour % 24)), change: .preference)],
                           caller: "lokalbot-cli")
        }
        XCTAssertEqual(changes.recent.count, AgentSettingsChanges.recentLimit)
        XCTAssertEqual(AgentSettingsChanges(root: root).recent.count, AgentSettingsChanges.recentLimit)
    }
}
