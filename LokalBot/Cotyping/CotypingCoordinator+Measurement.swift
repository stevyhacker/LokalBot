import Foundation

/// Local measurements of how autocomplete behaves while typing in other apps:
/// how long a suggestion takes to appear after the last keystroke, whether an
/// accepted suggestion arrived in the field, and whether it was taken straight
/// back. Counts and timings only; see `CotypingLiveMeasure`.
extension CotypingCoordinator {
    /// A deletion or undo this soon after an accept counts as correcting it.
    nonisolated static let correctionWindowMilliseconds = 5_000
    /// Longer waits are a suggestion restored later, not typing latency.
    nonisolated static let maxMeasuredVisibleMilliseconds = 10_000

    func surfaceKey(for field: CotypingField) -> String {
        CotypingSurfaceClassifier.classify(
            bundleID: field.bundleID,
            isIntegratedTerminal: field.isIntegratedTerminal).rawValue
    }

    /// A continuation became visible. Counts it for the statistics, and
    /// records the wait since the keystroke that asked for it, once per
    /// keystroke.
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

    /// An accept keypress posted `inserted` into `field`; `words` of the
    /// suggestion's text went with it.
    func noteAcceptance(field: CotypingField, inserted: String, charsAccepted: Int, words: Int = 0) {
        let surface = surfaceKey(for: field)
        let now = DispatchTime.now().uptimeNanoseconds
        stats.recordAccept(charsAccepted: charsAccepted, surface: surface)
        // The first accept from a suggestion makes it a used one. Without a
        // shown suggestion nothing is marked used, so the share used never
        // counts a suggestion it did not see.
        let shown = shownSuggestion
            ?? ShownSuggestion(surface: surface, model: settingsProvider().cotypingStatisticsModelID, used: true)
        stats.recordSuggestionAccept(
            words: words, characters: charsAccepted, firstOfSuggestion: !shown.used,
            surface: shown.surface, model: shown.model)
        shownSuggestion?.used = true
        lastTypedKeyUptime = nil
        acceptAwaitingNextKey = (shown.surface, shown.model, now)
        guard !inserted.isEmpty else { return }
        // `field` is a fresh read, so it can settle the previous accept first.
        resolveInsertionCheck(live: field)
        if pendingInsertionCheck != nil {
            // The app has not published the previous accept yet; check both together.
            pendingInsertionCheck?.extend(byInserting: inserted, at: now)
        } else {
            pendingInsertionCheck = CotypingInsertionCheck(
                field: field, inserted: inserted, surface: surface, startedUptimeNanoseconds: now)
        }
        scheduleInsertionCheckExpiry()
    }

    /// Compares the pending accept with what the host field now holds.
    /// `expired` treats the wait as over whatever the clock says.
    func resolveInsertionCheck(live: CotypingField?, expired: Bool = false) {
        guard let check = pendingInsertionCheck else { return }
        let elapsed = Self.measuredMilliseconds(since: check.startedUptimeNanoseconds)
        let outcome = check.outcome(
            live: live,
            elapsedMilliseconds: expired ? max(elapsed, CotypingInsertionCheck.timeoutMilliseconds) : elapsed)
        guard outcome != .pending else { return }
        closeInsertionCheck(as: outcome)
    }

    /// Counts the pending accept and drops the text held to compare it.
    private func closeInsertionCheck(as outcome: CotypingInsertionCheck.Outcome) {
        guard let check = pendingInsertionCheck else { return }
        pendingInsertionCheck = nil
        insertionCheckExpiryTask?.cancel()
        insertionCheckExpiryTask = nil
        stats.recordInsertion(outcome, count: check.count, surface: check.surface)
    }

    /// An app that ignores an insertion publishes nothing, and typing may stop
    /// there, so no key or focus change would ever close the check. This does,
    /// which also bounds how long the compared text is kept.
    private func scheduleInsertionCheckExpiry() {
        insertionCheckExpiryTask?.cancel()
        let delay = insertionCheckExpiryMilliseconds
        insertionCheckExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, self.pendingInsertionCheck != nil else { return }
            // One last read, so an app that published late is not counted as silent.
            let live = self.isRunning
                ? await self.focusTracker.refreshNow().field
                : self.focusTracker.focus.field
            guard !Task.isCancelled else { return }
            self.resolveInsertionCheck(live: live, expired: true)
        }
    }

    /// Every observed key, with the field as last read.
    func noteKey(_ event: CotypingInputEvent, live: CotypingField?) {
        noteKeyAfterAcceptance(event)
        noteTyping(event, in: focusTracker.focus)
        resolveInsertionCheck(live: live)
        // A key that takes text back or moves the caret changes what is before
        // the caret, so an accept that is still unread can no longer be read
        // back. Typing on leaves it readable: the inserted text is still there.
        switch event.kind {
        case .navigation, .shortcut:
            closeInsertionCheck(as: .unconfirmed)
        case .textMutation where event.isCorrection:
            closeInsertionCheck(as: .unconfirmed)
        case .acceptance, .fullAcceptance, .dismissal, .textMutation, .other:
            break
        }
    }

    /// The first key after an accept shows whether the accepted text was kept.
    func noteKeyAfterAcceptance(_ event: CotypingInputEvent) {
        guard let accepted = acceptAwaitingNextKey else { return }
        switch event.kind {
        case .acceptance, .fullAcceptance:
            // Another accept restarts the window itself.
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

    /// Counts characters you type yourself, and the short gaps between them
    /// for your typing speed, where autocomplete could suggest. Any other key
    /// breaks the run, so a deletion or an accept is not timed as typing.
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

    /// Whether autocomplete could suggest in `focus`, so typing there is part
    /// of the text it could have helped with. Password fields never count.
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
