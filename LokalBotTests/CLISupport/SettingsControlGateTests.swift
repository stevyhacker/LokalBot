import XCTest
@testable import LokalBot

final class SettingsControlGateTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-settings-gate-\(UUID().uuidString)", isDirectory: true)
    }

    func testDisabledByDefaultAndEnableDisableRoundTrip() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SettingsControlGate(root: root)
        XCTAssertFalse(gate.isEnabled)
        XCTAssertThrowsError(try gate.requireAuthorized())

        try gate.enable()
        XCTAssertTrue(gate.isEnabled)
        XCTAssertNoThrow(try gate.requireAuthorized())
        let marker = try FileManager.default.attributesOfItem(atPath: gate.markerURL.path)
        let folder = try FileManager.default.attributesOfItem(atPath: gate.controlDirectory.path)
        XCTAssertEqual((marker[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        gate.disable()
        XCTAssertFalse(gate.isEnabled)
    }

    func testIndependentOfMeetingAndScreenAccess() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsControlGate(root: root)
        let meetings = AgentAccessGate(root: root)
        let screen = ScreenMemoryAccessGate(root: root)

        try meetings.enable()
        try screen.enable()
        XCTAssertFalse(settings.isEnabled)

        meetings.disable()
        screen.disable()
        try settings.enable()
        XCTAssertFalse(meetings.isEnabled)
        XCTAssertFalse(screen.isEnabled)
    }

    func testExistingControlFolderIsHardened() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SettingsControlGate(root: root)
        try FileManager.default.createDirectory(
            at: gate.controlDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try gate.enable()
        let folder = try FileManager.default.attributesOfItem(atPath: gate.controlDirectory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
