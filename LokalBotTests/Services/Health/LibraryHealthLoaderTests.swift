import XCTest
@testable import LokalBot

@MainActor
final class LibraryHealthLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryHealthLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoaderReadsBlocksCapturesAndDigestCoverage() throws {
        let store = ActivityStore(databaseURL: DiagnosticsPaths.database(root: root))
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date()).addingTimeInterval(-86_400)
        store.insert(ActivityBlock(app: "Xcode", title: "a", start: day.addingTimeInterval(9 * 3_600),
                                   end: day.addingTimeInterval(11 * 3_600)))
        _ = try store.insertScreenshot(ts: day.addingTimeInterval(9.5 * 3_600), path: "", app: "Xcode",
                                       windowTitle: "a", trigger: "interval", textSource: "accessibility",
                                       ocr: "text", sourceURL: "", documentName: "", meetingID: "",
                                       privacyRedactions: 0)
        let journal = LibraryHealthLoader.journalURL(root: root, day: day, calendar: calendar)
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("digest".utf8).write(to: journal)
        try DayDigestGenerationMetadataStore.record(
            quality: .complete, evidenceLatestAt: nil,
            coverage: DayDigestCoverage(coveredSeconds: 3_600, trackedSeconds: 7_200), for: journal)

        var settings = AppSettings()
        settings.trackingEnabled = true
        let loader = LibraryHealthLoader(
            activityStore: store, storageRoot: root, meetings: [], queuedMeetingIDs: [],
            settings: settings, hasDreamReport: { _ in true })
        let input = loader.input(for: day, now: day.addingTimeInterval(33 * 3_600), calendar: calendar)

        XCTAssertEqual(input.blocks.count, 1)
        XCTAssertEqual(input.captureCountsByApp["Xcode"], 1)
        XCTAssertEqual(input.digestCoverage?.coveredSeconds, 3_600)
    }

    func testReportStoreWritesJsonAndMarkdownAndFindsLatestRun() throws {
        let report = LibraryHealthReport(dayKey: "2026-09-29", generatedAt: Date(timeIntervalSince1970: 100),
                                         findings: [.init(check: .schedulers, status: .fail, summary: "Late")])
        let markdown = try LibraryHealthReportStore.write(report, root: root)
        XCTAssertTrue(try String(contentsOf: markdown, encoding: .utf8).contains("FAIL"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DiagnosticsPaths.healthReports(root: root).appendingPathComponent("2026-09-29.json").path))
        XCTAssertEqual(LibraryHealthReportStore.latestRunDate(root: root), Date(timeIntervalSince1970: 100))
    }
}
