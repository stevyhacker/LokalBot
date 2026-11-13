import XCTest
@testable import LokalBot

/// `action.setStatus` from a phone goes through `OutcomeIndex` like a click
/// in Actions: by id, by the text snapshot when reprocessing changed the id,
/// and otherwise reported as unmatched.
@MainActor
final class CompanionOpApplierTests: XCTestCase {
    private var fixture: CompanionFixtureLibrary!
    private var outcomes: OutcomeIndex!
    private var applier: CompanionOpApplier!
    private var meetings: [Meeting] = []

    override func setUp() async throws {
        fixture = try CompanionFixtureLibrary.make()
        let storage = StorageManager(rootURL: fixture.root)
        meetings = try SessionLookup.loadAllMeetings(root: fixture.root)
        outcomes = OutcomeIndex(storage: storage)
        outcomes.refresh(meetings: meetings)
        applier = CompanionOpApplier(outcomes: outcomes, meetings: { [unowned self] in self.meetings })
    }

    override func tearDown() async throws {
        fixture?.remove()
        fixture = nil
    }

    private func op(actionID: String, text: String? = nil, status: String = "done",
                    meetingID: UUID? = nil, type: String = "action.setStatus") throws -> String {
        try CompanionJSON.encode(CompanionSetStatusOp(
            type: type, opId: UUID().uuidString,
            meetingId: (meetingID ?? fixture.designReview.id).uuidString.lowercased(),
            actionId: actionID, actionText: text, status: status, at: CompanionJSON.instant(Date())))
    }

    private func savedStatus(_ actionID: String) -> OutcomeStatus? {
        let folder = fixture.designReview.folderURL(in: StorageManager(rootURL: fixture.root))
        return MeetingOutcomeStore.loadState(from: folder).actions[actionID]?.status
    }

    func testSetStatusByID() throws {
        let outcome = applier.apply(try op(actionID: "act-deck"))
        XCTAssertEqual(outcome.result.status, .applied)
        XCTAssertEqual(outcome.meetingID, fixture.designReview.id)
        XCTAssertEqual(savedStatus("act-deck"), .done)
        XCTAssertEqual(outcomes.projection(for: fixture.designReview.id)?
            .actionReferences.first { $0.action.id == "act-deck" }?.status, .done)
    }

    func testSetStatusFallsBackToTheTextSnapshot() throws {
        let outcome = applier.apply(try op(actionID: "act-id-before-reprocessing",
                                           text: "send the revised pricing deck to Maya!", status: "deferred"))
        XCTAssertEqual(outcome.result.status, .applied)
        XCTAssertEqual(savedStatus("act-deck"), .deferred)
    }

    func testUnknownActionIsUnmatchedAndChangesNothing() throws {
        let outcome = applier.apply(try op(actionID: "act-gone", text: "Book the offsite venue"))
        XCTAssertEqual(outcome.result.status, .unmatched)
        XCTAssertNotNil(outcome.result.message)
        XCTAssertNil(savedStatus("act-deck"))

        let missingMeeting = applier.apply(try op(actionID: "act-deck", meetingID: UUID()))
        XCTAssertEqual(missingMeeting.result.status, .unmatched)
    }

    func testMalformedOpsAreRejected() throws {
        XCTAssertEqual(applier.apply("{").result.status, .rejected)
        XCTAssertEqual(applier.apply(try op(actionID: "act-deck", status: "archived")).result.status, .rejected)
        XCTAssertEqual(applier.apply(try op(actionID: "act-deck", type: "action.delete")).result.status, .rejected)
        XCTAssertNil(savedStatus("act-deck"))
    }

    func testSampleMeetingsCannotBeChangedFromADevice() throws {
        let outcome = applier.apply(try op(actionID: "act-deck", meetingID: fixture.sampleMeeting.id))
        XCTAssertEqual(outcome.result.status, .unmatched)
    }

    func testMatcherNeedsAnUnambiguousText() {
        let meeting = fixture.designReview
        func reference(_ id: String, _ text: String) -> OutcomeActionReference {
            OutcomeActionReference(
                meetingID: meeting.id, meetingTitle: meeting.title, meetingStartedAt: meeting.startedAt,
                action: MeetingOutcomes.ActionItem(id: id, text: text, isForUser: true),
                status: .open, text: text, owner: "Me", due: nil, stateUpdatedAt: meeting.startedAt,
                textWasCorrected: false, ownerWasCorrected: false, dueWasCorrected: false)
        }
        let references = [reference("a", "Send the deck"), reference("b", "Send the deck"), reference("c", "Call Ana")]
        XCTAssertEqual(CompanionOpMatcher.match(actionID: "c", actionText: "anything", in: references), .byID("c"))
        XCTAssertEqual(CompanionOpMatcher.match(actionID: "x", actionText: "call  ANA.", in: references), .byText("c"))
        XCTAssertEqual(CompanionOpMatcher.match(actionID: "x", actionText: "Send the deck", in: references), .unmatched)
        XCTAssertEqual(CompanionOpMatcher.match(actionID: "x", actionText: nil, in: references), .unmatched)
    }
}
