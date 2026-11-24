import Foundation

extension CotypingCoordinator {
    func handleKey(_ event: CotypingInputEvent) {
        guard isRunning else { return }
        warmModelAfterPause()
        discardRevokedMemoryContext()
        noteKey(event, live: focusTracker.focus.field)
        if event.isEscape, let shown = session, overlay.isVisible, inputMonitor.isAcceptActive {
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
            CotypingWindowTextCapture.shared.noteTyping()
        case .textMutation:
            doubleTapAcceptance.reset()
            CotypingWindowTextCapture.shared.noteTyping()
            pendingKeystrokeUptime = nil
            if advanceActiveSessionIfTypedCharactersMatch(event.characters) {
                return
            }
            if session != nil {
                clearSuggestion()
                state = .idle
            }
            scheduleGenerationAfterHostPublishDelay()
        case .dismissal, .navigation, .shortcut, .other:
            doubleTapAcceptance.reset()
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
        CotypingAXHelper.forgetVisibleContext(exceptFor: focus.field?.focusIdentityKey, field: focus.field)
        if activeVisibleContext != nil, focus.field == nil {
            cancelPendingGenerationWork()
            acceptedSuggestionBatch.discardLearningRecord()
            clearSuggestion()
            suggestionAnchorCache.removeAll()
            self.activeVisibleContext = nil
            lastSuggestion = nil
            state = .idle
        }
        if let session,
           CotypingSessionReconciler.shouldClearActiveSessionOnFocusChange(
               session,
               liveField: focus.field,
               pendingInsertionConsumedCount: pendingInsertionConsumedCount) {
            clearSuggestion()
            if case .ready = state { state = .idle }
        } else if let field = focus.field {
            reanchorVisibleSuggestion(to: field)
        }
        if session == nil, state == .idle || isDisabledState,
           !isMeetingRecordingActive(), !isPausedForLowPowerMode {
            let settings = settingsProvider()
            if let reason = CotypingAvailability.disabledReason(
                enabled: settings.cotypingEnabled,
                excludedApps: settings.cotypingExcludedAppList,
                excludedDomains: settings.cotypingExcludedDomainList,
                suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
                selfBundleID: selfBundleID, focus: focus),
               case .unsupported = focus.capability {
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
        let interval = Self.hostPublishPollIntervalMs(elapsedMilliseconds: elapsedMs)
        let nextElapsed = elapsedMs + interval

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
                try? await Task.sleep(for: .milliseconds(interval))
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

        try? await Task.sleep(for: .milliseconds(interval))
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

    func reanchorVisibleSuggestion(to liveField: CotypingField) {
        guard let current = session, case .continuation = current.kind, overlay.isVisible,
              CotypingSessionReconciler.sessionReconciledByPublishedTyping(current, liveField: liveField) == current
        else { return }
        pendingInsertionConsumedCount = nil
        reanchor(current, to: liveField)
    }

    private func reanchor(_ current: CotypingSession, to liveField: CotypingField) {
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
            clearSuggestion()
            state = .idle
            scheduleGenerationAfterHostPublishDelay()
            return true
        } else {
            showSuggestion(remainingText, on: current.field)
            guard session != nil else { return true }
        }
        extendSuggestionIfNeeded()
        return true
    }
}
