import XCTest
@testable import LokalBot

/// What a scope on a question keeps the real library tools from reading. A
/// scope that holds nothing (a phone that shares no finished meeting yet) once
/// read as no scope at all, and every tool answered from the whole library.
@MainActor
final class ScopedToolScopeTests: XCTestCase {
    private var root: URL!
    private var tools: MeetingChatTools!
    private var shared: Meeting!
    private var sample: Meeting!
    private var live: Meeting!
    private var screens: [Int64] = []

    private let titles = ["Roadmap review", "Sample walkthrough", "Live call"]
    /// Words only the meetings hold; the query word alone can be echoed back.
    private let contents = ["shared orchard", "sample orchard", "live orchard"]
    private var outsideTheScope: [String] { ["Sample walkthrough", "Live call", "sample orchard", "live orchard"] }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-scoped-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageManager(rootURL: root)
        let sqlite = root.appendingPathComponent("lokalbotv3.sqlite")
        let searchIndex = SearchIndex(databaseURL: sqlite)
        // Noon, so "today" holds everything whenever the test runs.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)

        func meeting(_ title: String, path: String, started: TimeInterval, ended: TimeInterval?,
                     line: String, action: String) throws -> Meeting {
            let meeting = Meeting(
                id: UUID(), title: title, appName: "Zoom",
                startedAt: now.addingTimeInterval(started), endedAt: ended.map { now.addingTimeInterval($0) },
                relativePath: "meetings/2026/11/\(path)", hasSystemTrack: true)
            let folder = meeting.folderURL(in: storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let transcript = Transcript(
                segments: [.init(start: 5, end: 12, speaker: "me", text: line, confidence: nil)], engine: "test")
            try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
            try Data(transcript.markdown.utf8).write(to: folder.appendingPathComponent("transcript.md"))
            try Data("## TL;DR\n\(line)".utf8).write(to: folder.appendingPathComponent("summary.md"))
            var outcomes = MeetingOutcomes()
            outcomes.actionItems = [.init(text: action, owner: "Ana")]
            try outcomes.write(to: folder)
            searchIndex.reindex(meeting, storage: storage)
            return meeting
        }
        shared = try meeting("Roadmap review", path: "roadmap", started: -1_800, ended: -900,
                             line: "We agreed to ship the shared orchard build on Friday.",
                             action: "Send the shared orchard notes")
        var sampled = try meeting("Sample walkthrough", path: "sample", started: -1_200, ended: -600,
                                  line: "This is the sample orchard conversation.",
                                  action: "Tidy the sample orchard")
        sampled.sampleID = "tour"
        sample = sampled
        live = try meeting("Live call", path: "live", started: -300, ended: nil,
                           line: "A live orchard discussion is still going on.",
                           action: "Join the live orchard")

        let activityStore = ActivityStore(databaseURL: sqlite)
        XCTAssertTrue(activityStore.insert(ActivityBlock(
            id: 0, app: "Xcode", title: "Roadmap.md",
            start: now.addingTimeInterval(-240), end: now.addingTimeInterval(-60))))
        screens = [
            try activityStore.insertScreenshot(
                ts: now.addingTimeInterval(-120), path: "", app: "Numbers", windowTitle: "Budget first",
                trigger: "app_switch", ocr: "The orchard budget sheet for the first quarter"),
            try activityStore.insertScreenshot(
                ts: now.addingTimeInterval(-2_400), path: "", app: "Keynote", windowTitle: "Budget second",
                trigger: "app_switch", ocr: "Slides reviewing the orchard budget with the board"),
        ]
        var settings = AppSettings()
        settings.semanticSearchEnabled = false
        let all: [Meeting] = [live, sample, shared]
        tools = MeetingChatTools(
            meetings: { all }, storage: storage, searchIndex: searchIndex,
            embeddingIndex: EmbeddingIndex(databaseURL: sqlite, storage: storage),
            activityStore: activityStore, settings: { settings }, now: { now })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every meeting tool the phone's Ask can reach, with the arguments a model would give.
    private let meetingCalls: [(name: String, arguments: [String: String])] = [
        ("list_meetings", [:]),
        ("get_meeting", ["id": "latest", "include": "all"]),
        ("search_meetings", ["query": "orchard"]),
        ("get_action_items", [:]),
        ("activity_summary", ["day": "today"]),
    ]

    private func run(_ runner: ScopedChatToolRunner, _ call: (name: String, arguments: [String: String])) async -> String {
        await runner.run(ChatToolCall(name: call.name, arguments: call.arguments)).text
    }

    func testTheFixtureIsReadableWithoutAScope() async {
        let runner = ScopedChatToolRunner(base: tools, scopes: [.meetings, .today, .screen])
        let list = await run(runner, meetingCalls[0])
        for title in titles { XCTAssertTrue(list.contains(title), list) }
        let search = await run(runner, meetingCalls[2])
        XCTAssertTrue(search.contains("Sample walkthrough") && search.contains("Roadmap review"), search)
        let actions = await run(runner, meetingCalls[3])
        XCTAssertTrue(actions.contains("Tidy the sample orchard"), actions)
        let today = await run(runner, meetingCalls[4])
        XCTAssertTrue(today.contains("Xcode") && today.contains("Live call"), today)
        let screen = await runner.run(ChatToolCall(name: "search_screen", arguments: ["query": "orchard budget"]))
        XCTAssertEqual(screen.evidence.screenIDs, Set(screens), screen.text)
    }

    func testAnEmptyMeetingScopeReadsNoMeeting() async {
        let runner = ScopedChatToolRunner(base: tools, scopes: [.meetings, .today], meetingIDs: [])
        for call in meetingCalls {
            let text = await run(runner, call)
            for hidden in titles + contents {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(hidden), "\(call.name) read \(hidden): \(text)")
            }
        }
        // The Timeline is its own source: an empty meeting scope hides the
        // day's meetings, not the day's apps.
        let today = await run(runner, meetingCalls[4])
        XCTAssertTrue(today.contains("Xcode"), today)
    }

    func testAScopeThatLeavesAMeetingOutNeverReturnsIt() async {
        let runner = ScopedChatToolRunner(base: tools, scopes: [.meetings, .today], meetingIDs: [shared.id])
        for call in meetingCalls {
            let text = await run(runner, call)
            XCTAssertTrue(text.contains("Roadmap review") || text.contains("shared orchard"), "\(call.name): \(text)")
            for hidden in outsideTheScope {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(hidden), "\(call.name) read \(hidden): \(text)")
            }
        }
    }

    func testAnEmptyScreenScopeReadsNoScreen() async {
        let none = ScopedChatToolRunner(base: tools, scopes: [.screen], screenSnapshotIDs: [])
        let nothing = await none.run(ChatToolCall(name: "search_screen", arguments: ["query": "orchard budget"]))
        XCTAssertTrue(nothing.evidence.screenIDs.isEmpty, nothing.text)
        XCTAssertFalse(nothing.text.contains("Budget"), nothing.text)

        let one = ScopedChatToolRunner(base: tools, scopes: [.screen], screenSnapshotIDs: [screens[1]])
        let found = await one.run(ChatToolCall(name: "search_screen", arguments: ["query": "orchard budget"]))
        XCTAssertEqual(found.evidence.screenIDs, [screens[1]])
        XCTAssertFalse(found.text.contains("Budget first"), found.text)
    }

    func testAnEmptyScopeIsNotAMissingOne() {
        let none = ChatToolCall(name: "list_meetings", arguments: [:])
        let empty = ChatToolCall(name: "list_meetings", arguments: ["_lokalbot_meeting_ids": ""])
        let two = ChatToolCall(name: "list_meetings", arguments: ["_lokalbot_meeting_ids": "a, b,"])
        XCTAssertNil(none.scope("_lokalbot_meeting_ids"))
        XCTAssertEqual(empty.scope("_lokalbot_meeting_ids"), [])
        XCTAssertEqual(two.scope("_lokalbot_meeting_ids"), ["a", "b"])
    }
}
