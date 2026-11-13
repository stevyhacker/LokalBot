import AppKit
import XCTest
@testable import LokalBot

// MARK: - Availability gate

final class CotypingAvailabilityTests: XCTestCase {
    private func focus(app: String = "Slack", bundle: String? = "com.tinyspeck.slackmacgap",
                       capability: CotypingCapability = .supported) -> CotypingFocus {
        CotypingFocus(appName: app, bundleID: bundle, capability: capability, field: nil)
    }

    func testDisabledWhenOff() {
        XCTAssertEqual(
            CotypingAvailability.disabledReason(enabled: false, excludedApps: [], selfBundleID: nil, focus: focus()),
            "Cotyping is off.")
    }

    func testExcludedApp() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: ["Slack"], selfBundleID: nil, focus: focus())
        XCTAssertEqual(reason, "Disabled in Slack.")
    }

    func testOffInsideSelf() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], selfBundleID: "me.dotenv.LokalBot",
            focus: focus(app: "LokalBot", bundle: "me.dotenv.LokalBot"))
        XCTAssertEqual(reason, "Off in LokalBot.")
    }

    func testBlockedCapabilityReason() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true, excludedApps: [], selfBundleID: nil,
            focus: focus(capability: .blocked("Secure field — never read.")))
        XCTAssertEqual(reason, "Secure field — never read.")
    }

    func testSupportedNotExcludedAllows() {
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true, excludedApps: ["Terminal"], selfBundleID: "me.dotenv.LokalBot", focus: focus()))
    }

    func testTerminalAppsAreBlockedByDefault() {
        let reason = CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: focus(app: "Terminal", bundle: "com.apple.Terminal"))
        XCTAssertEqual(reason, "Not available in terminal apps.")
    }

    func testIntegratedTerminalsAreBlockedByDefault() {
        var field = CotypingField(
            appName: "Code", bundleID: "com.microsoft.VSCode", processID: 1,
            role: "AXTextField", precedingText: "npm", trailingText: "",
            selectionLength: 0, caretRect: .zero, isSecure: false,
            isIntegratedTerminal: true, caretIsExact: true)
        let reason = CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field))
        XCTAssertEqual(reason, "Not available in the integrated terminal.")

        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            suggestInIntegratedTerminals: true,
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field)))

        field.isIntegratedTerminal = false
        XCTAssertNil(CotypingAvailability.disabledReason(
            enabled: true,
            excludedApps: [],
            selfBundleID: nil,
            focus: CotypingFocus(
                appName: "Code",
                bundleID: "com.microsoft.VSCode",
                capability: .supported,
                field: field)))
    }
}

// MARK: - Sensitive field detector

final class CotypingSecureFieldDetectorTests: XCTestCase {
    func testPlainTextFieldIsNotSecure() {
        XCTAssertFalse(CotypingSecureFieldDetector.isSecure(
            role: "AXTextField",
            subrole: nil,
            roleDescription: "text field",
            title: "Email",
            descriptionLabel: nil))
    }

    func testSecureTextFieldRoleDescriptionBlocksBeforeValueRead() {
        XCTAssertTrue(CotypingSecureFieldDetector.isSecure(
            role: "AXTextField",
            subrole: nil,
            roleDescription: "secure text field",
            title: nil,
            descriptionLabel: nil))
    }

    func testNativeSecureSubroleStillBlocks() {
        XCTAssertTrue(CotypingSecureFieldDetector.isSecure(
            role: "AXTextField",
            subrole: kAXSecureTextFieldSubrole as String,
            roleDescription: nil,
            title: nil,
            descriptionLabel: nil))
    }

    func testNonPasswordSecretLabelsBlock() {
        for label in ["CVV", "Security code", "Verification code", "One-time code", "Card number"] {
            XCTAssertTrue(
                CotypingSecureFieldDetector.isSecure(
                    role: "AXTextField",
                    subrole: nil,
                    roleDescription: nil,
                    title: label,
                    descriptionLabel: nil),
                "Expected \(label) to be treated as sensitive")
        }
    }

    func testSearchFieldIsNotOvermatched() {
        XCTAssertFalse(CotypingSecureFieldDetector.isSecure(
            role: "AXTextField",
            subrole: nil,
            roleDescription: "text field",
            title: "Search",
            descriptionLabel: "Type to search"))
    }
}

// MARK: - Code field detector

final class CotypingCodeFieldDetectorTests: XCTestCase {
    /// A verification code field named only by its placeholder or `<label>`
    /// got suggestions.
    func testCodeFieldNamesAreRecognized() {
        let labels = [
            "Code", "Enter code", "Enter the 6-digit code", "Code sent by SMS",
            "SMS code", "Login code", "Two-factor authentication", "2-Step Verification",
            "One-time password", "OTP", "Authenticator app code", "PIN", "Backup code",
            "otpInput", "SMSCode", "verification-code", "mfa_code", "one-time-code",
            "Unesite kod", "Verifikacioni kod", "Kod za potvrdu", "Jednokratna lozinka",
            "Унесите код", "Код за потврду",
        ]
        for label in labels {
            XCTAssertTrue(CotypingCodeFieldDetector.isCodeField(labels: [nil, label]), label)
        }
    }

    func testOrdinaryFieldsAreNotCodeFields() {
        let labels = [
            "Message #general", "Reply to Claude…", "Pinned notes", "Opinion", "Spinner",
            "Write a code review comment", "Source Control Input", "iMessage",
            "Text Message • SMS", "Subject", "Add a comment", "Shipping address", "",
        ]
        for label in labels {
            XCTAssertFalse(CotypingCodeFieldDetector.isCodeField(labels: [label]), label)
        }
        XCTAssertFalse(CotypingCodeFieldDetector.isCodeField(labels: [nil, nil]))
    }

    func testWordsSplitIdsAndHumps() {
        XCTAssertEqual(CotypingCodeFieldDetector.words(in: "SMSCode"), ["sms", "code"])
        XCTAssertEqual(CotypingCodeFieldDetector.words(in: "otpInput-2"), ["otp", "input", "2"])
        XCTAssertEqual(CotypingCodeFieldDetector.words(in: "2FA"), ["2fa"])
        XCTAssertEqual(CotypingCodeFieldDetector.words(in: "Унесите код"), ["унесите", "код"])
    }
}

final class CotypingAppReadPolicyTests: XCTestCase {
    func testExclusionsBlockTextReaderBeforeContentIsCollected() {
        let policy = CotypingAppReadPolicy(enabled: true, excludedApps: ["mail", "secret"], selfBundleID: "me.dotenv.LokalBot")
        for (name, bundle) in [("Mail", "com.apple.mail"), ("Notes", "com.secret.app"),
                               ("LokalBot", "me.dotenv.LokalBot"), ("", "")] {
            var reads = 0
            let text = policy.readIfAllowed(appName: name, bundleID: bundle) { reads += 1; return "private" }
            XCTAssertNil(text)
            XCTAssertEqual(reads, 0)
        }
        XCTAssertEqual(policy.readIfAllowed(appName: "TextEdit", bundleID: "com.apple.TextEdit") { "allowed" }, "allowed")
        XCTAssertNil(CotypingAppReadPolicy().readIfAllowed(appName: "TextEdit", bundleID: "com.apple.TextEdit") { "private" })
    }
}
