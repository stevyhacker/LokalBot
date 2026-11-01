import XCTest
@testable import LokalBot

/// Settings → Phones & tablets: off by default, persisted like every other
/// setting, and classified as consent when an agent widens it.
final class CompanionSettingsTests: XCTestCase {
    func testSharingIsOffByDefaultWithGenerousClasses() {
        let settings = AppSettings()
        XCTAssertFalse(settings.companionSharingEnabled)
        let sharing = settings.companionSharing
        XCTAssertFalse(sharing.enabled)
        XCTAssertEqual(sharing.dataClasses, .all)
        XCTAssertEqual(sharing.history, .all)
        XCTAssertTrue(sharing.answersQuestions)
        XCTAssertEqual(sharing.port, 17890)
        XCTAssertTrue(sharing.advertisesOnBonjour)
    }

    func testCompanionSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.companionSharingEnabled = true
        settings.companionShareTranscripts = false
        settings.companionShareWindowTitles = false
        settings.companionHistory = .days90
        settings.companionAnswersQuestions = false
        settings.companionPort = 18000
        settings.companionAdvertisesOnBonjour = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.companionSharing, settings.companionSharing)
        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)
    }

    func testOlderSettingsDecodeWithSharingOff() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menuBarOnly": false}"#.utf8))
        XCTAssertFalse(decoded.companionSharingEnabled)
        XCTAssertTrue(decoded.corruptedSettingsKeys.isEmpty)
    }

    func testPortIsClampedOnDecode() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"companionPort": 80}"#.utf8))
        XCTAssertEqual(decoded.companionPort, 1024)
        XCTAssertEqual(CompanionSharing.clampedPort(70_000), 65535)
    }

    func testHistoryWindowStartsOnLocalDays() {
        let calendar = Calendar.current
        let now = calendar.date(byAdding: .hour, value: 15, to: calendar.startOfDay(for: Date()))!
        XCTAssertNil(CompanionHistoryWindow.all.startOfWindow(now: now))
        let start = CompanionHistoryWindow.days30.startOfWindow(now: now)!
        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day, 29)
        XCTAssertTrue(CompanionHistoryWindow.days30.contains(start, now: now))
        XCTAssertFalse(CompanionHistoryWindow.days30.contains(start.addingTimeInterval(-1), now: now))
    }

    func testAgentsNeedApprovalToWidenSharing() throws {
        let enabled = try XCTUnwrap(SettingRegistry.spec(for: "companionSharingEnabled"))
        XCTAssertEqual(enabled.classify(from: false, to: true), .widening)
        XCTAssertEqual(enabled.classify(from: true, to: false), .narrowing)
        let history = try XCTUnwrap(SettingRegistry.spec(for: "companionHistory"))
        XCTAssertEqual(history.classify(from: 30, to: 0), .widening)
        XCTAssertEqual(history.classify(from: 90, to: 365), .widening)
        XCTAssertEqual(history.classify(from: 0, to: 30), .narrowing)
        XCTAssertEqual(try XCTUnwrap(SettingRegistry.spec(for: "companionPort")).classify(from: 17890, to: 18000),
                       .preference)
        XCTAssertEqual(try XCTUnwrap(SettingRegistry.spec(for: "companionAdvertisesOnBonjour"))
            .classify(from: false, to: true), .widening)
    }

    @MainActor
    func testPhonesAndTabletsTab() {
        XCTAssertEqual(AppState.SettingsTab(captureName: "phones & tablets"), .devices)
        XCTAssertEqual(AppState.SettingsTab(captureName: "devices"), .devices)
        XCTAssertEqual(AppState.SettingsTab.devices.displayName, "Phones & tablets")
        XCTAssertTrue(SettingDescriptor.search("tailscale").contains { $0.id == "settings.companionSharingEnabled" })
        // The other controls appear only once sharing is on.
        let port = try? XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.companionPort" })
        var settings = AppSettings()
        XCTAssertEqual(port?.focusTarget(in: settings), "settings.companionSharingEnabled")
        settings.companionSharingEnabled = true
        XCTAssertEqual(port?.focusTarget(in: settings), "settings.companionPort")
    }

    func testTailscaleAddressesAreRecognized() {
        XCTAssertEqual(CompanionNetwork.classify("100.101.102.103"), .tailscale)
        XCTAssertEqual(CompanionNetwork.classify("100.101.102.103:17890"), .tailscale)
        XCTAssertEqual(CompanionNetwork.classify("[fd7a:115c:a1e0::1]:17890"), .tailscale)
        XCTAssertEqual(CompanionNetwork.classify("192.168.1.20"), .localNetwork)
        XCTAssertEqual(CompanionNetwork.classify("100.63.0.1"), .localNetwork)
        XCTAssertEqual(CompanionNetwork.classify("fe80::1"), .localNetwork)
        XCTAssertNil(CompanionNetwork.classify(""))
    }

    func testBonjourNameAndTXTRecord() {
        XCTAssertEqual(CompanionBonjourAdvertiser.instanceName(fingerprint: "a1b2c3d4e5f60718"), "LokalBot-A1B2")
        let txt = CompanionBonjourAdvertiser.txtRecord(fingerprint: "a1b2c3d4e5f60718")
        XCTAssertEqual(txt.first, 18)
        XCTAssertEqual(String(decoding: txt.dropFirst(), as: UTF8.self), "k=a1b2c3d4e5f60718")
    }

    func testPairingPromptShowsABoundedName() {
        XCTAssertEqual(CompanionPairingPrompt.displayName("Stevan's iPad\n\u{7}"), "Stevan's iPad")
        XCTAssertEqual(CompanionPairingPrompt.displayName("   "), "A device")
        XCTAssertEqual(CompanionPairingPrompt.displayName(String(repeating: "x", count: 100)).count, 60)
        XCTAssertEqual(CompanionPairingPrompt.platformName("ipados"), "iPad")
    }

    func testQRCodeRendersThePayload() {
        XCTAssertNotNil(CompanionQRCode.image(for: "lokalbot://pair?d=eyJ2IjoxfQ"))
    }
}
