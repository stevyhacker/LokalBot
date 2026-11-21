import CoreGraphics
import XCTest
@testable import LokalBot

final class CotypingInserterTests: XCTestCase {
    func testMarkerTagsAnEventAndRecognizesIt() throws {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertFalse(CotypingSyntheticMarker.isSynthetic(event),
                       "a fresh event must not read as synthetic")
        CotypingSyntheticMarker.mark(event)
        XCTAssertTrue(CotypingSyntheticMarker.isSynthetic(event))
    }

    func testSuppressionControllerForwardsTheMarker() throws {
        let controller = CotypingInputSuppressionController()
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertFalse(controller.isSynthetic(event))
        controller.markSynthetic(event)
        XCTAssertTrue(controller.isSynthetic(event))
    }

    @MainActor
    func testInsertRejectsEmptyAndCarriageReturnOnlyText() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.insert(""))
        XCTAssertFalse(inserter.insert("\r"),
                       "carriage returns are scrubbed; a CR-only insert is a no-op")
        XCTAssertFalse(inserter.insert("\r\r"))
    }

    @MainActor
    func testReplaceRejectsNothingToDeleteAndNothingToType() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.replace(deletingCharacters: 0, with: ""))
        XCTAssertFalse(inserter.replace(deletingCharacters: 0, with: "\r"))
        XCTAssertFalse(inserter.replace(deletingCharacters: -3, with: ""))
    }

    @MainActor
    func testReplaceForwardRejectsNothingToDeleteAndNothingToType() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.replaceForward(deletingCharacters: 0, with: ""))
        XCTAssertFalse(inserter.replaceForward(deletingCharacters: 0, with: "\r"))
    }

    func testSyntheticDeletionPolicyHasSmallInclusiveCaps() {
        XCTAssertTrue(CotypingSyntheticEditPolicy.allowsBackwardDeletion(0))
        XCTAssertTrue(CotypingSyntheticEditPolicy.allowsBackwardDeletion(64))
        XCTAssertFalse(CotypingSyntheticEditPolicy.allowsBackwardDeletion(-1))
        XCTAssertFalse(CotypingSyntheticEditPolicy.allowsBackwardDeletion(65))

        XCTAssertTrue(CotypingSyntheticEditPolicy.allowsForwardDeletion(0))
        XCTAssertTrue(CotypingSyntheticEditPolicy.allowsForwardDeletion(64))
        XCTAssertFalse(CotypingSyntheticEditPolicy.allowsForwardDeletion(-1))
        XCTAssertFalse(CotypingSyntheticEditPolicy.allowsForwardDeletion(65))
    }

    @MainActor
    func testReplaceRejectsOversizedDeletionBeforePostingEvents() {
        let inserter = CotypingInserter()

        XCTAssertFalse(inserter.replace(deletingCharacters: 65, with: ""))
        XCTAssertFalse(inserter.replace(deletingCharacters: -1, with: "replacement"))
        XCTAssertFalse(inserter.replaceForward(deletingCharacters: 65, with: ""))
        XCTAssertFalse(inserter.replaceForward(deletingCharacters: -1, with: "replacement"))
    }

    @MainActor
    func testInsertViaPasteRejectsEmptyText() async {
        let inserter = CotypingInserter()

        let empty = await inserter.insertViaPaste("")
        XCTAssertEqual(empty, .failed, "an empty paste must bail before touching the pasteboard")
        let carriageReturn = await inserter.insertViaPaste("\r")
        XCTAssertEqual(carriageReturn, .failed)
    }
}
