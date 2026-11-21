import XCTest
@testable import LokalBot

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

    func testAFullQuestionReadsTheChosenSourcesEvenWhileMatchesAreListed() {
        for query in ["What did we decide about Redis?", "who owns the failover benchmark",
                      "summarize the design review", "failover benchmark?",
                      "Šta smo odlučili o Redisu", "ko je vlasnik failover testa",
                      "notes from the design review"] {
            XCTAssertEqual(AskAnswerScope.resolve(query: query, hasMatches: true, isRememberStatement: false),
                           .chosenSources, query)
            XCTAssertEqual(AskAnswerScope.resolve(query: query, hasMatches: false, isRememberStatement: false),
                           .chosenSources, query)
        }
    }

    func testAKeywordOrShortPhraseIsAnsweredFromItsMatches() {
        for query in ["failover", "redis cluster", "PR-1234", "redis?", "what", "design review notes"] {
            XCTAssertEqual(AskAnswerScope.resolve(query: query, hasMatches: true, isRememberStatement: false),
                           .listedMatches, query)
            XCTAssertEqual(AskAnswerScope.resolve(query: query, hasMatches: false, isRememberStatement: false),
                           .chosenSources, "with nothing listed there is nothing to limit to: \(query)")
        }
    }

    func testARememberStatementLimitsNothing() {
        XCTAssertEqual(AskAnswerScope.resolve(query: "Remember that Maya is my manager", hasMatches: true,
                                              isRememberStatement: true), .chosenSources)
        XCTAssertEqual(AskAnswerScope.resolve(query: "Remember Maya", hasMatches: true,
                                              isRememberStatement: false), .listedMatches)
        XCTAssertEqual(AskAnswerScope.resolve(query: "Remember that Maya is my manager", hasMatches: true,
                                              isRememberStatement: false), .chosenSources)
    }

    func testTheSourcesMenuTellsTheTruthForBothKindsOfInput() {
        let meeting = UUID()
        func askedState(_ query: String, from start: RecallWorkspaceState = RecallWorkspaceState()) -> RecallWorkspaceState {
            var state = start
            if AskAnswerScope.resolve(query: query, hasMatches: true, isRememberStatement: false) == .listedMatches {
                state.selectResultEvidence(meetingIDs: [meeting], screenIDs: [])
            }
            return state
        }
        func menu(_ state: RecallWorkspaceState) -> AskScopeSummary {
            AskScopeSummary.make(
                .init(sources: state.sources, available: AskSourceScope.allCases, meetingIDs: state.meetingIDs,
                      screenIDs: state.screenIDs, sourcesBeforeEvidence: state.sourcesBeforeEvidence),
                meetingTitle: { $0 == meeting ? "Design review meeting" : nil })
        }

        let question = askedState("What did we decide about failover?")
        XCTAssertNil(question.meetingIDs, "a full question is not narrowed to the matches on screen")
        XCTAssertNil(question.screenIDs)
        XCTAssertEqual(question.sources, AskSourceScope.defaults)
        XCTAssertEqual(menu(question).title, "All sources")
        XCTAssertFalse(menu(question).isNarrowed)

        let keyword = askedState("failover")
        XCTAssertEqual(keyword.meetingIDs, [meeting])
        XCTAssertEqual(menu(keyword).title, "Design review meeting")
        XCTAssertEqual(menu(keyword).widenTitle, "All sources")

        var handedOver = RecallWorkspaceState()
        handedOver.selectEvidence(meetingIDs: [meeting], screenIDs: nil)
        let followUp = askedState("What did we decide about failover?", from: handedOver)
        XCTAssertEqual(followUp.meetingIDs, [meeting])
        XCTAssertEqual(menu(followUp).narrowedTo, "Design review meeting")

        var meetingsOnly = RecallWorkspaceState()
        meetingsOnly.chooseSources([.meetings])
        let scoped = askedState("What did we decide about failover?", from: meetingsOnly)
        XCTAssertEqual(scoped.sources, [.meetings])
        XCTAssertNil(scoped.meetingIDs)
        XCTAssertEqual(menu(scoped).title, "Meetings")
    }
}
