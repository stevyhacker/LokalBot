import XCTest
@testable import LokalBot

final class AskReturnActionTests: XCTestCase {
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

    func testReturnOpensKeywordResultsAndStaysSilentWithoutResults() {
        XCTAssertEqual(AskReturnAction.resolve(query: "failover", resultCount: 3, pickedWithKeyboard: false), .openResult)
        XCTAssertEqual(AskReturnAction.resolve(query: "failover", resultCount: 0, pickedWithKeyboard: false), .none)
    }

    func testReturnAsksQuestionsUnlessAResultWasPicked() {
        let question = "What did we decide about Redis?"
        XCTAssertEqual(AskReturnAction.resolve(query: question, resultCount: 3, pickedWithKeyboard: false), .ask)
        XCTAssertEqual(AskReturnAction.resolve(query: question, resultCount: 0, pickedWithKeyboard: false), .ask)
        XCTAssertEqual(AskReturnAction.resolve(query: question, resultCount: 3, pickedWithKeyboard: true), .openResult)
    }
}
