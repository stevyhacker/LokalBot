import AppKit
import XCTest
@testable import LokalBot

// MARK: - Prefix window + gating

final class CotypingPrefixWindowTests: XCTestCase {
    func testShouldGenerateRequiresNonWhitespace() {
        XCTAssertFalse(CotypingPrefixWindow.shouldGenerate(for: "   \n"))
        XCTAssertTrue(CotypingPrefixWindow.shouldGenerate(for: "hi"))
    }

    func testKeepsTrailingWords() {
        let windowed = CotypingPrefixWindow.truncatedPrefix(
            from: "one two three four", maxCharacters: 100, maxWords: 2)
        XCTAssertEqual(windowed, "three four")
    }

    func testCharacterWindowBoundsLongText() {
        let windowed = CotypingPrefixWindow.truncatedPrefix(
            from: String(repeating: "a", count: 50), maxCharacters: 5, maxWords: 10)
        XCTAssertEqual(windowed, "aaaaa")
    }

    func testPreservesParagraphsListsAndCaretIndentation() {
        let text = "Hi Ana,\n\nNext steps:\n  1. Review\n  2. "
        XCTAssertEqual(CotypingPrefixWindow.truncatedPrefix(
            from: text, maxCharacters: 2500, maxWords: 500), text)
        XCTAssertEqual(CotypingPrefixWindow.truncatedPrefix(
            from: text, maxCharacters: 2500, maxWords: 3), "1. Review\n  2. ")
    }

    /// Typing on at the end of a long draft keeps the window's start in
    /// place, so the model does not read the whole window again per keystroke.
    func testALongDraftsWindowStartStaysPutWhileTyping() {
        let sentence = "We reviewed the onboarding funnel again this week. "
        let draft = String(repeating: sentence, count: 80) + "The next step is to share"
        var starts = Set<String>()
        for typed in ["", " t", " the", " the res", " the results"] {
            let window = CotypingPrefixWindow.truncatedPrefix(from: draft + typed, maxCharacters: 2500, maxWords: 500)
            XCTAssertTrue(window.hasPrefix("We reviewed"))
            XCTAssertTrue(window.hasSuffix("share" + typed))
            XCTAssertLessThanOrEqual(window.count, 2500)
            starts.insert(String(window.prefix(200)))
        }
        XCTAssertEqual(starts.count, 1)
    }

    func testZeroBudgetDoesNotCrashOrRetainContext() {
        XCTAssertEqual(CotypingPrefixWindow.truncatedPrefix(from: "hello", maxCharacters: 0, maxWords: 3), "")
        XCTAssertEqual(CotypingPrefixWindow.truncatedPrefix(from: "hello", maxCharacters: 3, maxWords: 0), "")
    }
}

// MARK: - Request builder

final class CotypingRequestBuilderTests: XCTestCase {
    private func field(preceding: String, trailing: String = "") -> CotypingField {
        CotypingField(
            appName: "Notes", bundleID: "com.apple.Notes", processID: 1, role: "AXTextArea",
            precedingText: preceding, trailingText: trailing, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true)
    }

    func testNilForBlankContext() {
        let request = CotypingRequestBuilder.build(
            field: field(preceding: "   "), config: .standard,
            personalization: .none, generation: 1)
        XCTAssertNil(request)
    }

    func testBuildsRequestWithPrefixAndGeneration() throws {
        var config = CotypingConfiguration.standard
        config.maxResponseWords = 12
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "Hello there"), config: config,
            personalization: .none, generation: 7))
        XCTAssertEqual(request.prefixText, "Hello there")
        XCTAssertEqual(request.prompt, "Hello there")
        XCTAssertEqual(request.generation, 7)
        XCTAssertEqual(request.maxTokens, CotypingConfiguration.standard.maxResponseTokens)
        XCTAssertEqual(request.maxWords, 12)
        XCTAssertFalse(request.isMultiLine)
        XCTAssertNil(request.conditioningPreface)
    }

    func testPersonalizationEntersPrompt() throws {
        let personalization = CotypingPersonalization(
            userName: "Sam", styleNote: nil, languageHint: nil, isMultiLine: true, appContextEnabled: false)
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "Dear team"), config: .standard,
            personalization: personalization, generation: 0))
        XCTAssertTrue(request.prompt.hasPrefix("Written by Sam."))
        XCTAssertEqual(request.conditioningPreface, "Written by Sam.")
        XCTAssertTrue(request.isMultiLine)
    }

    func testCapturesWordPrefixAtCaretWithSpellVerdict() throws {
        // The fragment at the caret plus the injected spell-checker verdict are
        // what arm the normalizer's word-completion mismatch guard downstream.
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "I want to rec"), config: .standard,
            personalization: .none, generation: 0, wordPrefixIsValidWord: false))
        XCTAssertEqual(request.wordPrefixAtCaret, "rec")
        XCTAssertFalse(request.wordPrefixIsValidWord)
    }

    func testWordPrefixIsEmptyAtWordBoundary() throws {
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: "I want to "), config: .standard,
            personalization: .none, generation: 0))
        XCTAssertEqual(request.wordPrefixAtCaret, "")
        XCTAssertTrue(request.prompt.hasSuffix("I want to "))
    }

    func testProductionRequestKeepsEarlierDocumentFacts() throws {
        let text = "Release owner: Irena.\n\n" + String(repeating: "reviewed item ", count: 100) + "\nAsk "
        let request = try XCTUnwrap(CotypingRequestBuilder.build(
            field: field(preceding: text), config: .standard, personalization: .none, generation: 0))
        XCTAssertEqual(request.prefixText, text)
        XCTAssertEqual(request.prompt, text)
    }
}
