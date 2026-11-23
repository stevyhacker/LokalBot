import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class DictationPasteSeamTests: XCTestCase {
    private static let everyday: Set<String> = ["probably", "next", "buy", "then", "zeit"]

    private func fit(_ before: String?, _ text: String, english: Bool = true) -> DictationPasteSeam.Fit {
        DictationPasteSeam.fit(text, textBeforeCaret: before, lowersSentenceCapital: english,
                               isEverydayWord: { Self.everyday.contains($0) })
    }

    func testBackToBackDictationsGetASpace() {
        XCTAssertEqual(fit("right now.", "Next one"), .init(text: " Next one", addedSpace: true))
        XCTAssertEqual(fit("Note:", "Next").text, " Next")
    }

    func testNoSpaceAfterWhitespaceOrANewLine() {
        XCTAssertEqual(fit("Hello ", "world").text, "world")
        XCTAssertEqual(fit("line\n", "Next").text, "Next")
    }

    func testAnUnreadOrEmptyFieldGetsTheTextUnchanged() {
        XCTAssertEqual(fit(nil, "Next one"), .init(text: "Next one"), "nothing read, nothing changed")
        XCTAssertEqual(fit("", "Next one"), .init(text: "Next one"), "the start of an empty field")
    }

    func testNoSpaceAfterAnOpeningCharacter() {
        for opening in ["(", "[", "“", "/", "@", "#", "$", "-"] {
            XCTAssertEqual(fit("see " + opening, "aside").text, "aside", opening)
        }
    }

    func testNoSpaceBeforeADictationThatAttachesToTheTextBefore() {
        XCTAssertEqual(fit("word", ", and").text, ", and")
        XCTAssertEqual(fit("ok", "…").text, "…")
        XCTAssertEqual(fit("done", "!").text, "!")
    }

    func testAStraightQuoteOpensOrClosesByWhatComesBeforeIt() {
        XCTAssertEqual(fit("He said \"", "hi").text, "hi", "opening quote")
        XCTAssertEqual(fit("\"", "hi").text, "hi", "a quote at the start of the field opens")
        XCTAssertEqual(fit("He said \"hi.\"", "Then").text, " Then", "closing quote after a sentence")
    }

    func testScriptsWrittenWithoutSpacesGetNoSpace() {
        XCTAssertEqual(fit("我们", "今天").text, "今天", "Chinese")
        XCTAssertEqual(fit("こんにちは", "世界").text, "世界", "Japanese")
        XCTAssertEqual(fit("สวัสดี", "ครับ").text, "ครับ", "Thai")
        XCTAssertEqual(fit("Hello", "今天").text, "今天", "Chinese after Latin")
        XCTAssertEqual(fit("今天。", "Hello").text, "Hello", "Latin after Chinese punctuation")
        XCTAssertEqual(fit("안녕하세요", "감사").text, " 감사", "Korean separates words with spaces")
    }

    func testAnEverydayFirstWordIsLoweredInTheMiddleOfASentence() {
        XCTAssertEqual(fit("we should", "Probably wait"),
                       .init(text: " probably wait", addedSpace: true, loweredFirstWord: true))
        XCTAssertEqual(fit("we should ", "Probably wait"),
                       .init(text: "probably wait", loweredFirstWord: true))
        XCTAssertEqual(fit("we should", "Probably").text, " probably", "a one-word dictation")
    }

    func testIAcronymsNamesAndMixedCaseKeepTheirCapitals() {
        XCTAssertEqual(fit("we should", "I think").text, " I think")
        XCTAssertEqual(fit("we should", "I'm sure").text, " I'm sure")
        XCTAssertEqual(fit("we should", "I’ll ask").text, " I’ll ask")
        XCTAssertEqual(fit("we should", "NASA said").text, " NASA said")
        XCTAssertEqual(fit("we should", "McDonald said").text, " McDonald said")
        XCTAssertEqual(fit("we should", "iPhone").text, " iPhone")
        XCTAssertEqual(fit("we should", "Priya said").text, " Priya said", "not an everyday word: a name")
    }

    func testASentenceStartKeepsItsCapital() {
        XCTAssertEqual(fit("Done.", "Next").text, " Next")
        XCTAssertEqual(fit("Done.\"", "Next").text, " Next", "a closing quote after the period")
        XCTAssertEqual(fit("Done!) ", "Next").text, "Next", "a closing bracket after the mark")
        XCTAssertEqual(fit("Is it?", "Then").text, " Then")
        XCTAssertEqual(fit("你好。", "Next").text, "Next")
        XCTAssertEqual(fit("First line\n", "Next").text, "Next", "a new line")
        XCTAssertEqual(fit("First line\n  ", "Next").text, "Next", "a new indented line")
    }

    func testAListItemsMarkerStartsASentence() {
        for marker in ["- ", "* ", "• ", "1. ", "12) ", "a) ", "notes\n  - "] {
            XCTAssertEqual(fit(marker, "Buy milk").text, "Buy milk", marker)
        }
    }

    func testCapitalsAreLeftAloneWhenTheRuleDoesNotApply() {
        XCTAssertEqual(fit("wir haben keine", "Zeit", english: false),
                       .init(text: " Zeit", addedSpace: true), "German nouns keep their capitals")
    }

    func testTheCapitalRuleIsEnglishOnly() {
        XCTAssertTrue(DictationPasteSeam.lowersSentenceCapital(language: .en, text: "irrelevant"))
        XCTAssertFalse(DictationPasteSeam.lowersSentenceCapital(language: .de, text: "we should probably wait"))
        XCTAssertTrue(DictationPasteSeam.lowersSentenceCapital(
            language: .auto, text: "I think we should probably wait for the reply before we send it"))
        XCTAssertFalse(DictationPasteSeam.lowersSentenceCapital(
            language: .auto, text: "Ich glaube, wir sollten auf die Antwort warten, bevor wir sie schicken"))
    }

    func testTheEverydayWordCheckKeepsWordsTheDictionaryCapitalizes() throws {
        try XCTSkipUnless(NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix("en") },
                          "no English dictionary on this Mac")
        for word in ["testing", "probably", "next", "then"] {
            XCTAssertTrue(DictationPasteSeam.isEverydayEnglishWord(word), word)
        }
        for word in ["monday", "january", "english", "french", "google", "christmas", "priya"] {
            XCTAssertFalse(DictationPasteSeam.isEverydayEnglishWord(word), word)
        }
    }

    func testThePasteUsesTheFittedText() async {
        let inserter = CotypingInserter()
        let outcome = await inserter.insertViaPaste("Next one", fitToField: { _ in "" })
        XCTAssertEqual(outcome, .failed)
    }

    func testAQueuedPasteIsFittedWhenItsTurnComes() async throws {
        let inserter = CotypingInserter()
        let gate = SeamGate()
        var order: [String] = []
        let first = Task {
            await inserter.insertViaPaste("first", fitToField: { _ in
                await gate.wait()
                order.append("first fitted")
                return ""
            })
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task {
            await inserter.insertViaPaste("second", fitToField: { _ in
                order.append("second fitted")
                return ""
            })
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(order, [], "the second paste waits for the first")
        gate.open()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(order, ["first fitted", "second fitted"])
    }
}

@MainActor
private final class SeamGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
