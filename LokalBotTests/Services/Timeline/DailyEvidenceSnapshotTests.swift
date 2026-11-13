import XCTest
@testable import LokalBot

final class DailyEvidenceSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSnapshotAppliesOverlayAndRejectsStaleDigest() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(
                id: meetingID,
                title: "Release review",
                startedAt: try date("2026-07-18T09:00:00Z"),
                summary: "Reviewed the launch plan."),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let done = MeetingOutcomes.ActionItem(text: "Publish old draft", owner: "Me")
        let corrected = MeetingOutcomes.ActionItem(text: "Publish draft", owner: "Me")
        try MeetingOutcomes(
            actionItems: [done, corrected],
            decisions: ["Ship Tuesday"]).write(to: meeting.folderURL(in: storage))
        let artifactDate = try date("2026-07-18T17:00:00Z")
        for artifact in ["summary.md", MeetingOutcomes.fileName] {
            try FileManager.default.setAttributes(
                [.modificationDate: artifactDate],
                ofItemAtPath: meeting.folderURL(in: storage)
                    .appendingPathComponent(artifact).path)
        }

        let journal = root.appendingPathComponent("journal/2026-07-18.md")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "Stale digest says publish both drafts.".write(
            to: journal,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: try date("2026-07-18T18:00:00Z")],
            ofItemAtPath: journal.path)

        var state = MeetingOutcomeState()
        state.actions[done.id] = .init(
            status: .done,
            updatedAt: try date("2026-07-18T18:05:00Z"),
            userEdited: true)
        state.actions[corrected.id] = .init(
            dueOverride: "Tuesday",
            textCorrection: "Publish the verified draft",
            updatedAt: try date("2026-07-18T18:05:00Z"),
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        let stateURL = meeting.folderURL(in: storage)
            .appendingPathComponent(MeetingOutcomeState.fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: try date("2026-07-18T18:05:00Z")],
            ofItemAtPath: stateURL.path)

        let snapshot = try FileDailyEvidenceSource(
            root: root,
            calendar: calendar).snapshot(
            for: day,
            meetings: [meeting],
            includeDetailedActivity: false)
        let evidence = try XCTUnwrap(snapshot.meetings.first)

        XCTAssertEqual(evidence.summary, "Reviewed the launch plan.")
        XCTAssertEqual(evidence.activeActionReferences.map(\.text), ["Publish the verified draft"])
        XCTAssertEqual(evidence.activeActionReferences.first?.due, "Tuesday")
        XCTAssertEqual(evidence.activeOutcomes.actionItems.map(\.text), ["Publish the verified draft"])
        XCTAssertEqual(snapshot.latestEvidenceAt, try date("2026-07-18T18:05:00Z"))
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(
            for: snapshot,
            root: root,
            calendar: calendar))
    }

    func testSignatureChangesWithUserCorrection() throws {
        let root = try temporaryRoot()
        let startedAt = try date("2026-07-18T09:00:00Z")
        try MeetingFixture.write([
            .init(title: "Planning", startedAt: startedAt),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let action = MeetingOutcomes.ActionItem(text: "Send the plan", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let before = try source.snapshot(
            for: startedAt,
            meetings: [meeting],
            includeDetailedActivity: false)

        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(
            dueOverride: "Friday",
            textCorrection: "Send the verified plan",
            updatedAt: startedAt.addingTimeInterval(600),
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        let after = try source.snapshot(
            for: startedAt,
            meetings: [meeting],
            includeDetailedActivity: false)

        XCTAssertNotEqual(before.signature, after.signature)
        XCTAssertEqual(after.meetings.first?.activeActionReferences.first?.text,
                       "Send the verified plan")
    }

    func testFullSnapshotToleratesDatabaseBeforeSchemaCreation() throws {
        let root = try temporaryRoot()
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("lokalbotv3.sqlite").path,
            contents: Data())

        let snapshot = try FileDailyEvidenceSource(
            root: root,
            calendar: calendar).snapshot(for: try date("2026-07-18T12:00:00Z"))

        XCTAssertEqual(snapshot.coverage, .all)
        XCTAssertTrue(snapshot.activityBlocks.isEmpty)
        XCTAssertTrue(snapshot.screenContexts.isEmpty)
        XCTAssertEqual(snapshot.stats.trackedSeconds, 0)
    }

    func testDreamUsesCorrectedActiveThreadsAndExcludesCompletedActions() throws {
        let root = try temporaryRoot()
        let firstID = UUID()
        let secondID = UUID()
        let firstDate = try date("2026-07-17T09:00:00Z")
        let secondDate = try date("2026-07-18T09:00:00Z")
        try MeetingFixture.write([
            .init(id: firstID, title: "Planning", startedAt: firstDate),
            .init(id: secondID, title: "Review", startedAt: secondDate),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        for meeting in meetings {
            let repeated = MeetingOutcomes.ActionItem(
                text: "Send the revised launch proposal",
                owner: "Me")
            let obsolete = MeetingOutcomes.ActionItem(
                text: "Publish obsolete checklist",
                owner: "Me")
            try MeetingOutcomes(actionItems: [repeated, obsolete])
                .write(to: meeting.folderURL(in: storage))
            var state = MeetingOutcomeState()
            state.actions[obsolete.id] = .init(status: .done, userEdited: true)
            if meeting.id == secondID {
                state.actions[repeated.id] = .init(
                    textCorrection: "Send Acme the revised launch proposal",
                    userEdited: true)
            }
            try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        }

        let evidence = try DreamCompiler.compile(
            day: secondDate,
            storageRoot: root,
            calendar: calendar)

        XCTAssertEqual(evidence.openActions.count, 1)
        XCTAssertTrue(evidence.openActions[0].contains("Send Acme the revised launch proposal"))
        XCTAssertTrue(evidence.openActions[0].contains("sources:"))
        XCTAssertFalse(evidence.openActions[0].contains("obsolete"))
        XCTAssertFalse(evidence.meetings.flatMap { $0.outcomes.actionItems }
            .contains(where: { $0.text.contains("obsolete") }))
    }

    func testDeletionInvalidatesDigestEvenWhenWatermarkDoesNotAdvance() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        try MeetingFixture.write([
            .init(title: "Older", startedAt: day.addingTimeInterval(-3_600)),
            .init(title: "Newer", startedAt: day),
        ], under: root)
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let before = try source.snapshot(for: day)
        let journal = try writeDigest("Includes both meetings", snapshot: before, root: root)
        XCTAssertEqual(DailyEvidenceArtifacts.currentDigest(for: before, root: root, calendar: calendar),
                       "Includes both meetings")
        let storage = StorageManager(rootURL: root)
        try storage.deleteMeeting(before.meetings[0].meeting)
        let after = try source.snapshot(for: day)
        XCTAssertLessThanOrEqual(after.latestEvidenceAt ?? .distantPast, before.latestEvidenceAt ?? .distantPast)
        XCTAssertNotEqual(after.digestEvidence(calendar: calendar).contentSignature,
                          before.digestEvidence(calendar: calendar).contentSignature)
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: after, root: root, calendar: calendar))
        XCTAssertNil(try DreamCompiler.compile(day: day, storageRoot: root, calendar: calendar).digest)
        let exported = try FileDailyMemoryExportSource(root: root, calendar: calendar)
            .snapshot(for: day, interval: after.interval)
        XCTAssertNil(exported.digest)
        XCTAssertTrue(exported.digestIsOutOfDate)
        try storage.deleteMeeting(after.meetings[0].meeting)
        let empty = try source.snapshot(for: day)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: empty, root: root, calendar: calendar))
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "Includes both meetings")
    }

    func testSignatureIncludesCorrectionsAndCompletionButNotArtifactMtime() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        try MeetingFixture.write([.init(title: "Plan", startedAt: day)], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let action = MeetingOutcomes.ActionItem(text: "Send the revised proposal", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let before = try source.snapshot(for: day)
        _ = try writeDigest("Proposal is open", snapshot: before, root: root)
        var touched = before
        touched.meetings[0].artifactModifiedAt = Date().addingTimeInterval(500)
        XCTAssertEqual(before.digestEvidence(calendar: calendar).contentSignature,
                       touched.digestEvidence(calendar: calendar).contentSignature)
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(status: .done, textCorrection: "Send Acme the proposal", userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        let after = try source.snapshot(for: day)
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: after, root: root, calendar: calendar))
    }

    func testDigestRejectsUnsignedAndManuallyEditedJournal() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        let snapshot = try FileDailyEvidenceSource(root: root, calendar: calendar).snapshot(for: day)
        let journal = root.appendingPathComponent("journal/2026-07-18.md")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Legacy journal".write(to: journal, atomically: true, encoding: .utf8)
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: snapshot, root: root, calendar: calendar))
        _ = try writeDigest("Generated", snapshot: snapshot, root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        try "My handwritten edits".write(to: journal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: journal.path)
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: snapshot, root: root, calendar: calendar))
        XCTAssertEqual(try String(contentsOf: journal, encoding: .utf8), "My handwritten edits")
    }

    func testSummaryOnlyReaderLoadsSameDetailedDigestEvidenceAndDetectsScreenDeletion() throws {
        let root = try temporaryRoot()
        let day = try date("2026-07-18T12:00:00Z")
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        try database.execute("""
            CREATE TABLE activity_blocks (id INTEGER PRIMARY KEY, app TEXT, title TEXT, start REAL, end REAL);
            CREATE VIRTUAL TABLE ocr_fts USING fts5(text, window_title, ts UNINDEXED, app UNINDEXED, snapshot_id UNINDEXED);
            """)
        try database.runChecked("INSERT INTO activity_blocks VALUES (1, 'Xcode', 'Source', ?1, ?2)",
                                bind: [day.timeIntervalSince1970, day.timeIntervalSince1970 + 600])
        try database.runChecked("INSERT INTO ocr_fts VALUES ('Retained source text', 'Source', ?1, 'Xcode', 1)",
                                bind: [day.timeIntervalSince1970 + 300])
        let source = FileDailyEvidenceSource(root: root, calendar: calendar)
        let full = try source.snapshot(for: day, meetings: [], includeScreenSummary: false)
        _ = try writeDigest("Screen-backed digest", snapshot: full, root: root)
        let partial = try source.snapshot(for: day, meetings: [], includeDetailedActivity: false, includeScreenSummary: false)
        XCTAssertEqual(DailyEvidenceArtifacts.currentDigest(for: partial, root: root, calendar: calendar),
                       "Screen-backed digest")
        try database.execute("DELETE FROM ocr_fts")
        XCTAssertNil(DailyEvidenceArtifacts.currentDigest(for: partial, root: root, calendar: calendar))
    }

    private func writeDigest(_ text: String, snapshot: DailyEvidenceSnapshot, root: URL) throws -> URL {
        let journal = root.appendingPathComponent("journal/\(DreamDay.key(for: snapshot.day, calendar: calendar)).md")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: journal, atomically: true, encoding: .utf8)
        let evidence = snapshot.digestEvidence(calendar: calendar)
        try DayDigestGenerationMetadataStore.record(
            quality: .complete, evidenceLatestAt: snapshot.latestEvidenceAt,
            evidenceSignature: evidence.contentSignature, meetingEvidenceSignature: evidence.meetingSignature,
            for: journal)
        return journal
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
