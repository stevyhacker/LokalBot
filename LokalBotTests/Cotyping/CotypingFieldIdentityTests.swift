import AppKit
import XCTest
@testable import LokalBot

final class CotypingFocusPrewarmIdentityTests: XCTestCase {
    private func field(
        preceding: String = "draft",
        focusIdentityKey: String? = "field-a",
        inputFrameRect: CGRect? = CGRect(x: 20, y: 40, width: 300, height: 44),
        windowTitle: String? = "Draft",
        fieldPlaceholder: String? = "Message"
    ) -> CotypingField {
        CotypingField(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            processID: 42,
            role: "AXTextArea",
            focusIdentityKey: focusIdentityKey,
            precedingText: preceding,
            trailingText: "",
            selectionLength: 0,
            caretRect: CGRect(x: 120, y: 40, width: 1, height: 18),
            inputFrameRect: inputFrameRect,
            isSecure: false,
            caretIsExact: true,
            windowTitle: windowTitle,
            fieldPlaceholder: fieldPlaceholder)
    }

    func testPrewarmIdentityIgnoresTextCaretAndSurfaceChurnWhenFocusIdentityExists() {
        let original = field()
        var changed = original
        changed.precedingText = "draft with more words"
        changed.caretRect = CGRect(x: 240, y: 40, width: 1, height: 18)
        changed.windowTitle = "Draft (edited)"
        changed.fieldPlaceholder = "Reply"

        XCTAssertEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: changed))
    }

    func testPrewarmIdentityChangesWithFocusedFieldIdentity() {
        let original = field(focusIdentityKey: "field-a")
        let other = field(focusIdentityKey: "field-b")

        XCTAssertNotEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: other))
    }

    func testSuggestionAnchorChangesWithFocusedFieldIdentity() {
        let original = field(focusIdentityKey: "field-a")
        let other = field(focusIdentityKey: "field-b")

        XCTAssertNotEqual(
            CotypingFieldIdentity.suggestionAnchor(for: original),
            CotypingFieldIdentity.suggestionAnchor(for: other))
    }

    func testSuggestionAnchorFallsBackToFrameWhenFocusIdentityIsMissing() {
        let original = field(
            focusIdentityKey: nil,
            inputFrameRect: CGRect(x: 20, y: 40, width: 300, height: 44))
        var changedTextAndSurface = original
        changedTextAndSurface.precedingText = "draft with more words"
        changedTextAndSurface.windowTitle = "Draft (edited)"
        changedTextAndSurface.fieldPlaceholder = "Reply"
        let otherFrame = field(
            focusIdentityKey: nil,
            inputFrameRect: CGRect(x: 20, y: 120, width: 300, height: 44))

        XCTAssertEqual(
            CotypingFieldIdentity.suggestionAnchor(for: original),
            CotypingFieldIdentity.suggestionAnchor(for: changedTextAndSurface))
        XCTAssertNotEqual(
            CotypingFieldIdentity.suggestionAnchor(for: original),
            CotypingFieldIdentity.suggestionAnchor(for: otherFrame))
    }

    func testPrewarmIdentityFallsBackToFrameWhenFocusIdentityIsMissing() {
        let original = field(focusIdentityKey: nil, inputFrameRect: CGRect(x: 20, y: 40, width: 300, height: 44))
        var changedTextAndTitle = original
        changedTextAndTitle.precedingText = "draft with more words"
        changedTextAndTitle.windowTitle = "Draft (edited)"
        let otherFrame = field(focusIdentityKey: nil, inputFrameRect: CGRect(x: 20, y: 120, width: 300, height: 44))

        XCTAssertEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: changedTextAndTitle))
        XCTAssertNotEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: otherFrame))
    }

    func testPrewarmIdentityUsesSurfaceOnlyAsLastResort() {
        let original = field(focusIdentityKey: nil, inputFrameRect: nil, windowTitle: "Draft", fieldPlaceholder: "Message")
        let sameSurface = field(focusIdentityKey: nil, inputFrameRect: nil, windowTitle: "Draft", fieldPlaceholder: "Message")
        let differentSurface = field(focusIdentityKey: nil, inputFrameRect: nil, windowTitle: "Thread", fieldPlaceholder: "Reply")

        XCTAssertEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: sameSurface))
        XCTAssertNotEqual(
            CotypingFieldIdentity.prewarm(for: original),
            CotypingFieldIdentity.prewarm(for: differentSurface))
    }
}

final class CotypingAXFocusIdentityKeyTests: XCTestCase {
    func testDuplicateAXIdentifiersStillRequireTheSameConcreteElement() {
        let first = CotypingAXFocusIdentityKey.make(
            processID: 42,
            bundleID: "com.example.Editor",
            role: "AXTextArea",
            subrole: nil,
            axIdentifier: "reused-editor-id",
            elementHash: 100)
        let second = CotypingAXFocusIdentityKey.make(
            processID: 42,
            bundleID: "com.example.Editor",
            role: "AXTextArea",
            subrole: nil,
            axIdentifier: "reused-editor-id",
            elementHash: 200)

        XCTAssertNotEqual(first, second)
    }

    func testSameConcreteElementKeepsStableIdentityWithOrWithoutLabel() {
        XCTAssertEqual(
            CotypingAXFocusIdentityKey.make(
                processID: 42,
                bundleID: nil,
                role: "AXTextField",
                subrole: "AXSearchField",
                axIdentifier: nil,
                elementHash: 100),
            CotypingAXFocusIdentityKey.make(
                processID: 42,
                bundleID: nil,
                role: "AXTextField",
                subrole: "AXSearchField",
                axIdentifier: "",
                elementHash: 100))
    }
}
