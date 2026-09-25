import XCTest
@testable import LokalBot

final class MeetingMergeServiceTests: XCTestCase {
    private func mergeFixture() async throws -> (StorageManager, MeetingMergeService.Result) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeRecovery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try MeetingFixture.write([
            .init(title: "First canary", startedAt: Date(timeIntervalSince1970: 1_752_000_000),
                  transcriptLines: ["Recovery canary evidence"]),
            .init(title: "Second canary", startedAt: Date(timeIntervalSince1970: 1_752_003_600),
                  transcriptLines: ["Recovery canary evidence"])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let result = try await MeetingMergeService.merge(
            meetings: storage.loadMeetings(), title: "Combined", storage: storage)
        return (storage, result)
    }

    private func persistedMeeting(_ meeting: Meeting, storage: StorageManager) throws -> Meeting {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: Data(contentsOf:
            meeting.folderURL(in: storage).appendingPathComponent("meta.json")))
    }

    func testPermanentDeletionIncludesNestedSourcesButNotUnrelatedMeetings() async throws {
        let (storage, first) = try await mergeFixture()
        let start = Date(timeIntervalSince1970: 1_752_010_000)
        try MeetingFixture.write([
            .init(title: "Third source", startedAt: start, transcriptLines: ["Third evidence"]),
            .init(title: "Unrelated", startedAt: start.addingTimeInterval(100))
        ], under: storage.rootURL)
        let third = try XCTUnwrap(storage.loadMeetings().first { $0.title == "Third source" })
        let unrelated = try XCTUnwrap(storage.loadMeetings().first { $0.title == "Unrelated" })
        let nested = try await MeetingMergeService.merge(
            meetings: [first.meeting, third], title: "Nested", storage: storage)
        let order = try storage.deletionOrder(for: nested.meeting)
        XCTAssertEqual(order.last?.id, nested.meeting.id)
        XCTAssertEqual(Set(order.map(\.id)), Set(first.sourceMeetings.map(\.id) +
            [first.meeting.id, third.id, nested.meeting.id]))
        for meeting in order {
            try storage.deleteMeeting(meeting)
            // Loading between every operation simulates a restart checkpoint.
            XCTAssertTrue(Set(storage.loadMeetings().map(\.id))
                .isSubset(of: [nested.meeting.id, unrelated.id]))
        }
        XCTAssertEqual(storage.loadMeetings().map(\.id), [unrelated.id])
        XCTAssertEqual(try SessionLookup.loadAllMeetings(root: storage.rootURL).map(\.id), [unrelated.id])
        XCTAssertTrue(order.allSatisfy { !FileManager.default.fileExists(atPath: $0.folderURL(in: storage).path) })
    }

    func testPermanentDeletionCanResumeAfterRemovingOnlyOneSource() async throws {
        let (storage, result) = try await mergeFixture()
        let initial = try storage.deletionOrder(for: result.meeting)
        XCTAssertEqual(initial.count, 3)
        try storage.deleteMeeting(initial[0])
        XCTAssertEqual(storage.loadMeetings().map(\.id), [result.meeting.id])
        let remaining = try storage.deletionOrder(for: result.meeting)
        XCTAssertEqual(remaining.map(\.id), initial.dropFirst().map(\.id))
        for meeting in remaining { try storage.deleteMeeting(meeting) }
        XCTAssertTrue(storage.loadMeetings(includeMergedSources: true).isEmpty)
    }

    func testOrphanRecoveryRestoresSearchAndTombstonesRemovedParent() async throws {
        let (storage, result) = try await mergeFixture()
        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        for source in result.sourceMeetings { XCTAssertTrue(index.remove(source.id)) }
        index.reindex(result.meeting, storage: storage)
        XCTAssertFalse(index.search("canary").isEmpty)
        try storage.deleteMeeting(result.meeting)

        let recovered = storage.loadMeetings()
        let restarted = SearchIndex(databaseURL: databaseURL)
        restarted.reindexAll(recovered, storage: storage)
        XCTAssertEqual(Set(restarted.search("canary").map(\.meetingID)), Set(result.sourceMeetings.map(\.id)))
        let db = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(db.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                               bind: [result.meeting.id.uuidString]))
        for source in result.sourceMeetings {
            XCTAssertFalse(db.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                                    bind: [source.id.uuidString]))
            XCTAssertNil(try persistedMeeting(source, storage: storage).mergedIntoMeetingID)
        }
    }

    func testFailedRecoveryKeepsJournalAndRetriesAfterSQLiteFailure() async throws {
        let (storage, result) = try await mergeFixture()
        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        for source in result.sourceMeetings { XCTAssertTrue(index.remove(source.id)) }
        let db = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(db.exec("""
            CREATE TRIGGER fail_restore BEFORE DELETE ON deleted_meetings
            BEGIN SELECT RAISE(ABORT, 'injected restore failure'); END;
            """))
        try storage.deleteMeeting(result.meeting)
        XCTAssertTrue(storage.loadMeetings().isEmpty)
        for source in result.sourceMeetings {
            XCTAssertEqual(try persistedMeeting(source, storage: storage).mergedIntoMeetingID, result.meeting.id)
        }
        // No partial transaction may tombstone the parent while leaving the
        // failed source restore committed.
        XCTAssertFalse(db.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                                bind: [result.meeting.id.uuidString]))
        XCTAssertTrue(db.exec("DROP TRIGGER fail_restore"))
        let recovered = storage.loadMeetings()
        XCTAssertEqual(recovered.count, 2)
        let restarted = SearchIndex(databaseURL: databaseURL)
        restarted.reindexAll(recovered, storage: storage)
        XCTAssertEqual(Set(restarted.search("canary").map(\.meetingID)), Set(recovered.map(\.id)))
    }

    func testRecoveryCanRepeatAfterIndexCommitBeforeMetadataSave() async throws {
        let (storage, result) = try await mergeFixture()
        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        for source in result.sourceMeetings { XCTAssertTrue(index.remove(source.id)) }
        try storage.deleteMeeting(result.meeting)
        let source = result.sourceMeetings[0]
        try SearchIndex.restoreMergedSource(source.id, from: result.meeting.id, databaseURL: databaseURL)
        XCTAssertNotNil(try persistedMeeting(source, storage: storage).mergedIntoMeetingID)
        let recovered = storage.loadMeetings()
        XCTAssertEqual(recovered.count, 2)
        let restarted = SearchIndex(databaseURL: databaseURL)
        restarted.reindexAll(recovered, storage: storage)
        XCTAssertEqual(Set(restarted.search("canary").map(\.meetingID)), Set(recovered.map(\.id)))
    }

    func testCLIProjectionHandlesFoldedLegacyAndOrphanSourcesWithoutWriting() async throws {
        let (storage, result) = try await mergeFixture()
        XCTAssertEqual(try SessionLookup.loadAllMeetings(root: storage.rootURL).map(\.id), [result.meeting.id])
        // Older merge records can have the manifest without a source marker.
        var legacy = result.sourceMeetings[0]
        legacy.mergedIntoMeetingID = nil
        try storage.saveMeta(legacy)
        XCTAssertEqual(try SessionLookup.loadAllMeetings(root: storage.rootURL).map(\.id), [result.meeting.id])
        XCTAssertNil(try persistedMeeting(legacy, storage: storage).mergedIntoMeetingID)
        try storage.deleteMeeting(result.meeting)
        let visible = try SessionLookup.loadAllMeetings(root: storage.rootURL)
        XCTAssertEqual(Set(visible.map(\.id)), Set(result.sourceMeetings.map(\.id)))
        XCTAssertTrue(visible.allSatisfy { !$0.isMergedSource })
        // CLI must not persist repairs or mutate search state.
        XCTAssertNotNil(try persistedMeeting(result.sourceMeetings[1], storage: storage).mergedIntoMeetingID)
    }

    func testWorkerUndoRestoresIndexesBeforeClearingSourceMarker() async throws {
        let (storage, result) = try await mergeFixture()
        let databaseURL = storage.rootURL.appendingPathComponent("lokalbotv3.sqlite")
        let worker = SearchIndexWorkQueue(databaseURL: databaseURL, rootURL: storage.rootURL)
        for source in result.sourceMeetings { _ = await worker.remove(source.id) }
        try storage.deleteMeeting(result.meeting)
        let db = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(db.exec("""
            CREATE TRIGGER fail_worker_restore BEFORE DELETE ON deleted_meetings
            BEGIN SELECT RAISE(ABORT, 'injected worker failure'); END;
            """))
        do {
            _ = try await worker.restore(result.sourceMeetings[0])
            XCTFail("Undo must report a durable restore failure")
        } catch {
            XCTAssertNotNil(try persistedMeeting(result.sourceMeetings[0], storage: storage).mergedIntoMeetingID)
        }
        XCTAssertTrue(db.exec("DROP TRIGGER fail_worker_restore"))
        for source in result.sourceMeetings {
            let restored = try await worker.restore(source)
            XCTAssertNil(restored.mergedIntoMeetingID)
            XCTAssertNil(try persistedMeeting(source, storage: storage).mergedIntoMeetingID)
        }
        await worker.waitUntilIdle()
        let index = SearchIndex(databaseURL: databaseURL)
        XCTAssertEqual(Set(index.search("canary").map(\.meetingID)), Set(result.sourceMeetings.map(\.id)))
        await worker.stop()
    }

    func testMergeCreatesScopedTranscriptAndKeepsSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeService-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDate = Date(timeIntervalSince1970: 1_752_000_000)
        try MeetingFixture.write([
            .init(title: "Design review", startedAt: firstDate,
                  summary: "## Decisions\n\nKeep the new flow.",
                  transcriptLines: ["I will update the flow.", "The team agrees."]),
            .init(title: "Launch check", startedAt: firstDate.addingTimeInterval(3_600),
                  summary: "## Actions\n\nShip the checklist.",
                  transcriptLines: ["I will ship the checklist.", "Please review it."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }

        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Release working session",
            storage: storage)

        XCTAssertTrue(result.meeting.isMergedMeeting)
        XCTAssertEqual(result.meeting.mergedSourceMeetingIDs, sources.map(\.id))
        XCTAssertTrue(result.sourceMeetings.allSatisfy(\.isMergedSource))
        XCTAssertEqual(result.transcriptSegmentCount, 4)
        XCTAssertTrue(result.transcriptCoverageComplete)
        XCTAssertEqual(result.meeting.recordedDuration ?? 0, 3_600, accuracy: 0.01)

        let folder = result.meeting.folderURL(in: storage)
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertGreaterThanOrEqual(transcript.segments[2].start, 1_800)
        XCTAssertTrue(transcript.speakerAliases.keys.contains("source1:me"))
        XCTAssertTrue(transcript.speakerAliases.values.contains { $0.contains("source 2") })

        let summary = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertTrue(summary.contains("Design review"))
        XCTAssertTrue(summary.contains("Launch check"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("merge-manifest.json").path))

        let visibleMeetings = storage.loadMeetings()
        XCTAssertEqual(visibleMeetings.map(\.id), [result.meeting.id])
        let allMeetings = storage.loadMeetings(includeMergedSources: true)
        XCTAssertEqual(allMeetings.count, 3)
        for source in sources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.folderURL(in: storage).path))
            let persisted = try XCTUnwrap(allMeetings.first { $0.id == source.id })
            XCTAssertEqual(persisted.mergedIntoMeetingID, result.meeting.id)
            XCTAssertNil(persisted.mergedSourceMeetingIDs)
        }
    }

    func testMixedTranscriptAndAudioMergeRequiresRetranscriptionBeforeSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeMixed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_752_025_000)
        try MeetingFixture.write([
            .init(title: "Transcribed source", startedAt: start,
                  transcriptLines: ["This source already has text."]),
            .init(title: "Audio-only source", startedAt: start.addingTimeInterval(60)),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let audioFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LiveTranscript/continuous-speech.wav")
        var sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }
        for index in sources.indices {
            if index == 1 {
                let folder = sources[index].folderURL(in: storage)
                try FileManager.default.copyItem(
                    at: audioFixture,
                    to: MeetingAudioFiles.recoveryURL(for: .mic, in: folder))
            }
            sources[index].recordedDuration = 17.7
            sources[index].endedAt = sources[index].startedAt.addingTimeInterval(17.7)
            try storage.saveMeta(sources[index])
        }

        let result = try await MeetingMergeService.merge(
            meetings: sources, title: "Complete session", storage: storage)

        XCTAssertFalse(result.transcriptCoverageComplete)
        XCTAssertEqual(result.transcriptSegmentCount, 1)
        XCTAssertNotNil(MeetingAudioFiles.readableURL(
            for: .mic, in: result.meeting.folderURL(in: storage)))

        let folder = result.meeting.folderURL(in: storage)
        let previous = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        let regenerated = Transcript(
            segments: [.init(
                start: 18,
                end: 19,
                speaker: "them 1",
                text: "Fresh audio-only text.",
                confidence: 1,
                timingPrecision: .span)],
            engine: "fixture")
        let combined = try MeetingMergeService.preservingTranscriptOnlySources(
            from: previous,
            in: folder,
            regenerated: regenerated)
        XCTAssertEqual(
            combined.segments.map(\.displayText),
            ["This source already has text.", "Fresh audio-only text."])
    }

    func testLoadMeetingsRepairsOrphanedMergeSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeOrphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date(timeIntervalSince1970: 1_752_050_000)
        try MeetingFixture.write([
            .init(title: "First part", startedAt: start,
                  transcriptLines: ["First source."]),
            .init(title: "Second part", startedAt: start.addingTimeInterval(300),
                  transcriptLines: ["Second source."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }
        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Temporary merged meeting",
            storage: storage)

        try storage.deleteMeeting(result.meeting)

        let repaired = storage.loadMeetings()
        XCTAssertEqual(Set(repaired.map(\.id)), Set(sources.map(\.id)))
        XCTAssertTrue(repaired.allSatisfy { $0.mergedIntoMeetingID == nil })
    }

    func testMergeHonorsSourceContentRanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeRange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = UUID()
        let secondID = UUID()
        let start = Date(timeIntervalSince1970: 1_752_100_000)
        try MeetingFixture.write([
            .init(id: firstID, title: "Part one", startedAt: start,
                  transcriptLines: ["First opening.", "First close."]),
            .init(id: secondID, title: "Part two", startedAt: start.addingTimeInterval(100),
                  transcriptLines: ["Second opening.", "Second close."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        var sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }
        sources[0].contentRange = .init(start: 0, end: 20)
        try storage.saveMeta(sources[0])
        sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }

        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Bounded merge",
            storage: storage)
        XCTAssertEqual(result.meeting.recordedDuration ?? 0, 1_820, accuracy: 0.01)

        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: result.meeting.folderURL(in: storage)
                .appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertGreaterThanOrEqual(transcript.segments[2].start, 20)
    }

    func testMergeRequiresTwoCompletedMeetings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Only one", appName: "Tests")
        var finished = meeting
        finished.endedAt = finished.startedAt.addingTimeInterval(60)
        finished.recordedDuration = 60
        try storage.saveMeta(finished)

        do {
            _ = try await MeetingMergeService.merge(
                meetings: [finished], title: "Invalid", storage: storage)
            XCTFail("Expected a validation error")
        } catch let error as MeetingMergeService.MergeError {
            guard case .needsAtLeastTwo = error else {
                return XCTFail("Unexpected merge error: \(error)")
            }
        }
    }
}
