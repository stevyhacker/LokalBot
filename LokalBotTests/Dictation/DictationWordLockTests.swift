import XCTest
@testable import LokalBot

final class DictationWordLockTests: XCTestCase {
    private func broken(_ spoken: String, _ cleaned: String, glossary: String? = nil) -> [DictationWordLock.Reason] {
        DictationWordLock.broken(spoken: spoken, cleaned: cleaned, glossary: glossary)
    }

    func testFluentCleanupPasses() {
        XCTAssertEqual(broken("um so the meeting is at 3 tomorrow", "The meeting is at 3 tomorrow."), [])
        XCTAssertEqual(broken("lets ship the 6 fixes tomorrow", "Let's ship the 6 fixes tomorrow."), [])
        XCTAssertEqual(broken("we are not ready we are not ready yet", "We are not ready yet."), [])
        XCTAssertEqual(broken("call 14:30 with Orion", "Call at 14:30 with Orion."), [])
    }

    func testDigitsMustStayAsSpoken() {
        XCTAssertEqual(broken("Can you send me the 4 slides before noon?", "Can you send me the four slides before noon?"),
                       [.digits], "spelled out")
        XCTAssertEqual(broken("Javi mi sutra da li dolaziš na 3 sastanka.", "Javi mi sutra da li dolaziš na tri sastanka."),
                       [.digits], "in any language")
        XCTAssertEqual(broken("we meet at 3", "We meet at 3 or 4."), [.digits], "a digit is never invented")
        XCTAssertEqual(broken("the budget is 120", "The budget is 1,200."), [.digits])
    }

    func testNegationMustNotDisappear() {
        XCTAssertEqual(broken("i'm not ready to sign yet", "I'm ready to sign."), [.negation])
        XCTAssertEqual(broken("don't send the draft", "Send the draft."), [.negation])
        XCTAssertEqual(broken("we never ship on fridays", "We ship on Fridays."), [.negation])
        XCTAssertEqual(broken("i can't make the call", "I cannot make the call."), [], "same negation, other spelling")
        XCTAssertEqual(broken("don't merge it", "Do not merge it."), [])
        XCTAssertEqual(broken("uh no I don't think that works", "I don't think that works."), [],
                       "an opening \"no\" is an answer, not a negation")
        XCTAssertEqual(broken("there is no budget left", "There is budget left."), [.negation])
    }

    func testNamesMustSurviveUnlessRespelledFromTheGlossary() {
        XCTAssertEqual(broken("send it to Mila Novak today", "Send it to Mila today."), [.names])
        XCTAssertEqual(broken("send it to Mila Novack today", "Send it to Mila Novak today.", glossary: "Mila Novak, Orion"),
                       [], "a respelling to a glossary term is a fix")
        XCTAssertEqual(broken("send it to Mila Novack today", "Send it to Mila Novak today."), [.names])
        XCTAssertEqual(broken("I think I'll call later", "I'll call later."), [], "\"I\" is not a name")
        XCTAssertEqual(broken("Marko said yes", "He said yes."), [], "a sentence's first word isn't treated as a name")
    }

    func testWhatRealSpeechRecognitionLooksLikeDoesNotTripTheLock() {
        XCTAssertEqual(broken("we checked the items Related to the order Was it shipped",
                              "We checked the items related to the order. Was it shipped?"), [],
                       "a capital that only marks a missed sentence start may be lowered")
        XCTAssertEqual(broken("the bill came to 1500 dollars", "The bill came to 1,500 dollars."), [], "grouping only")
        XCTAssertEqual(broken("the bill came to 1500 dollars", "The bill came to 1 500 dollars."), [])
        XCTAssertEqual(broken("it was twelve hundred dollars", "It was 1200 dollars."), [], "spoken numbers may become digits")
        XCTAssertEqual(broken("meet me at 930 tomorrow", "Meet me at 9:30 tomorrow."), [], "same digits, a time's colon added")
        XCTAssertEqual(broken("the code is 213 292", "The code is 213-292."), [])
        XCTAssertEqual(broken("there was not anything left", "There was nothing left."), [], "negation by meaning")
        XCTAssertEqual(broken("we are not done", "We are done."), [.negation])
        XCTAssertEqual(broken("ask Zorana to call", "Ask Zarana to call."), [.names], "a respelled name still counts")
    }

    func testASelfCorrectionMayDropWhatItCorrects() {
        XCTAssertEqual(broken("let's meet at 3, no, 4", "Let's meet at 4."), [])
        XCTAssertEqual(broken("send it to Ana I mean Mila", "Send it to Mila."), [])
        XCTAssertEqual(broken("let's meet at 3, no, 4", "Let's meet at 4 or 5."), [.digits], "inventing a digit still breaks it")
    }

    func testATimeOrDecimalSpelledOutKeepsTheTranscriptInsteadOfLosingItsSeparator() {
        let lock = DictationWordLock.digitsNamesNegation
        let time = lock.kept(spoken: "um the call is at 3:30 tomorrow", cleaned: "The call is at three thirty tomorrow.")
        XCTAssertEqual(time.text, "um the call is at 3:30 tomorrow")
        XCTAssertEqual(time.broken, [.digits])
        let decimal = lock.kept(spoken: "it grew 2.5 percent", cleaned: "It grew two point five percent.")
        XCTAssertEqual(decimal.text, "it grew 2.5 percent")
        let mixed = lock.kept(spoken: "at 3:30 for 2 weeks", cleaned: "At 3:30 for two weeks.")
        XCTAssertEqual(mixed.text, "At 3:30 for 2 weeks.")
    }

    func testSpelledOutNumbersAreTurnedBackIntoTheSpokenDigits() {
        let lock = DictationWordLock.production
        XCTAssertEqual(lock.kept(spoken: "uh the last 3 releases slipped", cleaned: "The last three releases slipped.").text,
                       "The last 3 releases slipped.", "cleanup is kept and the digit comes back")
        XCTAssertEqual(lock.kept(spoken: "we need 2 or 3 people for about 25 minutes",
                                 cleaned: "We need two or three people for about twenty-five minutes.").text,
                       "We need 2 or 3 people for about 25 minutes.")
        XCTAssertEqual(lock.kept(spoken: "one of us will call at 3", cleaned: "One of us will call at three.").text,
                       "One of us will call at 3.", "a pronoun \"one\" is left alone")
        let serbian = lock.kept(spoken: "Javi mi sutra da li dolaziš na 3 sastanka.", cleaned: "Javi mi sutra da li dolaziš na tri sastanka.")
        XCTAssertEqual(serbian.text, "Javi mi sutra da li dolaziš na 3 sastanka.")
        XCTAssertEqual(serbian.broken, [.digits], "only English number words are turned back")
        XCTAssertEqual(lock.kept(spoken: "we meet at 3", cleaned: "We meet at three or 4.").broken, [.digits],
                       "an invented digit still keeps the transcript")
        XCTAssertNil(DictationWordLock.restoringDigits(spoken: "no digits here", cleaned: "No digits here."))
        XCTAssertEqual(lock.kept(spoken: "honestly the last 3 releases slipped and I would rather wait",
                                 cleaned: "Honestly, the last three releases slipped, and I would rather wait.").text,
                       "Honestly, the last 3 releases slipped, and I would rather wait.",
                       "an everyday \"rather\" or \"wait\" doesn't let a spelled-out digit through")
        XCTAssertEqual(lock.kept(spoken: "let's meet at 3, no, 4", cleaned: "Let's meet at 4.").text, "Let's meet at 4.",
                       "a real self-correction is left as cleaned")
    }

    func testASpokenNumberWordIsNotMistakenForTheDigitToRestore() {
        let lock = DictationWordLock.production
        XCTAssertEqual(lock.kept(spoken: "one of us needs 1 ticket", cleaned: "One of us needs one ticket.").text,
                       "One of us needs 1 ticket.", "the spoken \"one\" stays a word; the spoken digit comes back")
        XCTAssertEqual(lock.kept(spoken: "book 2 rooms for two nights", cleaned: "Book two rooms for two nights.").text,
                       "Book 2 rooms for two nights.")
        let dropped = lock.kept(spoken: "one one of us needs 1 ticket", cleaned: "Of us needs one ticket.")
        XCTAssertEqual(dropped.text, "one one of us needs 1 ticket", "when the words don't line up the transcript is kept")
        XCTAssertEqual(dropped.broken, [.digits])
    }

    func testAddedDigitsMustComeFromTheSpokenNumberWords() {
        let lock = DictationWordLock.production
        let invented = lock.kept(spoken: "we need 3 slides and one summary", cleaned: "We need 34 slides and one summary.")
        XCTAssertEqual(invented.broken, [.digits], "a number word elsewhere doesn't excuse an invented digit")
        XCTAssertEqual(invented.text, "we need 3 slides and one summary")
        XCTAssertEqual(lock.kept(spoken: "twelve of them arrive at 3", cleaned: "12 of them arrive at 3.").broken, [])
        XCTAssertEqual(lock.kept(spoken: "it was twenty twenty six by then", cleaned: "It was 2026 by then.").broken, [])
        XCTAssertEqual(lock.kept(spoken: "about twelve hundred dollars", cleaned: "About 1200 dollars.").broken, [],
                       "hundreds and thousands are not converted, so they stay allowed")
    }

    func testTheLockKeepsTheTranscriptOnlyWhenOn() {
        let spoken = "Can you send me the 4 slides?"
        let cleaned = "Can you send me the 4 or 5 slides?"
        XCTAssertEqual(DictationWordLock.production, .digitsNamesNegation)
        XCTAssertEqual(DictationWordLock.production.kept(spoken: spoken, cleaned: cleaned).text, spoken)
        XCTAssertEqual(DictationWordLock.production.kept(spoken: spoken, cleaned: cleaned).broken, [.digits])
        XCTAssertEqual(DictationWordLock.off.kept(spoken: spoken, cleaned: cleaned).text, cleaned)
        XCTAssertEqual(DictationWordLock.production.kept(spoken: spoken, cleaned: "Can you send me the 4 slides?").text,
                       "Can you send me the 4 slides?")
    }

    func testPrepareLocksCleanedDirectSpeechButNotWritingRequests() async throws {
        var settings = AppSettings()
        settings.dictationIntent = .compose
        let engine = WordLockTestEngine(reply: "Can you send me the four slides before noon?")
        let restored = try await DictationTextPreparation.prepare(
            speech: "can you send me the 4 slides before noon", settings: settings,
            screenContext: { nil }, makeEngine: { _ in engine })
        XCTAssertEqual(restored.text, "Can you send me the 4 slides before noon?")

        let inventing = WordLockTestEngine(reply: "Can you send me the 4 or 5 slides before noon?")
        let locked = try await DictationTextPreparation.prepare(
            speech: "can you send me the 4 slides before noon", settings: settings,
            screenContext: { nil }, makeEngine: { _ in inventing })
        XCTAssertEqual(locked.text, "can you send me the 4 slides before noon")

        let unlocked = try await DictationTextPreparation.prepare(
            speech: "can you send me the 4 slides before noon", settings: settings,
            screenContext: { nil }, wordLock: .off, makeEngine: { _ in engine })
        XCTAssertEqual(unlocked.text, "Can you send me the four slides before noon?")

        let request = WordLockTestEngine(reply: "The session starts at 14:30.")
        let composed = try await DictationTextPreparation.prepare(
            speech: "Reply with the start time from the message above.", settings: settings,
            screenContext: { nil }, makeEngine: { _ in request })
        XCTAssertEqual(composed.text, "The session starts at 14:30.", "a writing request's answer is not locked")
    }
}

private final class WordLockTestEngine: TextEngine {
    let reply: String
    init(reply: String) { self.reply = reply }
    var displayName: String { "Synthetic" }
    func generate(system: String, prompt: String, context: [String]) async throws -> String { reply }
}
