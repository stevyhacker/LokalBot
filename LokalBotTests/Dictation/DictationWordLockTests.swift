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
        XCTAssertEqual(broken("there was not anything left", "There was nothing left."), [], "negation by meaning")
        XCTAssertEqual(broken("we are not done", "We are done."), [.negation])
        XCTAssertEqual(broken("ask Zorana to call", "Ask Zarana to call."), [.names], "a respelled name still counts")
    }

    func testASelfCorrectionMayDropWhatItCorrects() {
        XCTAssertEqual(broken("let's meet at 3, no, 4", "Let's meet at 4."), [])
        XCTAssertEqual(broken("send it to Ana I mean Mila", "Send it to Mila."), [])
        XCTAssertEqual(broken("let's meet at 3, no, 4", "Let's meet at 4 or 5."), [.digits], "inventing a digit still breaks it")
    }

    func testTheLockKeepsTheTranscriptOnlyWhenOn() {
        let spoken = "Can you send me the 4 slides?"
        let cleaned = "Can you send me the four slides?"
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
        let locked = try await DictationTextPreparation.prepare(
            speech: "can you send me the 4 slides before noon", settings: settings,
            screenContext: { nil }, makeEngine: { _ in engine })
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
