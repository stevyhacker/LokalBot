import Foundation
import Network
import Testing
@testable import LokalBotCompanionKit

@Suite("Platform policies")
struct PlatformPolicyTests {
    @Test func appLockStartsLockedOnlyWhenEnabled() {
        let disabled = AppLockPolicy(isEnabled: false)
        #expect(!disabled.isEnabled)
        #expect(!disabled.isLocked)
        #expect(!disabled.isObscured)

        let enabled = AppLockPolicy(isEnabled: true)
        #expect(enabled.isEnabled)
        #expect(enabled.isLocked)
        #expect(!enabled.isObscured)
    }

    @Test func appLockObscuresOnInactiveLocksOnBackgroundAndPromptsOnReturn() {
        var lock = AppLockPolicy(isEnabled: true)
        lock.finishUnlock(succeeded: false)
        #expect(lock.isLocked)
        lock.finishUnlock(succeeded: true)
        #expect(!lock.isLocked)

        let promptOnInactive = lock.transition(to: .inactive)
        #expect(!promptOnInactive)
        #expect(lock.isObscured)
        #expect(!lock.isLocked)

        let promptOnActiveUnlocked = lock.transition(to: .active)
        #expect(!promptOnActiveUnlocked)
        #expect(!lock.isObscured)
        #expect(!lock.isLocked)

        let promptOnBackground = lock.transition(to: .background)
        #expect(!promptOnBackground)
        #expect(lock.isLocked)
        #expect(lock.isObscured)

        let promptOnReturn = lock.transition(to: .active)
        #expect(promptOnReturn)
        #expect(!lock.isObscured)
        #expect(lock.isLocked)
    }

    @Test func appLockRefusesDisablingWhileLocked() {
        var lock = AppLockPolicy(isEnabled: true)
        lock.applyEnableChange(enabled: false, authenticated: false)
        #expect(lock.isEnabled)
        #expect(lock.isLocked)

        lock.finishUnlock(succeeded: true)
        lock.applyEnableChange(enabled: false, authenticated: false)
        #expect(!lock.isEnabled)
        #expect(!lock.isObscured)

        lock.applyEnableChange(enabled: true, authenticated: false)
        #expect(!lock.isEnabled)
        lock.applyEnableChange(enabled: true, authenticated: true)
        #expect(lock.isEnabled)
    }

    @Test func macDiscoveryOrdersMatchingFingerprintFirstAndDropsMismatchedMacs() {
        let instances = [
            MacDiscovery.Instance(name: "Other Mac", fingerprint: "aaaa", address: "192.168.1.10:17890"),
            MacDiscovery.Instance(name: "Legacy Mac", fingerprint: nil, address: "192.168.1.11:17890"),
            MacDiscovery.Instance(name: "My Mac", fingerprint: "bbbb", address: "192.168.1.12:17890"),
        ]
        #expect(MacDiscovery.orderedAddresses(from: instances, preferringFingerprint: "bbbb")
                == ["192.168.1.12:17890", "192.168.1.11:17890"])
        #expect(MacDiscovery.orderedAddresses(from: instances, preferringFingerprint: nil)
                == ["192.168.1.10:17890", "192.168.1.11:17890", "192.168.1.12:17890"])
    }

    @Test func macDiscoveryFormatsIPv4IPv6AndNamedEndpoints() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 17_890))
        let ipv4 = try #require(IPv4Address("192.168.1.24"))
        #expect(MacDiscovery.format(.ipv4(ipv4), port) == "192.168.1.24:17890")

        let ipv6 = try #require(IPv6Address("fd7a:115c:a1e0::1"))
        #expect(MacDiscovery.format(.ipv6(ipv6), port) == "[fd7a:115c:a1e0:0:0:0:0:1]:17890")

        #expect(MacDiscovery.format(.name("macbook.local", nil), port) == "macbook.local:17890")
    }

    @Test func meetingsPageSkipsCorruptRowsAndPreservesHasMore() throws {
        let meeting = Meeting(
            id: "m1",
            title: "Sync",
            startedAt: Date(timeIntervalSince1970: 1_762_765_200),
            endedAt: Date(timeIntervalSince1970: 1_762_765_800),
            day: "2026-11-10",
            timeZoneOffsetMinutes: 0,
            durationSeconds: 600)
        let valid = try CompanionJSON.encodeString(meeting)
        let page = MeetingsPage(rows: [valid, "{corrupt", valid], limit: 2)
        #expect(page.meetings.count == 1)
        #expect(page.meetings.first?.id == "m1")
        #expect(page.hasMore)

        let shortPage = MeetingsPage(rows: [valid, "{corrupt"], limit: 2)
        #expect(shortPage.meetings.count == 1)
        #expect(!shortPage.hasMore)
    }
}
