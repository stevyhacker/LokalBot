import AppKit
import XCTest
@testable import LokalBot

// MARK: - Input monitor

final class CotypingInputMonitorTests: XCTestCase {
    func testAcceptOwnershipRequiresVisibleSuggestionAndLiveSession() {
        XCTAssertFalse(CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
            overlayIsVisible: false,
            hasSession: false))
        XCTAssertFalse(CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
            overlayIsVisible: false,
            hasSession: true))
        XCTAssertFalse(CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
            overlayIsVisible: true,
            hasSession: false))
        XCTAssertTrue(CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
            overlayIsVisible: true,
            hasSession: true))
    }

    func testAcceptTapTeardownDelayMatchesCoTabbyFinalAcceptGuard() {
        XCTAssertEqual(CotypingInputMonitor.acceptTapTeardownDelaySeconds, 0.05, accuracy: 0.0001)
    }

    func testAcceptSnapshotRejectsMarkedTextAndSelections() {
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .active,
            composingInputModeActive: true,
            hasLiveContent: true,
            selectionLength: 0))
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .inactive,
            composingInputModeActive: false,
            hasLiveContent: true,
            selectionLength: 2))
    }

    func testAcceptSnapshotRejectsAnyComposingInputMode() {
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .unknown,
            composingInputModeActive: true,
            hasLiveContent: true,
            selectionLength: 0))
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .inactive,
            composingInputModeActive: true,
            hasLiveContent: true,
            selectionLength: 0))
        XCTAssertTrue(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .unknown,
            composingInputModeActive: false,
            hasLiveContent: true,
            selectionLength: 0))
    }

    func testIdentityOnlyAcceptSnapshotAlwaysFailsClosed() {
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .inactive,
            composingInputModeActive: false,
            hasLiveContent: false,
            selectionLength: 0))
        XCTAssertFalse(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .inactive,
            composingInputModeActive: false,
            hasLiveContent: false,
            selectionLength: nil))
    }

    func testVerifiedLiveContentCanAccept() {
        XCTAssertTrue(CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: .inactive,
            composingInputModeActive: false,
            hasLiveContent: true,
            selectionLength: 0))
    }

    func testSyntheticSuppressionAccumulatesAcrossRapidBursts() {
        let controller = CotypingInputSuppressionController()
        let now = Date()

        controller.registerSyntheticInsertion(expectedKeyDownCount: 3, now: now)
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        controller.registerSyntheticInsertion(expectedKeyDownCount: 2, now: now)

        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertFalse(controller.consumeIfNeeded(now: now))
    }

    func testSyntheticSuppressionDropsStaleTokens() {
        let controller = CotypingInputSuppressionController()
        let now = Date()
        controller.registerSyntheticInsertion(expectedKeyDownCount: 5, now: now)

        XCTAssertFalse(controller.consumeIfNeeded(
            now: now.addingTimeInterval(
                CotypingInputSuppressionController.syntheticSuppressionWindowSeconds + 0.1)))

        controller.registerSyntheticInsertion(expectedKeyDownCount: 1, now: now)
        XCTAssertTrue(controller.consumeIfNeeded(now: now))
        XCTAssertFalse(controller.consumeIfNeeded(now: now))
    }
}

final class CotypingAcceptanceContentBoundsTests: XCTestCase {
    func testRangesStayInsideTheConfiguredCaretWindows() throws {
        let ranges = try XCTUnwrap(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 8_000, length: 0),
            totalUTF16Length: 12_000))

        XCTAssertEqual(
            ranges.preceding,
            NSRange(location: 3_904, length: 4_096))
        XCTAssertEqual(
            ranges.trailing,
            NSRange(location: 8_000, length: 1_024))
    }

    func testRangesClampAtDocumentEdges() throws {
        let start = try XCTUnwrap(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 0, length: 0),
            totalUTF16Length: 20))
        XCTAssertEqual(start.preceding, NSRange(location: 0, length: 0))
        XCTAssertEqual(start.trailing, NSRange(location: 0, length: 20))

        let end = try XCTUnwrap(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 20, length: 0),
            totalUTF16Length: 20))
        XCTAssertEqual(end.preceding, NSRange(location: 0, length: 20))
        XCTAssertEqual(end.trailing, NSRange(location: 20, length: 0))
    }

    func testRangesRejectSelectionsAndInvalidCaretOffsets() {
        XCTAssertNil(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 5, length: 1),
            totalUTF16Length: 20))
        XCTAssertNil(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 21, length: 0),
            totalUTF16Length: 20))
    }

    func testWholeValueFallbackRejectsDocumentsLargerThanBothWindows() {
        XCTAssertTrue(CotypingAcceptanceContentBounds.allowsWholeValueFallback(
            totalUTF16Length: 5_120))
        XCTAssertFalse(CotypingAcceptanceContentBounds.allowsWholeValueFallback(
            totalUTF16Length: 5_121))
    }

    func testReturnedTextMustExactlyMatchRequestedLengths() throws {
        let ranges = try XCTUnwrap(CotypingAcceptanceContentBounds.ranges(
            selection: NSRange(location: 3, length: 0),
            totalUTF16Length: 5))
        XCTAssertTrue(CotypingAcceptanceContentBounds.returnedTextMatchesRequestedRanges(
            precedingText: "abc",
            trailingText: "de",
            ranges: ranges))
        XCTAssertFalse(CotypingAcceptanceContentBounds.returnedTextMatchesRequestedRanges(
            precedingText: "ab",
            trailingText: "de",
            ranges: ranges))
    }
}
