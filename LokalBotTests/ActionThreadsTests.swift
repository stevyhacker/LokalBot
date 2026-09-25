import XCTest
@testable import LokalBot

@MainActor
final class ActionThreadsTests: XCTestCase {
    func testClustersCompatibleMentionsAndPrefersUserCorrection() throws {
        let older = reference(
            meetingID: UUID(),
            meetingTitle: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            text: "I will send the revised launch proposal",
            due: "Friday")
        let newer = reference(
            meetingID: UUID(),
            meetingTitle: "Client review",
            startedAt: older.meetingStartedAt.addingTimeInterval(2 * 86_400),
            text: "Send the revised launch proposal",
            due: "Monday",
            correctedText: "Send Acme the revised launch proposal by email",
            correctedDue: "Tuesday")

        let threads = ActionThreadClusterer.cluster([older, newer])

        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.meetingCount, 2)
        XCTAssertEqual(thread.mentionCount, 2)
        XCTAssertEqual(thread.text, "Send Acme the revised launch proposal by email")
        XCTAssertEqual(thread.due, "Tuesday")
        XCTAssertEqual(thread.dueHistory, ["Tuesday", "Friday"])
        XCTAssertEqual(thread.references.map(\.meetingTitle), ["Client review", "Planning"])
    }

    func testKeepsGenericConflictingAndDifferentOwnerActionsSeparate() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let references = [
            reference(
                meetingID: UUID(), meetingTitle: "One", startedAt: start,
                text: "Follow up", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Two",
                startedAt: start.addingTimeInterval(60),
                text: "Follow up", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Release 72", startedAt: start,
                text: "Ship release 72 candidate today", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Release 73",
                startedAt: start.addingTimeInterval(60),
                text: "Ship release 73 candidate today", owner: "Me"),
            reference(
                meetingID: UUID(), meetingTitle: "Ana",
                startedAt: start.addingTimeInterval(120),
                text: "Send the revised launch proposal", owner: "Ana"),
            reference(
                meetingID: UUID(), meetingTitle: "Me",
                startedAt: start.addingTimeInterval(180),
                text: "Send the revised launch proposal", owner: "Me"),
        ]

        XCTAssertEqual(ActionThreadClusterer.cluster(references).count, references.count)
    }

    func testMixedStatusPreservesUnfinishedWorkAndFiltersByEachSource() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let first = reference(
            meetingID: UUID(),
            meetingTitle: "Planning",
            startedAt: start,
            text: "Send the revised launch proposal",
            status: .open,
            stateUpdatedAt: start.addingTimeInterval(100))
        let completed = reference(
            meetingID: UUID(),
            meetingTitle: "Review",
            startedAt: start.addingTimeInterval(60),
            text: "Send the revised launch proposal",
            status: .done,
            stateUpdatedAt: start.addingTimeInterval(200))

        let thread = try XCTUnwrap(ActionThreadClusterer.cluster([first, completed]).first)

        XCTAssertEqual(thread.status, .open)
        XCTAssertTrue(thread.hasMixedStatus)
        XCTAssertEqual(thread.statusLabel, "Mixed")
        XCTAssertTrue(ActionStatusFilter.done.includes(thread))
        XCTAssertTrue(ActionStatusFilter.active.includes(thread))
        XCTAssertFalse(ActionStatusFilter.deferred.includes(thread))
    }

    func testSourceCompletionIsLocalAndExplicitThreadCompletionUpdatesAllSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-thread-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        let startedAt = Date()
        try MeetingFixture.write([
            .init(id: firstID, title: "Planning", startedAt: startedAt),
            .init(
                id: secondID,
                title: "Review",
                startedAt: startedAt.addingTimeInterval(60)),
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let meetings = try SessionLookup.loadAllMeetings(root: root)
        for meeting in meetings {
            try MeetingOutcomes(actionItems: [
                .init(text: "Send the revised launch proposal", owner: "Me"),
            ]).write(to: meeting.folderURL(in: storage))
        }
        var notifications: [Meeting.ID] = []
        var batches: [[Meeting.ID]] = []
        let index = OutcomeIndex(storage: storage, onEvidenceChanged: { meetings in
            notifications.append(contentsOf: meetings.map(\.id))
            batches.append(meetings.map(\.id))
        })
        index.refresh(meetings: meetings)
        let thread = try XCTUnwrap(index.openUserActionThreads.first)
        XCTAssertEqual(thread.meetingCount, 2)

        let source = thread.references[0]
        XCTAssertTrue(index.setStatus(
            .done,
            actionID: source.action.id,
            meetingID: source.meetingID))
        XCTAssertEqual(index.openUserActions.count, 1)
        XCTAssertEqual(notifications, [source.meetingID])
        XCTAssertTrue(index.userActionThreads[0].hasMixedStatus)
        XCTAssertFalse(index.setStatus(.done, thread: thread), "Reject a stale UI snapshot")
        XCTAssertTrue(index.setStatus(.done, thread: index.userActionThreads[0]))
        XCTAssertTrue(index.openUserActions.isEmpty)
        XCTAssertEqual(index.userActionThreads.map(\.status), [.done])
        XCTAssertEqual(Set(notifications), Set([firstID, secondID]))
        XCTAssertEqual(notifications.count, 2)
        for meeting in meetings {
            let state = MeetingOutcomeStore.loadState(from: meeting.folderURL(in: storage))
            XCTAssertEqual(state.actions.values.first?.status, .done)
        }
        batches.removeAll()
        XCTAssertTrue(index.setStatus(.open, thread: index.userActionThreads[0]))
        XCTAssertEqual(batches.count, 1, "One bulk edit must invalidate derived consumers once")
        XCTAssertEqual(Set(batches[0]), Set([firstID, secondID]))
    }

    func testOppositeNegatedReorderedAndNumberedCommitmentsStaySeparate() {
        let date = Date()
        let texts = [
            "Enable automatic daily export for all workspace users",
            "Disable automatic daily export for all workspace users",
            "Do not enable automatic daily export for all workspace users",
            "Send the launch proposal to Alice from Bob",
            "Send the launch proposal to Bob from Alice",
            "Ship release 72 candidate today",
            "Ship release 73 candidate today",
            "Set the alert threshold to -5 degrees",
            "Set the alert threshold to 5 degrees",
            "Set the alert threshold to >= 5 degrees",
            "Set the alert threshold to <= 5 degrees",
        ]
        let references = texts.enumerated().map { index, text in
            reference(meetingID: UUID(), meetingTitle: text,
                      startedAt: date.addingTimeInterval(Double(index)), text: text)
        }
        XCTAssertEqual(ActionThreadClusterer.cluster(references).count, texts.count)
    }

    func testCorrectionsKeepMembershipAndIDAcrossRefresh() throws {
        let start = Date()
        let first = reference(meetingID: UUID(), meetingTitle: "One", startedAt: start,
                              text: "Send the revised launch proposal")
        var second = reference(meetingID: UUID(), meetingTitle: "Two", startedAt: start.addingTimeInterval(60),
                               text: "Send the revised launch proposal")
        let original = try XCTUnwrap(ActionThreadClusterer.cluster([first, second]).first)
        second.text = "Send Acme the revised launch proposal by email"
        second.textWasCorrected = true
        second.owner = "Alice"
        second.ownerWasCorrected = true
        let updated = ActionThreadClusterer.cluster([first, second])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, original.id)
        XCTAssertEqual(updated[0].owner, "Alice")
        XCTAssertFalse(updated[0].isForUser)
        XCTAssertEqual(updated[0].text, second.text)
    }

    func testLatestExplicitClearsWinAcrossThreadReferences() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var older = reference(
            meetingID: UUID(), meetingTitle: "Planning", startedAt: start,
            text: "Send the revised launch proposal", owner: "Me", due: "Friday")
        older.owner = "Alice"
        older.due = "Tuesday"
        older.ownerWasCorrected = true
        older.dueWasCorrected = true
        older.ownerCorrectedAt = start.addingTimeInterval(30)
        older.dueCorrectedAt = start.addingTimeInterval(30)
        var cleared = reference(
            meetingID: UUID(), meetingTitle: "Review",
            startedAt: start.addingTimeInterval(60),
            text: "Send the revised launch proposal", owner: "Me", due: "Monday")
        cleared.owner = nil
        cleared.due = nil
        cleared.ownerWasCorrected = true
        cleared.dueWasCorrected = true
        cleared.ownerCorrectedAt = start.addingTimeInterval(90)
        cleared.dueCorrectedAt = start.addingTimeInterval(90)

        let thread = try XCTUnwrap(ActionThreadClusterer.cluster([older, cleared]).first)

        XCTAssertNil(thread.owner)
        XCTAssertNil(thread.due)
    }

    func testCorrectionIntentDistinguishesUntouchedNilFromExplicitClear() {
        XCTAssertNil(ActionCorrectionFieldIntent.persistedValue(
            "", wasCorrected: false, wasEdited: false))
        XCTAssertEqual(ActionCorrectionFieldIntent.persistedValue(
            "", wasCorrected: false, wasEdited: true), "")
        XCTAssertEqual(ActionCorrectionFieldIntent.persistedValue(
            "", wasCorrected: true, wasEdited: false), "")
        XCTAssertNil(ActionCorrectionFieldIntent.persistedValue(
            "Me", wasCorrected: false, wasEdited: false))
        XCTAssertEqual(ActionCorrectionFieldIntent.persistedValue(
            "Alice", wasCorrected: false, wasEdited: true), "Alice")
    }

    func testRemoteAliasMeCannotEnterUserActionThreads() throws {
        let remote = reference(meetingID: UUID(), meetingTitle: "Remote owner named Me", startedAt: Date(),
            text: "I will send the final proposal", owner: "Me",
            attribution: .init(resolution: .other, speakerID: "them 1", basis: .commitment))
        XCTAssertFalse(remote.isForUser)
        XCTAssertFalse(try XCTUnwrap(ActionThreadClusterer.cluster([remote]).first).isForUser)
    }

    private func reference(
        meetingID: UUID,
        meetingTitle: String,
        startedAt: Date,
        text: String,
        owner: String = "Me",
        due: String? = nil,
        correctedText: String? = nil,
        correctedDue: String? = nil,
        status: OutcomeStatus = .open,
        stateUpdatedAt: Date? = nil,
        attribution: OutcomeAttribution? = nil
    ) -> OutcomeActionReference {
        let action = MeetingOutcomes.ActionItem(
            text: text,
            owner: owner,
            due: due,
            citations: [.init(
                meetingID: meetingID,
                segmentID: "segment-\(meetingID.uuidString)",
                start: 1,
                end: 2,
                speaker: owner,
                excerpt: text)], attribution: attribution)
        return OutcomeActionReference(
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingStartedAt: startedAt,
            action: action,
            status: status,
            text: correctedText ?? action.displayText,
            owner: owner,
            due: correctedDue ?? due,
            stateUpdatedAt: stateUpdatedAt ?? startedAt.addingTimeInterval(30),
            textWasCorrected: correctedText != nil,
            ownerWasCorrected: false,
            dueWasCorrected: correctedDue != nil)
    }
}
