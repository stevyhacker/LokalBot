import XCTest
@testable import LokalBot

@MainActor
final class DailyEvidenceIntegrationTests: XCTestCase {
    func testInterruptedJournalOwnershipWriteRecoversGeneratedClassification() throws {
        let root = try temporaryRoot()
        let day = Date()
        let snapshot = try FileDailyEvidenceSource(root: root).snapshot(for: day)
        let journal = root.appendingPathComponent(
            "journal/\(DreamDay.key(for: day)).md")
        let metadataURL = DayDigestGenerationMetadataStore.metadataURL(
            for: journal)
        try FileManager.default.createDirectory(
            at: metadataURL,
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try DayDigestJournalWriter.write(
            "Generated journal",
            to: journal,
            replacing: .init(digest: nil),
            evidence: snapshot.digestEvidence(),
            quality: .complete))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DayDigestJournalWriter.transactionURL(for: journal).path))

        let provisional = try XCTUnwrap(
            DayDigestGenerationMetadataStore.load(for: journal))
        XCTAssertTrue(DayDigestGenerationMetadataStore.journalMatches(
            provisional,
            at: journal))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DayDigestJournalWriter.transactionURL(for: journal).path),
            "the transaction must remain until ownership is durable")

        try FileManager.default.removeItem(at: metadataURL)
        let recovered = try XCTUnwrap(
            DayDigestGenerationMetadataStore.load(for: journal))
        XCTAssertTrue(DayDigestGenerationMetadataStore.journalMatches(
            recovered,
            at: journal))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DayDigestJournalWriter.transactionURL(for: journal).path))
    }

    func testInterruptedJournalOwnershipDoesNotClaimLaterUserEdit() throws {
        let root = try temporaryRoot()
        let day = Date()
        let snapshot = try FileDailyEvidenceSource(root: root).snapshot(for: day)
        let journal = root.appendingPathComponent(
            "journal/\(DreamDay.key(for: day)).md")
        let metadataURL = DayDigestGenerationMetadataStore.metadataURL(
            for: journal)
        try FileManager.default.createDirectory(
            at: metadataURL,
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try DayDigestJournalWriter.write(
            "Generated journal",
            to: journal,
            replacing: .init(digest: nil),
            evidence: snapshot.digestEvidence(),
            quality: .complete))
        try "My notes after recovery".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.removeItem(at: metadataURL)

        XCTAssertNil(DayDigestGenerationMetadataStore.load(for: journal))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DayDigestJournalWriter.transactionURL(for: journal).path))
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { [] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { _, _, _, _ in throw IntegrationError.unavailable })
        try lifecycle.retractGeneratedJournals(for: [day])
        XCTAssertEqual(
            try String(contentsOf: journal, encoding: .utf8),
            "My notes after recovery")
    }

    func testOnlyDeletingSourcesWithdrawsTheDayDigest() throws {
        let root = try temporaryRoot()
        let previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
        }
        let app = AppState()
        let day = Date()
        let journal = app.dayDigest.journalURL(for: day)
        try DayDigestJournalWriter.write(
            "Generated digest",
            to: journal,
            replacing: .init(digest: nil),
            evidence: FileDailyEvidenceSource(root: root).snapshot(for: day).digestEvidence(),
            quality: .complete)
        let meeting = Meeting(
            id: UUID(),
            title: "Standup",
            appName: "Meet",
            startedAt: day,
            endedAt: day.addingTimeInterval(60),
            relativePath: "meetings/standup")

        app.meetingArtifactsWillChange(meeting)
        try app.withPrimaryEvidenceChange(on: [day], .revision) {}
        try app.withScheduledRetention(on: [day]) {}

        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "Generated digest",
                       "reprocessing, corrections, and expiry must not delete the digest")
        XCTAssertNotNil(DayDigestGenerationMetadataStore.load(for: journal))

        try app.withPrimaryEvidenceChange(on: [day], .removal) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path),
                       "deleting the sources still withdraws their generated digest")
    }

    func testCompletingActionItemPreservesYesterdayDreamReportAndPastDayDigest() throws {
        let root = try temporaryRoot()
        let previousRoot = ProcessInfo.processInfo.environment["LOKALBOT_STORAGE_ROOT"]
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
        defer {
            if let previousRoot { setenv("LOKALBOT_STORAGE_ROOT", previousRoot, 1) } else { unsetenv("LOKALBOT_STORAGE_ROOT") }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let meetingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let meetingStart = meetingDay.addingTimeInterval(10 * 3_600)
        try MeetingFixture.write([.init(title: "Funding sync", startedAt: meetingStart)], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        let meeting = try XCTUnwrap(meetings.first)
        let action = MeetingOutcomes.ActionItem(text: "Order the Mac Mini", owner: "Me")
        let folder = meeting.folderURL(in: storage)
        try MeetingOutcomes(actionItems: [action]).write(to: folder)
        for name in ["summary.md", MeetingOutcomes.fileName] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: meetingStart.addingTimeInterval(1_800)],
                    ofItemAtPath: url.path)
            }
        }

        let app = AppState()
        app.outcomeIndex.refresh(meetings: meetings)
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            calendar: calendar,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { meetings },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { _, _, _, _ in throw IntegrationError.unavailable })
        let snapshot = try FileDailyEvidenceSource(root: root, calendar: calendar)
            .snapshot(for: meetingDay, meetings: meetings, includeScreenSummary: false)
        let journal = lifecycle.journalURL(for: meetingDay)
        try DayDigestJournalWriter.write(
            "Finalized meeting-day digest",
            to: journal,
            replacing: .init(digest: nil),
            evidence: snapshot.digestEvidence(calendar: calendar),
            quality: .complete)
        let finalizedAt = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: meetingDay))
            .addingTimeInterval(3_600)
        try FileManager.default.setAttributes([.modificationDate: finalizedAt], ofItemAtPath: journal.path)

        let revision = try app.dreamStore.evidenceRevision()
        let meetingDayKey = DreamDay.key(for: meetingDay, calendar: calendar)
        for offset in -7 ... -1 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            let key = DreamDay.key(for: day, calendar: calendar)
            let provenance = DreamEvidenceProvenance(
                sources: [
                    DreamEvidenceSource(kind: .meeting, id: meeting.id.uuidString, dayKey: meetingDayKey),
                    DreamEvidenceSource(kind: .screenDay, id: key, dayKey: key),
                    DreamEvidenceSource(kind: .digest, id: key, dayKey: key),
                ],
                revision: revision)
            try app.dreamStore.save(DreamReport(
                day: key,
                generatedAt: day.addingTimeInterval(86_400),
                engineName: "Test",
                evidenceProvenance: provenance,
                narrative: "Review for \(key)"))
        }
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let yesterdayKey = DreamDay.key(for: yesterday, calendar: calendar)
        app.latestDreamReport = app.dreamStore.latestReport()
        XCTAssertEqual(app.latestDreamReport?.day, yesterdayKey)

        let thread = try XCTUnwrap(app.outcomeIndex.openUserActionThreads.first)
        XCTAssertTrue(app.outcomeIndex.setStatus(.done, thread: thread))
        XCTAssertEqual(app.outcomeIndex.projection(for: meeting.id)?.actionReferences.first?.status, .done)

        XCTAssertNotNil(app.dreamStore.report(forDayKey: yesterdayKey),
                        "Checking off an action item must not delete Yesterday's Dream report")
        XCTAssertEqual(
            TodayDreamSelection.report(
                referenceDate: today,
                latest: app.latestDreamReport,
                store: app.dreamStore,
                calendar: calendar)?.day,
            yesterdayKey,
            "Yesterday's brief must stay visible on Today")
        XCTAssertNil(
            DreamScheduler.oldestMissingTarget(
                firstEligibleDayKey: meetingDayKey,
                through: yesterday,
                hasReport: { app.dreamStore.hasReport(forDayKey: $0) },
                calendar: calendar),
            "Checking off an action item must not queue prior days for overnight review")

        let digestAfter = lifecycle.snapshot(for: meetingDay)
        XCTAssertTrue(digestAfter.evidenceMatches,
                      "Checking off an action item must not invalidate the meeting day's digest signature")
        XCTAssertFalse(digestAfter.isStale,
                       "Checking off an action item must not mark the meeting day's digest stale")
    }

    func testCorrectionRefreshesExportAgainAfterDigestPersistence() async throws {
        let root = try temporaryRoot()
        let current = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: current)
        try MeetingFixture.write([.init(title: "Launch planning", startedAt: day)], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        let meeting = try XCTUnwrap(meetings.first)
        let action = MeetingOutcomes.ActionItem(text: "Send the revised launch proposal", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let initial = try source.snapshot(for: day)
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
        try DayDigestJournalWriter.write("Original digest", to: journal,
                                        replacing: .init(digest: nil), evidence: initial.digestEvidence(), quality: .complete)

        let exports = DailyMemoryExportScheduler(calendar: calendar, now: { current })
        defer { exports.stop() }
        let destination = root.appendingPathComponent("exports")
        let output = destination.appendingPathComponent("\(DreamDay.key(for: day, calendar: calendar)).md")
        exports.configure(.init(enabled: true, hour: 0, destinationID: destination.path)) { date, pass in
            let service = DailyMemoryExportService(source: FileDailyMemoryExportSource(root: root), calendar: calendar)
            _ = try service.export(day: date, configuration: .init(destinationDirectory: destination, format: .markdown),
                                   pass: pass)
        } onError: { XCTFail($0) }
        await waitForText("Original digest", at: output)

        let generationStarted = expectation(description: "Replacement digest captured corrected evidence")
        let allowGeneration = EvidenceGenerationGate()
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { current }),
            blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { meetings },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _, validateEvidence, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                generationStarted.fulfill()
                await allowGeneration.wait()
                let text = snapshot.meetings.flatMap(\.actionReferences).map(\.text).joined(separator: "\n")
                try validateEvidence()
                try DayDigestJournalWriter.write(text, to: journal, replacing: revision,
                                                evidence: snapshot.digestEvidence(), quality: .complete)
                return .init(text: text, url: journal, quality: .complete)
            }, onGenerated: { exports.reconsider(day: $0) })
        defer { lifecycle.stopAutomaticGeneration() }
        lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 0), canRun: { true }, onError: { XCTFail($0) })
        let index = OutcomeIndex(storage: storage, onEvidenceChanged: { changed in
            let days = changed.map(\.startedAt)
            lifecycle.reconsiderEvidence(for: days)
            exports.reconsider(days: days)
        })
        index.refresh(meetings: meetings)
        XCTAssertTrue(index.correctAction(actionID: action.id, meetingID: meeting.id,
                                          text: "Send the signed final proposal", owner: nil, due: nil))
        await fulfillment(of: [generationStarted], timeout: 3)
        await waitForText("The day's digest is out of date", at: output)
        await allowGeneration.release()
        await waitForText("Send the signed final proposal", at: output)
        XCTAssertTrue(DayDigestGenerationMetadataStore.isCurrent(
            for: journal, evidenceSignature: try source.snapshot(for: day).digestEvidence().contentSignature))
    }

    func testJournalEditDuringGenerationPreservesUserBytesAndMetadata() async throws {
        let root = try temporaryRoot()
        let day = Date()
        let snapshot = try FileDailyEvidenceSource(root: root).snapshot(for: day)
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day)).md")
        try DayDigestJournalWriter.write("Generated journal", to: journal, replacing: .init(digest: nil),
                                        evidence: snapshot.digestEvidence(), quality: .complete)
        let metadataURL = DayDigestGenerationMetadataStore.metadataURL(for: journal)
        let metadata = try Data(contentsOf: metadataURL)
        let started = expectation(description: "Generation started")
        let gate = EvidenceGenerationGate()
        var didNotify = false
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { [] },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _, validateEvidence, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                started.fulfill()
                await gate.wait()
                try validateEvidence()
                try DayDigestJournalWriter.write("New generated journal", to: journal, replacing: revision,
                                                evidence: snapshot.digestEvidence(), quality: .complete)
                return .init(text: "New generated journal", url: journal, quality: .complete)
            }, onGenerated: { _ in didNotify = true })
        let generation = Task { try await lifecycle.generate(for: day) }
        await fulfillment(of: [started], timeout: 3)
        try "My handwritten changes".write(to: journal, atomically: true, encoding: .utf8)
        await gate.release()
        do {
            _ = try await generation.value
            XCTFail("A changed journal must not be replaced")
        } catch DayDigestJournalWriter.WriteError.changedDuringGeneration {
        }
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "My handwritten changes")
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertFalse(didNotify)
    }

    func testEvidenceMutationDuringGenerationCannotCommitStaleDigest() async throws {
        let root = try temporaryRoot()
        let day = Date()
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day)).md")
        let generationStarted = expectation(description: "Generation captured its evidence")
        let gate = EvidenceGenerationGate()
        var blocks = [ActivityBlock(
            id: 1,
            app: "Xcode",
            title: "Before correction",
            start: day.addingTimeInterval(-60),
            end: day)]
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            blocks: { _ in blocks },
            screenContexts: { _ in [] },
            meetings: { [] },
            latestActivityEvidenceAt: { _ in nil },
            settings: AppSettings.init,
            generator: { snapshot, _, validateEvidence, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                generationStarted.fulfill()
                await gate.wait()
                let evidence = snapshot.digestEvidence()
                try validateEvidence()
                try DayDigestJournalWriter.write(
                    evidence.renderDocument(summary: "Stale overview"),
                    to: journal,
                    replacing: revision,
                    evidence: evidence,
                    quality: .complete)
                return .init(text: "Stale overview", url: journal, quality: .complete)
            })

        let generation = Task { try await lifecycle.generate(for: day) }
        await fulfillment(of: [generationStarted], timeout: 3)
        blocks[0].title = "Corrected evidence"
        await gate.release()

        do {
            _ = try await generation.value
            XCTFail("Changed primary evidence must revoke the pending digest")
        } catch DayDigestLifecycle.GenerationError.evidenceChangedDuringGeneration {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testNewEvidenceDuringManualGenerationSavesOriginalSnapshotAsStale() async throws {
        try await assertNewEvidenceDuringGeneration(scheduled: false)
    }

    func testNewEvidenceDuringScheduledGenerationSavesOriginalSnapshotAsStale() async throws {
        try await assertNewEvidenceDuringGeneration(scheduled: true)
    }

    private func assertNewEvidenceDuringGeneration(scheduled: Bool) async throws {
        let root = try temporaryRoot()
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day)).md")
        let started = expectation(description: "Generation captured its evidence")
        let finished = expectation(description: "Original snapshot was saved")
        let gate = EvidenceGenerationGate()
        var blocks = [ActivityBlock(id: 1, app: "Xcode", title: "Original work",
                                    start: day.addingTimeInterval(-120), end: day.addingTimeInterval(-60))]
        var contexts = [DayScreenContext(snapshotID: 1, capturedAt: day.addingTimeInterval(-30),
                                        app: "Notes", windowTitle: "Original context", text: "Original screen evidence")]
        var meetings: [Meeting] = []
        var originalSignature: String?
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            scheduler: DayDigestScheduler(now: { day }),
            blocks: { _ in blocks }, screenContexts: { _ in contexts }, meetings: { meetings },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _, validateEvidence, _ in
                let revision = try DayDigestJournalWriter.revision(at: journal)
                let evidence = snapshot.digestEvidence()
                originalSignature = evidence.contentSignature
                started.fulfill()
                await gate.wait()
                let text = evidence.renderDocument(summary: "Original overview")
                try validateEvidence()
                try DayDigestJournalWriter.write(text, to: journal, replacing: revision,
                                                evidence: evidence, quality: .complete)
                return .init(text: text, url: journal, quality: .complete)
            }, onGenerated: { _ in finished.fulfill() })
        defer { lifecycle.stopAutomaticGeneration() }
        var generation: Task<DayDigestGenerationResult, Error>?
        if scheduled {
            lifecycle.configureAutomaticGeneration(.init(enabled: true, hour: 0),
                                                   canRun: { true }, onError: { XCTFail($0) })
        } else {
            generation = Task { try await lifecycle.generate(for: day) }
        }
        await fulfillment(of: [started], timeout: 3)

        blocks.append(ActivityBlock(id: 2, app: "Notes", title: "Later activity",
                                    start: day.addingTimeInterval(-60), end: day.addingTimeInterval(30)))
        contexts.append(DayScreenContext(snapshotID: 2, capturedAt: day.addingTimeInterval(-90),
                                         app: "Xcode", windowTitle: "Later capture", text: "Later screen evidence"))
        meetings.append(Meeting(id: UUID(), title: "Newly finished meeting", appName: "Meet",
                                startedAt: day.addingTimeInterval(-60), endedAt: day,
                                relativePath: "meetings/new"))
        await gate.release()
        if let generation { _ = try await generation.value }
        await fulfillment(of: [finished], timeout: 3)

        let text = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertTrue(text.contains("Original overview"))
        XCTAssertTrue(text.contains("Original work"))
        XCTAssertFalse(text.contains("Later activity"))
        XCTAssertFalse(text.contains("Later screen evidence"))
        XCTAssertFalse(text.contains("Newly finished meeting"))
        let metadata = try XCTUnwrap(DayDigestGenerationMetadataStore.load(for: journal))
        XCTAssertEqual(metadata.evidenceSignature, try XCTUnwrap(originalSignature))
        let saved = lifecycle.snapshot(for: day)
        XCTAssertEqual(saved.text, text)
        XCTAssertFalse(saved.evidenceMatches)
        XCTAssertTrue(saved.isStale, "New evidence should mark the saved snapshot stale, not discard it")
    }

    func testOriginalEvidenceDeletionAndCorrectionStillRejectGenerationWithNewActivity() async throws {
        for change in ["delete block", "correct block", "delete context", "correct context",
                       "delete meeting", "correct meeting", "correct summary", "correct outcomes"] {
            let root = try temporaryRoot()
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
            let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: day)).md")
            var blocks = [ActivityBlock(id: 1, app: "Xcode", title: "Original work",
                                        start: day.addingTimeInterval(-60), end: day)]
            var contexts = [DayScreenContext(snapshotID: 1, capturedAt: day.addingTimeInterval(-30),
                                            app: "Xcode", windowTitle: "Work", text: "Original evidence")]
            var meetings = [Meeting(id: UUID(), title: "Original meeting", appName: "Meet",
                                    startedAt: day.addingTimeInterval(-120), endedAt: day,
                                    relativePath: "meetings/original")]
            let folder = root.appendingPathComponent(meetings[0].relativePath)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let summaryURL = folder.appendingPathComponent("summary.md")
            try "Original summary".write(to: summaryURL, atomically: true, encoding: .utf8)
            try MeetingOutcomes(decisions: ["Original decision"]).write(to: folder)
            var didNotify = false
            let lifecycle = DayDigestLifecycle(
                storageRoot: root, blocks: { _ in blocks }, screenContexts: { _ in contexts },
                meetings: { meetings }, latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
                generator: { snapshot, _, validateEvidence, _ in
                    let revision = try DayDigestJournalWriter.revision(at: journal)
                    blocks.append(ActivityBlock(id: 2, app: "Notes", title: "New work",
                                                start: day, end: day.addingTimeInterval(60)))
                    switch change {
                    case "delete block": blocks.removeFirst()
                    case "correct block": blocks[0].title = "Corrected work"
                    case "delete context": contexts.removeAll()
                    case "correct context": contexts[0].text = "Corrected evidence"
                    case "delete meeting": meetings.removeAll()
                    case "correct meeting": meetings[0].title = "Corrected meeting"
                    case "correct summary":
                        try "Corrected summary".write(to: summaryURL, atomically: true, encoding: .utf8)
                    case "correct outcomes":
                        try MeetingOutcomes(decisions: ["Corrected decision"]).write(to: folder)
                    default: XCTFail("Unhandled evidence change: \(change)")
                    }
                    try validateEvidence()
                    try DayDigestJournalWriter.write("Stale overview", to: journal, replacing: revision,
                                                    evidence: snapshot.digestEvidence(), quality: .complete)
                    return .init(text: "Stale overview", url: journal, quality: .complete)
                }, onGenerated: { _ in didNotify = true })
            do {
                _ = try await lifecycle.generate(for: day)
                XCTFail("Original evidence must still be validated: \(change)")
            } catch DayDigestLifecycle.GenerationError.evidenceChangedDuringGeneration {
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), change)
            XCTAssertNil(DayDigestGenerationMetadataStore.load(for: journal), change)
            XCTAssertFalse(didNotify, change)
        }
    }

    private func waitForText(_ text: String, at url: URL) async {
        for _ in 0..<150 {
            if (try? String(contentsOf: url, encoding: .utf8))?.contains(text) == true { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected \(text) in \(url.lastPathComponent)")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private enum IntegrationError: Error {
    case unavailable
}

private actor EvidenceGenerationGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
