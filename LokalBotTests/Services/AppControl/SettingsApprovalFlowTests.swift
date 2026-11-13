import XCTest
@testable import LokalBot

/// Requests that wait for the person: what the reply says, what Approve and
/// Deny do, retention reviews, and write-only API keys. Runs against a real
/// `AppState` in a temporary library.
@MainActor
final class SettingsApprovalFlowTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?
    private var app: AppState!
    private var gate: SettingsControlGate!
    private var handler: AppControlHandler!
    private var keychain: [String: String] = [:]
    private let agent = AppControlPeer(pid: 42, description: "lokalbot-cli via claude")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-approvals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        app = AppState()
        app.settings = AppSettings()
        keychain = [:]
        app.agentSecrets = AgentSecretStore(
            read: { [unowned self] in keychain[$0] },
            write: { [unowned self] account, value in
                keychain[account] = value
                return true
            })
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

    private func send(_ method: AppControlProtocol.Method, _ params: [String: JSONValue]) async -> AppControlResponse {
        await handler.handle(AppControlRequest(method: method, params: params), from: agent)
    }

    private func set(_ changes: [String: JSONValue]) async -> AppControlResponse {
        await send(.settingsSet, SettingsChangeRequest(changes: changes).params)
    }

    private func requestID(_ response: AppControlResponse) throws -> UUID {
        XCTAssertEqual(response.error?.code, "needs_approval")
        return try XCTUnwrap(UUID(uuidString: response.error?.details?["id"]?.stringValue ?? ""))
    }

    func testApprovingAppliesTheWholeRequestAndRecordsTheCaller() async throws {
        let response = await set(["meetingVisualContextEnabled": true, "noteTemplate": "lecture"])
        let id = try requestID(response)
        XCTAssertTrue(response.error?.message.contains("config request \(id.uuidString)") == true)
        XCTAssertFalse(app.settings.meetingVisualContextEnabled)
        XCTAssertEqual(app.settings.noteTemplate, .meeting)

        try app.approveSettingsRequest(id)

        XCTAssertTrue(app.settings.meetingVisualContextEnabled)
        XCTAssertEqual(app.settings.noteTemplate, .lecture)
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
        let status = await send(.settingsRequest, ["id": .string(id.uuidString)])
        XCTAssertEqual(status.result?["state"], "approved")
        XCTAssertEqual(status.result?["result"]?["applied"], true)
        let recent = app.agentSettingsChanges.recent.prefix(2)
        XCTAssertEqual(Set(recent.map(\.key)), ["meetingVisualContextEnabled", "noteTemplate"])
        XCTAssertTrue(recent.allSatisfy { $0.caller == "lokalbot-cli via claude" })
    }

    func testDenyingChangesNothing() async throws {
        let id = try requestID(await set(["meetingVisualContextEnabled": true]))
        app.settingsApprovals.deny(id)
        XCTAssertEqual(app.settings, AppSettings())
        let status = await send(.settingsRequest, ["id": .string(id.uuidString)])
        XCTAssertEqual(status.result?["state"], "denied")
        XCTAssertThrowsError(try app.approveSettingsRequest(id))
        XCTAssertEqual(app.settings, AppSettings())
    }

    func testAnIdenticalRequestIsAskedOnce() async throws {
        let first = try requestID(await set(["meetingVisualContextEnabled": true]))
        let second = try requestID(await set(["meetingVisualContextEnabled": true]))
        XCTAssertEqual(first, second)
        XCTAssertEqual(app.settingsApprovals.pending.count, 1)
    }

    func testInvalidValuesFailBeforeAskingThePerson() async {
        let response = await set(["meetingVisualContextEnabled": true, "dayDigestHour": 30])
        XCTAssertEqual(response.error?.code, "invalid_value")
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
    }

    func testTurningTheGrantOffDeniesWaitingRequests() async throws {
        let id = try requestID(await set(["meetingVisualContextEnabled": true]))
        app.settingsControl.setEnabled(false)
        XCTAssertEqual(app.settingsApprovals.request(id)?.state, .denied)
        XCTAssertFalse(app.settings.meetingVisualContextEnabled)
    }

    func testUnknownRequestsAndStatusCount() async throws {
        let unknown = await send(.settingsRequest, ["id": .string(UUID().uuidString)])
        XCTAssertEqual(unknown.error?.code, "unknown_request")
        _ = try requestID(await set(["meetingVisualContextEnabled": true]))
        let status = await handler.handle(AppControlRequest(method: .status))
        XCTAssertEqual(status.result?["approvals"]?["pending"], 1)
    }

    func testShorterRetentionCarriesItsReviewAndAppliesIt() async throws {
        let response = await set(["retentionDays": 7])
        let id = try requestID(response)
        XCTAssertEqual(response.error?.details?["retentionReview"]?["days"], 7)
        XCTAssertEqual(app.settingsApprovals.request(id)?.retention?.days, 7)
        XCTAssertEqual(app.settings.retentionDays, 14)

        try app.approveSettingsRequest(id)

        XCTAssertEqual(app.settings.retentionDays, 7)
        // Undoing it could delete without a review, so Settings handles that.
        let entry = try XCTUnwrap(app.agentSettingsChanges.recent.first { $0.key == "retentionDays" })
        XCTAssertFalse(app.agentSettingsChanges.canUndo(entry, in: app.settings))
    }

    func testLongerRetentionNeedsNoCleanup() async throws {
        let id = try requestID(await set(["retentionDays": 30]))
        XCTAssertNil(app.settingsApprovals.request(id)?.retention)
        try app.approveSettingsRequest(id)
        XCTAssertEqual(app.settings.retentionDays, 30)
    }

    func testAShorterPolicyWithoutAReviewWaitsForOne() async throws {
        // Lengthening needs no cleanup when asked, but the person lengthens
        // further before approving, so applying it now would delete.
        let id = try requestID(await set(["retentionDays": 30]))
        app.settings.retentionDays = 60
        XCTAssertThrowsError(try app.approveSettingsRequest(id))
        XCTAssertEqual(app.settings.retentionDays, 60)
        XCTAssertEqual(app.settingsApprovals.request(id)?.retention?.days, 30)
        XCTAssertNotNil(app.settingsApprovals.request(id)?.problem)

        try app.approveSettingsRequest(id)
        XCTAssertEqual(app.settings.retentionDays, 30)
    }

    func testApprovingKeepsWhatThePersonChangedSinceAndTheCardDidNotShow() async throws {
        let origin = "https://think.example.com"
        app.settings.approvedRemoteInferenceOrigins = [origin]
        // The origin list is unchanged, so the card shows only the capture change.
        let id = try requestID(await set([
            "meetingVisualContextEnabled": true,
            "approvedRemoteInferenceOrigins": [.string(origin)],
        ]))
        XCTAssertEqual(app.settingsApprovals.request(id)?.items.map(\.spec.key), ["meetingVisualContextEnabled"])
        app.settings.approvedRemoteInferenceOrigins = []

        try app.approveSettingsRequest(id)

        XCTAssertTrue(app.settings.meetingVisualContextEnabled)
        XCTAssertEqual(app.settings.approvedRemoteInferenceOrigins, [])
    }

    func testAWideningThatGrewWhileWaitingIsShownAgain() async throws {
        let first = "https://a.example.com", second = "https://b.example.com"
        app.settings.approvedRemoteInferenceOrigins = [first]
        let id = try requestID(await set(["approvedRemoteInferenceOrigins": [.string(first), .string(second)]]))
        // The card adds one origin; approving now would add both.
        app.settings.approvedRemoteInferenceOrigins = []

        XCTAssertThrowsError(try app.approveSettingsRequest(id))
        XCTAssertEqual(app.settings.approvedRemoteInferenceOrigins, [])
        let refreshed = try XCTUnwrap(app.settingsApprovals.request(id))
        XCTAssertEqual(refreshed.state, .pending)
        XCTAssertNotNil(refreshed.problem)
        XCTAssertEqual(refreshed.items.first?.previous, .array([]))
        XCTAssertEqual(refreshed.changes.first?["previous"], .array([]))

        try app.approveSettingsRequest(id)
        XCTAssertEqual(app.settings.approvedRemoteInferenceOrigins, [first, second])
    }

    func testTheCardShowsEveryEntryAListGainsOrLoses() throws {
        let origins = try XCTUnwrap(SettingRegistry.spec(for: "approvedRemoteInferenceOrigins"))
        let long = (1...4).map { JSONValue.string("https://inference-server-\($0).example.com") }
        let added = JSONValue.string("https://another-inference-server.example.com")
        XCTAssertEqual(origins.changeLines(from: .array(long), to: .array(long + [added])),
                       ["Adds: https://another-inference-server.example.com"])

        let sites = try XCTUnwrap(SettingRegistry.spec(for: "excludedScreenDomains"))
        let excluded = "bank.example.com, health.example.com, mail.example.com, payroll.example.com, zoom.us"
        XCTAssertEqual(sites.changeLines(from: .string(excluded), to: .string(String(excluded.dropLast(9)))),
                       ["Removes: zoom.us"])

        let visual = try XCTUnwrap(SettingRegistry.spec(for: "meetingVisualContextEnabled"))
        XCTAssertEqual(visual.changeLines(from: .bool(false), to: .bool(true)), ["Off → On"])

        // A change only in what a URL hides still says so.
        let server = try XCTUnwrap(SettingRegistry.spec(for: "openAIBaseURL"))
        let lines = server.changeLines(from: .string("https://api.example.com/v1"),
                                       to: .string("https://api.example.com/v1?key=secret"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.joined().contains("secret"))
    }

    func testAPIKeysWaitForApprovalAndNeverComeBack() async throws {
        let key = "sk-test-0123456789abcd"
        let response = await send(.secretSet, ["name": "openai-compatible", "value": .string(key)])
        let id = try requestID(response)
        let reply = try String(decoding: JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(reply.contains(key))
        XCTAssertEqual(response.error?.details?["changes"]?.arrayItems?.first?["value"], "new key …abcd")
        XCTAssertTrue(keychain.isEmpty)

        try app.approveSettingsRequest(id)

        XCTAssertEqual(keychain[AppSecret.openAICompatible.keychainAccount], key)
        let list = await send(.secretList, [:])
        XCTAssertEqual(list.result?.arrayItems?.first { $0["name"] == "openai-compatible" }?["isSet"], true)
        XCTAssertEqual(app.agentSettingsChanges.recent.first?.key, "secret.openai-compatible")
        if case .secret(_, let value)? = app.settingsApprovals.request(id)?.subject {
            XCTAssertTrue(value.isEmpty)
        } else {
            XCTFail("not a secret request")
        }

        let cleared = await send(.secretClear, ["name": "openai-compatible"])
        XCTAssertNil(cleared.error)
        XCTAssertNil(keychain[AppSecret.openAICompatible.keychainAccount])
    }

    func testUnknownAndMalformedKeysAreRefused() async {
        let unknown = await send(.secretSet, ["name": "nope", "value": "x"])
        XCTAssertEqual(unknown.error?.code, "unknown_secret")
        let multiline = await send(.secretSet, ["name": "openai-compatible", "value": "a\nb"])
        XCTAssertEqual(multiline.error?.code, "invalid_request")
        XCTAssertTrue(app.settingsApprovals.pending.isEmpty)
    }

    func testLegacyScreenshotSwitchIsReadOnly() async {
        let response = await set(["screenshotsEnabled": true])
        XCTAssertEqual(response.error?.code, "read_only")
    }
}

private extension JSONValue {
    var arrayItems: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}
