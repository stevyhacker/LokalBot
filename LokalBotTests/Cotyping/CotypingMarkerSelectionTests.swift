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

// MARK: - Chromium paragraph breaks

final class CotypingParagraphBreakAlignmentTests: XCTestCase {
    /// Chromium's value has a line break between paragraphs; its selection
    /// and `AXStringForRange` count the text without it.
    private let value = "On Sunday morning I sent one message.\nI made a elabor\nSome details from the Claude Code side:"
    private let plainBeforeCaret = "On Sunday morning I sent one message.I made a elabor"

    private func context(at location: Int) -> CotypingTextContext? {
        CotypingAcceptanceContentBounds.context(in: value, selection: NSRange(location: location, length: 0))
    }

    /// 2026-10-21, Reddit in Chrome: split at the reported offset, the caret
    /// came out one character early, so the suggestion after "elabor" began
    /// "rate" and showed in a popup over the text.
    func testTheCaretLandsAfterTheLastTypedCharacter() throws {
        let location = try XCTUnwrap(CotypingParagraphBreakAlignment.caretLocation(
            in: value, textBeforeCaret: plainBeforeCaret))
        let split = try XCTUnwrap(context(at: location))

        XCTAssertTrue(split.preceding.hasSuffix("message.\nI made a elabor"))
        XCTAssertTrue(split.trailing.hasPrefix("\nSome details"))
        XCTAssertTrue(CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: split.trailing))
    }

    func testEachParagraphAboveMovesTheCaretOneCharacter() {
        XCTAssertEqual(CotypingParagraphBreakAlignment.caretLocation(
            in: "One\nTwo\nThree\nFour", textBeforeCaret: "OneTwoThreeFou"), 17)
    }

    func testHostsThatCountTheSameWayAreUnchanged() {
        let native = "First line\nsecond line"
        XCTAssertEqual(CotypingParagraphBreakAlignment.caretLocation(
            in: native, textBeforeCaret: "First line\nsecond"), 17)
        XCTAssertEqual(CotypingParagraphBreakAlignment.caretLocation(
            in: "one line", textBeforeCaret: "one"), 3)
    }

    /// A `<br>` is a line break in both counts; a paragraph break next to it
    /// is only in the value.
    func testALineBreakNextToAParagraphBreakIsMatchedOnce() {
        XCTAssertEqual(CotypingParagraphBreakAlignment.caretLocation(
            in: "A\n\nB", textBeforeCaret: "A\nB"), 4)
    }

    func testAnEmbeddedObjectTheValueLeavesOutIsSkipped() {
        XCTAssertEqual(CotypingParagraphBreakAlignment.caretLocation(
            in: "Caption\nText", textBeforeCaret: "\u{FFFC}CaptionTe"), 10)
    }

    func testTextThatDoesNotLineUpIsRefused() {
        XCTAssertNil(CotypingParagraphBreakAlignment.caretLocation(
            in: "Hello\nworld", textBeforeCaret: "Help"))
    }

    /// Tab is checked against a second read of the field. Read the way the
    /// suggestion's snapshot was, it matches; the `AXStringForRange` windows
    /// the accept used to read have no paragraph breaks and never match when
    /// paragraphs surround the caret, so Tab was refused there.
    func testAnAcceptReadLikeTheSnapshotMatchesIt() throws {
        let location = try XCTUnwrap(CotypingParagraphBreakAlignment.caretLocation(
            in: value, textBeforeCaret: plainBeforeCaret))
        let snapshot = try XCTUnwrap(context(at: location))
        let session = CotypingSession(field: chromeField(snapshot), fullText: "ate blog post about")

        XCTAssertTrue(CotypingSessionReconciler.isAcceptanceContinuation(
            of: session, liveField: chromeField(snapshot), pendingInsertionConsumedCount: nil))

        let plain = value.replacingOccurrences(of: "\n", with: "")
        let windows = try XCTUnwrap(CotypingAcceptanceContentBounds.context(
            in: plain, selection: NSRange(location: (plainBeforeCaret as NSString).length, length: 0)))
        XCTAssertFalse(CotypingSessionReconciler.isAcceptanceContinuation(
            of: session, liveField: chromeField(windows), pendingInsertionConsumedCount: nil))
    }

    private func chromeField(_ context: CotypingTextContext) -> CotypingField {
        var field = CotypingField(
            appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 42, role: "AXTextArea",
            focusIdentityKey: nil, precedingText: context.preceding, trailingText: context.trailing,
            selectionLength: 0, caretRect: .zero, isSecure: false, caretIsExact: true)
        field.selectionSkipsParagraphBreaks = true
        return field
    }
}

// MARK: - Field style from web text attributes

final class CotypingWebFieldStyleTests: XCTestCase {
    /// Chromium's marker-based attributed string has an `AXFont` with only a
    /// size, and the text color as a `CGColor`.
    func testChromiumFontSizeAndColorAreRead() throws {
        let style = try XCTUnwrap(CotypingAXHelper.extractFieldStyle(from: [
            NSAttributedString.Key("AXFont"): ["AXFontSize": NSNumber(value: 16)],
            NSAttributedString.Key("AXForegroundColor"): CGColor(srgbRed: 0.84, green: 0.85, blue: 0.86, alpha: 1),
        ]))

        XCTAssertNil(style.fontName)
        XCTAssertEqual(style.fontPointSize, 16)
        XCTAssertEqual(style.colorHex, "D6D9DB")
    }

    func testASizeAloneIsAStyle() {
        let style = CotypingAXHelper.extractFieldStyle(from: [
            NSAttributedString.Key("AXFont"): ["AXFontSize": NSNumber(value: 15)],
        ])
        XCTAssertEqual(style?.fontPointSize, 15)
    }

    /// Without extended accessibility Chromium sends an empty font.
    func testAnEmptyChromiumFontIsNoStyle() {
        XCTAssertNil(CotypingAXHelper.extractFieldStyle(from: [NSAttributedString.Key("AXFont"): [String: Any]()]))
    }
}
