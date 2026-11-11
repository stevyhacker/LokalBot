import XCTest
@testable import LokalBot

/// Return in Ask asks, whatever was typed. It opens a match only after the
/// arrow keys moved onto one. (Quick Recall keeps Return for opening.)
final class AskReturnActionTests: XCTestCase {
    func testReturnAsksForKeywordsAndQuestionsAlike() {
        for query in ["failover", "redis cluster", "What did we decide about Redis?",
                      "Remember that Maya is my manager"] {
            XCTAssertEqual(AskReturnAction.resolve(query: query, resultCount: 3, pickedWithKeyboard: false), .ask, query)
            XCTAssertEqual(AskReturnAction.resolve(query: query, resultCount: 0, pickedWithKeyboard: false), .ask, query)
        }
    }

    func testReturnOpensTheMatchTheArrowKeysChose() {
        XCTAssertEqual(AskReturnAction.resolve(query: "failover", resultCount: 3, pickedWithKeyboard: true), .openResult)
        XCTAssertEqual(AskReturnAction.resolve(query: "What did we decide?", resultCount: 3, pickedWithKeyboard: true),
                       .openResult)
        XCTAssertEqual(AskReturnAction.resolve(query: "failover", resultCount: 0, pickedWithKeyboard: true), .ask,
                       "with nothing left to open, Return asks again")
    }

    /// `AskIntent` no longer decides what Return does; it is kept as the
    /// measured baseline of the Laya benchmark, so its rules stay pinned.
    func testQuestionsAreRecognized() {
        XCTAssertTrue(AskIntent.isQuestion("What did we decide about Redis?"))
        XCTAssertTrue(AskIntent.isQuestion("what did we decide about redis"))
        XCTAssertTrue(AskIntent.isQuestion("Who owns the failover benchmark"))
        XCTAssertTrue(AskIntent.isQuestion("summarize the design review"))
        XCTAssertTrue(AskIntent.isQuestion("redis cluster mode?"))
    }

    func testKeywordsAreNotQuestions() {
        XCTAssertFalse(AskIntent.isQuestion("failover"))
        XCTAssertFalse(AskIntent.isQuestion("redis cluster"))
        XCTAssertFalse(AskIntent.isQuestion("what"))
        XCTAssertFalse(AskIntent.isQuestion("redis?"))
        XCTAssertFalse(AskIntent.isQuestion("PR-1234"))
        XCTAssertFalse(AskIntent.isQuestion("  "))
        XCTAssertFalse(AskIntent.isQuestion("whatever happened"))
    }

    func testReturnDoesNothingInAnEmptyField() {
        XCTAssertEqual(AskReturnAction.resolve(query: "", resultCount: 0, pickedWithKeyboard: false), .none)
        XCTAssertEqual(AskReturnAction.resolve(query: "  \n", resultCount: 0, pickedWithKeyboard: false), .none)
    }
}
