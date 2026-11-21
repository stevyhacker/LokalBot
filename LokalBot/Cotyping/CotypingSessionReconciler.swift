import Foundation

enum CotypingSessionReconciler {

    static func hostPublishDidMove(from baseline: CotypingField?, to current: CotypingField?) -> Bool {
        guard let baseline else { return current != nil }
        guard let current else { return true }
        return current.contentSignature != baseline.contentSignature
            || current.processID != baseline.processID
            || current.bundleID != baseline.bundleID
            || current.role != baseline.role
            || knownFocusIdentityDidMove(from: baseline, to: current)
            || CotypingFieldIdentity.suggestionAnchor(for: current)
                != CotypingFieldIdentity.suggestionAnchor(for: baseline)
    }

    static func isContinuation(of session: CotypingSession, liveField: CotypingField?) -> Bool {
        guard let liveField, liveField.processID == session.field.processID else { return false }
        guard liveField.bundleID == session.field.bundleID, liveField.role == session.field.role else { return false }
        if let originalIdentity = session.field.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        let previous = session.field.precedingText
        let live = liveField.precedingText
        if live.hasPrefix(previous) { return true }
        let windowLimit = CotypingAXHelper.maxPrecedingCharacters
        guard session.field.precedingTextIsTruncated || liveField.precedingTextIsTruncated
            || previous.utf16.count >= windowLimit || live.utf16.count >= windowLimit else {
            return false
        }
        return hasCappedPrefixWindowOverlap(previous: previous, live: live)
    }

    static func isAcceptanceContinuation(
        of session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard isContinuation(of: session, liveField: liveField) else { return false }
        guard let liveField else { return false }
        if shouldAwaitPostInsertionSync(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return true
        }
        if isPostInsertionSyncTarget(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return true
        }
        return liveField.trailingText == session.field.trailingText
    }

    static func shouldClearActiveSessionOnFocusChange(
        _ session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard let liveField else { return true }
        if shouldAwaitPostInsertionSync(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return false
        }
        if isPostInsertionSyncTarget(
            session,
            liveField: liveField,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            return false
        }
        guard isContinuation(of: session, liveField: liveField) else { return true }
        return liveField.trailingText != session.field.trailingText
    }

    static func isCurrentGenerationTarget(
        _ originalField: CotypingField,
        liveField: CotypingField?
    ) -> Bool {
        guard let liveField else { return false }
        guard liveField.processID == originalField.processID,
              liveField.bundleID == originalField.bundleID,
              liveField.role == originalField.role,
              liveField.contentSignature == originalField.contentSignature,
              CotypingFieldIdentity.suggestionAnchor(for: liveField)
                == CotypingFieldIdentity.suggestionAnchor(for: originalField) else {
            return false
        }
        if let originalIdentity = originalField.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        return true
    }

    static func isExactAcceptanceTarget(
        _ session: CotypingSession,
        liveField: CotypingField?
    ) -> Bool {
        isCurrentGenerationTarget(session.field, liveField: liveField)
    }

    static func sessionReconciledByPublishedTyping(
        _ session: CotypingSession,
        liveField: CotypingField?
    ) -> CotypingSession? {
        guard case .continuation = session.kind,
              let liveField,
              isContinuation(of: session, liveField: liveField) else { return nil }

        let expectedPrefix = session.field.precedingText + session.acceptedText
        guard liveField.precedingText.hasPrefix(expectedPrefix) else { return nil }
        let typed = String(liveField.precedingText.dropFirst(expectedPrefix.count))
        if typed.isEmpty { return session }
        guard session.remainingText.hasPrefix(typed) else { return nil }
        return session.advanced(by: typed.count)
    }

    static func shouldAwaitPostInsertionSync(
        _ session: CotypingSession,
        liveField: CotypingField?,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard let liveField,
              isPostInsertionSyncTarget(
                  session,
                  liveField: liveField,
                  pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            return false
        }

        let expectedPrefix = session.field.precedingText + session.acceptedText
        guard !liveField.precedingText.hasPrefix(expectedPrefix) else {
            return false
        }

        return true
    }

    static func sessionAdvancedByTypedCharacters(
        _ session: CotypingSession,
        typedCharacters: String
    ) -> CotypingSession? {
        guard case .continuation = session.kind,
              !typedCharacters.isEmpty,
              typedCharacters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              session.remainingText.hasPrefix(typedCharacters) else {
            return nil
        }
        return session.advanced(by: typedCharacters.count)
    }

    static func isStaleAcceptanceEcho(
        resultText: String,
        acceptedChunk: String,
        currentPrecedingText: String,
        acceptedPrecedingText: String
    ) -> Bool {
        let trimmedChunk = acceptedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return false }
        guard resultText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedChunk else { return false }
        return currentPrecedingText == acceptedPrecedingText
    }

    private static func knownFocusIdentityDidMove(
        from baseline: CotypingField,
        to current: CotypingField
    ) -> Bool {
        guard let original = baseline.focusIdentityKey,
              let live = current.focusIdentityKey else {
            return false
        }
        return original != live
    }

    private static func isPostInsertionSyncTarget(
        _ session: CotypingSession,
        liveField: CotypingField,
        pendingInsertionConsumedCount: Int?
    ) -> Bool {
        guard case .continuation = session.kind,
              pendingInsertionConsumedCount == session.consumedCount,
              liveField.processID == session.field.processID,
              liveField.bundleID == session.field.bundleID,
              liveField.role == session.field.role,
              liveField.selectionLength == 0 else {
            return false
        }
        if let originalIdentity = session.field.focusIdentityKey,
           let liveIdentity = liveField.focusIdentityKey,
           originalIdentity != liveIdentity {
            return false
        }
        return true
    }

    private static func hasCappedPrefixWindowOverlap(previous: String, live: String) -> Bool {
        let windowLimit = CotypingAXHelper.maxPrecedingCharacters
        let maxLength = min(min(previous.count, live.count), windowLimit)
        let minimumOverlap = min(1024, maxLength)
        guard minimumOverlap > 0 else { return false }
        var length = maxLength
        while length >= minimumOverlap {
            if previous.suffix(length) == live.prefix(length) { return true }
            length -= 1
        }
        return false
    }
}

struct CotypingReplacementAcceptancePlan: Equatable, Sendable {
    let deletingCharacters: Int
    let replacementText: String
}

enum CotypingReplacementAcceptancePlanner {
    static func plan(
        for session: CotypingSession,
        liveField: CotypingField?
    ) -> CotypingReplacementAcceptancePlan? {
        guard let liveField,
              CotypingSessionReconciler.isExactAcceptanceTarget(
                  session,
                  liveField: liveField) else {
            return nil
        }

        switch session.kind {
        case .continuation:
            return nil
        case .correction(let typoWord):
            guard let correction = CotypingCorrectionPlan.plan(
                precedingText: liveField.precedingText,
                expectedTypo: typoWord,
                correctedWord: session.fullText),
                  CotypingSyntheticEditPolicy.allowsBackwardDeletion(
                      correction.deletingCharacters) else {
                return nil
            }
            return CotypingReplacementAcceptancePlan(
                deletingCharacters: correction.deletingCharacters,
                replacementText: correction.replacementText)
        case .emoji(let expectedShortcode):
            guard let emoji = CotypingEmoji.match(trailing: liveField.precedingText),
                  emoji.shortcode == expectedShortcode,
                  emoji.glyph == session.fullText,
                  CotypingSyntheticEditPolicy.allowsBackwardDeletion(
                      emoji.typedLength) else {
                return nil
            }
            return CotypingReplacementAcceptancePlan(
                deletingCharacters: emoji.typedLength,
                replacementText: session.fullText)
        case .macro(let expectedQuery):
            guard CotypingMacro.trailingQuery(in: liveField.precedingText) == expectedQuery,
                  let tokenLength = CotypingMacro.trailingTokenLength(
                      in: liveField.precedingText),
                  CotypingSyntheticEditPolicy.allowsBackwardDeletion(
                      tokenLength) else {
                return nil
            }
            return CotypingReplacementAcceptancePlan(
                deletingCharacters: tokenLength,
                replacementText: session.fullText)
        }
    }
}
