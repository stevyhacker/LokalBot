import XCTest
@testable import LokalBot

/// The Ask surface's phase routing (spec §2.3 "one input, two response
/// modes"): a non-empty query always shows live results; an empty query
/// falls back to the conversation when one exists, else the empty state.
@MainActor
final class AskRoutingTests: XCTestCase {

    func testNonEmptyQueryAlwaysSearches() {
        XCTAssertEqual(AskRouter.phase(query: "failover", hasMessages: false), .searching)
        XCTAssertEqual(AskRouter.phase(query: "failover", hasMessages: true), .searching)
    }

    func testEmptyQueryShowsConversationWhenMessagesExist() {
        XCTAssertEqual(AskRouter.phase(query: "", hasMessages: true), .conversation)
    }

    func testEmptyQueryShowsIdleWithoutMessages() {
        XCTAssertEqual(AskRouter.phase(query: "", hasMessages: false), .idle)
    }

    func testWhitespaceOnlyQueryCountsAsEmpty() {
        XCTAssertEqual(AskRouter.phase(query: "  \n ", hasMessages: true), .conversation)
        XCTAssertEqual(AskRouter.phase(query: "  ", hasMessages: false), .idle)
    }

    func testFacetKindMapping() {
        XCTAssertNil(AskFacet.all.kind)
        XCTAssertNil(AskFacet.screen.kind)
        XCTAssertEqual(AskFacet.transcripts.kind, .segment)
        XCTAssertEqual(AskFacet.summaries.kind, .summary)
    }

    func testSubmittingAskHandoffCarriesQueryAndContext() {
        let app = AppState()
        app.openAsk(
            query: "What was I looking at?",
            screenSnapshotIDs: [42],
            submit: true)

        let handoff = app.navigationHandoff.consumeAsk()
        XCTAssertEqual(app.navSection, .ask)
        XCTAssertEqual(handoff?.query, "What was I looking at?")
        XCTAssertEqual(handoff?.screenSnapshotIDs, [42])
        XCTAssertTrue(handoff?.submit == true)
        XCTAssertNil(app.navigationHandoff.consumeAsk())
    }

    func testReturningFromEvidenceRestoresOriginatingMeetingSelection() {
        let app = AppState()
        let origin = UUID()
        let evidence = UUID()
        app.navSection = .timeline
        app.selectedMeetingIDs = [origin]
        app.openMeeting(evidence, seek: 30)
        XCTAssertEqual(app.selectedMeetingIDs, [evidence])
        app.returnFromEvidence()
        XCTAssertEqual(app.navSection, .timeline)
        XCTAssertEqual(app.selectedMeetingIDs, [origin])
        XCTAssertNil(app.evidenceReturnSection)

        app.navSection = .ask
        app.selectedMeetingIDs = []
        app.openScreenSnapshot(42)
        app.returnFromEvidence()
        XCTAssertEqual(app.navSection, .ask)
        XCTAssertTrue(app.selectedMeetingIDs.isEmpty)
    }

    func testActivitySourceDoesNotGrantMeetingOrScreenAccess() async throws {
        let base = RecordingToolRunner()
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 12)))
        let scoped = ScopedChatToolRunner(base: base, scopes: [.today], dayScope: day)

        XCTAssertEqual(scoped.libraryOverview(), "")
        XCTAssertEqual(scoped.specs.map(\.name), ["activity_summary"])
        let denied = await scoped.run(.init(
            name: "search_meetings", arguments: ["query": "roadmap"]))
        XCTAssertEqual(denied.summary, "source not enabled")
        XCTAssertNil(base.lastCall)

        _ = await scoped.run(.init(
            name: "activity_summary", arguments: ["day": "yesterday"]))
        XCTAssertEqual(base.lastCall?.string("day"), "2026-08-31")
        XCTAssertEqual(base.lastCall?.string("_lokalbot_include_meetings"), "false")
    }

    func testCalendarDayScopeIsAppliedIndependentlyToEveryEnabledSource() async throws {
        let base = RecordingToolRunner()
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 12)))
        let scoped = ScopedChatToolRunner(
            base: base,
            scopes: AskSourceScope.defaults,
            dayScope: day)

        XCTAssertEqual(scoped.libraryOverview(), "",
                       "day-scoped questions must not receive ambient titles from other days")
        _ = await scoped.run(.init(
            name: "search_meetings", arguments: ["query": "roadmap"]))
        XCTAssertEqual(base.lastCall?.string("_lokalbot_day_scope"), "2026-08-31")

        _ = await scoped.run(.init(
            name: "search_screen", arguments: ["query": "roadmap"]))
        XCTAssertEqual(base.lastCall?.string("_lokalbot_day_scope"), "2026-08-31")

        _ = await scoped.run(.init(
            name: "activity_summary", arguments: ["day": "yesterday"]))
        XCTAssertEqual(base.lastCall?.string("day"), "2026-08-31")
        XCTAssertEqual(base.lastCall?.string("_lokalbot_include_meetings"), "true")
    }

    func testSourceStorageKeepsLegacyTodayRawValueWhileDisplayingActivity() throws {
        XCTAssertEqual(AskSourceScope.today.rawValue, "Today")
        XCTAssertEqual(AskSourceScope.today.displayName, "Activity")

        let selected: Set<AskSourceScope> = [.meetings, .today]
        let stored = AskSourceScope.storageValue(for: selected)
        XCTAssertEqual(AskSourceScope.scopes(fromStorageValue: stored), selected)
        XCTAssertEqual(
            AskSourceScope.scopes(fromStorageValue: "unknown"),
            AskSourceScope.defaults)
    }

    func testDisabledSourceIsAbsentAndDeniedAtExecution() async {
        let base = RecordingToolRunner()
        let scoped = ScopedChatToolRunner(base: base, scopes: [.meetings])

        XCTAssertFalse(scoped.specs.contains { $0.name == "search_screen" })
        let result = await scoped.run(.init(
            name: "search_screen", arguments: ["query": "secret" ]))
        XCTAssertEqual(result.summary, "source not enabled")
        XCTAssertNil(base.lastCall)
    }

    func testCivilDayKeySurvivesTimeZoneChange() throws {
        var origin = Calendar(identifier: .gregorian)
        origin.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))
        let selected = try XCTUnwrap(origin.date(from: DateComponents(
            year: 2026, month: 9, day: 1, hour: 12)))
        let key = AskDayScope.key(for: selected, calendar: origin)

        var destination = Calendar(identifier: .gregorian)
        destination.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -10 * 3_600))
        let restored = try XCTUnwrap(AskDayScope.date(for: key, calendar: destination))

        XCTAssertEqual(key, "2026-09-01")
        XCTAssertEqual(AskDayScope.key(for: restored, calendar: destination), key)
    }

    func testPinnedScreenContextEnablesScreenWithoutWideningSelectedDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31)))
        let reconciled = AskScopeReconciler.addingScreenContext(
            to: [.meetings], dayScope: selected)

        XCTAssertEqual(reconciled.scopes, [.meetings, .screen])
        XCTAssertEqual(reconciled.dayScope, selected)
    }

    func testSearchEscalationPreservesReviewedScope() throws {
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: 31)))

        let scope = AskEscalationScope.resolve(
            mode: .keyword, selectedSources: [.screen], selectedDay: day)

        XCTAssertEqual(scope.sources, [.screen])
        XCTAssertEqual(scope.dayScope, day)
    }

    func testExplicitMeetingAndScreenScopesCannotBeOverriddenByToolArguments() async {
        let base = RecordingToolRunner()
        let meetingID = UUID()
        let scoped = ScopedChatToolRunner(base: base, scopes: [.meetings, .screen],
                                          meetingIDs: [meetingID], screenSnapshotIDs: [42])
        XCTAssertEqual(scoped.libraryOverview(), "")
        _ = await scoped.run(.init(name: "search_meetings", arguments: [
            "query": "roadmap", "_lokalbot_meeting_ids": UUID().uuidString]))
        XCTAssertEqual(base.lastCall?.string("_lokalbot_meeting_ids"), meetingID.uuidString)
        _ = await scoped.run(.init(name: "search_screen", arguments: ["query": "roadmap"]))
        XCTAssertEqual(base.lastCall?.string("_lokalbot_screen_ids"), "42")
    }

    func testMessageScopeSurvivesPersistenceIncludingEmptyBoundary() throws {
        let meetingID = UUID()
        let message = ChatMessage(role: .user, text: "What was decided?",
                                  meetingIDs: [meetingID], screenSnapshotIDs: [])
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.meetingIDs, [meetingID])
        XCTAssertEqual(decoded.screenSnapshotIDs, [])
    }

    func testDateRangeIsEnforcedOnAllSourcesAndCannotBeOverridden() async {
        let base = RecordingToolRunner()
        let key = "2026-09-01...2026-09-07"
        let runner = ScopedChatToolRunner(base: base, scopes: AskSourceScope.defaults, dayScopeKey: key)
        for tool in ["search_meetings", "search_screen", "activity_summary"] {
            _ = await runner.run(.init(name: tool, arguments: ["day": "today", "_lokalbot_day_scope": "2020-01-01"]))
            XCTAssertEqual(base.lastCall?.string("_lokalbot_day_scope"), key)
        }
        XCTAssertEqual(base.lastCall?.string("day"), key)
        XCTAssertEqual(runner.libraryOverview(), "")
    }

    func testInvalidDateScopeNeverReachesRetrievalTools() async {
        let base = RecordingToolRunner()
        let runner = ScopedChatToolRunner(base: base, scopes: AskSourceScope.defaults, dayScopeKey: "invalid")
        let result = await runner.run(.init(name: "search_meetings", arguments: ["query": "private"]))
        XCTAssertEqual(result.summary, "invalid date scope")
        XCTAssertNil(base.lastCall)
    }

    private final class RecordingToolRunner: ChatToolRunner {
        let specs = [
            ChatToolSpec(name: "search_meetings", summary: "meetings", arguments: []),
            ChatToolSpec(name: "search_screen", summary: "screen", arguments: []),
            ChatToolSpec(name: "activity_summary", summary: "today", arguments: []),
        ]
        var lastCall: ChatToolCall?

        func libraryOverview() -> String { "all meeting titles" }
        func run(_ call: ChatToolCall) async -> ChatToolResult {
            lastCall = call
            return ChatToolResult(text: "ok", summary: "ok")
        }
    }
}
