import XCTest
@testable import LokalBot

/// The one-time GitHub star request: when it may appear, that answering it is
/// permanent, and that test, capture, and demo launches never see it.
@MainActor
final class GitHubStarPromptTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(day: Int, hour: Int = 10, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "GitHubStarPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeStore(_ defaults: UserDefaults,
                           launch: GitHubStarPrompt.Launch = .init(),
                           opened: @escaping @MainActor (URL) -> Void = { _ in }) -> GitHubStarPromptStore {
        GitHubStarPromptStore(defaults: defaults, launch: launch, openURL: opened)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubStarPromptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: Eligibility

    func testFreshInstallIsNotAsked() {
        XCTAssertFalse(GitHubStarPrompt.shouldShow(.init(), in: .init()))
    }

    func testFirstCompletedSummaryMakesThePromptEligible() {
        XCTAssertTrue(GitHubStarPrompt.shouldShow(.init(summaryCompleted: true), in: .init()))
    }

    func testSevenDistinctDaysMakeThePromptEligible() {
        var state = GitHubStarPrompt.State()
        for day in 1...6 {
            state = GitHubStarPrompt.recordingActiveDay(DreamDay.key(for: date(day: day), calendar: calendar), in: state)
        }
        XCTAssertFalse(GitHubStarPrompt.shouldShow(state, in: .init()), "six days of use are not enough")
        state = GitHubStarPrompt.recordingActiveDay(DreamDay.key(for: date(day: 7), calendar: calendar), in: state)
        XCTAssertTrue(GitHubStarPrompt.shouldShow(state, in: .init()))
        XCTAssertEqual(GitHubStarPrompt.recordingActiveDay("2026-10-08", in: state), state,
                       "no more days are kept once there are enough to ask")
    }

    func testSameDayRelaunchesCountOnce() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults)
        store.recordActiveDay(date(day: 1, hour: 0, minute: 1), calendar: calendar)
        store.recordActiveDay(date(day: 1, hour: 9), calendar: calendar)
        let relaunched = makeStore(defaults)
        relaunched.recordActiveDay(date(day: 1, hour: 23, minute: 59), calendar: calendar)
        XCTAssertEqual(relaunched.state.activeDays, ["2026-10-01"])

        // Many launches spread over six days are still six days.
        for day in 2...6 {
            for hour in [8, 12, 18] {
                makeStore(defaults).recordActiveDay(date(day: day, hour: hour), calendar: calendar)
            }
        }
        XCTAssertEqual(makeStore(defaults).state.activeDays.count, 6)
        XCTAssertFalse(makeStore(defaults).showsPrompt)
        makeStore(defaults).recordActiveDay(date(day: 7), calendar: calendar)
        XCTAssertTrue(makeStore(defaults).showsPrompt)
    }

    func testDismissedPromptIsNeverEligibleAgain() {
        let answered = GitHubStarPrompt.State(
            dismissed: true, summaryCompleted: true,
            activeDays: (1...7).map { String(format: "2026-10-%02d", $0) })
        XCTAssertFalse(GitHubStarPrompt.shouldShow(answered, in: .init()))
    }

    func testTestCaptureAndDemoLaunchesNeverShowThePrompt() {
        let eligible = GitHubStarPrompt.State(
            summaryCompleted: true,
            activeDays: (1...7).map { String(format: "2026-10-%02d", $0) })
        XCTAssertTrue(GitHubStarPrompt.shouldShow(eligible, in: .init()))
        let suppressed: [GitHubStarPrompt.Launch] = [
            .init(uiTesting: true), .init(unitTesting: true), .init(headless: true), .init(seededDemoLibrary: true),
        ]
        for launch in suppressed {
            XCTAssertTrue(launch.suppressesPrompt, "\(launch)")
            XCTAssertFalse(GitHubStarPrompt.shouldShow(eligible, in: launch), "\(launch)")
        }
    }

    func testSuppressedLaunchesRecordNothing() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults, launch: .init(uiTesting: true))
        store.recordSummaryCompleted()
        store.recordActiveDay(date(day: 1), calendar: calendar)
        XCTAssertEqual(store.state, .init())
        XCTAssertFalse(store.showsPrompt)
        XCTAssertNil(defaults.object(forKey: GitHubStarPromptStore.summaryCompletedKey))
        XCTAssertNil(defaults.object(forKey: GitHubStarPromptStore.activeDaysKey))
        XCTAssertFalse(makeStore(defaults).showsPrompt, "a later normal launch has nothing to act on")
    }

    /// The detection the app itself uses: XCTest hosts the app, so this very
    /// process must count as a test launch.
    func testHostedTestProcessIsSuppressed() throws {
        let store = GitHubStarPromptStore.live(libraryRoot: try makeRoot())
        XCTAssertTrue(store.launch.unitTesting)
        XCTAssertTrue(store.launch.suppressesPrompt)
    }

    func testSeededDemoLibraryIsRecognizedByTheSeedScriptMarker() throws {
        let root = try makeRoot()
        XCTAssertFalse(GitHubStarPrompt.isSeededDemoLibrary(root))
        try Data("LokalBot synthetic demo library\n".utf8)
            .write(to: root.appendingPathComponent(".lokalbot-demo-library"))
        XCTAssertTrue(GitHubStarPrompt.isSeededDemoLibrary(root))
    }

    // MARK: Persistence

    func testDismissalSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults)
        store.recordSummaryCompleted()
        XCTAssertTrue(store.showsPrompt)
        store.dismiss()
        XCTAssertFalse(store.showsPrompt)

        let relaunched = makeStore(defaults)
        XCTAssertTrue(relaunched.state.dismissed)
        XCTAssertFalse(relaunched.showsPrompt)
        for day in 1...7 { relaunched.recordActiveDay(date(day: day), calendar: calendar) }
        relaunched.recordSummaryCompleted()
        XCTAssertFalse(makeStore(defaults).showsPrompt, "nothing brings an answered request back")
    }

    func testEligibilitySurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        makeStore(defaults).recordSummaryCompleted()
        XCTAssertTrue(makeStore(defaults).state.summaryCompleted)
        XCTAssertTrue(makeStore(defaults).showsPrompt)
    }

    func testStarringOpensTheRepositoryAndRetiresThePrompt() throws {
        let defaults = try makeDefaults()
        var opened: [URL] = []
        let store = makeStore(defaults) { opened.append($0) }
        store.recordSummaryCompleted()
        store.openRepository()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/stevyhacker/LokalBot"])
        XCTAssertFalse(store.showsPrompt)
        XCTAssertFalse(makeStore(defaults).showsPrompt)
    }
}

/// The request counts a meeting summary only when the pipeline saved one.
@MainActor
final class ProcessingPipelineSummarySignalTests: XCTestCase {
    /// `onArtifactsWritten` also fires when notes fail, so it cannot tell a
    /// finished summary from a failed one.
    func testFailedSummaryIsNotACompletedSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessingPipelineSummarySignalTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                              startedAt: Date(), endedAt: Date().addingTimeInterval(60),
                              relativePath: "meetings/2026/10/17-standup")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = Transcript(
            segments: [.init(start: 0, end: 4, speaker: "me", text: "I will send the deck tomorrow.")],
            engine: "fixture")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))

        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        // Not approved, so the engine is refused before any request is made.
        settings.openAIBaseURL = "https://notes.example.com/v1"
        let pipeline = ProcessingPipeline(storage: storage, settings: { settings })
        var artifactsWritten = 0
        var summariesCompleted = 0
        pipeline.onArtifactsWritten = { _ in artifactsWritten += 1 }
        pipeline.onSummaryCompleted = { _ in summariesCompleted += 1 }

        pipeline.enqueue(meeting, transcribe: false, summarize: true)
        for _ in 0..<500 where pipeline.stages[meeting.id]?.isFailure != true {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertGreaterThan(artifactsWritten, 0)
        XCTAssertEqual(summariesCompleted, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
    }
}
