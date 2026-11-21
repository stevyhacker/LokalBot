import Foundation

extension CotypingCoordinator {
    func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning, !discardRevokedMemoryContext() else { return false }
        if let activeVisibleContext,
           !CotypingVisibleContext.Policy(settings: settingsProvider()).permits(activeVisibleContext) {
            clearSuggestion()
            state = .idle
            return false
        }
        guard CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                  overlayIsVisible: overlay.isVisible,
                  hasSession: session != nil),
              var current = session else { return false }
        guard overlay.acceptanceText == current.remainingText else {
            clearSuggestion()
            state = .idle
            return false
        }
        let live = CotypingAXHelper.resolveAcceptanceSnapshot(
            cachedField: focusTracker.focus.field)
        guard CotypingAcceptanceSnapshotPolicy.canAccept(
            markedTextState: live.markedTextState,
            composingInputModeActive: inputSourceMonitor.isComposingIMEActive,
            hasLiveContent: live.hasLiveContent,
            selectionLength: live.field?.selectionLength) else {
            clearSuggestion()
            state = .idle
            return false
        }

        if case .continuation = current.kind {
        } else {
            guard let plan = CotypingReplacementAcceptancePlanner.plan(
                for: current,
                liveField: live.field),
                  inserter.replace(
                      deletingCharacters: plan.deletingCharacters,
                      with: plan.replacementText) else {
                clearSuggestion()
                state = .idle
                return false
            }
            if case .correction = current.kind {
                acceptedWordCount += 1
                stats.recordTypoFixed()
            }
            clearSuggestion()
            state = .idle
            return true
        }

        guard CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: live.field,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            clearSuggestion()
            state = .idle
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else {
            clearSuggestion()
            state = .idle
            return false
        }

        let settings = settingsProvider()
        let liveField = live.field ?? current.field
        guard let acceptance = CotypingContinuationAcceptance.plan(
            session: current,
            scope: scope,
            precedingText: liveField.precedingText,
            trailingText: liveField.trailingText,
            options: .init(settings: settings)) else { return false }
        let acceptedChunk = acceptance.acceptedChunk
        let insertionText = acceptance.insertionText
        let forwardDeleteCount = acceptance.forwardDeleteCount
        let inserted: Bool
        if insertionText.isEmpty {
            inserted = true
        } else if forwardDeleteCount > 0 {
            inserted = CotypingSyntheticEditPolicy.allowsForwardDeletion(forwardDeleteCount)
                && inserter.replaceForward(
                    deletingCharacters: forwardDeleteCount,
                    with: insertionText)
        } else {
            inserted = inserter.insert(insertionText)
        }
        guard inserted else {
            clearSuggestion()
            state = .idle
            return false
        }
        lastAcceptanceAt = Date()
        let acceptedWords = CotypingAcceptanceChunker.acceptedWordCount(in: acceptedChunk)
        noteAcceptance(field: liveField, inserted: insertionText, charsAccepted: acceptedChunk.count,
                       words: acceptedWords)
        recordAcceptedText(acceptedChunk, field: liveField, settings: settings)

        acceptedWordCount += acceptedWords
        current = current.advanced(by: acceptedChunk.count)
        session = current
        noteSuggestionActivity()

        if current.isExhausted {
            pendingInsertionConsumedCount = nil
            lastAcceptedTail = AcceptedSuggestionTail(text: acceptedChunk, precedingText: liveField.precedingText)
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: liveField)
        } else {
            pendingInsertionConsumedCount = current.consumedCount
            let remainingText = current.remainingText
            let advanced = overlay.advanceInline(
                to: remainingText,
                insertedText: insertionText,
                isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(liveField.precedingText),
                emphasisLength: acceptEmphasisLength(for: remainingText))
            if !advanced, overlay.isShowingInline {
                clearSuggestion()
                state = .idle
                scheduleGenerationAfterHostPublishDelay(baseline: liveField)
                return true
            }
            if !advanced {
                showSuggestion(remainingText, on: live.field ?? current.field)
            }
            syncAcceptInterception()
            extendSuggestionIfNeeded()
            refreshCaretSoon()
        }
        return true
    }

    func refreshCaretSoon() {
        caretRefreshTask?.cancel()
        caretRefreshTask = Task { [weak self] in
            for delay in [30, 90] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.overlay.isVisible, let current = self.session else { return }
                let live = await self.focusTracker.refreshNow().field
                guard !Task.isCancelled, self.session == current, let live else { return }
                self.visualCaret.refreshIfDrifted(for: live)
                guard CotypingSessionReconciler.sessionReconciledByPublishedTyping(current, liveField: live) != current
                else { return }
            }
        }
    }

    func dismissFromTap() -> Bool {
        guard isRunning, let current = session, overlay.isVisible else { return false }
        let takesKey = settingsProvider().cotypingEscapeBehavior == .pause
            && !inputSourceMonitor.isComposingIMEActive
        cancelPendingGenerationWork()
        clearSuggestion()
        state = .idle
        if takesKey {
            escapePause = (
                fieldAnchor: CotypingFieldIdentity.suggestionAnchor(for: current.field),
                until: Date().addingTimeInterval(CotypingEscapeBehavior.pauseSeconds))
        }
        return takesKey
    }

    func isPausedByEscape(in field: CotypingField, now: Date = Date()) -> Bool {
        guard let pause = escapePause else { return false }
        guard now < pause.until else {
            escapePause = nil
            return false
        }
        return pause.fieldAnchor == CotypingFieldIdentity.suggestionAnchor(for: field)
    }

    func recordAcceptedText(_ text: String, field: CotypingField, settings: AppSettings) {
        acceptedSuggestionBatch.append(
            field: field, acceptedText: text,
            learningEnabled: settings.cotypingUseLocalLearning && activeMemoryContext.selection.items.isEmpty
                && activeVisibleContext == nil)
    }

    func present(
        _ newSession: CotypingSession,
        overlayText: String,
        acceptanceText: String? = nil
    ) {
        pendingInsertionConsumedCount = nil
        session = newSession
        showOverlay(text: overlayText, field: newSession.field, acceptanceText: acceptanceText)
        guard overlay.isVisible else {
            clearSuggestion()
            state = .idle
            return
        }
        keepSessionToShownText()
        markReady(overlay.acceptanceText ?? acceptanceText ?? overlayText)
        noteSuggestionShown(newSession)
    }

    func showSuggestion(
        _ text: String,
        on field: CotypingField,
        placement: CotypingOverlayPlacement? = nil
    ) {
        showOverlay(text: text, field: field, placement: placement)
        guard overlay.isVisible else {
            clearSuggestion()
            state = .idle
            return
        }
        keepSessionToShownText()
        markReady(session?.remainingText ?? text)
    }

    func keepSessionToShownText() {
        guard let current = session, case .continuation = current.kind,
              let shown = overlay.acceptanceText, !shown.isEmpty,
              shown != current.remainingText, current.remainingText.hasPrefix(shown) else { return }
        var trimmed = CotypingSession(
            field: current.field, fullText: current.acceptedText + shown,
            consumedCount: current.consumedCount, kind: .continuation)
        trimmed.isOpenEnded = true
        session = trimmed
    }

    func markReady(_ text: String) {
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
        noteSuggestionActivity()
    }

    func noteSuggestionActivity() {
        lastSuggestionActivity = .now
        guard suggestionExpiryTask == nil else { return }
        suggestionExpiryTask = Task { [weak self] in
            await self?.expireIdleSuggestion()
        }
    }

    private func expireIdleSuggestion() async {
        while session != nil, let lastActivity = lastSuggestionActivity {
            let deadline = lastActivity.advanced(by: .milliseconds(idleSuggestionLifetimeMilliseconds))
            guard ContinuousClock.now < deadline else {
                suggestionExpiryTask = nil
                clearSuggestion()
                if case .ready = state { state = .idle }
                return
            }
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
        }
        suggestionExpiryTask = nil
    }

    func clearSuggestion() {
        if let completed = acceptedSuggestionBatch.complete() {
            stats.suggestionCompleted()
            if let record = completed.learningRecord {
                learningStore.recordCompletedSuggestion(
                    field: record.field,
                    acceptedText: record.acceptedText)
            }
        }
        session = nil
        shownSuggestion = nil
        suggestionExpiryTask?.cancel()
        suggestionExpiryTask = nil
        lastSuggestionActivity = nil
        caretRefreshTask?.cancel()
        caretRefreshTask = nil
        cancelSuggestionExtension()
        pendingInsertionConsumedCount = nil
        overlay.hide()
        syncAcceptInterception()
    }

    private func syncAcceptInterception() {
        inputMonitor.setAcceptActive(
            CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                overlayIsVisible: overlay.isVisible,
                hasSession: session != nil))
    }

    func millisecondsSinceLastAcceptance() -> Int? {
        lastAcceptanceAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    }
}
