import XCTest
@testable import LokalBot

@MainActor
final class DayDigestLifecycleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    func testEvidenceRetractionDeletesOnlyUnchangedGeneratedJournals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = makeLifecycle(root: root, latestActivityEvidenceAt: { _ in nil })
        let first = try date("2026-08-21T12:00:00Z")
        let edited = try date("2026-08-22T12:00:00Z")
        let legacy = try date("2026-08-23T12:00:00Z")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("journal"), withIntermediateDirectories: true)
        for day in [first, edited, legacy] {
            let url = lifecycle.journalURL(for: day)
            try "Generated private source text".write(to: url, atomically: true, encoding: .utf8)
            if day != legacy { try DayDigestGenerationMetadataStore.record(quality: .complete, evidenceLatestAt: day, for: url) }
        }
        try "User-authored changes".write(to: lifecycle.journalURL(for: edited), atomically: true, encoding: .utf8)
        try lifecycle.retractGeneratedJournals(for: [first, edited, legacy])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycle.journalURL(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DayDigestGenerationMetadataStore.metadataURL(for: lifecycle.journalURL(for: first)).path))
        XCTAssertEqual(try String(contentsOf: lifecycle.journalURL(for: edited), encoding: .utf8), "User-authored changes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lifecycle.journalURL(for: legacy).path))
    }

    func testScheduledDigestNeedsAutomationApprovalButManualRunKeepsGeneralConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digest-consent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try date("2026-08-23T19:00:00Z")
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://remote.example/v1"
        settings.approvedRemoteInferenceOrigins = ["https://remote.example"]
        let unexpected = expectation(description: "No unattended request before approval")
        unexpected.isInverted = true
        let approved = expectation(description: "Approved scheduled request")
        var manual = false
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { now }),
            blocks: { _ in [ActivityBlock(id: 1, app: "Notes", title: "Work", start: now.addingTimeInterval(-60), end: now)] },
            screenContexts: { _ in [] }, meetings: { [] }, latestActivityEvidenceAt: { _ in now },
            settings: { settings }, generator: { _, _, _ in
                if !manual {
                    if settings.approvedRemoteAutomationOrigins.isEmpty { unexpected.fulfill() } else { approved.fulfill() }
                }
                return DayDigestGenerationResult(text: "fixture", url: root.appendingPathComponent("journal.md"), quality: .complete)
            })
        lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 18), canRun: { true }, onError: { XCTFail($0) })
        await fulfillment(of: [unexpected], timeout: 0.15)
        lifecycle.stopAutomaticGeneration()
        manual = true
        _ = try await lifecycle.generate(for: now)
        manual = false
        settings.approvedRemoteAutomationOrigins = ["https://remote.example"]
        lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 18), canRun: { true }, onError: { XCTFail($0) })
        await fulfillment(of: [approved], timeout: 2)
        lifecycle.stopAutomaticGeneration()
    }

    func testSnapshotOwnsJournalFreshnessAndLatestEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "## Focus\n\nShipped the lifecycle.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        let modifiedAt = try date("2026-08-23T18:00:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: journal.path)
        let latestEvidenceAt = try date("2026-08-23T18:30:00Z")

        let lifecycle = makeLifecycle(
            root: root,
            latestActivityEvidenceAt: { _ in latestEvidenceAt })
        let snapshot = lifecycle.snapshot(for: day)

        XCTAssertEqual(snapshot.text, "## Focus\n\nShipped the lifecycle.")
        XCTAssertEqual(snapshot.modifiedAt, modifiedAt)
        XCTAssertEqual(snapshot.latestEvidenceAt, latestEvidenceAt)
        XCTAssertTrue(snapshot.isStale)
    }

    func testGenerateCollectsFinishedDayEvidenceThroughOneInterface() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let finished = Meeting(
            id: UUID(),
            title: "Architecture",
            appName: "Meet",
            startedAt: try date("2026-08-23T09:00:00Z"),
            endedAt: try date("2026-08-23T09:30:00Z"),
            relativePath: "meetings/architecture")
        let inProgress = Meeting(
            id: UUID(),
            title: "Live",
            appName: "Meet",
            startedAt: try date("2026-08-23T11:00:00Z"),
            endedAt: nil,
            relativePath: "meetings/live")
        let block = ActivityBlock(
            id: 7,
            app: "Xcode",
            title: "DayDigestLifecycle.swift",
            start: try date("2026-08-23T10:00:00Z"),
            end: try date("2026-08-23T10:30:00Z"))
        let screen = DayScreenContext(
            snapshotID: 42,
            capturedAt: try date("2026-08-23T10:15:00Z"),
            app: "Xcode",
            windowTitle: "LokalBot",
            text: "Deepen the Day Digest module")
        var receivedBlocks: [ActivityBlock] = []
        var receivedMeetings: [Meeting] = []
        var receivedScreens: [DayScreenContext] = []

        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            blocks: { _ in [block] },
            screenContexts: { _ in [screen] },
            meetings: { [finished, inProgress] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { evidence, _, _ in
                receivedBlocks = evidence.activityBlocks
                receivedMeetings = evidence.meetings.map(\.meeting)
                receivedScreens = evidence.screenContexts
                return DayDigestGenerationResult(
                    text: "digest",
                    url: root.appendingPathComponent("journal/2026-08-23.md"),
                    quality: .complete)
            })

        _ = try await lifecycle.generate(for: day)

        XCTAssertEqual(receivedBlocks, [block])
        XCTAssertEqual(receivedMeetings, [finished])
        XCTAssertEqual(receivedScreens, [screen])
    }

    func testSummaryWrittenAfterDigestAdvancesEvidenceAndMarksSnapshotStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let meeting = try finishedMeeting()
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "## Day summary\n\nInitial digest.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        let digestAt = try date("2026-08-23T10:00:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: digestAt],
            ofItemAtPath: journal.path)

        let lifecycle = makeLifecycle(
            root: root,
            meetings: { [meeting] },
            latestActivityEvidenceAt: { _ in nil })
        XCTAssertTrue(lifecycle.snapshot(for: day).isStale, "Legacy journals have no evidence proof")

        let summary = folder.appendingPathComponent("summary.md")
        try "## TL;DR\n\nArchitecture shipped.".write(
            to: summary,
            atomically: true,
            encoding: .utf8)
        let summaryAt = try date("2026-08-23T10:05:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: summaryAt],
            ofItemAtPath: summary.path)

        let snapshot = lifecycle.snapshot(for: day)
        XCTAssertEqual(snapshot.latestEvidenceAt, summaryAt)
        XCTAssertTrue(snapshot.isStale)
    }

    func testOutcomesWrittenAfterDigestMakeAutomaticGenerationRepairIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let now = try date("2026-08-23T19:00:00Z")
        let meeting = try finishedMeeting()
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "## Day summary\n\nInitial digest.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        let digestAt = try date("2026-08-23T18:01:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: digestAt],
            ofItemAtPath: journal.path)

        let action = MeetingOutcomes.ActionItem(text: "Ship the lifecycle", owner: "Me")
        try MeetingOutcomes(
            actionItems: [action],
            decisions: ["Ship the lifecycle."]).write(to: folder)
        let outcomes = folder.appendingPathComponent(MeetingOutcomes.fileName)
        let outcomesAt = try date("2026-08-23T18:05:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: outcomesAt],
            ofItemAtPath: outcomes.path)
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(status: .done, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: folder)
        let stateAt = try date("2026-08-23T18:06:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: stateAt],
            ofItemAtPath: folder.appendingPathComponent(MeetingOutcomeState.fileName).path)

        let generated = expectation(description: "stale digest repaired")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { now })
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            scheduler: scheduler,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { [meeting] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { evidence, _, _ in
                XCTAssertEqual(DreamDay.key(for: evidence.day, calendar: self.calendar),
                               "2026-08-23")
                XCTAssertEqual(evidence.meetings.map(\.meeting), [meeting])
                generated.fulfill()
                return DayDigestGenerationResult(
                    text: "repaired",
                    url: journal,
                    quality: .complete)
            })
        let snapshot = lifecycle.snapshot(for: day)
        XCTAssertEqual(snapshot.latestEvidenceAt, stateAt)
        XCTAssertTrue(snapshot.isStale)

        lifecycle.configureAutomaticGeneration(
            .init(enabled: true, hour: 18),
            canRun: { true },
            onError: { XCTFail($0) })
        await fulfillment(of: [generated], timeout: 2)
        lifecycle.stopAutomaticGeneration()
    }

    func testArtifactWrittenAfterYesterdayFinalizationReopensAutomaticRepair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-digest-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try date("2026-08-23T12:00:00Z")
        let now = try date("2026-08-24T08:00:00Z")
        let meeting = try finishedMeeting()
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "## Day summary\n\nFinalized digest.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        let finalizedAt = try date("2026-08-24T00:05:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: finalizedAt],
            ofItemAtPath: journal.path)

        let summary = folder.appendingPathComponent("summary.md")
        try "## TL;DR\n\nRecovered after finalization.".write(
            to: summary,
            atomically: true,
            encoding: .utf8)
        let summaryAt = try date("2026-08-24T00:10:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: summaryAt],
            ofItemAtPath: summary.path)

        let generated = expectation(description: "finalized digest repaired")
        let scheduler = DayDigestScheduler(calendar: calendar, now: { now })
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            scheduler: scheduler,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { [meeting] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { evidence, _, _ in
                XCTAssertEqual(DreamDay.key(for: evidence.day, calendar: self.calendar),
                               "2026-08-23")
                generated.fulfill()
                return DayDigestGenerationResult(
                    text: "repaired",
                    url: journal,
                    quality: .complete)
            })
        XCTAssertTrue(lifecycle.snapshot(for: day).isStale)

        lifecycle.configureAutomaticGeneration(
            .init(enabled: true, hour: 18),
            canRun: { true },
            onError: { XCTFail($0) })
        await fulfillment(of: [generated], timeout: 2)
        lifecycle.stopAutomaticGeneration()
    }

    func testHeadlessOutputKeepsJournalPathAtStablePosition() throws {
        let day = try date("2026-08-23T12:00:00Z")
        let result = DayDigestGenerationResult(
            text: "## Focus",
            url: URL(fileURLWithPath: "/tmp/journal/2026-08-23.md"),
            quality: .complete)

        let output = DayDigestCLIOutput.render(
            result: result,
            modelID: "qwen",
            day: day)

        XCTAssertTrue(output.hasPrefix(
            "LokalBot --digest: /tmp/journal/2026-08-23.md ("))
        XCTAssertTrue(output.contains("model=qwen"))
        XCTAssertTrue(output.contains("day=2026-08-23"))
    }

    func testDeletingLastMeetingReopensOwnedYesterdayDigestButPreservesManualEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try finishedMeeting()
        let day = meeting.startedAt
        let now = try date("2026-08-24T08:00:00Z")
        let journal = root.appendingPathComponent("journal/2026-08-23.md")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Meeting no longer exists".write(to: journal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: journal.path)
        let original = try FileDailyEvidenceSource(root: root, calendar: calendar)
            .snapshot(for: day, meetings: [meeting], includeScreenSummary: false)
            .digestEvidence(calendar: calendar)
        try DayDigestGenerationMetadataStore.record(
            quality: .complete, evidenceLatestAt: original.latestEvidenceAt,
            evidenceSignature: original.contentSignature, meetingEvidenceSignature: original.meetingSignature,
            for: journal, generatedAt: now.addingTimeInterval(-600))

        let regenerated = expectation(description: "Deleted evidence is removed from yesterday's digest")
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { now }),
            blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { [] },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { evidence, _, _ in
                XCTAssertTrue(evidence.isEmpty)
                regenerated.fulfill()
                return DayDigestGenerationResult(text: "Empty day", url: journal, quality: .complete)
            })
        XCTAssertTrue(lifecycle.snapshot(for: day).isStale)
        lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 18), canRun: { true }, onError: { XCTFail($0) })
        await fulfillment(of: [regenerated], timeout: 2)
        lifecycle.stopAutomaticGeneration()

        try DayDigestGenerationMetadataStore.record(
            quality: .fallback, evidenceLatestAt: original.latestEvidenceAt,
            evidenceSignature: original.contentSignature, meetingEvidenceSignature: original.meetingSignature,
            for: journal, generatedAt: now.addingTimeInterval(-600))
        let modifiedAt = try XCTUnwrap(DayDigestGenerationMetadataStore.load(for: journal)?.journalModifiedAt)
        try "My handwritten journal".write(to: journal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: journal.path)
        let shouldNotGenerate = expectation(description: "Manual edits are preserved")
        shouldNotGenerate.isInverted = true
        let protected = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { now }),
            blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { [] },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { _, _, _ in
                shouldNotGenerate.fulfill()
                return DayDigestGenerationResult(text: "Unexpected", url: journal, quality: .complete)
            })
        protected.configureAutomaticGeneration(.init(enabled: true, hour: 18), canRun: { true }, onError: { XCTFail($0) })
        await fulfillment(of: [shouldNotGenerate], timeout: 0.15)
        protected.stopAutomaticGeneration()
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "My handwritten journal")
    }

    private func makeLifecycle(
        root: URL,
        meetings: @escaping () -> [Meeting] = { [] },
        latestActivityEvidenceAt: @escaping (Date) -> Date?
    ) -> DayDigestLifecycle {
        DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: meetings,
            latestActivityEvidenceAt: latestActivityEvidenceAt,
            settings: AppSettings.init,
            generator: { evidence, _, _ in
                DayDigestGenerationResult(
                    text: "",
                    url: root.appendingPathComponent(
                        "journal/\(DreamDay.key(for: evidence.day)).md"),
                    quality: .complete)
            })
    }

    private func finishedMeeting() throws -> Meeting {
        Meeting(
            id: UUID(),
            title: "Architecture",
            appName: "Meet",
            startedAt: try date("2026-08-23T09:00:00Z"),
            endedAt: try date("2026-08-23T09:30:00Z"),
            relativePath: "meetings/architecture")
    }
}
