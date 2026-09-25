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
            generator: { _, _, _ in throw IntegrationError.unavailable })
        try lifecycle.retractGeneratedJournals(for: [day])
        XCTAssertEqual(
            try String(contentsOf: journal, encoding: .utf8),
            "My notes after recovery")
    }

    func testSummaryReprocessingRetractsDigestWhenAutomaticRepairIsUnavailable() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(rootURL: root)
        let day = Date()
        let meeting = Meeting(
            id: UUID(),
            title: "Review",
            appName: "Meet",
            startedAt: day,
            endedAt: day.addingTimeInterval(60),
            relativePath: "meetings/review")
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.dayDigestAutoEnabled = false
        let pipeline = ProcessingPipeline(
            storage: storage,
            settings: { settings },
            builtInModelPreparer: { _, _ in
                throw IntegrationError.unavailable
            })
        try pipeline.saveTranscript(
            Transcript(
                segments: [.init(
                    start: 0,
                    end: 1,
                    speaker: "me",
                    text: "Review the generated digest lifecycle",
                    confidence: 1,
                    timingPrecision: .span)],
                engine: "test"),
            for: meeting)
        let source = FileDailyEvidenceSource(root: root)
        let snapshot = try source.snapshot(for: day, meetings: [meeting])
        let journal = root.appendingPathComponent(
            "journal/\(DreamDay.key(for: day)).md")
        try DayDigestJournalWriter.write(
            "Generated from the old transcript",
            to: journal,
            replacing: .init(digest: nil),
            evidence: snapshot.digestEvidence(),
            quality: .complete)
        let lifecycle = DayDigestLifecycle(
            storageRoot: root,
            blocks: { _ in [] },
            screenContexts: { _ in [] },
            meetings: { [meeting] },
            latestActivityEvidenceAt: { _ in nil },
            settings: { settings },
            generator: { _, _, _ in throw IntegrationError.unavailable })
        pipeline.onArtifactsWillChange = { changedMeeting in
            try lifecycle.retractGeneratedJournals(
                for: [changedMeeting.startedAt])
            lifecycle.reconsiderEvidence(for: changedMeeting.startedAt)
        }

        pipeline.enqueue(
            meeting,
            transcribe: false,
            summarize: true)
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }

        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path),
                       "model availability must not gate evidence retraction")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            DayDigestGenerationMetadataStore.metadataURL(for: journal).path))
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
        exports.configure(.init(enabled: true, hour: 0, destinationID: destination.path)) { date in
            let service = DailyMemoryExportService(source: FileDailyMemoryExportSource(root: root), calendar: calendar)
            _ = try service.export(day: date, configuration: .init(destinationDirectory: destination, format: .markdown))
        } onError: { XCTFail($0) }
        await waitForText("Original digest", at: output)

        let generationStarted = expectation(description: "Replacement digest captured corrected evidence")
        let allowGeneration = EvidenceGenerationGate()
        let lifecycle = DayDigestLifecycle(
            storageRoot: root, calendar: calendar,
            scheduler: DayDigestScheduler(calendar: calendar, now: { current }),
            blocks: { _ in [] }, screenContexts: { _ in [] }, meetings: { meetings },
            latestActivityEvidenceAt: { _ in nil }, settings: AppSettings.init,
            generator: { snapshot, _, validateEvidence in
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
        await waitForText("No day digest was generated", at: output)
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
            generator: { snapshot, _, validateEvidence in
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
            generator: { snapshot, _, validateEvidence in
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
            generator: { snapshot, _, validateEvidence in
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

        // A block that closes during generation can start before the request
        // and contain a context that was standalone in the original snapshot.
        blocks.append(ActivityBlock(id: 2, app: "Notes", title: "Later activity",
                                    start: day.addingTimeInterval(-60), end: day.addingTimeInterval(30)))
        // Late capture ingestion may also add context to an original block.
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
                generator: { snapshot, _, validateEvidence in
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

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
