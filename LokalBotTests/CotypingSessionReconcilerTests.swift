import AppKit
import XCTest
@testable import LokalBot

// MARK: - Stale-field guard (continuation)

final class CotypingContinuationTests: XCTestCase {
    private func field(
        _ preceding: String,
        trailingText: String = "",
        pid: pid_t = 5,
        focusIdentityKey: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: pid,
            role: "AXTextArea", focusIdentityKey: focusIdentityKey,
            precedingText: preceding, trailingText: trailingText,
            selectionLength: 0, caretRect: .zero, isSecure: false, caretIsExact: true)
    }

    private func session(
        _ preceding: String,
        pid: pid_t = 5,
        focusIdentityKey: String? = nil
    ) -> CotypingSession {
        CotypingSession(
            field: field(preceding, pid: pid, focusIdentityKey: focusIdentityKey),
            fullText: " up on the deck")
    }

    func testSameUntouchedFieldIsContinuation() {
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow")))
    }

    func testFieldGrownByAcceptedWordsIsContinuation() {
        // After accepting a word, the live preceding text only grows.
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("I wanted to follow up")))
    }

    func testDifferentFieldSameProcessIsNotContinuation() {
        // Another compose box in the same app (same PID) must NOT match.
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: field("Reply to the thread")))
    }

    func testDifferentFieldSameProcessWithSameTextIsNotContinuationWhenIdentityDiffers() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(
            of: session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow", focusIdentityKey: "field-b")))
    }

    func testMissingFocusIdentityKeepsTextFallbackForContinuation() {
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(
            of: session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow")))
    }

    func testCappedLongFieldShiftAfterAcceptedWordIsContinuation() {
        let previous = String(repeating: "a", count: 4096)
        let live = String(previous.dropFirst(3)) + " up"
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(of: session(previous), liveField: field(live)))
    }

    func testDifferentProcessIsNotContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow", pid: 5), liveField: field("I wanted to follow", pid: 99)))
    }

    func testNoLiveFieldIsNotContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isContinuation(of: session("I wanted to follow"), liveField: nil))
    }

    func testAcceptanceRequiresTrailingTextToRemainStable() {
        let current = CotypingSession(
            field: field("I wanted to follow", trailingText: " tomorrow"),
            fullText: " up on the deck")

        XCTAssertTrue(CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: field("I wanted to follow", trailingText: " tomorrow"),
            pendingInsertionConsumedCount: nil))
        XCTAssertFalse(CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: nil))
    }

    func testFocusChangeClearsWhenTrailingTextChangesOutsideInsertionSync() {
        let current = CotypingSession(
            field: field("I wanted to follow", trailingText: " tomorrow"),
            fullText: " up on the deck")

        XCTAssertTrue(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: nil))
    }

    func testPostInsertionSyncToleratesTransientTrailingAndPrefixRaces() {
        let current = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("I wanted to follow", trailingText: " changed"),
            pendingInsertionConsumedCount: 3))
        XCTAssertFalse(CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
            current,
            liveField: field("Goodbye", trailingText: " changed"),
            pendingInsertionConsumedCount: 3))
    }

    func testCurrentGenerationTargetRequiresSameContentAndIdentity() {
        var original = field("I wanted to follow")
        original.focusIdentityKey = "field-a"
        var live = original

        XCTAssertTrue(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live.precedingText += " up"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live = original
        live.focusIdentityKey = "field-b"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))
    }

    func testReplacementPlannerRejectsSameProcessFieldWithDifferentIdentity() {
        let original = field("Please send :wave:", focusIdentityKey: "field-a")
        let session = CotypingSession(
            field: original,
            fullText: "👋",
            kind: .emoji(shortcode: "wave"))
        let other = field("Please send :wave:", focusIdentityKey: "field-b")

        XCTAssertNil(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: other))
    }

    func testReplacementPlannerRequiresExactEmojiTriggerAndGlyph() throws {
        let live = field("Please send :wave:", focusIdentityKey: "field-a")
        let valid = CotypingSession(
            field: live,
            fullText: "👋",
            kind: .emoji(shortcode: "wave"))
        let plan = try XCTUnwrap(CotypingReplacementAcceptancePlanner.plan(
            for: valid,
            liveField: live))

        XCTAssertEqual(plan.deletingCharacters, 6)
        XCTAssertEqual(plan.replacementText, "👋")

        let stale = CotypingSession(
            field: live,
            fullText: "😄",
            kind: .emoji(shortcode: "smile"))
        XCTAssertNil(CotypingReplacementAcceptancePlanner.plan(
            for: stale,
            liveField: live))
    }

    func testReplacementPlannerInsertsPreviewedMacroWithoutReevaluation() throws {
        let live = field("Roll /d20", focusIdentityKey: "field-a")
        let session = CotypingSession(
            field: live,
            fullText: "7",
            kind: .macro(query: "d20"))
        let plan = try XCTUnwrap(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: live))

        XCTAssertEqual(plan.deletingCharacters, 4)
        XCTAssertEqual(plan.replacementText, "7")
    }

    func testReplacementPlannerRejectsChangedMacroQuery() {
        let live = field("Date /today", focusIdentityKey: "field-a")
        let session = CotypingSession(
            field: live,
            fullText: "Jul 21, 2026",
            kind: .macro(query: "tomorrow"))

        XCTAssertNil(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: live))
    }

    func testReplacementPlannerBuildsCorrectionOnlyForExactFieldSnapshot() throws {
        let live = field("Please recieve", focusIdentityKey: "field-a")
        let session = CotypingSession(
            field: live,
            fullText: "receive",
            kind: .correction(typoWord: "recieve"))
        let plan = try XCTUnwrap(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: live))

        XCTAssertEqual(plan.deletingCharacters, 7)
        XCTAssertEqual(plan.replacementText, "receive")

        var changed = live
        changed.precedingText += " later"
        XCTAssertNil(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: changed))
    }

    func testReplacementPlannerRejectsCorrectionBeyondEventTapDeletionCap() {
        let typo = String(repeating: "a", count: 65)
        let live = field(typo, focusIdentityKey: "field-a")
        let session = CotypingSession(
            field: live,
            fullText: "replacement",
            kind: .correction(typoWord: typo))

        XCTAssertNil(CotypingReplacementAcceptancePlanner.plan(
            for: session,
            liveField: live))
    }

    func testCurrentGenerationTargetAllowsMissingFocusIdentityButStillRequiresAnchorIdentity() {
        var original = field("I wanted to follow")
        original.windowTitle = "Draft"
        var live = original
        live.focusIdentityKey = nil

        XCTAssertTrue(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))

        live.windowTitle = "Other Draft"
        XCTAssertFalse(CotypingSessionReconciler.isCurrentGenerationTarget(original, liveField: live))
    }

    func testHostPublishDetectsSameTextFieldSwitchWhenIdentityIsKnown() {
        let original = field("I wanted to follow", focusIdentityKey: "field-a")
        let live = field("I wanted to follow", focusIdentityKey: "field-b")

        XCTAssertTrue(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testHostPublishUsesAnchorIdentityWhenFocusIdentityIsMissing() {
        var original = field("I wanted to follow")
        original.windowTitle = "Draft"
        var live = original
        live.windowTitle = "Other Draft"

        XCTAssertTrue(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testHostPublishTreatsIdentityLossAsMovement() {
        let original = field("I wanted to follow", focusIdentityKey: "field-a")
        let live = field("I wanted to follow")

        XCTAssertTrue(CotypingSessionReconciler.hostPublishDidMove(from: original, to: live))
    }

    func testPublishedTypingAdvancesSuggestionTail() throws {
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
        XCTAssertEqual(advanced.field.precedingText, "I wanted to follow")
    }

    func testSuccessiveHostPublishesNeverCountAcceptedPrefixTwice() throws {
        for optimistic in [false, true] {
            var current = session("I wanted to follow")
            if optimistic { current = current.advanced(by: 3) }
            for (suffix, count, remaining) in [(" up", 3, " on the deck"),
                                               (" up on", 6, " the deck"),
                                               (" up on the", 10, " deck")] {
                current = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
                    current, liveField: field("I wanted to follow" + suffix)))
                XCTAssertEqual(current.consumedCount, count)
                XCTAssertEqual(current.remainingText, remaining)
                XCTAssertEqual(current.field.precedingText, "I wanted to follow")
            }
        }
    }

    func testUnicodeCappedContextRemainsAnAcceptanceContinuation() throws {
        let before = String(repeating: "e\u{301}", count: 3_000) + " please"
        let oldContext = try XCTUnwrap(CotypingAcceptanceContentBounds.context(
            in: before, selection: NSRange(location: before.utf16.count, length: 0)))
        let after = before + " send"
        let newContext = try XCTUnwrap(CotypingAcceptanceContentBounds.context(
            in: after, selection: NSRange(location: after.utf16.count, length: 0)))
        var oldField = field(oldContext.preceding)
        oldField.precedingTextIsTruncated = oldContext.precedingIsTruncated
        var live = field(newContext.preceding)
        live.precedingTextIsTruncated = newContext.precedingIsTruncated
        XCTAssertTrue(CotypingSessionReconciler.isContinuation(
            of: CotypingSession(field: oldField, fullText: " send the contract"), liveField: live))
    }

    func testPublishedTypingHonorsAlreadyAcceptedPrefix() throws {
        let accepted = session("I wanted to follow").advanced(by: 3)
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            accepted,
            liveField: field("I wanted to follow up on")))

        XCTAssertEqual(advanced.consumedCount, 6)
        XCTAssertEqual(advanced.remainingText, " the deck")
    }

    func testPublishedTypingDoesNotAdvanceMismatchedText() {
        XCTAssertNil(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow"),
            liveField: field("I wanted to follow nope")))
    }

    func testPublishedTypingDoesNotAdvanceAcrossKnownDifferentFieldIdentity() {
        XCTAssertNil(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            session("I wanted to follow", focusIdentityKey: "field-a"),
            liveField: field("I wanted to follow up", focusIdentityKey: "field-b")))
    }

    func testDirectTypedCharactersAdvanceSuggestionTailBeforeHostPublishes() throws {
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: " up"))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
        XCTAssertEqual(advanced.field.precedingText, "I wanted to follow")
    }

    func testDirectTypedCharactersRejectMismatchAndControlInput() {
        XCTAssertNil(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: " nope"))
        XCTAssertNil(CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
            session("I wanted to follow"),
            typedCharacters: "\n"))
    }

    func testPublishedTypingRebasesOptimisticallyAdvancedSessionWhenHostCatchesUp() throws {
        let optimistic = session("I wanted to follow").advanced(by: 3)
        let rebased = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            optimistic,
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(rebased.consumedCount, 3)
        XCTAssertEqual(rebased.remainingText, " on the deck")
        XCTAssertEqual(rebased.field.precedingText, "I wanted to follow")
    }

    func testPublishedTypingCanAdvanceBeyondOptimisticConsumedPrefix() throws {
        let optimistic = session("I wanted to follow").advanced(by: 1)
        let advanced = try XCTUnwrap(CotypingSessionReconciler.sessionReconciledByPublishedTyping(
            optimistic,
            liveField: field("I wanted to follow up")))

        XCTAssertEqual(advanced.consumedCount, 3)
        XCTAssertEqual(advanced.remainingText, " on the deck")
    }

    func testPostInsertionSyncWaitsWhileAcceptedTextIsNotPublished() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertTrue(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncStopsWaitingOnceAcceptedTextPublishes() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow up"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncRequiresMatchingPendingConsumedCount() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: nil))
        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow"),
            pendingInsertionConsumedCount: 1))
    }

    func testPostInsertionSyncDoesNotCrossKnownDifferentFieldIdentity() {
        let accepted = session("I wanted to follow", focusIdentityKey: "field-a").advanced(by: 3)

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("I wanted to follow", focusIdentityKey: "field-b"),
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncDoesNotWaitWhenTextIsSelected() {
        let accepted = session("I wanted to follow").advanced(by: 3)
        var selected = field("I wanted to follow")
        selected.selectionLength = 2

        XCTAssertFalse(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: selected,
            pendingInsertionConsumedCount: 3))
    }

    func testPostInsertionSyncToleratesPrefixAnchorRace() {
        let accepted = session("I wanted to follow").advanced(by: 3)

        XCTAssertTrue(CotypingSessionReconciler.shouldAwaitPostInsertionSync(
            accepted,
            liveField: field("Goodbye"),
            pendingInsertionConsumedCount: 3))
    }

    func testStaleAcceptanceEchoDropsRepeatOfAcceptedTailWhileFieldUnchanged() {
        XCTAssertTrue(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoToleratesLeadingWhitespaceDifference() {
        XCTAssertTrue(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: "today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsSuggestionOnceInsertPublished() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " today",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind today",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoAllowsGenuinelyDifferentContinuation() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " tomorrow",
            acceptedChunk: " today",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }

    func testStaleAcceptanceEchoIgnoresWhitespaceOnlyChunk() {
        XCTAssertFalse(CotypingSessionReconciler.isStaleAcceptanceEcho(
            resultText: " ",
            acceptedChunk: " ",
            currentPrecedingText: "what's on your mind",
            acceptedPrecedingText: "what's on your mind"))
    }
}
