import Foundation

/// Focus changes, keyboard input, and host-publish reconciliation.
extension CotypingCoordinator {
    // MARK: - Input handling

    func handleKey(_ event: CotypingInputEvent) {
        guard isRunning else { return }
        discardRevokedMemoryContext()
        noteKey(event, live: focusTracker.focus.field)
        if event.isEscape, let shown = session, overlay.isVisible, inputMonitor.isAcceptActive {
            // The accept tap takes this Escape and decides whether the app
            // sees it. Should the tap miss the key, the suggestion still goes.
            pendingKeystrokeUptime = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.session == shown else { return }
                self.cancelPendingGenerationWork()
                self.clearSuggestion()
                self.state = .idle
            }
            return
        }
        switch event.kind {
        case .acceptance, .fullAcceptance:
            break // owned by the accept tap
        case .textMutation:
            // Typing through a ghost that is already on screen has no wait to
            // measure; scheduling the next suggestion starts a new one.
            pendingKeystrokeUptime = nil
            if advanceActiveSessionIfTypedCharactersMatch(event.characters) {
                return
            }
            // The key leaves the suggestion behind. The app draws its letters
            // where the ghost starts, so the ghost goes now rather than when
            // the app publishes them, which in a browser can take a while.
            if session != nil {
                clearSuggestion()
                state = .idle
            }
            scheduleGenerationAfterHostPublishDelay()
        case .dismissal, .navigation, .shortcut, .other:
            pendingKeystrokeUptime = nil
            cancelPendingGenerationWork()
            clearSuggestion()
            state = .idle
        }
    }

    func handleFocusChange(_ focus: CotypingFocus) {
        guard isRunning else { return }
        discardRevokedMemoryContext()
        resolveInsertionCheck(live: focus.field)
        // Text read from the screen is forgotten as soon as focus leaves the
        // field it was read for.
        CotypingAXHelper.forgetVisibleContext(exceptFor: focus.field?.focusIdentityKey)
        if activeVisibleContext != nil, focus.field == nil {
            cancelPendingGenerationWork()
            acceptedSuggestionBatch.discardLearningRecord()
            clearSuggestion()
            suggestionAnchorCache.removeAll()
            self.activeVisibleContext = nil
            lastSuggestion = nil
            state = .idle
        }
        // Drop a live suggestion when focus leaves the field/app it belongs to.
        if let session,
           CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
               session,
               liveField: focus.field,
               pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            clearSuggestion()
        } else if let field = focus.field {
            reanchorVisibleSuggestion(to: field)
        }
        // Surface a disabled reason in the UI while idle (no live suggestion).
        if session == nil, state == .idle || isDisabledState {
            let settings = settingsProvider()
            if let reason = CotypingAvailability.disabledReason(
                enabled: settings.cotypingEnabled,
                excludedApps: settings.cotypingExcludedAppList,
                excludedDomains: settings.cotypingExcludedDomainList,
                suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
                selfBundleID: selfBundleID, focus: focus),
               case .unsupported = focus.capability {
                // Only reflect hard "not a text field" states passively; avoid
                // flapping the label on every transient focus change.
                state = .disabled(reason)
            } else if case .supported = focus.capability {
                state = .idle
            }
        }
        scheduleFocusPrewarm(for: focus)
    }

    var isDisabledState: Bool {
        if case .disabled = state { return true }
        return false
    }

    func scheduleGenerationAfterHostPublishDelay(baseline explicitBaseline: CotypingField? = nil) {
        cancelPendingGenerationWork()
        cancelSuggestionExtension()
        let baseline = explicitBaseline ?? focusTracker.focus.field
        let pollGeneration = hostPublishPollGeneration
        let keystrokeUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        // Measured from here until the suggestion this keystroke asks for is visible.
        pendingKeystrokeUptime = keystrokeUptimeNanoseconds

        hostPublishPollTask?.cancel()
        hostPublishPollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.hostPublishFirstPollIntervalMs))
            guard !Task.isCancelled else { return }
            await self?.pollForHostPublish(
                baseline: baseline,
                pollGeneration: pollGeneration,
                elapsedMs: Self.hostPublishFirstPollIntervalMs,
                keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds
            )
        }
    }

    private func pollForHostPublish(
        baseline: CotypingField?,
        pollGeneration: UInt64,
        elapsedMs: Int,
        keystrokeUptimeNanoseconds: UInt64
    ) async {
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let focus = await focusTracker.refreshNow()
        guard isRunning, pollGeneration == hostPublishPollGeneration else { return }
        let nextElapsed = elapsedMs + Self.hostPublishPollIntervalMs

        if CotypingSessionReconciler.hostPublishDidMove(from: baseline, to: focus.field) {
            let consumed = Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds)
            if let field = focus.field,
               advanceActiveSessionIfPublishedTextMatches(field, consumedDelayMilliseconds: consumed) {
                return
            }
            if let current = session,
               CotypingSessionReconciler.shouldAwaitPostInsertionSync(
                   current,
                   liveField: focus.field,
                   pendingInsertionConsumedCount: pendingInsertionConsumedCount),
               nextElapsed < Self.hostPublishWaitCeilingMs {
                try? await Task.sleep(for: .milliseconds(Self.hostPublishPollIntervalMs))
                guard !Task.isCancelled else { return }
                await pollForHostPublish(
                    baseline: baseline,
                    pollGeneration: pollGeneration,
                    elapsedMs: nextElapsed,
                    keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds)
                return
            }
            scheduleGeneration(consumedDelayMilliseconds: consumed)
            return
        }

        guard nextElapsed < Self.hostPublishWaitCeilingMs else {
            scheduleGeneration(consumedDelayMilliseconds: Self.elapsedMilliseconds(since: keystrokeUptimeNanoseconds))
            return
        }

        try? await Task.sleep(for: .milliseconds(Self.hostPublishPollIntervalMs))
        guard !Task.isCancelled else { return }
        await pollForHostPublish(
            baseline: baseline,
            pollGeneration: pollGeneration,
            elapsedMs: nextElapsed,
            keystrokeUptimeNanoseconds: keystrokeUptimeNanoseconds)
    }

    private nonisolated static func elapsedMilliseconds(since uptimeNanoseconds: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
    }

    private func advanceActiveSessionIfPublishedTextMatches(
        _ liveField: CotypingField,
        consumedDelayMilliseconds: Int
    ) -> Bool {
        guard let current = session,
              let advanced = CotypingSessionReconciler.sessionReconciledByPublishedTyping(
                  current, liveField: liveField) else {
            return false
        }

        session = advanced
        if advanced.isExhausted {
            clearSuggestion()
            state = .idle
            scheduleGeneration(consumedDelayMilliseconds: consumedDelayMilliseconds)
            return true
        }

        pendingInsertionConsumedCount = nil
        reanchor(advanced, to: liveField)
        guard session != nil else { return true }
        extendSuggestionIfNeeded()
        return true
    }

    /// Moves the visible ghost to the caret the app reports, once the app
    /// shows everything accepted or typed through so far. Until then the
    /// ghost stays where the keys moved it. Called for every focus change,
    /// so the ghost also follows a field that scrolls or moves.
    func reanchorVisibleSuggestion(to liveField: CotypingField) {
        guard let current = session, case .continuation = current.kind, overlay.isVisible,
              CotypingSessionReconciler.sessionReconciledByPublishedTyping(current, liveField: liveField) == current
        else { return }
        // Every accept so far is in the field.
        pendingInsertionConsumedCount = nil
        reanchor(current, to: liveField)
    }

    /// Lays out the rest of `current` at `liveField`'s caret unless it is
    /// already there; a ghost that would cover typed text always moves.
    private func reanchor(_ current: CotypingSession, to liveField: CotypingField) {
        // A quick read leaves out the field's font; the suggestion keeps the
        // one it was drawn in.
        var live = liveField
        if live.fieldStyle == nil { live.fieldStyle = current.field.fieldStyle }
        let field = displayField(live)
        let placement = self.placement(for: field)
        let remainingText = current.remainingText
        if overlay.shouldHoldInlineReanchor(
            text: remainingText,
            caretRect: field.caretRect,
            style: field.fieldStyle,
            placement: placement,
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance(),
            inputFrameRect: field.inputFrameRect,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText),
            precedingText: field.precedingText,
            trailingText: field.trailingText) {
            markReady(remainingText)
            return
        }
        showSuggestion(remainingText, on: field, placement: placement)
    }

    private func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String) -> Bool {
        guard let current = session,
              let advanced = CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
                  current,
                  typedCharacters: typedCharacters) else {
            return false
        }

        cancelPendingGenerationWork()
        session = advanced
        if advanced.isExhausted {
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay(baseline: current.field)
            return true
        }

        let remainingText = advanced.remainingText
        if overlay.advanceInline(
            to: remainingText,
            insertedText: typedCharacters,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(current.field.precedingText),
            emphasisLength: acceptEmphasisLength(for: remainingText)) {
            markReady(remainingText)
            refreshCaretSoon()
        } else if overlay.isShowingInline {
            // Where the typed letters end is known only once the app shows
            // them, and the caret read for this suggestion is behind them.
            // The rest comes back from the anchor cache at the app's caret.
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay()
            return true
        } else {
            // A popup sits under the caret's line, clear of the text.
            showSuggestion(remainingText, on: current.field)
            guard session != nil else { return true }
        }
        extendSuggestionIfNeeded()
        return true
    }
}
