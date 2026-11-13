import AppKit
import XCTest
@testable import LokalBot

// MARK: - Focus capability flicker gate

final class CotypingFocusCapabilityFlickerGateTests: XCTestCase {
    func testSingleBlockedFlickerOnSameElementIsSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
    }

    func testSupportedReturnAfterFlickerResetsCounter() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))
        _ = gate.evaluate(blockedFocus(identity: "field-A"))

        XCTAssertEqual(gate.evaluate(supportedFocus(identity: "field-A")), .apply)
        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
    }

    func testSecondConsecutiveBlockedReadAppliesDowngrade() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(blockedFocus(identity: "field-A")),
            .suppress(pendingBlockedReadCount: 1))
        XCTAssertEqual(gate.evaluate(blockedFocus(identity: "field-A")), .apply)
    }

    func testBlockedOnDifferentElementAppliesImmediately() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(gate.evaluate(blockedFocus(identity: "field-B")), .apply)
    }

    func testUnsupportedIsNeverSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Finder", bundleID: "com.apple.finder",
                capability: .unsupported("No focused text field."), field: nil)),
            .apply)
    }

    func testSecureFieldBlockIsNeverSuppressed() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Safari", bundleID: "com.apple.Safari",
                capability: .blocked("Secure field — never read."), field: nil,
                focusIdentityKey: "field-A")),
            .apply)
    }

    func testMissingBlockedIdentityAppliesImmediately() {
        var gate = CotypingFocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedFocus(identity: "field-A"))

        XCTAssertEqual(
            gate.evaluate(CotypingFocus(
                appName: "Safari", bundleID: "com.apple.Safari",
                capability: .blocked("Text selected."), field: nil)),
            .apply)
    }

    private func supportedFocus(identity: String?) -> CotypingFocus {
        let field = CotypingField(
            appName: "Safari", bundleID: "com.apple.Safari", processID: 1,
            role: "AXTextArea", focusIdentityKey: identity,
            precedingText: "hello", trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
        return CotypingFocus(
            appName: "Safari", bundleID: "com.apple.Safari",
            capability: .supported, field: field, focusIdentityKey: identity)
    }

    private func blockedFocus(identity: String?) -> CotypingFocus {
        CotypingFocus(
            appName: "Safari", bundleID: "com.apple.Safari",
            capability: .blocked("Text selected."), field: nil,
            focusIdentityKey: identity)
    }
}
