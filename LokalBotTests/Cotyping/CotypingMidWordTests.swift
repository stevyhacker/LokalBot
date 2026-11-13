import AppKit
import XCTest
@testable import LokalBot

// MARK: - Mid-word continuation (complete the word being typed)

final class CotypingMidWordTests: XCTestCase {
    private func request(prefix: String, trailing: String, force: Bool) -> CotypingRequest {
        CotypingRequest(
            prompt: prefix, prefixText: prefix, trailingText: trailing, isMultiLine: false,
            maxTokens: 24, temperature: 0.1, topP: 0.7, topK: 20, minP: 0.08,
            repeatPenalty: 1.05, seed: 0, generation: 0, forceWordContinuation: force)
    }

    func testForceOnlyWhenStrictlyInsideWord() {
        XCTAssertTrue(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: "eive"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: ""))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: " more"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec", trailingText: "."))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "rec ", trailingText: "x"))
        XCTAssertFalse(CotypingMidWord.shouldForceContinuation(precedingText: "", trailingText: "x"))
    }

    func testCurrentPartialWord() {
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "I want to rec"), "rec")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "I want to "), "")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "price is 42"), "42")
        XCTAssertEqual(CotypingMidWord.currentPartialWord(in: "end."), "")
    }

    func testStripsRetypedPartialWordSoItCompletes() {
        // Typed "rec"; the model echoed the whole word — keep only the new tail.
        let result = CotypingTextNormalizer.normalize(
            "receive the package", for: request(prefix: "I want to rec", trailing: "", force: false))
        XCTAssertEqual(result, "eive the package")
    }

    func testNaturalContinuationUnchanged() {
        let result = CotypingTextNormalizer.normalize(
            "eive the package", for: request(prefix: "I want to rec", trailing: "", force: false))
        XCTAssertEqual(result, "eive the package")
    }

    func testForceContinuationStripsLeadingSpace() {
        let forced = CotypingTextNormalizer.normalize(
            " ord", for: request(prefix: "rec", trailing: "ord", force: true))
        XCTAssertEqual(forced, "ord")
    }

    func testAcceptedMidWordOverlapDeletesExistingTrailingFragment() {
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "ord", trailingText: "ord"), 3)
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "ording", trailingText: "ord"), 3)
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "or", trailingText: "ord"), 2)
    }

    func testAcceptedMidWordOverlapIgnoresWeakSharedPrefix() {
        XCTAssertEqual(CotypingMidWord.acceptedTrailingOverlapCount(acceptedText: "operate", trailingText: "ord"), 0)
    }

    func testForceContinuationSuppressesIncompatibleWordTail() {
        let detailed = CotypingTextNormalizer.normalizeDetailed(
            "ode the following code in C++:",
            for: request(prefix: "Please rec", trailing: "eive the files when ready.", force: true))
        XCTAssertEqual(detailed.text, "")
        XCTAssertEqual(detailed.suppression, .unsafeToInsert)
    }

    func testNoForceKeepsModelSpacingAtWordEnd() {
        // Not strictly inside a word: the model's "this word is done" call stands.
        let result = CotypingTextNormalizer.normalize(
            " document", for: request(prefix: "rec", trailing: "", force: false))
        XCTAssertEqual(result, " document")
    }

    func testDoesNotStripShortPartialWord() {
        let result = CotypingTextNormalizer.normalize(
            "am late", for: request(prefix: "I a", trailing: "", force: false))
        XCTAssertEqual(result, "am late")
    }
}
