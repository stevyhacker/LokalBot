import XCTest
@testable import LokalBot

private final class StubScreenMemoryReader: ScreenMemoryReading {
    var timestamp = Date(timeIntervalSince1970: 1_780_000_000)
    var lastSearchRequest: ScreenMemorySearchRequest?

    func search(_ request: ScreenMemorySearchRequest) throws -> [ScreenMemorySearchHit] {
        lastSearchRequest = request
        return [ScreenMemorySearchHit(
            snapshotID: 7, capturedAt: timestamp, app: "Safari",
            windowTitle: "Report", textSource: "ocr", snippet: "«revenue» grew")]
    }

    func timeline(from start: Date, to end: Date, limit: Int) throws -> ScreenMemoryTimeline {
        ScreenMemoryTimeline(
            start: start,
            end: end,
            activity: [ScreenMemoryActivityBlock(
                id: 3, app: "Safari", windowTitle: "Report",
                startedAt: timestamp, endedAt: timestamp.addingTimeInterval(60),
                durationSeconds: 60)],
            screenshots: [ScreenMemoryScreenshotSummary(
                snapshotID: 7, capturedAt: timestamp, app: "Safari",
                windowTitle: "Report", captureTrigger: "window_change",
                hasOCR: true, isSaved: true)])
    }

    func recentActivity(since: Date, limit: Int) throws -> [ScreenMemoryActivityBlock] {
        [ScreenMemoryActivityBlock(
            id: 3, app: "Safari", windowTitle: "Report",
            startedAt: timestamp, endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60)]
    }

    func appUsage(from start: Date, to end: Date, limit: Int) throws
        -> [ScreenMemoryAppUsage] {
        [ScreenMemoryAppUsage(app: "Safari", durationSeconds: 60, blockCount: 1)]
    }

    func screenshotDetail(snapshotID: Int64) throws -> ScreenMemoryScreenshotDetail? {
        guard snapshotID == 7 else { return nil }
        return ScreenMemoryScreenshotDetail(
            snapshotID: 7, capturedAt: timestamp, app: "Safari", windowTitle: "Report",
            captureTrigger: "window_change", hasEncryptedPixels: true,
            textSources: ["ocr"], ocrText: "Revenue grew", isSaved: true,
            savedNote: "Review", savedAt: timestamp)
    }

    func savedMoments(from start: Date, to end: Date, limit: Int) throws
        -> [ScreenMemorySavedMoment] { [] }

    func daySummary(from start: Date, to end: Date) throws -> ScreenMemoryDaySummary {
        ScreenMemoryDaySummary(
            trackedSeconds: 60, appCount: 1, activityBlockCount: 1,
            screenshotCount: 1, savedMomentCount: 1)
    }

    func activityBlocks(from start: Date, to end: Date) throws
        -> [ScreenMemoryActivityBlock] {
        [ScreenMemoryActivityBlock(
            id: 3,
            app: "Safari",
            windowTitle: "Report",
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60)]
    }

    func screenContexts(
        from start: Date,
        to end: Date,
        maxCharactersPerCapture: Int
    ) throws -> [ScreenMemoryTextContext] {
        [ScreenMemoryTextContext(
            snapshotID: 7,
            capturedAt: timestamp,
            app: "Safari",
            windowTitle: "Report",
            text: String("Revenue grew".prefix(maxCharactersPerCapture)))]
    }

    func latestEvidenceAt(from start: Date, to end: Date) throws -> Date? {
        timestamp
    }
}

final class FileLibraryToolProviderTests: XCTestCase {
    private var root: URL!
    private var gate: AgentAccessGate!
    private var screenGate: ScreenMemoryAccessGate!
    private var screenReader: StubScreenMemoryReader!
    private var askedQuestions: [String] = []

    private var provider: FileLibraryToolProvider {
        FileLibraryToolProvider(
            gate: gate,
            screenGate: screenGate,
            screenReader: screenReader,
            now: { Date(timeIntervalSince1970: 1_780_000_000) }
        ) { question in
            self.askedQuestions.append(question)
            return .text("stub answer")
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolprovider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        gate = AgentAccessGate(root: root)
        try gate.enable()
        screenGate = ScreenMemoryAccessGate(root: root)
        screenReader = StubScreenMemoryReader()
        askedQuestions = []

        try MeetingFixture.write([
            .init(
                id: UUID(uuidString: "AAAAAAAA-1111-4222-8333-444444444444")!,
                title: "Cache planning",
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                summary: "## TL;DR\nWe chose Redis for the caching layer.",
                transcriptLines: ["Let us decide on caching.", "Redis it is."]),
            .init(
                id: UUID(uuidString: "AAAAAAAB-2222-4333-8444-555555555555")!,
                title: "Old sync",
                startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                summary: "## TL;DR\nAncient history.",
                transcriptLines: ["Nothing to see."]),
        ], under: root)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAdvertisesMeetingAndScreenTools() {
        XCTAssertEqual(
            provider.tools.map(\.name),
            [
                "list_meetings", "get_meeting", "search_meetings", "ask_library",
                "search_screen", "get_timeline", "get_recent_activity", "get_app_usage",
                "get_screenshot_detail",
            ])
        for tool in provider.tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
        }
    }

    func testEveryToolRefusedWhenGateDisabled() async {
        gate.disable()
        for name in ["list_meetings", "get_meeting", "search_meetings", "ask_library"] {
            let result = await provider.call(
                name: name,
                arguments: ["id": "latest", "query": "x", "question": "x"])
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.text.hasPrefix("[access_disabled]"), name)
        }
        XCTAssertTrue(askedQuestions.isEmpty)
    }

    func testScreenToolsUseIndependentGate() async throws {
        for name in [
            "search_screen", "get_timeline", "get_recent_activity", "get_app_usage",
            "get_screenshot_detail",
        ] {
            let result = await provider.call(
                name: name,
                arguments: ["query": "revenue", "snapshot_id": 7])
            XCTAssertTrue(result.isError, name)
            XCTAssertTrue(result.text.hasPrefix("[screen_access_disabled]"), name)
        }

        try screenGate.enable()
        gate.disable()
        let screenResult = await provider.call(
            name: "search_screen", arguments: ["query": "revenue"])
        XCTAssertFalse(screenResult.isError)
        XCTAssertTrue(screenResult.text.contains("\"snapshot_id\" : 7"))

        let meetingResult = await provider.call(name: "list_meetings", arguments: nil)
        XCTAssertTrue(meetingResult.text.hasPrefix("[access_disabled]"))
    }

    func testListMeetingsReturnsBothNewestFirst() async {
        let result = await provider.call(name: "list_meetings", arguments: nil)
        XCTAssertFalse(result.isError)
        guard let cache = result.text.range(of: "Cache planning"),
              let old = result.text.range(of: "Old sync") else {
            return XCTFail("both meetings expected in: \(result.text)")
        }
        XCTAssertLessThan(cache.lowerBound, old.lowerBound)
    }

    func testMeetingToolsHideMergedSourcesAndRestoreThemAfterUndo() async throws {
        let storage = StorageManager(rootURL: root)
        let sources = storage.loadMeetings()
        let merged = try await MeetingMergeService.merge(
            meetings: sources, title: "Combined planning", storage: storage)
        let list = await provider.call(name: "list_meetings", arguments: nil)
        XCTAssertFalse(list.isError)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.text.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["uuid"] as? String }, [merged.meeting.id.uuidString.lowercased()])
        let search = await provider.call(name: "search_meetings", arguments: ["query": "Redis"])
        XCTAssertFalse(search.isError)
        let hits = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(search.text.utf8)) as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(Set(hits.compactMap { $0["meeting_id"] as? String }), [SessionLookup.shortID(merged.meeting.id)])
        for source in sources {
            let hidden = await provider.call(name: "get_meeting", arguments: ["id": .string(source.id.uuidString)])
            XCTAssertTrue(hidden.isError)
        }

        // Read-only CLI/MCP projection also works before the app repairs an
        // interrupted undo on its next launch.
        try storage.deleteMeeting(merged.meeting)
        for source in sources {
            let restored = await provider.call(name: "get_meeting", arguments: ["id": .string(source.id.uuidString)])
            XCTAssertFalse(restored.isError)
        }
        let restoredList = await provider.call(name: "list_meetings", arguments: nil)
        let restoredRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restoredList.text.utf8)) as? [[String: Any]])
        XCTAssertEqual(restoredRows.count, 2)
    }

    func testListMeetingsFiltersByQuerySinceAndLimit() async {
        let byQuery = await provider.call(
            name: "list_meetings",
            arguments: ["query": "cache"])
        XCTAssertTrue(byQuery.text.contains("Cache planning"))
        XCTAssertFalse(byQuery.text.contains("Old sync"))

        let bySince = await provider.call(
            name: "list_meetings",
            arguments: ["since": "2026-04-01"])
        XCTAssertTrue(bySince.text.contains("Cache planning"))
        XCTAssertFalse(bySince.text.contains("Old sync"))

        let badSince = await provider.call(
            name: "list_meetings",
            arguments: ["since": "April 1st"])
        XCTAssertTrue(badSince.isError)
        XCTAssertTrue(badSince.text.hasPrefix("[invalid_arguments]"))

        let capped = await provider.call(
            name: "list_meetings",
            arguments: ["limit": 1])
        XCTAssertTrue(capped.text.contains("Cache planning"))
        XCTAssertFalse(capped.text.contains("Old sync"))

        for invalid: JSONValue in [0, -1, .number(1.5), 1_001] {
            let result = await provider.call(
                name: "list_meetings", arguments: ["limit": invalid])
            XCTAssertTrue(result.text.hasPrefix("[invalid_arguments]"), "\(invalid)")
        }
    }

    func testGetMeetingLatestReturnsMarkdownSections() async {
        let result = await provider.call(
            name: "get_meeting",
            arguments: ["id": "latest"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("# Cache planning"))
        XCTAssertTrue(result.text.contains("Redis"))

        let summaryOnly = await provider.call(
            name: "get_meeting",
            arguments: ["id": "latest", "include": "summary"])
        XCTAssertTrue(summaryOnly.text.contains("Redis"))
        XCTAssertFalse(summaryOnly.text.contains("# Cache planning"))
    }

    func testGetMeetingErrorCodes() async {
        let missingID = await provider.call(name: "get_meeting", arguments: nil)
        XCTAssertTrue(missingID.text.hasPrefix("[invalid_arguments]"))

        let notFound = await provider.call(
            name: "get_meeting",
            arguments: ["id": "ffffffff"])
        XCTAssertTrue(notFound.text.hasPrefix("[meeting_not_found]"))

        let ambiguous = await provider.call(
            name: "get_meeting",
            arguments: ["id": "aaaaaaa"])
        XCTAssertTrue(ambiguous.text.hasPrefix("[ambiguous_id]"))
    }

    func testSearchMeetingsReturnsHitJSON() async {
        let result = await provider.call(
            name: "search_meetings",
            arguments: ["query": "redis"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("\"match_kind\""))
        XCTAssertTrue(result.text.contains("Cache planning"))

        let missing = await provider.call(name: "search_meetings", arguments: nil)
        XCTAssertTrue(missing.text.hasPrefix("[invalid_arguments]"))

        let badLimit = await provider.call(
            name: "search_meetings", arguments: ["query": "redis", "limit": -4])
        XCTAssertTrue(badLimit.text.hasPrefix("[invalid_arguments]"))
    }

    func testAskLibraryDelegatesToClosure() async {
        let result = await provider.call(
            name: "ask_library",
            arguments: ["question": "What did we decide about caching?"])
        XCTAssertEqual(result.text, "stub answer")
        XCTAssertEqual(askedQuestions, ["What did we decide about caching?"])

        let empty = await provider.call(
            name: "ask_library",
            arguments: ["question": "   "])
        XCTAssertTrue(empty.text.hasPrefix("[invalid_arguments]"))
    }

    func testScreenToolsReturnOnlyOCRAndMetadata() async throws {
        try screenGate.enable()

        let search = await provider.call(
            name: "search_screen",
            arguments: ["query": "revenue", "day": "2026-05-27", "limit": 10])
        XCTAssertFalse(search.isError)
        XCTAssertTrue(search.text.contains("«revenue»"))

        let timeline = await provider.call(
            name: "get_timeline", arguments: ["day": "2026-05-27"])
        XCTAssertFalse(timeline.isError)
        XCTAssertTrue(timeline.text.contains("\"activity\""))
        XCTAssertTrue(timeline.text.contains("\"screenshots\""))

        let recent = await provider.call(
            name: "get_recent_activity", arguments: ["minutes": 60])
        XCTAssertFalse(recent.isError)
        XCTAssertTrue(recent.text.contains("\"duration_seconds\""))

        let usage = await provider.call(
            name: "get_app_usage", arguments: ["day": "2026-05-27"])
        XCTAssertFalse(usage.isError)
        XCTAssertTrue(usage.text.contains("Safari"))

        let detail = await provider.call(
            name: "get_screenshot_detail", arguments: ["snapshot_id": 7])
        XCTAssertFalse(detail.isError)
        XCTAssertTrue(detail.text.contains("Revenue grew"))
        XCTAssertTrue(detail.text.contains("\"has_encrypted_pixels\" : true"))
        XCTAssertFalse(detail.text.contains("path"))
        XCTAssertFalse(detail.text.contains("image"))
        XCTAssertFalse(detail.text.contains("base64"))
    }

    func testScreenToolArgumentErrorsAndMissingScreenshot() async throws {
        try screenGate.enable()

        let emptyQuery = await provider.call(name: "search_screen", arguments: ["query": " "])
        XCTAssertTrue(emptyQuery.text.hasPrefix("[invalid_arguments]"))

        let badDay = await provider.call(
            name: "get_timeline", arguments: ["day": "2026-02-30"])
        XCTAssertTrue(badDay.text.hasPrefix("[invalid_arguments]"))

        let badMinutes = await provider.call(
            name: "get_recent_activity", arguments: ["minutes": 0])
        XCTAssertTrue(badMinutes.text.hasPrefix("[invalid_arguments]"))

        let badID = await provider.call(
            name: "get_screenshot_detail", arguments: ["snapshot_id": -1])
        XCTAssertTrue(badID.text.hasPrefix("[invalid_arguments]"))

        let missing = await provider.call(
            name: "get_screenshot_detail", arguments: ["snapshot_id": 99])
        XCTAssertTrue(missing.text.hasPrefix("[screenshot_not_found]"))
    }

    func testScreenScopeBoundsSearchAndRejectsOlderDetail() async throws {
        try screenGate.enable(profile: ScreenMemoryAccessProfile(scope: .today))
        screenReader.timestamp = Date(timeIntervalSince1970: 1_780_000_000 - 86_400)

        let search = await provider.call(
            name: "search_screen", arguments: ["query": "revenue"])
        XCTAssertFalse(search.isError)
        XCTAssertFalse(search.text.contains("\"snapshot_id\" : 7"))
        let expectedCutoff = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(screenReader.lastSearchRequest?.start, expectedCutoff)

        let detail = await provider.call(
            name: "get_screenshot_detail", arguments: ["snapshot_id": 7])
        XCTAssertTrue(detail.text.hasPrefix("[screenshot_not_found]"))
    }

    func testUnknownToolName() async {
        let result = await provider.call(name: "delete_everything", arguments: nil)
        XCTAssertTrue(result.text.hasPrefix("[unknown_tool]"))
    }
}
