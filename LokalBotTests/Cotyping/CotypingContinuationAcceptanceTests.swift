import XCTest
@testable import LokalBot

/// One accept keypress, planned once for both the live accept tap and the
/// Settings rehearsal.
final class CotypingContinuationAcceptanceTests: XCTestCase {
    private typealias Options = CotypingContinuationAcceptance.Options

    private func session(_ suggestion: String, after text: String, consumed: Int = 0) -> CotypingSession {
        let field = CotypingField(appName: "Notes", processID: 0, role: "AXTextArea",
                                  precedingText: text, trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true)
        return CotypingSession(field: field, fullText: suggestion, consumedCount: consumed)
    }

    private func plan(_ suggestion: String, after text: String, scope: CotypingAcceptScope = .chunk,
                      trailing: String = "", options: Options = .init()) -> CotypingContinuationAcceptance? {
        CotypingContinuationAcceptance.plan(session: session(suggestion, after: text), scope: scope,
                                           precedingText: text, trailingText: trailing, options: options)
    }

    func testWordGranularityTakesOneWord() {
        let acceptance = plan(" up on the timeline.", after: "I wanted to follow")
        XCTAssertEqual(acceptance?.acceptedChunk, " up")
        XCTAssertEqual(acceptance?.insertionText, " up")
        XCTAssertEqual(acceptance?.forwardDeleteCount, 0)
    }

    func testPhraseGranularityStopsAtTheSentence() {
        let acceptance = plan(" up tomorrow. Then we plan.", after: "I will follow",
                              options: .init(granularity: .phrase))
        XCTAssertEqual(acceptance?.acceptedChunk, " up tomorrow.")
    }

    func testTheFullAcceptKeyTakesEverythingWhateverTheGranularity() {
        for granularity in CotypingAcceptGranularity.allCases {
            let acceptance = plan(" up on the timeline.", after: "I wanted to follow", scope: .whole,
                                  options: .init(granularity: granularity))
            XCTAssertEqual(acceptance?.acceptedChunk, " up on the timeline.")
        }
    }

    func testSpacingAndPunctuationFollowTheAcceptanceSettings() {
        // A space the field already has is not inserted twice.
        XCTAssertEqual(plan(" world again", after: "Hello ")?.insertionText, "world")
        // A new sentence gets its separating space.
        XCTAssertEqual(plan("Next step", after: "Done.")?.insertionText, " Next")
        // Punctuation is its own keypress unless the setting attaches it.
        let attached = Options(autoAcceptTrailingPunctuation: true)
        XCTAssertEqual(plan(" yes, please", after: "I say")?.acceptedChunk, " yes")
        XCTAssertEqual(plan(" yes, please", after: "I say", options: attached)?.acceptedChunk, " yes,")
        // The optional trailing space is added only when the suggestion ends.
        let spaced = Options(addSpaceAfterAccept: true)
        XCTAssertEqual(plan(" soon", after: "See you", options: spaced)?.insertionText, " soon ")
        XCTAssertEqual(plan(" very soon", after: "See you", options: spaced)?.insertionText, " very ")
    }

    func testCompletingAWordReplacesItsTypedTail() {
        let acceptance = plan("ld peace", after: "Hello wor", scope: .whole, trailing: "ld!")
        XCTAssertEqual(acceptance?.insertionText, "ld peace")
        XCTAssertEqual(acceptance?.forwardDeleteCount, 2)
    }

    func testAnExhaustedSuggestionPlansNothing() {
        let done = session(" up", after: "follow", consumed: 3)
        XCTAssertNil(CotypingContinuationAcceptance.plan(
            session: done, scope: .chunk, precedingText: "follow up", trailingText: "", options: .init()))
    }

    func testOptionsMirrorTheSettings() {
        var settings = AppSettings()
        settings.cotypingAcceptGranularity = .phrase
        settings.cotypingAutoAcceptTrailingPunctuation = true
        settings.cotypingAddSpaceAfterAccept = true
        XCTAssertEqual(Options(settings: settings),
                       Options(granularity: .phrase, autoAcceptTrailingPunctuation: true, addSpaceAfterAccept: true))
        XCTAssertEqual(Options(settings: AppSettings()), Options())
    }

    func testHintNamesWhatEachKeyTakes() {
        XCTAssertEqual(CotypingAcceptHint.text(acceptKey: .tab, fullAcceptKey: .backtick, granularity: .word),
                       "Tab accepts the next word · ` accepts the rest · Esc dismisses")
        XCTAssertEqual(CotypingAcceptHint.text(acceptKey: .tab, fullAcceptKey: .off, granularity: .phrase),
                       "Tab accepts the next phrase · Esc dismisses")
        // The primary key wins when both keys are the same one.
        XCTAssertEqual(CotypingAcceptHint.text(acceptKey: .rightArrow, fullAcceptKey: .rightArrow, granularity: .word),
                       "Right Arrow accepts the next word · Esc dismisses")
    }
}

/// The rehearsal editor's suggestion state: the behavior a user sees when they
/// try autocomplete in Settings before relying on it elsewhere.
final class CotypingRehearsalTests: XCTestCase {
    private let draft = "Hi Sarah, thanks for the update. I wanted to follow"

    /// "One word" used to insert the whole suggestion on the first Tab.
    func testOneWordPerAcceptKeepsTheRestOfTheSuggestion() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" up on the timeline.", after: draft)
        let first = try XCTUnwrap(rehearsal.accept(.chunk, text: draft, options: .init()))
        XCTAssertEqual(first, draft + " up")
        XCTAssertEqual(rehearsal.ghost, " on the timeline.")
        // The editor reports the accepted text back; that is not a stale edit.
        XCTAssertEqual(rehearsal.textChanged(to: first), .unchanged)
        let second = try XCTUnwrap(rehearsal.accept(.chunk, text: first, options: .init()))
        XCTAssertEqual(second, draft + " up on")
        XCTAssertEqual(rehearsal.ghost, " the timeline.")
        let rest = try XCTUnwrap(rehearsal.accept(.whole, text: second, options: .init()))
        XCTAssertEqual(rest, draft + " up on the timeline.")
        XCTAssertEqual(rehearsal.ghost, "")
        XCTAssertEqual(rehearsal.textChanged(to: rest), .stale, "a finished suggestion asks for the next one")
    }

    func testOnePhrasePerAcceptStopsAtEachSentence() throws {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" up tomorrow. Then we plan.", after: draft)
        let phrase = Self.options(.phrase)
        let first = try XCTUnwrap(rehearsal.accept(.chunk, text: draft, options: phrase))
        XCTAssertEqual(first, draft + " up tomorrow.")
        XCTAssertEqual(rehearsal.ghost, " Then we plan.")
        XCTAssertEqual(rehearsal.accept(.chunk, text: first, options: phrase), draft + " up tomorrow. Then we plan.")
        XCTAssertEqual(rehearsal.ghost, "")
    }

    func testTypingTheSuggestedCharactersWalksThroughTheGhost() {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" up on", after: draft)
        XCTAssertEqual(rehearsal.textChanged(to: draft + " "), .advanced)
        XCTAssertEqual(rehearsal.ghost, "up on")
        XCTAssertEqual(rehearsal.textChanged(to: draft + " up"), .advanced)
        XCTAssertEqual(rehearsal.ghost, " on")
        // Tab then continues from what was typed.
        XCTAssertEqual(rehearsal.accept(.chunk, text: draft + " up", options: .init()), draft + " up on")
    }

    func testAnyOtherEditDiscardsTheSuggestion() {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" up on", after: draft)
        XCTAssertEqual(rehearsal.textChanged(to: draft + " x"), .stale)
        XCTAssertEqual(rehearsal.ghost, "")
        rehearsal.present(" up on", after: draft)
        XCTAssertEqual(rehearsal.textChanged(to: String(draft.dropLast())), .stale)
        XCTAssertEqual(rehearsal.ghost, "")
        // Typing the suggestion to its end also needs a new one.
        rehearsal.present(" up", after: draft)
        XCTAssertEqual(rehearsal.textChanged(to: draft + " up"), .stale)
    }

    func testAnAcceptAgainstChangedTextInsertsNothing() {
        var rehearsal = CotypingRehearsal()
        rehearsal.present(" up on", after: draft)
        XCTAssertNil(rehearsal.accept(.chunk, text: draft + "ing", options: .init()))
        rehearsal.dismiss()
        XCTAssertNil(rehearsal.accept(.whole, text: draft, options: .init()))
        rehearsal.present("", after: draft)
        XCTAssertEqual(rehearsal.ghost, "")
    }

    /// Accepting piece by piece must reproduce the suggestion exactly, for
    /// accents, emoji, punctuation runs and scripts written without spaces.
    func testAcceptingPieceByPieceReproducesTheSuggestion() throws {
        let suggestions = [
            " up on the migration timeline we scoped yesterday.",
            " café — déjà vu, naïve 🙂.",
            " („Zitat“) – fertig!",
            "明天见面。然后再讨论。",
            " one\ttwo  three",
        ]
        for suggestion in suggestions {
            for granularity in CotypingAcceptGranularity.allCases {
                var rehearsal = CotypingRehearsal()
                var text = "Notes"
                rehearsal.present(suggestion, after: text)
                var presses = 0
                while !rehearsal.ghost.isEmpty {
                    text = try XCTUnwrap(rehearsal.accept(.chunk, text: text, options: Self.options(granularity)),
                                         "\(suggestion) stalled at \(rehearsal.ghost)")
                    presses += 1
                    XCTAssertLessThan(presses, 40)
                }
                XCTAssertEqual(text, "Notes" + suggestion, "\(granularity) changed the text of \(suggestion)")
                if granularity == .word, suggestion.contains(" on ") {
                    XCTAssertGreaterThan(presses, 3, "one word per press, not the whole suggestion")
                }
            }
        }
    }

    private static func options(_ granularity: CotypingAcceptGranularity) -> CotypingContinuationAcceptance.Options {
        .init(granularity: granularity)
    }
}
