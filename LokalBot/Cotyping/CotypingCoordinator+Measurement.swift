import Foundation

extension CotypingCoordinator {
    nonisolated static let correctionWindowMilliseconds = 5_000
    nonisolated static let maxMeasuredVisibleMilliseconds = 10_000

    func surfaceKey(for field: CotypingField) -> String {
        CotypingSurfaceClassifier.classify(
            bundleID: field.bundleID,
            isIntegratedTerminal: field.isIntegratedTerminal).rawValue
    }

    func noteSuggestionShown(_ session: CotypingSession) {
        guard case .continuation = session.kind else { return }
        let surface = surfaceKey(for: session.field)
        let shown = ShownSuggestion(surface: surface, model: settingsProvider().cotypingStatisticsModelID)
        shownSuggestion = shown
        stats.recordSuggestionShown(surface: shown.surface, model: shown.model)
        guard let started = pendingKeystrokeUptime else { return }
        pendingKeystrokeUptime = nil
        let elapsed = Self.measuredMilliseconds(since: started)
        guard elapsed <= Self.maxMeasuredVisibleMilliseconds else { return }
        stats.recordShown(latencyMs: elapsed, surface: surface)
    }

    func noteAcceptance(field: CotypingField, inserted: String, charsAccepted: Int, words: Int = 0) {
        let surface = surfaceKey(for: field)
        let now = DispatchTime.now().uptimeNanoseconds
        stats.recordAccept(charsAccepted: charsAccepted, surface: surface)
        let shown = shownSuggestion
            ?? ShownSuggestion(surface: surface, model: settingsProvider().cotypingStatisticsModelID, used: true)
        stats.recordSuggestionAccept(
            words: words, characters: charsAccepted, firstOfSuggestion: !shown.used,
            surface: shown.surface, model: shown.model)
        shownSuggestion?.used = true
        lastTypedKeyUptime = nil
        acceptAwaitingNextKey = (shown.surface, shown.model, now)
        guard !inserted.isEmpty else { return }
        resolveInsertionCheck(live: field)
        if pendingInsertionCheck != nil {
            pendingInsertionCheck?.extend(byInserting: inserted, at: now)
        } else {
            pendingInsertionCheck = CotypingInsertionCheck(
                field: field, inserted: inserted, surface: surface, startedUptimeNanoseconds: now)
        }
        scheduleInsertionCheckExpiry()
    }

    func resolveInsertionCheck(live: CotypingField?, expired: Bool = false) {
        guard let check = pendingInsertionCheck else { return }
        let elapsed = Self.measuredMilliseconds(since: check.startedUptimeNanoseconds)
        let outcome = check.outcome(
            live: live,
            elapsedMilliseconds: expired ? max(elapsed, CotypingInsertionCheck.timeoutMilliseconds) : elapsed)
        guard outcome != .pending else { return }
        closeInsertionCheck(as: outcome)
    }

    private func closeInsertionCheck(as outcome: CotypingInsertionCheck.Outcome) {
        guard let check = pendingInsertionCheck else { return }
        pendingInsertionCheck = nil
        insertionCheckExpiryTask?.cancel()
        insertionCheckExpiryTask = nil
        stats.recordInsertion(outcome, count: check.count, surface: check.surface)
    }

    private func scheduleInsertionCheckExpiry() {
        insertionCheckExpiryTask?.cancel()
        let delay = insertionCheckExpiryMilliseconds
        insertionCheckExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, self.pendingInsertionCheck != nil else { return }
            let live = self.isRunning
                ? await self.focusTracker.refreshNow().field
                : self.focusTracker.focus.field
            guard !Task.isCancelled else { return }
            self.resolveInsertionCheck(live: live, expired: true)
        }
    }

    func noteKey(_ event: CotypingInputEvent, live: CotypingField?) {
        noteKeyAfterAcceptance(event)
        noteTyping(event, in: focusTracker.focus)
        resolveInsertionCheck(live: live)
        switch event.kind {
        case .navigation, .shortcut:
            closeInsertionCheck(as: .unconfirmed)
        case .textMutation where event.isCorrection:
            closeInsertionCheck(as: .unconfirmed)
        case .acceptance, .fullAcceptance, .dismissal, .textMutation, .other:
            break
        }
    }

    func noteKeyAfterAcceptance(_ event: CotypingInputEvent) {
        guard let accepted = acceptAwaitingNextKey else { return }
        switch event.kind {
        case .acceptance, .fullAcceptance:
            return
        case .dismissal, .navigation, .shortcut, .textMutation, .other:
            break
        }
        acceptAwaitingNextKey = nil
        guard event.isCorrection,
              Self.measuredMilliseconds(since: accepted.uptimeNanoseconds) <= Self.correctionWindowMilliseconds
        else { return }
        stats.recordCorrection(surface: accepted.surface)
        stats.recordTakenBack(surface: accepted.surface, model: accepted.model)
    }

    func noteTyping(_ event: CotypingInputEvent, in focus: CotypingFocus) {
        guard event.kind == .textMutation, !event.characters.isEmpty, !event.isCorrection,
              typingCounts(in: focus) else {
            lastTypedKeyUptime = nil
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = lastTypedKeyUptime.map { Self.measuredMilliseconds(since: $0) }
        lastTypedKeyUptime = now
        stats.recordTyped(
            characters: event.characters.count,
            gapMilliseconds: gap.flatMap { $0 <= CotypingUsageHistory.maxTypingGapMilliseconds ? $0 : nil })
    }

    func typingCounts(in focus: CotypingFocus) -> Bool {
        guard let field = focus.field, !field.isSecure, !isMeetingRecordingActive() else { return false }
        let settings = settingsProvider()
        return CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID, focus: focus) == nil
    }

    func resetMeasurementState() {
        pendingKeystrokeUptime = nil
        shownSuggestion = nil
        lastTypedKeyUptime = nil
        pendingInsertionCheck = nil
        insertionCheckExpiryTask?.cancel()
        insertionCheckExpiryTask = nil
        acceptAwaitingNextKey = nil
    }

    private nonisolated static func measuredMilliseconds(since uptimeNanoseconds: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- uptimeNanoseconds) / 1_000_000)
    }
}
