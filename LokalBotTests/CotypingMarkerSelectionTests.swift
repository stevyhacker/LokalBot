import AppKit
import XCTest
@testable import LokalBot

// MARK: - Marker selection synthesis

final class CotypingMarkerSelectionSynthesizerTests: XCTestCase {
    func testCaretInMiddleProducesZeroLengthSelectionAtBeforeLength() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "Hello ",
            selected: "",
            afterCaret: "world")

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testNonEmptySelectionIndexesIntoSynthesizedText() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "Hi ",
            selected: "there",
            afterCaret: "!")

        XCTAssertEqual(result.text, "Hi there!")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 5))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "there")
    }

    func testWindowingKeepsCaretAdjacentTextAndSelectionConsistent() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "ABCDEFG",
            selected: "X",
            afterCaret: "HIJKLM",
            window: 3)

        XCTAssertEqual(result.text, "EFGXHIJ")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 1))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "X")
    }

    func testWindowDoesNotSplitSurrogatePairs() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "😀😀😀",
            selected: "",
            afterCaret: "",
            window: 3)

        XCTAssertFalse(result.text.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertTrue(result.text.allSatisfy { $0 == "😀" })
        XCTAssertEqual(result.selection.location, (result.text as NSString).length)
        XCTAssertEqual(result.selection.length, 0)
    }

    func testPredictionAndAcceptanceShareUnicodeWindows() throws {
        for (before, after) in [
            (String(repeating: "e\u{301}", count: 3_000), ""),
            ("Hello", String(repeating: "😀", count: 700)),
            (String(repeating: "👩🏽‍💻", count: 600) + "x", String(repeating: "e\u{301}", count: 800)),
            (String(repeating: "😀", count: 3_000) + "x", String(repeating: "👩🏽‍💻", count: 700)),
        ] {
            let marker = CotypingMarkerSelectionSynthesizer.make(beforeCaret: before, selected: "", afterCaret: after)
            let value = before + after
            let ns = value as NSString
            let selection = NSRange(location: before.utf16.count, length: 0)
            let ranges = try XCTUnwrap(CotypingAcceptanceContentBounds.ranges(
                selection: selection, totalUTF16Length: ns.length))
            let acceptance = CotypingAcceptanceContentBounds.context(
                precedingText: ns.substring(with: ranges.preceding), trailingText: ns.substring(with: ranges.trailing),
                ranges: ranges, totalUTF16Length: ns.length)
            XCTAssertEqual(marker.context, acceptance)
            XCTAssertEqual(CotypingAcceptanceContentBounds.context(in: value, selection: selection), acceptance)
            XCTAssertFalse(acceptance.preceding.contains("\u{FFFD}"))
            XCTAssertFalse(acceptance.trailing.contains("\u{FFFD}"))
            XCTAssertLessThanOrEqual(acceptance.preceding.utf16.count, 4_096)
            XCTAssertLessThanOrEqual(acceptance.trailing.utf16.count, 1_024)
        }
    }

    func testShorterThanWindowIsUnchanged() {
        let result = CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: "ab",
            selected: "",
            afterCaret: "cd",
            window: 100)

        XCTAssertEqual(result.text, "abcd")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }
}

final class CotypingWebAccessibilityPrimingTests: XCTestCase {
    func testChromiumBrowsersNeedPriming() {
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.google.Chrome"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.google.Chrome.canary"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.brave.Browser"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.edgemac"))
    }

    func testSafariAndFirefoxDoNotNeedChromiumPriming() {
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.apple.Safari"))
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "org.mozilla.firefox"))
    }

    func testNamedElectronEditorsNeedPrimingCaseInsensitively() {
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.microsoft.vscodeinsiders"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.vscodium"))
        XCTAssertTrue(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.clickup.desktop-app"))
    }

    func testBroadElectronOrToDesktopAppsAreNotPrimedByPrefix() {
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.todesktop.12345"))
        XCTAssertFalse(CotypingAXHelper.needsWebAccessibilityPriming(bundleID: "com.electron.random"))
    }
}

final class CotypingAXHitTestFocusValidatorTests: XCTestCase {
    func testAcceptsOnlyFocusedEditableOwnedByExpectedFrontmostProcess() {
        XCTAssertTrue(CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: 42,
            expectedProcessID: 42,
            candidateProcessID: 42,
            isEditable: true,
            isFocused: true))
    }

    func testRejectsElementUnderPointerWhenItIsNotFocused() {
        XCTAssertFalse(CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: 42,
            expectedProcessID: 42,
            candidateProcessID: 42,
            isEditable: true,
            isFocused: false))
    }

    func testRejectsFocusedElementOwnedByAnotherProcess() {
        XCTAssertFalse(CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: 42,
            expectedProcessID: 42,
            candidateProcessID: 77,
            isEditable: true,
            isFocused: true))
    }

    func testRejectsCandidateWhenExpectedProcessIsNoLongerFrontmost() {
        XCTAssertFalse(CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: 77,
            expectedProcessID: 42,
            candidateProcessID: 42,
            isEditable: true,
            isFocused: true))
    }

    func testRejectsFocusedNonEditableCandidate() {
        XCTAssertFalse(CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: 42,
            expectedProcessID: 42,
            candidateProcessID: 42,
            isEditable: false,
            isFocused: true))
    }
}
