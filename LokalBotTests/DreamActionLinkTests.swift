import XCTest
@testable import LokalBot

final class DreamActionLinkTests: XCTestCase {
    func testHandlesLinkTopActionsToThreadsAndAreStripped() {
        let linked = DreamPrompts.linkTopActions([
            "[A2] Send the synthetic pricing memo",
            "Block an hour for deep work",
            "[A9] Unknown handle stays unlinked",
            "[A2] Duplicate link is not reused",
            "[A1]: Punctuated handle",
        ], threadIDs: ["thread-a", "thread-b"])

        XCTAssertEqual(linked.texts, [
            "Send the synthetic pricing memo", "Block an hour for deep work",
            "Unknown handle stays unlinked", "Duplicate link is not reused", "Punctuated handle",
        ])
        XCTAssertEqual(linked.ids, ["thread-b", nil, nil, nil, "thread-a"])
    }

    func testSynthesisReportCarriesLinksOnlyWhenAnyMatched() {
        let synthesis = DreamSynthesis(
            narrative: "Yesterday was focused.", attention: [], repeatedWork: [], suggestedChecks: [],
            frictions: [], topActions: ["[A1] Finish the synthetic review"], memory: DreamMemoryUpdate())
        let report = synthesis.report(
            dayKey: "2026-09-28", generatedAt: Date(), engineName: "Test",
            inferenceProvenance: .init(location: .local), actionThreadIDs: ["thread-x"])
        XCTAssertEqual(report.topActions, ["Finish the synthetic review"])
        XCTAssertEqual(report.topActionThreadID(at: 0), "thread-x")
        XCTAssertNil(report.topActionThreadID(at: 3))

        let unlinked = synthesis.report(
            dayKey: "2026-09-28", generatedAt: Date(), engineName: "Test",
            inferenceProvenance: .init(location: .local))
        XCTAssertNil(unlinked.topActionThreadIDs)
        XCTAssertEqual(unlinked.topActions, ["Finish the synthetic review"])
    }

    func testReportsWrittenBeforeLinksStillDecode() throws {
        let legacy = """
        {"version":3,"day":"2026-09-01","generatedAt":0,"engineName":"Test","narrative":"n",
         "attention":[],"repeatedWork":[],"suggestedChecks":[],"frictions":[],"topActions":["Do it"]}
        """
        let report = try JSONDecoder().decode(DreamReport.self, from: Data(legacy.utf8))
        XCTAssertEqual(report.topActions, ["Do it"])
        XCTAssertNil(report.topActionThreadID(at: 0))
    }

    func testPromptRulesAskForCandidateHandles() {
        XCTAssertTrue(DreamPrompts.system.contains("[A2]"))
        let evidence = DreamEvidence(
            day: Date(), dayKey: "2026-09-28", digest: nil, meetings: [], appUsage: [],
            stats: ScreenMemoryDaySummary(trackedSeconds: 0, appCount: 0, activityBlockCount: 0,
                                          screenshotCount: 0, savedMomentCount: 0),
            savedMoments: [], priorMeetings: [],
            openActions: ["- [ ] [A1] Send the synthetic memo (sources: `abcd1234`)"],
            openActionThreadIDs: ["thread-1"])
        XCTAssertTrue(DreamCompiler.evidencePack(evidence).contains("[A1] Send the synthetic memo"))
    }
}
