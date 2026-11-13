import XCTest
@testable import LokalBot

@MainActor
final class MemoryRoutineRevisionTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_783_003_600)

    func testRoutineRefreshesAfterCorrectionsDeletionAndRelaunchAndPreservesUserEdits() async throws {
        let root = try temporaryRoot()
        let destination = root.appendingPathComponent("drafts")
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        _ = ActivityStore(databaseURL: databaseURL)
        try MeetingFixture.write([.init(title: "Planning", startedAt: fixedNow.addingTimeInterval(-600))], under: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let storage = StorageManager(rootURL: root)
        let action = MeetingOutcomes.ActionItem(text: "Send the revised proposal", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let configuration = MemoryRoutineScheduler.Configuration(
            enabled: true, destinationPath: destination.path, kinds: [.unfinishedActions], hour: 0, weekday: 6)
        let scheduler = MemoryRoutineScheduler(storageRoot: root, databaseURL: databaseURL, now: { self.fixedNow })
        scheduler.configure(configuration) { XCTFail($0) }
        await waitForIdle(scheduler)
        let url = try XCTUnwrap(scheduler.lastOutputURL)
        XCTAssertEqual(scheduler.recentRuns.count, 1)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Send the revised proposal"))

        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(textCorrection: "Email Acme the signed proposal", userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        scheduler.reconsiderEvidence()
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 2)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Email Acme the signed proposal"))
        let tokens = Set(scheduler.recentRuns.map(\.runToken))
        XCTAssertEqual(tokens.count, 2)
        scheduler.tick()
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 2)

        try storage.deleteMeeting(meeting)
        scheduler.reconsiderEvidence()
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 3)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("proposal"))
        scheduler.stop()

        let relaunched = MemoryRoutineScheduler(storageRoot: root, databaseURL: databaseURL, now: { self.fixedNow })
        defer { relaunched.stop() }
        var errors: [String] = []
        relaunched.configure(configuration) { errors.append($0) }
        await waitForIdle(relaunched)
        XCTAssertEqual(relaunched.recentRuns.count, 3)
        try "My edited task note".write(to: url, atomically: true, encoding: .utf8)
        try MeetingFixture.write([.init(title: "Later plan", startedAt: fixedNow.addingTimeInterval(-300))], under: root)
        let later = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        try MeetingOutcomes(actionItems: [.init(text: "Review the launch checklist", owner: "Me")])
            .write(to: later.folderURL(in: storage))
        relaunched.reconsiderEvidence()
        await waitForIdle(relaunched)
        XCTAssertEqual(relaunched.recentRuns.first?.status, "failed")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "My edited task note")
        relaunched.tick()
        await waitForIdle(relaunched)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(relaunched.recentRuns.count, 4)
        XCTAssertEqual(relaunched.pendingCount, 0)
    }

    func testFollowUpRevisionChangesWhenActionIsCompleted() async throws {
        let root = try temporaryRoot()
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        try MeetingFixture.write([
            .init(title: "Launch", startedAt: fixedNow.addingTimeInterval(-600), summary: "Launch summary")
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meeting = try XCTUnwrap(SessionLookup.loadAllMeetings(root: root).first)
        let action = MeetingOutcomes.ActionItem(text: "Publish the verified release", owner: "Me")
        try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        let scheduler = MemoryRoutineScheduler(storageRoot: root, databaseURL: databaseURL, now: { self.fixedNow })
        defer { scheduler.stop() }
        scheduler.configure(.init(enabled: true, destinationPath: root.appendingPathComponent("drafts").path,
                                  kinds: [.postMeetingFollowUp], hour: 0, weekday: 6)) { XCTFail($0) }
        await waitForIdle(scheduler)
        let output = try XCTUnwrap(scheduler.lastOutputURL)
        var state = MeetingOutcomeState()
        state.actions[action.id] = .init(status: .done, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        scheduler.reconsiderEvidence()
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 2)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("[x] Publish the verified release"))
        state.actions[action.id] = .init(status: .open, userEdited: true)
        try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        scheduler.reconsiderEvidence()
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 3, "Reverting to a prior revision must refresh the output")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("[ ] Publish the verified release"))
    }

    func testInvalidationCancelsPreparedSnapshotBeforeItCanWrite() async throws {
        let root = try temporaryRoot()
        let started = expectation(description: "First snapshot captured")
        let cancelled = expectation(description: "Stale snapshot cancelled")
        let calls = RoutinePreparationCalls()
        let scheduler = MemoryRoutineScheduler(
            storageRoot: root, databaseURL: root.appendingPathComponent("runs.sqlite"), now: { self.fixedNow },
            prepare: { _ in
                let count = await calls.next()
                if count == 1 {
                    started.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(20))
                    } catch {
                        cancelled.fulfill()
                        throw error
                    }
                }
                return MemoryRoutineRunner.Prepared(
                    folder: "Journal", file: "test.md",
                    body: MemoryRoutineRunner.generatedMarker + "\nFresh corrected evidence")
            })
        defer { scheduler.stop() }
        scheduler.configure(.init(enabled: true, destinationPath: root.appendingPathComponent("drafts").path,
                                  kinds: [.localJournal], hour: 0, weekday: 6)) { XCTFail($0) }
        await fulfillment(of: [started], timeout: 2)
        scheduler.reconsiderEvidence()
        await fulfillment(of: [cancelled], timeout: 2)
        await waitForIdle(scheduler)
        XCTAssertEqual(scheduler.recentRuns.count, 1)
        XCTAssertEqual(scheduler.recentRuns.first?.status, "succeeded")
        XCTAssertEqual(scheduler.pendingCount, 0)
        let output = try XCTUnwrap(scheduler.lastOutputURL)
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Fresh corrected evidence"))
    }

    func testLegacyRoutineNeedsIdenticalBytesBeforeOwnershipIsAdopted() throws {
        let root = try temporaryRoot()
        let prepared = MemoryRoutineRunner.Prepared(folder: "Journal", file: "test.md",
                                                    body: MemoryRoutineRunner.generatedMarker + "\nOriginal")
        let directory = root.appendingPathComponent("Journal")
        let url = directory.appendingPathComponent("test.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try prepared.body.write(to: url, atomically: true, encoding: .utf8)
        var updated = prepared
        updated.body += "\nCorrected"
        XCTAssertThrowsError(try MemoryRoutineRunner.write(updated, destinationRoot: root))
        _ = try MemoryRoutineRunner.write(prepared, destinationRoot: root)
        _ = try MemoryRoutineRunner.write(updated, destinationRoot: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), updated.body)
        let sidecar = GeneratedFileWriter.sidecarURL(for: url)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    private func waitForIdle(_ scheduler: MemoryRoutineScheduler) async {
        for _ in 0..<150 where scheduler.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(scheduler.isRunning, "Routine did not finish")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routine-revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private actor RoutinePreparationCalls {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
