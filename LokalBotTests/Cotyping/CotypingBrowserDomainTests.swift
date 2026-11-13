import AppKit
import XCTest
@testable import LokalBot

// MARK: - Per-domain disable

final class CotypingBrowserDomainTests: XCTestCase {
    func testHostStripsWWWAndPath() {
        XCTAssertEqual(CotypingBrowserDomain.host(fromURLString: "https://www.bank.com/login?x=1"), "bank.com")
    }
    func testHostKeepsSubdomainAndLowercases() {
        XCTAssertEqual(CotypingBrowserDomain.host(fromURLString: "https://Mail.Bank.com"), "mail.bank.com")
    }
    func testHostNilForNonWebURLs() {
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: "file:///Users/x"))
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: "about:blank"))
        XCTAssertNil(CotypingBrowserDomain.host(fromURLString: ""))
    }

    func testExactAndSubdomainMatch() {
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["bank.com"]))
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("mail.bank.com", excludedDomains: ["bank.com"]))
    }
    func testListEntryToleratesWWWAndFullURL() {
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["www.bank.com"]))
        XCTAssertTrue(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: ["https://bank.com/login"]))
    }
    func testSuffixLookalikeIsNotMatched() {
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("evilbank.com", excludedDomains: ["bank.com"]))
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("notbank.com", excludedDomains: ["bank.com"]))
    }
    func testEmptyHostOrListNeverMatches() {
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled(nil, excludedDomains: ["bank.com"]))
        XCTAssertFalse(CotypingBrowserDomain.isHostDisabled("bank.com", excludedDomains: []))
    }
}

final class CotypingDomainGateTests: XCTestCase {
    private func supportedFocus(host: String?) -> CotypingFocus {
        let field = CotypingField(
            appName: "Safari", bundleID: "com.apple.Safari", processID: 1, role: "AXTextArea",
            precedingText: "hello", trailingText: "", selectionLength: 0, caretRect: .zero,
            isSecure: false, caretIsExact: true)
        return CotypingFocus(appName: "Safari", bundleID: "com.apple.Safari",
                             capability: .supported, field: field, host: host)
    }

    func testDisabledOnExcludedDomain() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: "bank.com"))
        XCTAssertEqual(reason, "Disabled on bank.com.")
    }
    func testAllowedOffExcludedDomain() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: "github.com")))
    }
    func testNoDomainRulesAllowsBrowser() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: [],
            selfBundleID: nil, focus: supportedFocus(host: "bank.com")))
    }
    func testBrowserWithConfiguredRuleAndUnknownHostIsConservativelyGated() {
        XCTAssertEqual(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: supportedFocus(host: nil)),
            "Cannot verify this browser site — Cotyping paused.")
    }

    func testUnknownHostDoesNotGateNonBrowserApps() {
        var focus = supportedFocus(host: nil)
        focus.appName = "Pages"
        focus.bundleID = "com.apple.iWork.Pages"
        focus.field?.appName = "Pages"
        focus.field?.bundleID = "com.apple.iWork.Pages"
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], excludedDomains: ["bank.com"],
            selfBundleID: nil, focus: focus))
    }

    func testExcludedDomainListParse() {
        XCTAssertTrue(AppSettings().cotypingExcludedDomains.isEmpty)
        var settings = AppSettings()
        settings.cotypingExcludedDomains = "bank.com, https://x.com/y ,"
        XCTAssertEqual(settings.cotypingExcludedDomainList, ["bank.com", "https://x.com/y"])
    }
}
