import XCTest
@testable import LokalBot

@MainActor
final class RedesignContractTests: XCTestCase {
    func testNewDefaultsAndLegacyMigrationAreDifferentDeliberately() throws {
        let fresh = AppSettings()
        XCTAssertEqual(fresh.autoRecordMode, .ask)
        XCTAssertEqual(fresh.effectiveScreenContextCaptureMode, .activityOnly)
        XCTAssertEqual(fresh.dictationIntent, .transcribe)
        XCTAssertFalse(fresh.dictationUseScreenContext)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.autoRecordMode, .automatic)
        XCTAssertEqual(legacy.effectiveScreenContextCaptureMode, .visualContext)
        XCTAssertEqual(legacy.dictationIntent, .compose)
        XCTAssertTrue(legacy.dictationUseScreenContext)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(fresh)), fresh)
    }

    func testSetupDraftDoesNotChangeLiveSettingsOrRemoteApproval() {
        var live = AppSettings()
        live.approvedRemoteInferenceOrigins = ["https://model.example"]
        var draft = CaptureSetupDraft(settings: live)
        draft.meetingMode = .manual
        draft.dayMemory = false
        XCTAssertTrue(live.trackingEnabled)
        live.retentionDays = 17
        let applied = draft.applying(to: live)
        XCTAssertFalse(applied.trackingEnabled)
        XCTAssertEqual(applied.autoRecordMode, .manual)
        XCTAssertEqual(applied.retentionDays, 17)
        XCTAssertEqual(applied.approvedRemoteInferenceOrigins, live.approvedRemoteInferenceOrigins)
    }

    func testReopenedSetupPreservesDetailLevelWhileDayMemoryIsOff() {
        for mode in AppSettings.ScreenContextCaptureMode.allCases {
            var live = AppSettings()
            live.trackingEnabled = false
            live.screenContextCaptureMode = mode
            live.screenshotsEnabled = mode.capturesPixels
            let applied = CaptureSetupDraft(settings: live).applying(to: live)
            XCTAssertEqual(applied, live, "Applying unchanged setup must preserve the disabled configuration")
        }
    }

    func testDayActivityClipsBoundariesAndUnionsOverlaps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let blocks = [
            ActivityBlock(app: "Editor", title: "a", start: day.addingTimeInterval(-100), end: day.addingTimeInterval(300)),
            ActivityBlock(app: "Browser", title: "b", start: day.addingTimeInterval(200), end: day.addingTimeInterval(600)),
            ActivityBlock(app: "WindowServer", title: "", start: day, end: end),
            ActivityBlock(app: "Editor", title: "c", start: end.addingTimeInterval(-100), end: end.addingTimeInterval(500)),
        ]
        let projection = DayActivityProjection(blocks: blocks, day: day, calendar: calendar)
        XCTAssertEqual(end.timeIntervalSince(day), 23 * 3_600)
        XCTAssertEqual(projection.activeSeconds, 700)
        XCTAssertEqual(projection.sessions.reduce(0) { $0 + $1.activeDuration }, 700)
        XCTAssertFalse(projection.blocks.contains { $0.app == "WindowServer" })
    }

    func testGroupingKeepsAllMatchesAndLimitsMeetingsAfterGrouping() {
        let crowded = UUID(), other = UUID()
        let hits = (0..<100).map { SearchIndex.Hit(meetingID: crowded, kind: .segment, start: Double($0), snippet: "match", speaker: "Me") }
            + [SearchIndex.Hit(meetingID: other, kind: .title, start: 0, snippet: "second", speaker: "")]
        let groups = RecallSearch.groups(hits, limit: 2)
        XCTAssertEqual(groups.map(\.id), [crowded, other])
        XCTAssertEqual(groups[0].matches.count, 100)
    }

    func testScreenGroupingPreservesRelevanceAndAllMomentsInLongSessions() {
        let day = Calendar.current.startOfDay(for: Date())
        let hits = (0..<2_000).map { ActivityStore.OCRHit(snapshotID: Int64($0 + 1),
            ts: day.addingTimeInterval(Double($0 * 30)), app: "Editor", windowTitle: "Long session", snippet: "evidence") }
        // Relevance order can be unrelated to chronology, including a bridge
        // between initially distant hits. Source grouping must still be complete.
        let ranked = [hits[1_999], hits[0]] + Array(hits[1..<1_999])
        let groups = RecallSearch.screenGroups(ranked)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary.snapshotID, 2_000)
        XCTAssertEqual(Set(groups.flatMap(\.matches).map(\.snapshotID)), Set(hits.map(\.snapshotID)))
        XCTAssertTrue(RecallSearch.screenGroups(hits, limit: 0).isEmpty)
        let other = ActivityStore.OCRHit(snapshotID: 2_001, ts: day, app: "Browser", windowTitle: "Other", snippet: "source")
        XCTAssertEqual(RecallSearch.screenGroups([other] + ranked).map { $0.primary.snapshotID }, [2_001, 2_000])
    }

    func testRelativeDuePhrasesResolveOnlyAgainstTheirSpokenDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 10)))
        let key = { (date: Date?) in date.map { AskDayScope.key(for: $0) } }
        XCTAssertEqual(key(ActionDuePresentation.date("Tomorrow", spokenAt: tuesday)), "2026-09-23")
        XCTAssertEqual(key(ActionDuePresentation.date("Friday", spokenAt: tuesday)), "2026-09-25")
        XCTAssertEqual(key(ActionDuePresentation.date("2026-09-03", spokenAt: tuesday)), "2026-09-03")
        XCTAssertNil(ActionDuePresentation.date("once the budget lands", spokenAt: tuesday))
    }

    func testActionListsOfZeroFortyAndFourHundredPersistCorrectionsAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = Meeting(id: UUID(), title: "Synthetic review", appName: "Meet", startedAt: Date(), endedAt: Date(), relativePath: "meetings/synthetic")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for count in [0, 40, 400] {
            let outcomes = MeetingOutcomes(actionItems: (0..<count).map { .init(text: "Synthetic commitment \($0)", owner: "Me") })
            try outcomes.write(to: folder)
            let index = OutcomeIndex(storage: storage)
            index.refresh(meetings: [meeting])
            XCTAssertEqual(index.openUserActions.count, count)
            guard let first = index.openUserActions.first else { continue }
            XCTAssertTrue(index.correctAction(actionID: first.action.id, meetingID: meeting.id, text: "Reviewed wording", owner: "Me", due: "2026-09-03"))
            XCTAssertTrue(index.setStatus(.done, for: index.openUserActions).isEmpty)
            XCTAssertEqual(index.openUserActions.count, 0)
            index.undoStatusChange()
            let restarted = OutcomeIndex(storage: storage)
            restarted.refresh(meetings: [meeting])
            XCTAssertEqual(restarted.openUserActions.count, count)
            XCTAssertEqual(restarted.projection(for: meeting.id)?.actionReferences.first { $0.action.id == first.action.id }?.text, "Reviewed wording")
            XCTAssertEqual(MeetingOutcomes.load(from: folder)?.actionItems.first { $0.id == first.action.id }?.text, first.action.text)
        }
    }

    func testManualReviewExcludesSavedMomentsAndRejectsNewScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-cleanup-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(databaseURL: root)
        let now = Date()
        let interval = DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))
        let saved = try store.insertScreenshot(ts: now, path: "", app: "Editor", ocr: "saved")
        try store.saveMoment(snapshotID: saved)
        let review = try store.captureDeletionReview(in: interval, includesSaved: false)
        XCTAssertEqual(review.captures.count, 0)
        XCTAssertEqual(review.savedExcluded, 1)
        XCTAssertEqual(try store.captureDeletionReview(in: interval, includesSaved: true).captures.map(\.id), [saved])
        _ = try store.insertScreenshot(ts: now, path: "", app: "Editor", ocr: "new")
        XCTAssertFalse(review.covers(try store.captureDeletionReview(in: interval, includesSaved: false)))
        XCTAssertEqual(store.ocrText(snapshotID: saved), "saved")
    }

    func testRawScreenMatchesKeepEveryIDInsideTheRequestedBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-scope-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityStore(databaseURL: url)
        let now = Date()
        var ids: [Int64] = []
        for offset in 0..<4 {
            ids.append(try store.insertScreenshot(ts: now.addingTimeInterval(Double(offset)), path: "", app: "Editor", windowTitle: "Same document", ocr: "retained matching evidence"))
        }
        var filter = ScreenSearchFilter()
        filter.snapshotIDs = Set(ids.prefix(3))
        let hits = store.searchOCR("retained", filter: filter, groupResults: false)
        XCTAssertEqual(Set(hits.map(\.snapshotID)), Set(ids.prefix(3)))
        XCTAssertEqual(RecallSearch.screenGroups(hits).first?.matches.count, 3)
        filter.snapshotIDs = []
        XCTAssertTrue(store.searchOCR("retained", filter: filter, groupResults: false).isEmpty)
    }

    func testBatchFailurePreservesSuccessfulUpdatesAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meetings = ["good", "blocked"].map { name in
            Meeting(id: UUID(), title: name, appName: "Meet", startedAt: Date(), endedAt: Date(), relativePath: "meetings/\(name)")
        }
        for meeting in meetings {
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MeetingOutcomes(actionItems: [.init(text: meeting.title + " commitment", owner: "Me")]).write(to: folder)
        }
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        let blocked = meetings[1].folderURL(in: storage)
        let backup = root.appendingPathComponent("blocked-backup")
        try FileManager.default.moveItem(at: blocked, to: backup)
        try Data("fixture blocks directory writes".utf8).write(to: blocked)
        let failures = index.setStatus(.done, for: index.openUserActions)
        XCTAssertEqual(failures, ["blocked commitment"])
        XCTAssertEqual(index.statusUndo.count, 1)
        XCTAssertEqual(index.projection(for: meetings[0].id)?.actionReferences.first?.status, .done)
        index.undoStatusChange()
        XCTAssertEqual(index.projection(for: meetings[0].id)?.actionReferences.first?.status, .open)
        XCTAssertEqual(index.projection(for: meetings[1].id)?.actionReferences.first?.status, .open)
    }

    func testPartialUndoKeepsFailureVisibleAfterSuccessfulRestoresAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meetings = ["blocked", "good"].map { name in
            Meeting(id: UUID(), title: name, appName: "Meet", startedAt: Date(), endedAt: Date(), relativePath: "meetings/\(name)")
        }
        for meeting in meetings {
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MeetingOutcomes(actionItems: [.init(text: meeting.title + " commitment", owner: "Me")]).write(to: folder)
        }
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        let actions = meetings.compactMap { index.projection(for: $0.id)?.actionReferences.first }
        XCTAssertTrue(index.setStatus(.done, for: actions).isEmpty)
        let state = meetings[0].folderURL(in: storage).appendingPathComponent(MeetingOutcomeState.fileName)
        let savedState = try Data(contentsOf: state)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        index.undoStatusChange()
        XCTAssertEqual(index.lastError, "Could not undo: blocked commitment")
        XCTAssertEqual(index.statusUndo.map(\.meetingID), [meetings[0].id])
        XCTAssertEqual(index.projection(for: meetings[0].id)?.actionReferences.first?.status, .done)
        XCTAssertEqual(index.projection(for: meetings[1].id)?.actionReferences.first?.status, .open)
        try FileManager.default.removeItem(at: state)
        try savedState.write(to: state)
        index.undoStatusChange()
        XCTAssertNil(index.lastError)
        XCTAssertTrue(index.statusUndo.isEmpty)
        XCTAssertEqual(index.projection(for: meetings[0].id)?.actionReferences.first?.status, .open)
    }

    func testOptionalWritingModelDoesNotBlockMeetingReadiness() {
        let readiness = ModelReadinessSnapshot(transcriptionReady: true, thinkReady: true, autocompleteReady: false,
            provenance: .externalThink("model.example"), storedBytes: 0, availableBytes: nil, activeDownloads: 0, failedDownloads: 1)
        let snapshot = ModelRolesSnapshot(readiness: readiness, statuses: [.transcribe: .ready, .think: .ready, .autocomplete: .needsAttention("Unavailable")])
        XCTAssertTrue(snapshot.meetingReady)
        XCTAssertFalse(snapshot.coreReady)
        XCTAssertTrue(snapshot.detail.contains("model.example"))
        XCTAssertTrue(snapshot.detail.contains("separately"))
    }
}
