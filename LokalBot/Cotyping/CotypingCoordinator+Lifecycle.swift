import CoreGraphics
import Foundation

/// Lifecycle entry points, settings reconciliation, and callback wiring.
extension CotypingCoordinator {
    // MARK: - Lifecycle

    /// Start or stop to match the current settings + permissions. Idempotent —
    /// call on launch and whenever the cotyping settings change.
    func applySettings() {
        let settings = settingsProvider()
        let privacySettings = CotypingPrivacySettings(
            settings: settings,
            selfBundleID: selfBundleID)
        let privacySettingsChanged = appliedPrivacySettings != privacySettings
        appliedPrivacySettings = privacySettings
        let appReadPolicyChanged = CotypingAXHelper.configureAppReadPolicy(
            privacySettings.appReadPolicy)
        let shouldRefreshFocus = isRunning
            && (privacySettingsChanged || appReadPolicyChanged)
        if privacySettingsChanged || appReadPolicyChanged {
            cancelPendingGenerationWork()
            acceptedSuggestionBatch.discardLearningRecord()
            clearSuggestion()
        }
        guard settings.cotypingEnabled else { stop(reason: "Cotyping is off."); return }
        guard CotypingAXHelper.isTrusted else {
            stop(reason: "Accessibility permission needed.")
            return
        }
        guard CGPreflightListenEventAccess() else {
            stop(reason: "Input Monitoring permission needed.")
            return
        }
        if shouldRefreshFocus {
            // Drop any field snapshot captured under the previous boundary and
            // invalidate an AX read that may still be in flight.
            focusTracker.stop()
            focusTracker.start()
        }
        start()
    }

    func forgetLearnedText() async throws {
        cancelPendingGenerationWork()
        acceptedSuggestionBatch.discardLearningRecord()
        clearSuggestion()
        suggestionAnchorCache = CotypingSuggestionAnchorCache()
        activeSuggestionRequestFingerprint = nil
        lastSuggestion = nil
        lastAcceptedTail = nil
        try await learningStore.forgetAll()
    }

    private func start() {
        guard !isRunning else { return }
        wireIfNeeded()
        guard inputMonitor.start() else {
            state = .disabled("Input Monitoring permission needed.")
            return
        }
        focusTracker.start()
        isRunning = true
        state = .idle
    }

    func stop(reason: String? = nil) {
        cancelPendingGenerationWork()
        clearSuggestion()
        focusTracker.stop()
        inputMonitor.stop()
        isRunning = false
        if let reason { state = .disabled(reason) } else { state = .idle }
    }

    /// Called by AppState when a meeting recording starts or stops. Pausing
    /// drops any live ghost text immediately; the per-generation gate in
    /// `generate(work:)` keeps new suggestions from appearing while active.
    func meetingRecordingStateChanged(active: Bool) {
        guard isRunning else { return }
        if active {
            cancelPendingGenerationWork()
            clearSuggestion()
        }
        if let next = CotypingMeetingPause.transition(recordingActive: active, current: state) {
            state = next
        }
    }

    private func wireIfNeeded() {
        guard !wired else { return }
        wired = true
        focusTracker.onChange = { [weak self] focus in self?.handleFocusChange(focus) }
        inputMonitor.onKey = { [weak self] event in self?.handleKey(event) }
        inputMonitor.onAcceptKey = { [weak self] scope in self?.acceptFromTap(scope) ?? false }
        inputMonitor.acceptGate = { [weak self] in
            guard let self else { return false }
            return CotypingAcceptanceOwnershipPolicy.shouldOwnAcceptKey(
                overlayIsVisible: self.overlay.isVisible,
                hasSession: self.session != nil)
        }
        inputMonitor.acceptKeyCodeProvider = { [weak self] in
            self?.settingsProvider().cotypingAcceptKey.keyCode ?? 48
        }
        inputMonitor.fullAcceptKeyCodeProvider = { [weak self] in
            self?.settingsProvider().cotypingFullAcceptKey.keyCode
        }
    }
}
