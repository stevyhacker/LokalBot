import XCTest
@testable import LokalBot

final class ActionCompletionHintsTests: XCTestCase {
    private let spoken = Date(timeIntervalSince1970: 1_780_000_000)

    private func thread(_ text: String, owner: String = "Me", status: OutcomeStatus = .open) -> ActionThread {
        let action = MeetingOutcomes.ActionItem(text: text, owner: owner)
        let reference = OutcomeActionReference(
            meetingID: UUID(), meetingTitle: "Pricing", meetingStartedAt: spoken, action: action,
            status: status, text: action.text, owner: owner, due: nil, stateUpdatedAt: spoken,
            textWasCorrected: false, ownerWasCorrected: false, dueWasCorrected: false)
        return ActionThreadClusterer.cluster([reference])[0]
    }

    private func capture(_ id: Int64, after seconds: TimeInterval, app: String = "Mail",
                         title: String, text: String) -> ActionCompletionDetector.Capture {
        .init(snapshotID: id, capturedAt: spoken.addingTimeInterval(seconds), app: app, title: title, text: text)
    }

    func testDistinctiveTermsSkipGenericVerbsAndStopWords() {
        XCTAssertEqual(ActionCompletionDetector.distinctiveTerms("Send Ana the Q3 pricing deck by Friday"),
                       ["ana", "q3", "pricing", "deck"])
        XCTAssertTrue(ActionCompletionDetector.cues(for: "Send the deck").contains("message sent"))
        XCTAssertTrue(ActionCompletionDetector.cues(for: "Merge the retry PR").contains("merged"))
        XCTAssertTrue(ActionCompletionDetector.cues(for: "Ponder the thing").contains("completed"))
    }

    func testSuggestsOnlyWithMatchingWordsAndAVerbAppropriateCue() {
        let action = thread("Send Ana the Q3 pricing deck")
        let hint = ActionCompletionDetector.hint(for: action, captures: [
            capture(1, after: -60, title: "Q3 pricing deck", text: "Message sent to Ana"),
            capture(2, after: 600, title: "Inbox", text: "Sent  Drafts  Junk  Q3 pricing deck attached"),
            capture(3, after: 900, title: "Re: Q3 pricing deck", text: "Your message has been sent. Ana, attached is the pricing deck."),
        ], dismissed: [])
        XCTAssertEqual(hint?.snapshotID, 3)
        XCTAssertEqual(hint?.cue, "has been sent")

        XCTAssertNil(ActionCompletionDetector.hint(for: action, captures: [
            capture(3, after: 900, title: "Re: Q3 pricing deck", text: "Your message has been sent."),
        ], dismissed: ["\(action.id)#3"]))
    }

    func testIgnoresOtherPeoplesAndFinishedActionsAndVagueText() {
        let evidence = [capture(1, after: 60, title: "Q3 pricing deck", text: "Message sent: Q3 pricing deck")]
        XCTAssertNil(ActionCompletionDetector.hint(
            for: thread("Send Ana the Q3 pricing deck", owner: "Ana"), captures: evidence, dismissed: []))
        XCTAssertNil(ActionCompletionDetector.hint(
            for: thread("Send Ana the Q3 pricing deck", status: .done), captures: evidence, dismissed: []))
        XCTAssertNil(ActionCompletionDetector.hint(
            for: thread("Follow up"), captures: evidence, dismissed: []))
    }

    func testStoreBackedSearchFindsLaterCaptures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hints-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("activity.sqlite")
        let writer = ActivityStore(databaseURL: url)
        try writer.insertScreenshot(ts: spoken.addingTimeInterval(1_200), path: "", app: "GitHub Desktop",
                                    windowTitle: "retry-backoff", textSource: "accessibility",
                                    ocr: "Pull request successfully merged: retry backoff jitter")
        let action = thread("Merge the retry backoff jitter PR")
        let hints = ActionCompletionDetector.hints(
            for: [action], store: ActivityStore(databaseURL: url, readOnly: true), dismissed: [],
            now: spoken.addingTimeInterval(3_600))
        XCTAssertEqual(hints[action.id]?.cue, "merged")
    }
}
