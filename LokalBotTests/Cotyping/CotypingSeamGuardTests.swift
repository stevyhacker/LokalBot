import AppKit
import XCTest
@testable import LokalBot

final class CotypingSeamGuardTests: XCTestCase {
    func testAllowsNormalCompletion() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "I wanted to follow",
            completion: " up tomorrow",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .allow)
    }

    func testRejectsFreshJunkPunctuationRun() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "Thanks",
            completion: " !!!!",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .junkPunctuationRun)
    }

    func testAllowsExistingDividerContinuation() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "--",
            completion: "----",
            isKnownWord: { _ in true })
        XCTAssertEqual(verdict, .allow)
    }

    func testRejectsMidWordMisspelling() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "I am gre",
            completion: "atful",
            isKnownWord: { $0 == "grateful" })
        XCTAssertEqual(verdict, .seamMisspelling(word: "greatful"))
    }

    func testAllowsKnownMidWordJoin() {
        let verdict = CotypingSeamGuard.verdict(
            precedingText: "after",
            completion: "noon",
            isKnownWord: { $0 == "afternoon" })
        XCTAssertEqual(verdict, .allow)
    }
}
