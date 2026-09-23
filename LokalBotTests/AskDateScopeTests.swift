import XCTest
@testable import LokalBot

@MainActor
final class AskDateScopeTests: XCTestCase {
    func testSevenDaysUsesCivilBoundariesAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let scope = AskDateScope.lastSevenDays(now: now, calendar: calendar)
        let interval = try XCTUnwrap(scope.interval(calendar: calendar))
        XCTAssertEqual(scope.storageKey, "2026-03-04...2026-03-10")
        XCTAssertEqual(interval.duration, 7 * 86_400 - 3_600)
        XCTAssertTrue(scope.contains(interval.start, calendar: calendar))
        XCTAssertTrue(scope.contains(interval.end.addingTimeInterval(-1), calendar: calendar))
        XCTAssertFalse(scope.contains(interval.end, calendar: calendar))
    }

    func testRangeRestoresCivilDatesAfterTravel() throws {
        let scope = try XCTUnwrap(AskDateScope(storageKey: "2026-09-01...2026-09-07"))
        for offset in [-10, 14] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: offset * 3_600))
            let interval = try XCTUnwrap(scope.interval(calendar: calendar))
            XCTAssertEqual(AskDayScope.key(for: interval.start, calendar: calendar), "2026-09-01")
            XCTAssertEqual(AskDayScope.key(for: interval.end, calendar: calendar), "2026-09-08")
        }
    }

    func testInvalidOrReversedDatesAreRejected() {
        for key in ["2026-02-30", "2026-09-07...2026-09-01", "today", "2026-09-01...", "2026-09-01...2026-09-02...2026-09-03"] {
            XCTAssertNil(AskDateScope(storageKey: key), key)
        }
        XCTAssertEqual(AskDateScope(storageKey: "2026-09-01")?.storageKey, "2026-09-01")
    }

    func testSavedQuestionRestoresRangeAndExplicitEvidence() throws {
        let id = UUID()
        let message = ChatMessage(role: .user, text: "What happened?", sourceScopes: [.meetings, .screen],
                                  dayScopeKey: "2026-09-01...2026-09-07", meetingIDs: [id], screenSnapshotIDs: [42])
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.dayScopeKey, message.dayScopeKey)
        XCTAssertEqual(restored.meetingIDs, [id])
        XCTAssertEqual(restored.screenSnapshotIDs, [42])
    }

    func testNarrowerDateScopeExcludesPriorAnswersAndOutOfRangeAttachments() throws {
        let week = try XCTUnwrap(AskDateScope(storageKey: "2026-09-01...2026-09-07"))
        let messages = [
            ChatMessage(role: .user, text: "Within range", sourceScopes: [.screen],
                        dayScopeKey: week.storageKey, attachedScreenDayKeys: ["2026-09-03"]),
            ChatMessage(role: .assistant, text: "Scoped answer"),
            ChatMessage(role: .user, text: "Outside attachment", sourceScopes: [.screen],
                        dayScopeKey: week.storageKey, attachedScreenDayKeys: ["2026-08-31"]),
            ChatMessage(role: .assistant, text: "Outside answer"),
        ]
        XCTAssertEqual(ChatViewModel.finalizedHistory(from: messages, allowedScopes: [.screen], dateScope: week).count, 2)
        let day = try XCTUnwrap(AskDateScope(storageKey: "2026-09-03"))
        XCTAssertTrue(ChatViewModel.finalizedHistory(from: messages, allowedScopes: [.screen], dateScope: day).isEmpty)
    }

    func testSearchAndAnswerToolsUseTheSameDateRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-dates-\(UUID())")
        let previous = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            if let previous { setenv("LOKALBOT_STORAGE_ROOT", previous, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let scope = try XCTUnwrap(AskDateScope(storageKey: "2026-09-01...2026-09-07"))
        let interval = try XCTUnwrap(scope.interval())
        let dates = [interval.start.addingTimeInterval(-1), interval.start,
                     interval.end.addingTimeInterval(-1), interval.end]
        let ids = dates.map { _ in UUID() }
        try MeetingFixture.write(dates.enumerated().map { index, date in
            .init(id: ids[index], title: "Needle meeting \(index)", startedAt: date,
                  summary: "Needle decision \(index)", transcriptLines: ["Needle evidence \(index)."])
        }, under: root)
        let app = AppState()
        let meetings = app.storage.loadMeetings()
        app.searchIndex.reindexAll(meetings, storage: app.storage)
        var screenIDs: [Int64] = []
        for (index, date) in dates.enumerated() {
            screenIDs.append(try app.activityStore.insertScreenshot(ts: date,
                path: "/tmp/date-screen-\(index).enc", app: "Editor",
                windowTitle: "Needle screen \(index)", ocr: "Needle screen evidence \(index)"))
        }
        var state = RecallWorkspaceState()
        state.sources = [.screen]
        let search = await RecallSearch.search("Needle", state: state, dateScope: scope, app: app)
        XCTAssertEqual(Set(search.screens.flatMap(\.matches).map(\.snapshotID)), Set(screenIDs[1...2]))
        let all = await RecallSearch.search("Needle", state: state, dateScope: nil, app: app)
        XCTAssertEqual(Set(all.screens.flatMap(\.matches).map(\.snapshotID)), Set(screenIDs))

        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let base = MeetingChatTools(meetings: { meetings }, storage: app.storage,
            searchIndex: app.searchIndex, embeddingIndex: app.embeddingIndex,
            activityStore: app.activityStore, settings: { settings })
        let tools = ScopedChatToolRunner(base: base, scopes: AskSourceScope.defaults, dayScopeKey: scope.storageKey)
        for tool in ["search_meetings", "list_meetings", "search_screen"] {
            let result = await tools.run(.init(name: tool, arguments: ["query": "Needle"]))
            let prefix = tool == "search_screen" ? "Needle screen" : "Needle meeting"
            XCTAssertTrue(result.text.contains("\(prefix) 1"), result.text)
            XCTAssertTrue(result.text.contains("\(prefix) 2"), result.text)
            XCTAssertFalse(result.text.contains("\(prefix) 0"), result.text)
            XCTAssertFalse(result.text.contains("\(prefix) 3"), result.text)
        }
        let excluded = await tools.run(.init(name: "get_meeting", arguments: ["id": ids[0].uuidString]))
        XCTAssertTrue(excluded.text.contains("No meeting matches"))

        app.activityStore.insert(ActivityBlock(app: "Boundary", title: "Crossing midnight",
            start: interval.start.addingTimeInterval(-300), end: interval.start.addingTimeInterval(300)))
        app.activityStore.insert(ActivityBlock(app: "Outside", title: "Outside scope",
            start: interval.end, end: interval.end.addingTimeInterval(300)))
        let activity = await tools.run(.init(name: "activity_summary", arguments: ["day": "today"]))
        XCTAssertTrue(activity.text.contains("Boundary: 5m"), activity.text)
        XCTAssertFalse(activity.text.contains("Outside"), activity.text)
        XCTAssertFalse(activity.text.contains("Needle meeting 0"), activity.text)
    }
}
