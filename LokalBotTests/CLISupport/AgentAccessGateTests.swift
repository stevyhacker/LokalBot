import XCTest
@testable import LokalBot

final class AgentAccessGateTests: XCTestCase {
    private func makeGate() -> (AgentAccessGate, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-\(UUID().uuidString)", isDirectory: true)
        return (AgentAccessGate(root: root), root)
    }

    func testDisabledByDefaultAndEnableDisableRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.isEnabled)
        try gate.enable()
        XCTAssertTrue(gate.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("control/agent-access-enabled").path))
        gate.disable()
        XCTAssertFalse(gate.isEnabled)
    }

    /// The skill and AGENT_SETUP.md tell agents to look for these codes, and
    /// the Windows and Linux CLI prints the same ones.
    func testACommandRefusedForASwitchThatIsOffNamesItsCode() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try gate.requireCommandAccess(environment: [:])) { error in
            XCTAssertEqual(error.localizedDescription,
                           "[access_disabled] " + FileLibraryToolProvider.accessDisabledMessage)
        }
        try gate.enable()
        XCTAssertNoThrow(try gate.requireCommandAccess(environment: [:]))

        XCTAssertEqual(FilesSearchTool.Failure.disabled.commandError?.localizedDescription,
                       "[files_access_disabled] " + FilesSearchTool.disabledMessage)
        XCTAssertEqual(FilesSearchTool.Failure.unavailable.commandError?.localizedDescription,
                       "[files_unavailable] " + FilesSearchTool.unavailableMessage)
        XCTAssertNil(FilesSearchTool.Failure.invalid("bad").commandError)
        XCTAssertEqual(PersonalContextTool.Failure.disabled.commandError?.localizedDescription,
                       "[personal_context_disabled] " + PersonalContextTool.disabledMessage)
        XCTAssertEqual(PersonalContextTool.Failure.unavailable.commandError?.localizedDescription,
                       "[personal_context_unavailable] " + PersonalContextTool.unavailableMessage)
        XCTAssertNil(PersonalContextTool.Failure.invalid("bad").commandError)
    }

    func testWakeTouchConsumeCycle() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.pendingWake)
        XCTAssertFalse(gate.consumeWake())
        try gate.touchWake()
        XCTAssertTrue(gate.pendingWake)
        XCTAssertTrue(gate.consumeWake())
        XCTAssertFalse(gate.pendingWake)
    }

    func testWakeErrorRoundTrip() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(gate.readWakeError())
        gate.writeWakeError("engine offline")
        XCTAssertEqual(gate.readWakeError(), "engine offline")
        gate.clearWakeError()
        XCTAssertNil(gate.readWakeError())
    }

    func testDefaultRootFollowsStorageRootOverride() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-gate-env-\(UUID().uuidString)", isDirectory: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            unsetenv("LOKALBOT_STORAGE_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(AgentAccessGate().root.path, root.path)
    }

    func testScopedCapabilityAuthorizesOnlyWhilePresentAndUnexpired() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        let capability = try gate.issueScopedCapability(validFor: 120)
        let environment = [AgentAccessGate.capabilityEnvironmentKey: capability.token]

        XCTAssertTrue(gate.isAuthorized(environment: environment))
        XCTAssertFalse(gate.isAuthorized(
            environment: environment,
            now: Date().addingTimeInterval(121)))
        XCTAssertFalse(gate.isAuthorized(environment: [
            AgentAccessGate.capabilityEnvironmentKey: capability.token + "tampered",
        ]))

        gate.revoke(capability)
        XCTAssertFalse(gate.isAuthorized(environment: environment))
    }

    func testGlobalToggleAuthorizesWithoutCapability() throws {
        let (gate, root) = makeGate()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(gate.isAuthorized(environment: [:]))
        try gate.enable()
        XCTAssertTrue(gate.isAuthorized(environment: [:]))
    }
}
