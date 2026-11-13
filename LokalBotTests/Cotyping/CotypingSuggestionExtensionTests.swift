import XCTest
@testable import LokalBot

/// Topping up a suggestion while it is accepted. Cotypist keeps its ghost two
/// to five words ahead until the sentence ends; a suggestion that ran out
/// every three words and reappeared a moment later is what these rules replace.
final class CotypingSuggestionExtensionTests: XCTestCase {
    private typealias Rules = CotypingSuggestionExtension

    private func session(_ suggestion: String, after text: String = "The main tradeoff is",
                         openEnded: Bool = true,
                         kind: CotypingSuggestionKind = .continuation) -> CotypingSession {
        let field = CotypingField(appName: "Notes", processID: 0, role: "AXTextArea",
                                  precedingText: text, trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true)
        var session = CotypingSession(field: field, fullText: suggestion, kind: kind)
        session.isOpenEnded = openEnded
        return session
    }

    func testOnlyOutputCutByTheLengthLimitIsContinued() {
        XCTAssertTrue(Rules.isOpenEnded(" between the number", wordLimit: 3))
        // One word short still counts: the token budget can end before the last word is whole.
        XCTAssertTrue(Rules.isOpenEnded(" discuss how", wordLimit: 3))
        // A finished sentence, or a short answer the model chose to stop at, is left alone.
        XCTAssertFalse(Rules.isOpenEnded(" care of it.", wordLimit: 3))
        XCTAssertFalse(Rules.isOpenEnded(" 16:", wordLimit: 3))
        XCTAssertFalse(Rules.isOpenEnded(" first line\nsecond line", wordLimit: 3))
    }

    func testATopUpStartsOnceTwoWordsAreLeft() {
        let fresh = session(" between the number")
        XCTAssertFalse(Rules.shouldExtend(fresh, wordLimit: 3), "three words ahead is enough")
        let oneAccepted = fresh.advanced(by: " between".count)
        XCTAssertTrue(Rules.shouldExtend(oneAccepted, wordLimit: 3))
        // Typing part of the next word does not change how many words are left.
        XCTAssertTrue(Rules.shouldExtend(fresh.advanced(by: " between t".count), wordLimit: 3))
        XCTAssertFalse(Rules.shouldExtend(fresh.advanced(by: fresh.fullText.count), wordLimit: 3),
                       "an exhausted suggestion is replaced, not topped up")
    }

    func testAFinishedThoughtOrAReplacementIsNeverToppedUp() {
        let finished = session(" care of it.", openEnded: false).advanced(by: " care".count)
        XCTAssertFalse(Rules.shouldExtend(finished, wordLimit: 3))
        let correction = session("receive", kind: .correction(typoWord: "recieve"))
        XCTAssertFalse(Rules.shouldExtend(correction, wordLimit: 3))
    }

    func testTheThresholdFollowsTheLengthSetting() {
        XCTAssertEqual(Rules.threshold(wordLimit: 3), 2)
        XCTAssertEqual(Rules.threshold(wordLimit: 12), 2)
        XCTAssertEqual(Rules.threshold(wordLimit: 2), 1)
        // One word at a time means exactly that.
        XCTAssertEqual(Rules.threshold(wordLimit: 1), 0)
        let single = session(" between").advanced(by: " betw".count)
        XCTAssertFalse(Rules.shouldExtend(single, wordLimit: 1))
        let pair = session(" between the")
        XCTAssertFalse(Rules.shouldExtend(pair, wordLimit: 2))
        XCTAssertTrue(Rules.shouldExtend(pair.advanced(by: " between".count), wordLimit: 2))
    }

    func testATopUpIsOneWordShorterThanAFreshSuggestion() {
        XCTAssertEqual(Rules.topUpWordLimit(wordLimit: 4), 3)
        XCTAssertEqual(Rules.topUpWordLimit(wordLimit: 2), 1)
        XCTAssertEqual(Rules.topUpWordLimit(wordLimit: 1), 1)
    }

    func testTheModelContinuesFromTheEndOfTheWholeSuggestion() {
        let accepted = session(" between the number").advanced(by: " between".count)
        XCTAssertEqual(Rules.continuationPrefix(of: accepted), "The main tradeoff is between the number")
    }

    func testAnAdditionNeverChangesWordsAlreadyOnScreen() {
        let shown = " between the number"
        XCTAssertEqual(Rules.addition(from: " of menu items", to: shown), " of menu items")
        // Punctuation may attach to the last word.
        XCTAssertEqual(Rules.addition(from: ", and", to: shown), ", and")
        // "number" must not turn into "numbers" under the reader's eyes.
        XCTAssertNil(Rules.addition(from: "s of items", to: shown))
        XCTAssertNil(Rules.addition(from: "   ", to: shown))
        XCTAssertNil(Rules.addition(from: "", to: shown))
        XCTAssertNil(Rules.addition(from: " of\nitems", to: shown))
    }

    func testAnAdditionThatRepeatsTheSuggestionIsRefused() {
        XCTAssertNil(Rules.addition(from: " the number", to: " between the number"))
        XCTAssertNil(Rules.addition(from: " The  Number", to: " between the number"))
        XCTAssertEqual(Rules.addition(from: " the numbers add up", to: " between the number"),
                       " the numbers add up")
    }

    func testWordsAreCountedWithoutBarePunctuation() {
        XCTAssertEqual(Rules.wordCount(" up with you"), 3)
        XCTAssertEqual(Rules.wordCount(" it ."), 1)
        XCTAssertEqual(Rules.wordCount(" — "), 0)
        XCTAssertEqual(Rules.wordCount(""), 0)
    }
}

/// The Settings rehearsal tops up by the same rules as a live field.
final class CotypingRehearsalTopUpTests: XCTestCase {
    private let draft = "The main tradeoff is"

    func testAcceptingAWordAsksForMoreAndKeepsTheGhostAhead() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" between the number", after: draft, wordLimit: 3)
        XCTAssertNil(rehearsal.topUpPrefix(wordLimit: 3), "nothing is needed while three words are ahead")
        let first = try XCTUnwrap(rehearsal.accept(.chunk, text: draft, options: .init()))
        XCTAssertEqual(first, draft + " between")
        let prefix = try XCTUnwrap(rehearsal.topUpPrefix(wordLimit: 3))
        XCTAssertEqual(prefix, draft + " between the number")

        XCTAssertTrue(rehearsal.topUp(with: " of menu items", continuing: prefix, wordLimit: 3))
        XCTAssertEqual(rehearsal.ghost, " the number of menu items")
        XCTAssertNil(rehearsal.topUpPrefix(wordLimit: 3))
        // The accept keys walk straight on into the appended words.
        XCTAssertEqual(rehearsal.accept(.whole, text: first, options: .init()),
                       draft + " between the number of menu items")
    }

    func testATopUpForASuggestionThatHasMovedOnIsRefused() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" between the number", after: draft, wordLimit: 3)
        _ = try XCTUnwrap(rehearsal.accept(.chunk, text: draft, options: .init()))
        let prefix = try XCTUnwrap(rehearsal.topUpPrefix(wordLimit: 3))
        rehearsal.present(" that it costs", after: draft, wordLimit: 3)
        XCTAssertFalse(rehearsal.topUp(with: " of menu items", continuing: prefix, wordLimit: 3))
        XCTAssertEqual(rehearsal.ghost, " that it costs")
    }

    func testAFinishedSentenceAndAnUnlimitedSuggestionAreNotToppedUp() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" care of it.", after: "Sounds good, I can take", wordLimit: 3)
        _ = try XCTUnwrap(rehearsal.accept(.chunk, text: "Sounds good, I can take", options: .init()))
        XCTAssertNil(rehearsal.topUpPrefix(wordLimit: 3))

        // The fixed opening suggestion is presented without a limit.
        rehearsal.present(" up on the", after: draft)
        _ = try XCTUnwrap(rehearsal.accept(.chunk, text: draft, options: .init()))
        XCTAssertNil(rehearsal.topUpPrefix(wordLimit: 3))
    }

    func testTypingTheSuggestedWordsAsksForMoreJustAsAcceptingDoes() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" between the number", after: draft, wordLimit: 3)
        XCTAssertEqual(rehearsal.textChanged(to: draft + " between"), .advanced)
        let prefix = try XCTUnwrap(rehearsal.topUpPrefix(wordLimit: 3))
        XCTAssertEqual(prefix, draft + " between the number")
    }
}

/// Search boxes stay quiet.
final class CotypingSearchFieldDetectorTests: XCTestCase {
    func testSearchFieldsAreRecognizedByRoleOrSubrole() {
        XCTAssertTrue(CotypingSearchFieldDetector.isSearchField(role: "AXTextField", subrole: "AXSearchField"))
        XCTAssertTrue(CotypingSearchFieldDetector.isSearchField(role: "AXSearchField", subrole: nil))
        XCTAssertFalse(CotypingSearchFieldDetector.isSearchField(role: "AXTextField", subrole: nil))
        XCTAssertFalse(CotypingSearchFieldDetector.isSearchField(role: "AXTextArea", subrole: "AXUnknown"))
    }
}
