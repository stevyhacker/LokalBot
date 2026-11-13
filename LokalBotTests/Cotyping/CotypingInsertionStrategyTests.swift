import AppKit
import XCTest
@testable import LokalBot

// MARK: - IME composition input modes

final class CotypingCompositionModeClassifierTests: XCTestCase {
    func testPlainKeyboardLayoutIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: true,
                inputModeID: nil))
    }

    func testKnownComposingModesAreComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Japanese.Hiragana"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.SCIM.ITABC"))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Korean.2SetKorean"))
    }

    func testRomanDirectModeIsNotComposing() {
        XCTAssertFalse(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Roman"))
    }

    func testUnknownNonLayoutInputMethodIsComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: nil))
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.justsystems.inputmethod.atok33.Japanese"))
    }

    func testUnknownInputSourceTypeIsComposing() {
        XCTAssertTrue(
            CotypingCompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: nil,
                inputModeID: nil))
    }
}
