import XCTest
@testable import LokalBot

@MainActor
final class ActionThreadRevisionTests: XCTestCase {
    func testRejectedEvidenceMutationLeavesCorrectionAndNarrativeIntact() throws {
        let (storage, meetings, action) = try fixture()
        let meeting = meetings[0]
        let folder = meeting.folderURL(in: storage)
        let summaryURL = folder.appendingPathComponent("summary.md")
        let stateURL = folder.appendingPathComponent(MeetingOutcomeState.fileName)
        try MeetingOutcomeStore.writeState(MeetingOutcomeState(), to: folder)
        try Data("Original narrative".utf8).write(to: summaryURL)
        let originalState = try Data(contentsOf: stateURL)
        var notifications = 0
        let index = OutcomeIndex(storage: storage, mutateEvidence: { affected, _ in
            XCTAssertEqual(affected.map(\.id), [meeting.id])
            throw CocoaError(.fileWriteNoPermission)
        }, onEvidenceChanged: { _ in notifications += 1 })
        index.refresh(meetings: meetings)

        XCTAssertFalse(index.correctAction(actionID: action.id, meetingID: meeting.id,
                                           text: "Changed action", owner: "Alice", due: nil))

        XCTAssertEqual(try Data(contentsOf: stateURL), originalState)
        XCTAssertEqual(try String(contentsOf: summaryURL, encoding: .utf8), "Original narrative")
        XCTAssertFalse(MeetingAttributionArtifacts.needsRefresh(in: folder))
        XCTAssertEqual(index.projection(for: meeting.id)?.actionReferences.first?.text, action.text)
        XCTAssertEqual(index.projection(for: meeting.id)?.actionReferences.first?.owner, "Me")
        XCTAssertEqual(notifications, 0)
        XCTAssertNotNil(index.lastError)
    }

    func testEvidenceMutationWrapperEnclosesWritesBeforePublishingOrNotification() throws {
        let (storage, meetings, action) = try fixture()
        let meeting = meetings[0]
        let folder = meeting.folderURL(in: storage)
        let summaryURL = folder.appendingPathComponent("summary.md")
        try Data("Original narrative".utf8).write(to: summaryURL)
        var events: [String] = []
        let index = OutcomeIndex(storage: storage, mutateEvidence: { affected, mutation in
            XCTAssertEqual(affected.map(\.id), [meeting.id])
            XCTAssertNil(MeetingOutcomeStore.loadState(from: folder).actions[action.id]?.textCorrection)
            XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
            events.append("locked")
            try mutation()
            XCTAssertEqual(MeetingOutcomeStore.loadState(from: folder).actions[action.id]?.textCorrection,
                           "Corrected action")
            XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path))
            events.append("durable")
        }, onEvidenceChanged: { affected in
            XCTAssertEqual(affected.map(\.id), [meeting.id])
            events.append("notified")
        })
        index.refresh(meetings: meetings)

        XCTAssertTrue(index.correctAction(actionID: action.id, meetingID: meeting.id,
                                          text: "Corrected action", owner: "Alice", due: nil))

        XCTAssertEqual(events, ["locked", "durable", "notified"])
        XCTAssertEqual(index.projection(for: meeting.id)?.actionReferences.first?.text, "Corrected action")
    }

    func testRejectedEvidenceMutationLeavesStatusAndFollowUpIntact() throws {
        let (storage, meetings, action) = try fixture()
        let meeting = meetings[0]
        let folder = meeting.folderURL(in: storage)
        var wrapperCalls = 0
        let index = OutcomeIndex(storage: storage, mutateEvidence: { affected, _ in
            XCTAssertEqual(affected.map(\.id), [meeting.id])
            wrapperCalls += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        index.refresh(meetings: meetings)
        let originalFollowUp = try XCTUnwrap(index.projection(for: meeting.id)?.followUp)

        XCTAssertFalse(index.setStatus(.done, actionID: action.id, meetingID: meeting.id))
        XCTAssertFalse(index.saveFollowUp(originalFollowUp, meetingID: meeting.id))

        XCTAssertEqual(wrapperCalls, 2)
        XCTAssertEqual(index.projection(for: meeting.id)?.actionReferences.first?.status, .open)
        XCTAssertTrue(index.statusUndo.isEmpty)
        XCTAssertNil(MeetingOutcomeStore.loadState(from: folder).actions[action.id])
        XCTAssertNil(MeetingOutcomeStore.loadFollowUp(from: folder))
        XCTAssertEqual(index.projection(for: meeting.id)?.followUp, originalFollowUp)
        XCTAssertNotNil(index.lastError)
    }

    func testOwnerCorrectionInvalidatesNarrativeAndSurvivesSummaryRepairProjection() throws {
        let (storage, meetings, action) = try fixture()
        let meeting = meetings[0]
        let folder = meeting.folderURL(in: storage)
        try Data("## TL;DR\nAn old attribution".utf8).write(to: folder.appendingPathComponent("summary.md"))
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        XCTAssertTrue(index.correctAction(actionID: action.id, meetingID: meeting.id,
            text: "Send the corrected report", owner: "Alice", due: nil))
        XCTAssertTrue(MeetingAttributionArtifacts.needsRefresh(in: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
        let projection = try XCTUnwrap(MeetingOutcomeProjection.load(for: meeting, storage: storage))
        XCTAssertEqual(projection.correctedOutcomes.actionItems.first?.owner, "Alice")
        XCTAssertFalse(try XCTUnwrap(projection.correctedOutcomes.actionItems.first).isForUser)
        let summary = MeetingSummaryOutcomeSynchronizer.synchronize("## TL;DR\nRefreshed",
            outcomes: projection.correctedOutcomes, template: .meeting)
        XCTAssertTrue(summary.contains("Alice: Send the corrected report"))
    }

    func testCompletionAndUnrelatedFieldEditsPreserveCorrectionPrecedence() throws {
        let (storage, meetings, action) = try fixture()
        let baseline = Date().addingTimeInterval(-3_600)
        for (offset, meeting) in meetings.enumerated() {
            var state = MeetingOutcomeState()
            state.actions[action.id] = .init(
                dueOverride: offset == 0 ? "Monday" : "Friday",
                textCorrection: offset == 0 ? "Send the first draft" : "Send the signed proposal",
                updatedAt: baseline.addingTimeInterval(Double(offset * 600)), userEdited: true)
            try MeetingOutcomeStore.writeState(state, to: meeting.folderURL(in: storage))
        }
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        let original = try XCTUnwrap(index.userActionThreads.first)
        XCTAssertTrue(index.setStatus(.done, actionID: action.id, meetingID: meetings[0].id))
        XCTAssertEqual(index.userActionThreads.first?.text, original.text)
        XCTAssertEqual(index.userActionThreads.first?.due, "Friday")
        XCTAssertEqual(index.userActionThreads.first?.dueSourceMeetingDate, meetings[1].startedAt)

        // Correct only the older source's deadline; keep its text correction.
        XCTAssertTrue(index.correctAction(actionID: action.id, meetingID: meetings[0].id,
                                          text: "Send the first draft", owner: nil, due: "Tuesday"))
        XCTAssertEqual(index.userActionThreads.first?.text, "Send the signed proposal")
        XCTAssertEqual(index.userActionThreads.first?.due, "Tuesday")
        XCTAssertEqual(index.userActionThreads.first?.dueSourceMeetingDate, meetings[0].startedAt)
        index.refresh(meetings: meetings)
        XCTAssertEqual(index.userActionThreads.first?.text, "Send the signed proposal")
        XCTAssertEqual(index.userActionThreads.first?.due, "Tuesday")
    }

    func testLegacyCorrectionDatesAreFrozenBeforeStatusWrite() throws {
        let (storage, meetings, action) = try fixture()
        let folder = meetings[0].folderURL(in: storage)
        let json = """
            {"schemaVersion":1,"actions":{"\(action.id)":{
              "status":"open","textCorrection":"Earlier correction","dueOverride":"Friday",
              "ownerOverride":"Me","updatedAt":"2026-08-01T10:00:00.123Z","userEdited":true
            }}}
            """
        try Data(json.utf8).write(to: folder.appendingPathComponent(MeetingOutcomeState.fileName))
        let legacy = try XCTUnwrap(MeetingOutcomeStore.loadState(from: folder).actions[action.id])
        XCTAssertEqual(legacy.textCorrectedAt, legacy.updatedAt)
        XCTAssertEqual(legacy.ownerCorrectedAt, legacy.updatedAt)
        XCTAssertEqual(legacy.dueCorrectedAt, legacy.updatedAt)
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        XCTAssertTrue(index.setStatus(.done, actionID: action.id, meetingID: meetings[0].id))
        let saved = try XCTUnwrap(MeetingOutcomeStore.loadState(from: folder).actions[action.id])
        XCTAssertGreaterThan(saved.updatedAt, legacy.updatedAt)
        XCTAssertEqual(saved.textCorrectedAt, legacy.textCorrectedAt)
        XCTAssertEqual(saved.ownerCorrectedAt, legacy.ownerCorrectedAt)
        XCTAssertEqual(saved.dueCorrectedAt, legacy.dueCorrectedAt)
    }

    func testSeparatingSourcePersistsAndCanBeReversedWithoutChangingOutcomes() throws {
        let (storage, meetings, action) = try fixture()
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        let originalID = try XCTUnwrap(index.userActionThreads.first?.id)
        let sourceURL = meetings[0].folderURL(in: storage).appendingPathComponent(MeetingOutcomes.fileName)
        let originalSource = try Data(contentsOf: sourceURL)
        XCTAssertTrue(index.setThreadExcluded(true, actionID: action.id, meetingID: meetings[0].id))
        index.refresh(meetings: meetings)
        XCTAssertEqual(index.userActionThreads.count, 2)
        XCTAssertTrue(index.userActionThreads.allSatisfy { $0.meetingCount == 1 })
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSource)
        XCTAssertTrue(index.setStatus(.done, actionID: action.id, meetingID: meetings[0].id))
        XCTAssertEqual(index.openUserActions.count, 1)
        XCTAssertTrue(index.setThreadExcluded(false, actionID: action.id, meetingID: meetings[0].id))
        XCTAssertEqual(index.userActionThreads.count, 1)
        XCTAssertEqual(index.userActionThreads[0].id, originalID)
        XCTAssertTrue(index.userActionThreads[0].hasMixedStatus)
    }

    func testLargeLibraryClusteringKeepsOwnerTimeAndSameMeetingBoundaries() {
        let now = Date()
        let action = MeetingOutcomes.ActionItem(text: "Send the revised launch proposal", owner: "Me")
        let secondAction = MeetingOutcomes.ActionItem(id: "second", text: action.text, owner: "Me")
        let meetings = (0..<1_000).map { offset in
            Meeting(id: UUID(), title: "Planning", appName: "Meet",
                    startedAt: now.addingTimeInterval(Double(-offset) * 86_400),
                    endedAt: now, relativePath: "meeting-\(offset)")
        }
        let references = meetings.flatMap { meeting in
            MeetingOutcomeProjection(meeting: meeting, outcomes: .init(actionItems: [action, secondAction]),
                                     state: .init(), followUp: .init()).actionReferences
        }
        let threads = ActionThreadClusterer.cluster(references)
        XCTAssertEqual(threads.flatMap(\.references).count, references.count)
        for thread in threads {
            XCTAssertEqual(thread.meetingCount, thread.references.count)
            let dates = thread.references.map(\.meetingStartedAt)
            XCTAssertLessThanOrEqual(dates.max()!.timeIntervalSince(dates.min()!), ActionThreadClusterer.maximumMeetingSpan)
        }
    }

    func testDistinctActionsClusterWithinAnInteractiveBudget() {
        let now = Date()
        let references = (0..<1_000).flatMap { offset in
            let meeting = Meeting(id: UUID(), title: "Planning", appName: "Meet",
                                  startedAt: now, endedAt: now, relativePath: "meeting-\(offset)")
            let action = MeetingOutcomes.ActionItem(text: "Review the release proposal number \(offset)", owner: "Me")
            return MeetingOutcomeProjection(meeting: meeting, outcomes: .init(actionItems: [action]),
                                            state: .init(), followUp: .init()).actionReferences
        }
        let start = Date()
        XCTAssertEqual(ActionThreadClusterer.cluster(references).count, references.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Action edits must not scan and normalize every pair")
    }

    func testThreadUndoRestoresEachSourceStatusAndInvalidatesEvidence() throws {
        let (storage, meetings, action) = try fixture()
        var notifications: [[Meeting.ID]] = []
        let index = OutcomeIndex(storage: storage) { notifications.append($0.map(\.id)) }
        index.refresh(meetings: meetings)
        XCTAssertTrue(index.setStatus(.deferred, actionID: action.id, meetingID: meetings[0].id))
        notifications = []
        let sources = try meetings.map {
            try Data(contentsOf: $0.folderURL(in: storage).appendingPathComponent(MeetingOutcomes.fileName))
        }
        XCTAssertTrue(index.setStatus(.done, thread: try XCTUnwrap(index.userActionThreads.first)))
        XCTAssertEqual(index.statusUndo.count, 2)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(Set(notifications[0]), Set(meetings.map(\.id)))
        index.undoStatusChange()
        XCTAssertTrue(index.statusUndo.isEmpty)
        XCTAssertNil(index.lastError)
        XCTAssertEqual(index.projection(for: meetings[0].id)?.actionReferences.first?.status, .deferred)
        XCTAssertEqual(index.projection(for: meetings[1].id)?.actionReferences.first?.status, .open)
        XCTAssertEqual(Set(notifications.dropFirst().flatMap { $0 }), Set(meetings.map(\.id)))
        for (offset, meeting) in meetings.enumerated() {
            XCTAssertEqual(try Data(contentsOf: meeting.folderURL(in: storage)
                .appendingPathComponent(MeetingOutcomes.fileName)), sources[offset])
        }
    }

    func testPartialThreadCompletionKeepsSuccessfulSourcesUndoableAndCanRetry() throws {
        let (storage, meetings, _) = try fixture()
        let index = OutcomeIndex(storage: storage)
        index.refresh(meetings: meetings)
        let thread = try XCTUnwrap(index.userActionThreads.first)
        let blocked = try XCTUnwrap(thread.references.last)
        let folder = try XCTUnwrap(index.projection(for: blocked.meetingID)?.meeting.folderURL(in: storage))
        let stateURL = folder.appendingPathComponent(MeetingOutcomeState.fileName)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        XCTAssertFalse(index.setStatus(.done, thread: thread))
        XCTAssertNotNil(index.lastError)
        XCTAssertEqual(index.statusUndo.count, 1)
        XCTAssertEqual(index.statusUndo.first?.meetingID, thread.references.first?.meetingID)
        XCTAssertTrue(index.userActionThreads[0].hasMixedStatus)
        index.undoStatusChange()
        XCTAssertEqual(index.openUserActions.count, 2)
        XCTAssertNil(index.lastError)
        try FileManager.default.removeItem(at: stateURL)
        XCTAssertTrue(index.setStatus(.done, thread: try XCTUnwrap(index.userActionThreads.first)))
        XCTAssertTrue(index.openUserActions.isEmpty)
        XCTAssertEqual(index.statusUndo.count, 2)
        index.undoStatusChange()
        let reopened = OutcomeIndex(storage: storage)
        reopened.refresh(meetings: meetings)
        XCTAssertEqual(reopened.openUserActions.count, 2)
    }

    private func fixture() throws -> (StorageManager, [Meeting], MeetingOutcomes.ActionItem) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-revisions-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try MeetingFixture.write([
            .init(title: "Planning", startedAt: Date().addingTimeInterval(-600)),
            .init(title: "Review", startedAt: Date().addingTimeInterval(-300)),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        let action = MeetingOutcomes.ActionItem(text: "Send the revised launch proposal", owner: "Me")
        for meeting in meetings {
            try MeetingOutcomes(actionItems: [action]).write(to: meeting.folderURL(in: storage))
        }
        return (storage, meetings, action)
    }
}
