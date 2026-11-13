import XCTest
@testable import LokalBot

private final class StubDailyMemoryExportSource: DailyMemoryExportSource {
    var value: DailyMemoryExportSnapshot

    init(value: DailyMemoryExportSnapshot) {
        self.value = value
    }

    func snapshot(for day: Date, interval: DateInterval) throws -> DailyMemoryExportSnapshot {
        var copy = value
        copy.day = day
        return copy
    }
}

private struct SelfCancellingDailyMemoryExportSource: DailyMemoryExportSource {
    var value: DailyMemoryExportSnapshot

    func snapshot(for day: Date, interval: DateInterval) throws -> DailyMemoryExportSnapshot {
        withUnsafeCurrentTask { $0?.cancel() }
        var copy = value
        copy.day = day
        return copy
    }
}

final class DailyMemoryExportServiceTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var day: Date!
    private var source: StubDailyMemoryExportSource!
    private var service: DailyMemoryExportService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-memory-export-\(UUID().uuidString)", isDirectory: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Podgorica"))
        day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 12)))
        source = StubDailyMemoryExportSource(value: sampleSnapshot())
        service = DailyMemoryExportService(source: source, calendar: calendar)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testMarkdownIncludesDigestMeetingsSavedMomentsAndStatsWithoutPixelData() throws {
        let outcome = try service.export(
            day: day,
            configuration: .init(destinationDirectory: root, format: .markdown))
        let url = try writtenURL(outcome)
        XCTAssertEqual(url.lastPathComponent, "2026-07-14.md")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(DailyMemoryExportService.generatedFileMarker))
        XCTAssertTrue(text.contains("Shipped the recall slice."))
        XCTAssertTrue(text.contains("Planning \\*review\\*"))
        XCTAssertTrue(text.contains("`screen:42`"))
        XCTAssertTrue(text.contains("Use this chart"))
        XCTAssertTrue(text.contains("| Tracked time | 2h 5m |"))
        XCTAssertTrue(text.contains("- Safari: 1h 30m"))
        XCTAssertFalse(text.contains(".heic.enc"))
        XCTAssertFalse(text.contains("has_encrypted_pixels"))
        XCTAssertFalse(text.contains("screenshot_path"))
    }

    func testGeneratedNoteAndOwnershipSidecarArePrivate() throws {
        let outcome = try service.export(
            day: day,
            configuration: .init(destinationDirectory: root, format: .markdown))
        let url = try writtenURL(outcome)
        let sidecar = DailyMemoryExportService.ownershipSidecarURL(for: url)

        for file in [url, sidecar] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
                .intValue & 0o777
            XCTAssertEqual(mode, 0o600, file.lastPathComponent)
        }
    }

    func testFormatsUseDeterministicNamesAndMarkerPlacement() throws {
        let cases: [(DailyMemoryExportKind, String, String)] = [
            (.markdown, "2026-07-14.md", DailyMemoryExportService.generatedFileMarker + "\n\n#"),
            (.obsidian, "2026-07-14.md", "source: LokalBot\n---\n\n" + DailyMemoryExportService.generatedFileMarker),
            (.logseq, "2026_07_14.md", "tags:: lokalbot, daily-memory\n\n" + DailyMemoryExportService.generatedFileMarker),
        ]

        for (format, expectedName, markerContext) in cases {
            let directory = root.appendingPathComponent(format.rawValue, isDirectory: true)
            let outcome = try service.export(
                day: day,
                configuration: .init(destinationDirectory: directory, format: format))
            let url = try writtenURL(outcome)
            XCTAssertEqual(url.lastPathComponent, expectedName, format.rawValue)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains(markerContext), format.rawValue)
            XCTAssertEqual(
                text,
                service.render(source.valueWithDay(day), format: format),
                "rendering and exported content must be deterministic")
        }
    }

    func testIdenticalExportIsUnchangedAndPreservesModificationDate() throws {
        let configuration = DailyMemoryExportConfiguration(
            destinationDirectory: root, format: .markdown)
        let first = try service.export(day: day, configuration: configuration)
        let url = try writtenURL(first)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: url.path)

        let second = try service.export(day: day, configuration: configuration)
        guard case .unchanged(let unchangedURL) = second else {
            return XCTFail("expected unchanged, got \(second)")
        }
        XCTAssertEqual(unchangedURL, url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            modificationDate.timeIntervalSince1970,
            fixedDate.timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testChangedGeneratedFileIsAtomicallyRewritten() throws {
        let configuration = DailyMemoryExportConfiguration(
            destinationDirectory: root, format: .markdown)
        let first = try service.export(day: day, configuration: configuration)
        let url = try writtenURL(first)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8)
            .contains("Shipped the recall slice."))

        source.value.digest = "A newer digest after regeneration."
        let second = try service.export(day: day, configuration: configuration)
        _ = try writtenURL(second)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("A newer digest after regeneration."))
        XCTAssertFalse(text.contains("Shipped the recall slice."))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            Set([
                "2026-07-14.md",
                ".2026-07-14.md\(DailyMemoryExportService.ownershipSidecarSuffix)",
            ]),
            "atomic replacement must not leave temporary siblings behind")
    }

    func testUserEditsToGeneratedFileAreNeverOverwritten() throws {
        let configuration = DailyMemoryExportConfiguration(
            destinationDirectory: root, format: .markdown)
        let first = try service.export(day: day, configuration: configuration)
        let url = try writtenURL(first)
        let userEdited = try String(contentsOf: url, encoding: .utf8)
            + "\n## My additions\n\nKeep this paragraph.\n"
        try userEdited.write(to: url, atomically: true, encoding: .utf8)
        source.value.digest = "A regenerated digest that would otherwise replace the note."

        XCTAssertThrowsError(try service.export(day: day, configuration: configuration)) { error in
            XCTAssertEqual(error as? DailyMemoryExportError, .generatedFileModified(url))
            XCTAssertTrue(error.localizedDescription.contains("Your edits were preserved"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), userEdited)
    }

    func testIdenticalLegacyGeneratedFileIsAdoptedWithoutRewritingNote() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("2026-07-14.md")
        let rendered = service.render(source.valueWithDay(day), format: .markdown)
        try rendered.write(to: url, atomically: true, encoding: .utf8)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: url.path)

        let outcome = try service.export(
            day: day,
            configuration: .init(destinationDirectory: root, format: .markdown))
        guard case .unchanged = outcome else { return XCTFail("expected unchanged") }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            DailyMemoryExportService.ownershipSidecarURL(for: url).path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            modificationDate.timeIntervalSince1970,
            fixedDate.timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testUserAuthoredSameDayFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("2026-07-14.md")
        let original = "# My own journal\n\nDo not replace this.\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.export(
            day: day,
            configuration: .init(destinationDirectory: root, format: .markdown)
        )) { error in
            XCTAssertEqual(error as? DailyMemoryExportError, .destinationCollision(url))
            XCTAssertTrue(error.localizedDescription.contains("was not generated by LokalBot"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testCatchUpWritesAMissedDayOnceAndLeavesExistingFilesAlone() throws {
        let configuration = DailyMemoryExportConfiguration(destinationDirectory: root, format: .markdown)
        let url = try writtenURL(try service.export(day: day, configuration: configuration, pass: .catchUp))
        let first = try String(contentsOf: url, encoding: .utf8)

        source.value.digest = "A later digest."
        XCTAssertEqual(try service.export(day: day, configuration: configuration, pass: .catchUp), .skipped)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)

        let userDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let userNote = root.appendingPathComponent("2026-07-13.md")
        try "# My own note\n".write(to: userNote, atomically: true, encoding: .utf8)
        XCTAssertEqual(try service.export(day: userDay, configuration: configuration, pass: .catchUp), .skipped)
        XCTAssertEqual(try String(contentsOf: userNote, encoding: .utf8), "# My own note\n")
    }

    func testCatchUpSkipsADayWithNothingRecorded() throws {
        source.value = DailyMemoryExportSnapshot(
            day: day, digest: nil, meetings: [], savedMoments: [],
            stats: ScreenMemoryDaySummary(trackedSeconds: 0, appCount: 0, activityBlockCount: 0,
                                          screenshotCount: 0, savedMomentCount: 0),
            appUsage: [])
        let configuration = DailyMemoryExportConfiguration(destinationDirectory: root, format: .markdown)

        XCTAssertEqual(try service.export(day: day, configuration: configuration, pass: .catchUp), .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // Today's note is still written when nothing happened.
        _ = try writtenURL(try service.export(day: day, configuration: configuration))
    }

    func testOutOfDateDigestIsNamedInsteadOfShown() {
        var snapshot = sampleSnapshot()
        snapshot.digest = nil
        snapshot.digestIsOutOfDate = true

        let text = service.render(snapshot, format: .markdown)

        XCTAssertTrue(text.contains("The day's digest is out of date."))
        XCTAssertFalse(text.contains("No day digest was generated."))
    }

    func testCancellationBeforeMutationCreatesNoExportFiles() async throws {
        let directory = root.appendingPathComponent("cancelled", isDirectory: true)
        let cancellingService = DailyMemoryExportService(
            source: SelfCancellingDailyMemoryExportSource(value: source.value),
            calendar: calendar)
        let task = Task {
            try cancellingService.export(
                day: day,
                configuration: .init(destinationDirectory: directory, format: .markdown))
        }

        switch await task.result {
        case .success:
            XCTFail("cancelled export unexpectedly succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A freshly booted install has a `lokalbotv3.sqlite` file whose tables
    /// are created lazily — a read-only snapshot taken in that window (the
    /// headless `--dream` case) must see an empty day, not throw.
    func testSnapshotToleratesDatabaseFileWithoutSchema() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("lokalbotv3.sqlite").path,
            contents: Data())
        let fileSource = FileDailyMemoryExportSource(root: root, calendar: calendar)
        let start = calendar.startOfDay(for: day)
        let snapshot = try fileSource.snapshot(
            for: day, interval: DateInterval(start: start, duration: 86_400))
        XCTAssertEqual(snapshot.stats.trackedSeconds, 0)
        XCTAssertTrue(snapshot.savedMoments.isEmpty)
        XCTAssertTrue(snapshot.appUsage.isEmpty)
    }

    private func sampleSnapshot() -> DailyMemoryExportSnapshot {
        DailyMemoryExportSnapshot(
            day: day,
            digest: "## Summary\n\nShipped the recall slice.",
            meetings: [
                DailyMemoryMeetingReference(
                    id: "a1b2c3d4",
                    title: "Planning *review*",
                    startedAt: day.addingTimeInterval(-2 * 60 * 60),
                    durationSeconds: 45 * 60),
            ],
            savedMoments: [
                ScreenMemorySavedMoment(
                    snapshotID: 42,
                    capturedAt: day.addingTimeInterval(-60 * 60),
                    app: "Safari",
                    windowTitle: "Quarterly report",
                    captureTrigger: "window_change",
                    note: "Use this chart\nin the review",
                    savedAt: day.addingTimeInterval(-3_000),
                    ocrExcerpt: "Revenue grew 14 percent"),
            ],
            stats: ScreenMemoryDaySummary(
                trackedSeconds: 7_500,
                appCount: 2,
                activityBlockCount: 8,
                screenshotCount: 12,
                savedMomentCount: 1),
            appUsage: [
                ScreenMemoryAppUsage(app: "Safari", durationSeconds: 5_400, blockCount: 4),
                ScreenMemoryAppUsage(app: "Xcode", durationSeconds: 2_100, blockCount: 4),
            ])
    }

    private func writtenURL(_ outcome: DailyMemoryExportService.Outcome,
                            file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var written: URL?
        if case .written(let url) = outcome { written = url }
        return try XCTUnwrap(written, "expected written outcome, got \(outcome)", file: file, line: line)
    }
}

private extension StubDailyMemoryExportSource {
    func valueWithDay(_ day: Date) -> DailyMemoryExportSnapshot {
        var copy = value
        copy.day = day
        return copy
    }
}
