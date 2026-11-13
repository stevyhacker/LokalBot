import XCTest
@testable import LokalBot

@MainActor
final class MemoryRoutinesTests: XCTestCase {
    func testUnfinishedActionsUseOverlayCorrectionsAndExcludeDoneItems() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineOverlay-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = base.appendingPathComponent("library", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let meetingID = UUID()
        let date = Date()
        try MeetingFixture.write([
            .init(id: meetingID, title: "Overlay review", startedAt: date)
        ], under: storageRoot)
        let storage = StorageManager(rootURL: storageRoot)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: storageRoot).first)
        let done = MeetingOutcomes.ActionItem(text: "Already shipped", owner: "Me")
        let corrected = MeetingOutcomes.ActionItem(text: "Old wording", owner: "Them")
        try MeetingOutcomes(actionItems: [done, corrected])
            .write(to: meeting.folderURL(in: storage))
        var state = MeetingOutcomeState()
        state.actions[done.id] = .init(status: .done, userEdited: true)
        state.actions[corrected.id] = .init(
            ownerOverride: "Me",
            dueOverride: "Friday",
            textCorrection: "Publish the corrected plan",
            userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))

        let output = try MemoryRoutineRunner.run(
            kind: .unfinishedActions,
            referenceDate: date,
            storageRoot: storageRoot,
            destinationRoot: destination,
            meetingID: nil)
        let body = try String(contentsOf: output, encoding: .utf8)

        XCTAssertFalse(body.contains("Already shipped"))
        XCTAssertFalse(body.contains("Old wording"))
        XCTAssertTrue(body.contains("Publish the corrected plan"))
        XCTAssertTrue(body.contains("owner: Me"))
        XCTAssertTrue(body.contains("due: Friday"))
    }

    func testPostMeetingDraftIsPrivateRedactedIdempotentAndCollisionSafe() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineTests-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = base.appendingPathComponent("library", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let meetingID = UUID()
        let secret = "supersecretvalue123"
        try MeetingFixture.write([
            .init(
                id: meetingID,
                title: "Launch planning",
                startedAt: Date(timeIntervalSince1970: 1_783_000_000),
                summary: "We approved the launch. API key: \(secret)")
        ], under: storageRoot)
        let meeting = try XCTUnwrap(
            SessionLookup.loadAllMeetings(root: storageRoot).first)
        try MeetingOutcomes(
            actionItems: [.init(text: "Publish the release note", owner: "Sam", due: "Friday")],
            decisions: ["Ship the desktop build"],
            openQuestions: ["Which launch channel comes first?"])
            .write(to: meeting.folderURL(in: StorageManager(rootURL: storageRoot)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let output = try MemoryRoutineRunner.run(
            kind: .postMeetingFollowUp,
            referenceDate: meeting.startedAt,
            storageRoot: storageRoot,
            destinationRoot: destination,
            meetingID: meetingID,
            calendar: calendar)
        let body = try String(contentsOf: output, encoding: .utf8)

        XCTAssertTrue(body.contains(MemoryRoutineRunner.generatedMarker))
        XCTAssertTrue(body.contains("Launch planning"))
        XCTAssertTrue(body.contains("Publish the release note"))
        XCTAssertTrue(body.contains("[REDACTED]"))
        XCTAssertFalse(body.contains(secret))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: output.path)[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(mode, 0o600)

        XCTAssertEqual(try MemoryRoutineRunner.run(
            kind: .postMeetingFollowUp,
            referenceDate: meeting.startedAt,
            storageRoot: storageRoot,
            destinationRoot: destination,
            meetingID: meetingID,
            calendar: calendar), output)

        try "User-edited content".write(to: output, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MemoryRoutineRunner.run(
            kind: .postMeetingFollowUp,
            referenceDate: meeting.startedAt,
            storageRoot: storageRoot,
            destinationRoot: destination,
            meetingID: meetingID,
            calendar: calendar)) { error in
                guard case MemoryRoutineError.destinationCollision = error else {
                    return XCTFail("Expected a collision, got \(error)")
                }
            }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "User-edited content")
    }

    func testEveryScheduledLocalRendererProducesOwnedMarkdown() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineRenderers-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = base.appendingPathComponent("library", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let date = Date(timeIntervalSince1970: 1_783_000_000)

        for kind in AppSettings.MemoryRoutineKind.allCases where !kind.isEventDriven {
            let output = try MemoryRoutineRunner.run(
                kind: kind,
                referenceDate: date,
                storageRoot: storageRoot,
                destinationRoot: destination,
                meetingID: nil)
            XCTAssertEqual(output.pathExtension, "md", kind.rawValue)
            XCTAssertTrue(
                try String(contentsOf: output, encoding: .utf8)
                    .contains(MemoryRoutineRunner.generatedMarker),
                kind.rawValue)
        }
    }

    func testRoutineRefusesDirectorySymlinkOutsideChosenFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineSymlink-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = base.appendingPathComponent("library", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("Journal", isDirectory: true),
            withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertThrowsError(try MemoryRoutineRunner.run(
            kind: .localJournal,
            referenceDate: Date(timeIntervalSince1970: 1_783_000_000),
            storageRoot: storageRoot,
            destinationRoot: destination,
            meetingID: nil)) { error in
                guard case MemoryRoutineError.unsafeDestination = error else {
                    return XCTFail("Expected an unsafe destination, got \(error)")
                }
            }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testFailedScheduledTokenIsTerminalButInterruptedRunCanRecover() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = MemoryRoutineRunStore(databaseURL: base.appendingPathComponent("runs.sqlite"))
        let date = Date(timeIntervalSince1970: 1_783_000_000)

        let failedID = try store.begin(
            kind: .dailyStandup, runToken: "daily:2026-07-01", meetingID: nil, at: date)
        store.finish(
            id: failedID,
            outputURL: nil,
            error: MemoryRoutineError.destinationCollision(base),
            at: date.addingTimeInterval(1))
        XCTAssertTrue(store.hasFinished(runToken: "daily:2026-07-01"))
        XCTAssertFalse(store.hasSucceeded(runToken: "daily:2026-07-01"))

        _ = try store.begin(
            kind: .weeklyWorkLog, runToken: "weekly:2026-07-01", meetingID: nil, at: date)
        XCTAssertFalse(store.hasFinished(runToken: "weekly:2026-07-01"))
        XCTAssertEqual(store.runningCount(), 1)
    }

    func testSchedulerCatchesUpOnceAndDoesNotRepeatCompletedToken() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoutineScheduler-\(UUID().uuidString)", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let databaseURL = base.appendingPathComponent("lokalbotv3.sqlite")
        _ = ActivityStore(databaseURL: databaseURL)
        let fixedNow = Date(timeIntervalSince1970: 1_783_000_000)
        let scheduler = MemoryRoutineScheduler(
            storageRoot: base,
            databaseURL: databaseURL,
            now: { fixedNow })
        defer { scheduler.stop() }
        var errors: [String] = []

        scheduler.configure(.init(
            enabled: true,
            destinationPath: destination.path,
            kinds: [.localJournal],
            hour: 0,
            weekday: 6
        )) { errors.append($0) }

        for _ in 0..<100 where scheduler.recentRuns.isEmpty || scheduler.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(scheduler.recentRuns.first?.status, "succeeded")
        XCTAssertNotNil(scheduler.lastOutputURL)
        let completedCount = scheduler.recentRuns.count

        scheduler.tick()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(scheduler.recentRuns.count, completedCount)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testPostMeetingRoutineRunsOnlyAfterLocalSummaryExists() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostMeetingRoutineScheduler-\(UUID().uuidString)", isDirectory: true)
        let destination = base.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let databaseURL = base.appendingPathComponent("lokalbotv3.sqlite")
        _ = ActivityStore(databaseURL: databaseURL)
        let fixedNow = Date(timeIntervalSince1970: 1_783_003_600)
        let meetingID = UUID()
        try MeetingFixture.write([
            .init(
                id: meetingID,
                title: "Processed meeting",
                startedAt: fixedNow.addingTimeInterval(-3_600),
                summary: "## Summary\nThe local processing pipeline finished.")
        ], under: base)
        let scheduler = MemoryRoutineScheduler(
            storageRoot: base,
            databaseURL: databaseURL,
            now: { fixedNow })
        defer { scheduler.stop() }

        scheduler.configure(.init(
            enabled: true,
            destinationPath: destination.path,
            kinds: [.postMeetingFollowUp],
            hour: 8,
            weekday: 6
        )) { _ in }

        for _ in 0..<100 where scheduler.recentRuns.isEmpty || scheduler.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(scheduler.recentRuns.first?.kind, .postMeetingFollowUp)
        XCTAssertEqual(scheduler.recentRuns.first?.meetingID, meetingID)
        XCTAssertEqual(scheduler.recentRuns.first?.status, "succeeded")
    }
}
