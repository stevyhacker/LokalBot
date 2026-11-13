import AppKit
import XCTest
@testable import LokalBot

// MARK: - Autocorrect

final class CotypingAutocorrectTests: XCTestCase {
    func testExtractTrailingWord() {
        XCTAssertEqual(CotypingWord.extract(from: "I want to teh")?.word, "teh")
        XCTAssertNil(CotypingWord.extract(from: "I want to "))
        XCTAssertNil(CotypingWord.extract(from: "see http://x.com"))
        XCTAssertNil(CotypingWord.extract(from: "the API"))
        XCTAssertNil(CotypingWord.extract(from: "a"))
    }

    func testExtractTrailingWordToleratesOneSpace() {
        let result = CotypingWord.extractTrailingWord(from: "I want to teh ")
        XCTAssertEqual(result?.result.word, "teh")
        XCTAssertEqual(result?.trailingSpaceCount, 1)
        XCTAssertNil(CotypingWord.extractTrailingWord(from: "I want to teh  "))
    }

    func testCaseTransfer() {
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "Teh", to: "the"), "The")
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "HTE", to: "the"), "THE")
        XCTAssertEqual(CotypingCaseTransfer.applying(caseOf: "teh", to: "the"), "the")
    }

    func testTypoGateOffersCorrection() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "I want to teh", enabled: true,
            isTypo: { $0 == "teh" }, bestCorrection: { $0 == "teh" ? "the" : nil })
        XCTAssertEqual(decision, .offerCorrection(word: "teh", correctedWord: "the"))
    }

    func testTypoGateSuppressesWhenNoCorrection() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "asdfgh", enabled: true,
            isTypo: { _ in true }, bestCorrection: { _ in nil })
        XCTAssertEqual(decision, .suppress)
    }

    func testTypoGateProceedsWhenWordIsFine() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "I want to the", enabled: true,
            isTypo: { _ in false }, bestCorrection: { _ in nil })
        XCTAssertEqual(decision, .proceed)
    }

    func testTypoGateProceedsWhenDisabled() {
        let decision = CotypingTypoGate.resolve(
            precedingText: "teh", enabled: false,
            isTypo: { _ in true }, bestCorrection: { _ in "the" })
        XCTAssertEqual(decision, .proceed)
    }

    func testTypoGateProceedsForCompletableMidWordFragment() {
        // "follo" is flagged by the spell checker but is a live prefix of
        // "follow": it is an unfinished word, so the LLM continuation must run
        // (Cotypist's core mid-word behavior) instead of an autocorrect offer.
        let decision = CotypingTypoGate.resolve(
            precedingText: "I wanted to follo", enabled: true,
            isTypo: { $0 == "follo" },
            bestCorrection: { _ in "folio" },
            isCompletableWordPrefix: { $0 == "follo" })
        XCTAssertEqual(decision, .proceed)
    }

    func testTypoGateStillCorrectsUncompletableMidWordFragment() {
        // No dictionary word starts with "recieve" — mid-word or not, this is a
        // real typo and the correction must be offered.
        let decision = CotypingTypoGate.resolve(
            precedingText: "I did not recieve", enabled: true,
            isTypo: { $0 == "recieve" },
            bestCorrection: { $0 == "recieve" ? "receive" : nil },
            isCompletableWordPrefix: { _ in false })
        XCTAssertEqual(decision, .offerCorrection(word: "recieve", correctedWord: "receive"))
    }

    func testTypoGateIgnoresCompletabilityOnceWordIsFinished() {
        // A trailing space means the word is done: even a fragment that would
        // be completable mid-word ("follo" → follow) must be corrected, and the
        // completability check must not even be consulted.
        var consulted = false
        let decision = CotypingTypoGate.resolve(
            precedingText: "I wanted to follo ", enabled: true,
            isTypo: { $0 == "follo" },
            bestCorrection: { $0 == "follo" ? "follow" : nil },
            isCompletableWordPrefix: { _ in
                consulted = true
                return true
            })
        XCTAssertEqual(decision, .offerCorrection(word: "follo", correctedWord: "follow"))
        XCTAssertFalse(consulted)
    }

    func testCorrectionPlan() {
        let plan = CotypingCorrectionPlan.plan(
            precedingText: "I want to teh", expectedTypo: "teh", correctedWord: "the")
        XCTAssertEqual(plan?.deletingCharacters, 3)
        XCTAssertEqual(plan?.replacementText, "the")
    }

    func testCorrectionPlanPreservesTrailingSpace() {
        let plan = CotypingCorrectionPlan.plan(
            precedingText: "I want to teh ", expectedTypo: "teh", correctedWord: "the")
        XCTAssertEqual(plan?.deletingCharacters, 4)
        XCTAssertEqual(plan?.replacementText, "the ")
    }

    func testCorrectionPlanFailsWhenWordChanged() {
        XCTAssertNil(CotypingCorrectionPlan.plan(
            precedingText: "I want to the", expectedTypo: "teh", correctedWord: "the"))
    }
}
