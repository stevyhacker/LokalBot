import XCTest
@testable import LokalBot

/// `setup start` requests as the app reads and answers them, and the setup
/// methods an agent uses afterwards. Runs against a real `AppState` in a
/// temporary library; nothing here prompts or restarts.
@MainActor
final class AgentSetupTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?
    private var app: AppState!
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-agent-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        app = AppState()
        app.settings = AppSettings()
    }

    override func tearDown() async throws {
        app.settingsControl.setEnabled(false)
        app.agentAccess.setEnabled(false)
        app.screenMemoryAccess.setEnabled(false)
        app.settings = AppSettings()
        app = nil
        if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private var control: URL { SettingsControlGate(root: app.storage.rootURL).controlDirectory }

    private func leaveRequest(grants: [AgentSetup.Grant] = [.settings, .meetingLibrary, .screenMemory],
                              createdAt: Date? = nil) throws -> AgentSetup.Request {
        let created = createdAt ?? start
        let request = AgentSetup.Request(
            nonce: UUID().uuidString, requester: "lokalbot-cli via claude", grants: grants,
            createdAt: created, expiresAt: created.addingTimeInterval(AgentSetup.lifetime))
        try AgentSetup.write(request, to: AgentSetup.requestURL(controlDirectory: control))
        return request
    }

    private func requests(at date: Date? = nil) -> AgentSetupRequests {
        let now = date ?? start.addingTimeInterval(10)
        return AgentSetupRequests(controlDirectory: control, now: { now })
    }

    private func answer() -> AgentSetup.Answer? {
        AgentSetup.read(AgentSetup.Answer.self, from: AgentSetup.answerURL(controlDirectory: control))
    }

    func testARequestIsShownAndItsFileIsPrivate() throws {
        let request = try leaveRequest()
        let setup = requests()
        XCTAssertTrue(setup.check())
        XCTAssertEqual(setup.pending, request)
        let attributes = try FileManager.default.attributesOfItem(atPath: setup.requestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAllowingTurnsOnSettingsAndOnlyTheTickedReadAccess() throws {
        let request = try leaveRequest()
        let setup = requests()
        XCTAssertTrue(setup.check())

        setup.allow(meetingLibrary: true, screenMemory: false, in: app)

        XCTAssertTrue(app.settingsControl.isEnabled)
        XCTAssertTrue(app.agentAccess.isEnabled)
        XCTAssertFalse(app.screenMemoryAccess.isEnabled)
        XCTAssertNil(setup.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.requestURL.path))
        XCTAssertEqual(answer()?.nonce, request.nonce)
        XCTAssertEqual(answer()?.state, .approved)
        XCTAssertEqual(answer()?.grants, [.settings, .meetingLibrary])
        XCTAssertEqual(app.agentSettingsChanges.recent.first?.key, "setup.access")
        XCTAssertEqual(app.agentSettingsChanges.recent.first?.caller, "lokalbot-cli via claude")
    }

    func testReadAccessThatWasNotRequestedIsNotGranted() throws {
        _ = try leaveRequest(grants: [.settings])
        let setup = requests()
        XCTAssertTrue(setup.check())
        setup.allow(meetingLibrary: true, screenMemory: true, in: app)
        XCTAssertTrue(app.settingsControl.isEnabled)
        XCTAssertFalse(app.agentAccess.isEnabled)
        XCTAssertFalse(app.screenMemoryAccess.isEnabled)
        XCTAssertEqual(answer()?.grants, [.settings])
    }

    func testDecliningLeavesEverythingOff() throws {
        let request = try leaveRequest()
        let setup = requests()
        XCTAssertTrue(setup.check())
        setup.deny()
        XCTAssertFalse(app.settingsControl.isEnabled)
        XCTAssertFalse(app.agentAccess.isEnabled)
        XCTAssertEqual(answer()?.nonce, request.nonce)
        XCTAssertEqual(answer()?.state, .denied)
        XCTAssertEqual(answer()?.grants, [])
        XCTAssertNil(setup.pending)
    }

    func testExpiredAndMalformedRequestsAreRemovedUnanswerable() throws {
        let request = try leaveRequest()
        let late = requests(at: start.addingTimeInterval(AgentSetup.lifetime + 5))
        XCTAssertFalse(late.check())
        XCTAssertEqual(answer()?.nonce, request.nonce)
        XCTAssertEqual(answer()?.state, .expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.requestURL.path))

        try Data("not json".utf8).write(to: late.requestURL)
        XCTAssertFalse(late.check())
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.requestURL.path))
    }

    func testARequestMustAskForSettingsAccessAndBeShortLived() {
        let now = start.addingTimeInterval(10)
        var request = AgentSetup.Request(
            nonce: "n", requester: "x", grants: [.meetingLibrary],
            createdAt: start, expiresAt: start.addingTimeInterval(60))
        XCTAssertFalse(request.isLive(at: now))
        request.grants = [.settings]
        XCTAssertTrue(request.isLive(at: now))
        request.expiresAt = start.addingTimeInterval(24 * 3_600)
        XCTAssertFalse(request.isLive(at: now))
    }

    func testAllowingAnExpiredRequestGrantsNothing() throws {
        _ = try leaveRequest()
        var clock = start.addingTimeInterval(10)
        let setup = AgentSetupRequests(controlDirectory: control, now: { clock })
        XCTAssertTrue(setup.check())
        clock = start.addingTimeInterval(AgentSetup.lifetime + 5)
        setup.allow(meetingLibrary: true, screenMemory: true, in: app)
        XCTAssertFalse(app.settingsControl.isEnabled)
        XCTAssertEqual(answer()?.state, .expired)
    }

    // MARK: Setup methods

    private func handled(_ method: AppControlProtocol.Method, _ params: [String: JSONValue]? = nil) async throws -> AppControlResponse {
        let gate = SettingsControlGate(root: app.storage.rootURL)
        try gate.enable()
        return await AppControlHandler(app: app, gate: gate).handle(AppControlRequest(method: method, params: params))
    }

    func testThePlanCoversTheSetupSettingsAndAPresetForThisMac() async throws {
        let response = try await handled(.setupPlan)
        let plan = try XCTUnwrap(response.result)
        for key in SetupPlan.keys {
            XCTAssertNotNil(plan["settings"]?[key], key)
        }
        XCTAssertTrue(AppControlProtocol.modelPresets.contains(plan["models"]?.stringValue ?? ""))
        guard case .array(let needsApproval)? = plan["notes"]?["needsApproval"] else { return XCTFail("no notes") }
        XCTAssertTrue(needsApproval.contains("trackingEnabled"))
        XCTAssertFalse(needsApproval.contains("noteTemplate"))
        // The printed plan is what setup apply reads.
        XCTAssertNoThrow(try SetupPlan(json: plan))

        let lightweight = try await handled(.setupPlan, ["preset": "lightweight"])
        XCTAssertEqual(lightweight.result?["models"], "lightweight")
        let unknown = try await handled(.setupPlan, ["preset": "huge"])
        XCTAssertEqual(unknown.error?.code, "invalid_request")
    }

    func testPresetSuggestionFollowsMemory() {
        let small = HardwareCapability(physicalMemoryBytes: 8 * 1_073_741_824, isAppleSilicon: true)
        let large = HardwareCapability(physicalMemoryBytes: 64 * 1_073_741_824, isAppleSilicon: true)
        XCTAssertEqual(AppControlHandler.suggestedPreset(capability: small).preset, .lightweight)
        XCTAssertEqual(AppControlHandler.suggestedPreset(capability: large).preset, .recommended)
    }

    func testModelsStatusAndPermissions() async throws {
        let status = try await handled(.modelsStatus)
        let models = try XCTUnwrap(status.result)
        XCTAssertNotNil(models["meetingReady"])
        XCTAssertNotNil(models["preset"])
        XCTAssertNotNil(models["suggestedPreset"])

        let list = try await handled(.permissionsList)
        guard case .array(let permissions)? = list.result else {
            return XCTFail("no permissions")
        }
        XCTAssertEqual(Set(permissions.compactMap { $0["name"]?.stringValue }), Set(AppControlProtocol.permissionNames))
        let microphone = permissions.first { $0["name"] == "microphone" }
        guard case .array(let neededBy)? = microphone?["neededBy"] else { return XCTFail("no microphone row") }
        XCTAssertTrue(neededBy.contains("Meeting recording"))
    }

    func testPromptsAndRestartsNeedTheInteractiveApp() async throws {
        let request = try await handled(.permissionsRequest, ["name": "microphone"])
        XCTAssertEqual(request.error?.code, "unavailable")
        let restart = try await handled(.restart)
        XCTAssertEqual(restart.error?.code, "unavailable")
        let login = try await handled(.launchAtLogin, ["enabled": true])
        XCTAssertEqual(login.error?.code, "unavailable")
    }

    func testDoctorListsChecksAndNextSteps() async throws {
        let response = try await handled(.doctor)
        let doctor = try XCTUnwrap(response.result)
        guard case .array(let checks)? = doctor["checks"], case .array? = doctor["nextSteps"],
              case .bool? = doctor["ready"] else { return XCTFail("unexpected doctor reply") }
        XCTAssertEqual(Set(checks.compactMap { $0["name"]?.stringValue }),
                       ["models", "permissions", "onboarding", "approvals", "launchAtLogin"])
    }

    func testFinishingSetupMarksOnboardingDone() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppState.onboardingShownKey)
        defer {
            if let previous { defaults.set(previous, forKey: AppState.onboardingShownKey) } else {
                defaults.removeObject(forKey: AppState.onboardingShownKey)
            }
        }
        defaults.set(false, forKey: AppState.onboardingShownKey)
        let response = try await handled(.setupFinish)
        XCTAssertEqual(response.result?["finished"], true)
        XCTAssertTrue(defaults.bool(forKey: AppState.onboardingShownKey))
    }
}
