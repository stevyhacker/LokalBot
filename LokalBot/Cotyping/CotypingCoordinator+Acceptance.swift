import Foundation

/// Acceptance, session presentation, insertion bookkeeping, and teardown.
extension CotypingCoordinator {
    // MARK: - Acceptance (called synchronously from the accept tap)

    func acceptFromTap(_ scope: CotypingAcceptScope) -> Bool {
        guard isRunning, !discardRevokedMemoryContext() else { return false }
        if let activeVisibleContext,
           !CotypingVisibleContext.Policy(settings: settingsProvider()).permits(activeVisibleContext.target) {
            clearSuggestion()
            state = .idle
            return false
        }
        guard CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                  overlayIsVisible: overlay.isVisible,
                  hasSession: session != nil),
              var current = session else { return false }
        // The visible ghost must match the session tail — a mismatch means the
        // overlay is showing stale text and accepting would insert the wrong thing.
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

        // Replacements delete existing host text, so they share one exact-field
        // and exact-trigger validation path. A same-PID match is not sufficient.
        if case .continuation = current.kind {
            // Continue through the normal append-only acceptance path below.
        } else {
            guard let plan = CotypingReplacementAcceptancePlanner.plan(
                for: current,
                liveField: live.field),
                  inserter.replace(
                      deletingCharacters: plan.deletingCharacters,
                      with: plan.replacementText) else {
                clearSuggestion()
                return false
            }
            if case .correction = current.kind { acceptedWordCount += 1 }
            clearSuggestion()
            state = .idle
            return true
        }

        // Continuation: never insert into the wrong field (mouse-moved focus).
        guard CotypingSessionReconciler.isAcceptanceContinuation(
            of: current,
            liveField: live.field,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount) else {
            clearSuggestion()
            return false
        }
        let remaining = current.remainingText
        guard !remaining.isEmpty else { clearSuggestion(); return false }

        let settings = settingsProvider()
        let liveField = live.field ?? current.field
        // Shared with the Settings rehearsal: one plan decides how much a
        // keypress takes and how it is spaced.
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
            // The consuming event tap must remain constant-time and must never
            // touch the pasteboard or walk an app's AX menu tree. Composing
            // input sources fail open above; direct-input continuations use one
            // synthetic Unicode event pair regardless of text length or lines.
            inserted = inserter.insert(insertionText)
        }
        guard inserted else {
            clearSuggestion()
            state = .idle
            return false
        }
        lastAcceptanceAt = Date()
        noteAcceptance(field: liveField, inserted: insertionText, charsAccepted: acceptedChunk.count)
        recordAcceptedText(acceptedChunk, field: liveField, settings: settings)

        acceptedWordCount += CotypingAcceptanceChunker.acceptedWordCount(in: acceptedChunk)
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
            // Re-anchor the ghost after the host commits the insert (AX lag).
            pendingInsertionConsumedCount = current.consumedCount
            let remainingText = current.remainingText
            let advanced = overlay.advanceInline(
                to: remainingText,
                insertedText: insertionText,
                isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(liveField.precedingText),
                emphasisLength: acceptEmphasisLength(for: remainingText))
            if !advanced, overlay.isShowingInline {
                // Where the accepted text ends is known only once the app
                // shows it. Drawn at the caret read before the accept, the
                // rest would cover that text; it comes back from the anchor
                // cache at the new caret instead.
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

    /// Reads the field shortly, and once more if the app has not shown the
    /// text yet. The focus change a read publishes moves the ghost to the
    /// app's own caret (`reanchorVisibleSuggestion`), which corrects what the
    /// ghost's font measured, such as a page zoom it does not know about.
    func refreshCaretSoon() {
        caretRefreshTask?.cancel()
        caretRefreshTask = Task { [weak self] in
            for delay in [30, 90] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.overlay.isVisible, let current = self.session else { return }
                let live = await self.focusTracker.refreshNow().field
                guard !Task.isCancelled, self.session == current, let live,
                      CotypingSessionReconciler.sessionReconciledByPublishedTyping(current, liveField: live) != current
                else { return }
            }
        }
    }

    /// Escape while a suggestion is showing. The suggestion goes away and,
    /// unless the user chose otherwise, the key stops here, so it does not
    /// also close a dialog or leave a mode in the app, and the field stays
    /// quiet for a few seconds. Called synchronously from the accept tap.
    func dismissFromTap() -> Bool {
        guard isRunning, let current = session, overlay.isVisible else { return false }
        // A composing input method needs its own Escape.
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

    /// Whether Escape put this field on hold. The hold ends on its own, and it
    /// never follows the user to another field.
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

    /// Atomically presents a suggestion. The invariant *session exists ⟺
    /// overlay visible ⟺ state == .ready ⟺ accept tap armed* is established
    /// here (and torn down in `clearSuggestion`) — never by hand at call sites.
    /// A suggestion with no place on screen that covers no text is dropped.
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

    /// Shows the rest of the live session at `field`'s caret, keeping the
    /// session to what is drawn. With nowhere to draw it, the suggestion goes.
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

    /// The session keeps only what the ghost shows, so an accept never
    /// inserts words the user could not see. The rest may come back as a
    /// top-up once there is room.
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

    /// The published tail of `present` — also used by the advance paths, which
    /// keep the existing overlay window and only re-arm interception + state.
    func markReady(_ text: String) {
        syncAcceptInterception()
        lastSuggestion = text
        state = .ready(text: text)
        noteSuggestionActivity()
    }

    /// Restarts the idle clock of the suggestion on screen. Every key either
    /// advances the suggestion or clears it, so a minute without a call means
    /// a minute without typing in the field.
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
            // The continuous clock keeps counting while the Mac sleeps.
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
