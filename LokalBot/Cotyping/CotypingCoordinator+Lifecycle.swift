import AppKit
import CoreGraphics
import Foundation

extension CotypingCoordinator {
    func applySettings() {
        let settings = settingsProvider()
        let privacySettings = CotypingPrivacySettings(
            settings: settings,
            selfBundleID: selfBundleID)
        let privacySettingsChanged = appliedPrivacySettings != privacySettings
        appliedPrivacySettings = privacySettings
        CotypingAXHelper.configureVisibleContextPolicy(privacySettings.visibleContextPolicy)
        CotypingAXHelper.configureChromiumEnhancedAccessibility(settings.cotypingChromiumEnhancedAccessibility)
        let appReadPolicyChanged = CotypingAXHelper.configureAppReadPolicy(
            privacySettings.appReadPolicy)
        let shouldRefreshFocus = isRunning
            && (privacySettingsChanged || appReadPolicyChanged)
        if privacySettingsChanged || appReadPolicyChanged {
            contextEpoch &+= 1
            cancelPendingGenerationWork()
            acceptedSuggestionBatch.discardLearningRecord()
            clearSuggestion()
            activeMemoryContext = .empty
            memoryLookup.reset()
            activeVisibleContext = nil
            memoryContextSources = []
            memoryContextSearched = false
            suggestionAnchorCache.removeAll()
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
            focusTracker.stop()
            focusTracker.start()
        }
        start()
    }

    func forgetLearnedText() async throws {
        contextEpoch &+= 1
        cancelPendingGenerationWork()
        acceptedSuggestionBatch.discardLearningRecord()
        clearSuggestion()
        suggestionAnchorCache = CotypingSuggestionAnchorCache()
        activeSuggestionRequestFingerprint = nil
        lastSuggestion = nil
        lastAcceptedTail = nil
        try await learningStore.forgetAll()
    }

    func invalidateMemoryContext() {
        contextEpoch &+= 1
        memoryLookup.reset()
        guard CotypingMemoryContext.Policy(settings: settingsProvider()).enabled
                || !activeMemoryContext.selection.items.isEmpty else { return }
        cancelPendingGenerationWork()
        acceptedSuggestionBatch.discardLearningRecord()
        clearSuggestion()
        suggestionAnchorCache.removeAll()
        activeSuggestionRequestFingerprint = nil
        activeMemoryContext = .empty
        activeVisibleContext = nil
        memoryContextSources = []
        memoryContextSearched = false
        lastSuggestion = nil
        lastAcceptedTail = nil
        if !isDisabledState { state = .idle }
    }

    @discardableResult
    func discardRevokedMemoryContext() -> Bool {
        guard !activeMemoryContext.isCurrent(settings: settingsProvider()) else { return false }
        invalidateMemoryContext()
        return true
    }

    private func start() {
        guard !isRunning else { return }
        wireIfNeeded()
        guard inputMonitor.start() else {
            state = .disabled("Input Monitoring permission needed.")
            return
        }
        focusTracker.start()
        CotypingWindowTextCapture.shared.setUpdateHandler { [weak self] in
            Task { @MainActor in self?.windowTextDidChange() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocusSoon() }
        }
        observeReturnToTheMac()
        isRunning = true
        state = .idle
    }

    func refreshFocusSoon() {
        guard isRunning else { return }
        focusRefreshTask?.cancel()
        focusRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            await self.focusTracker.refreshNow()
        }
    }

    func stop(reason: String? = nil) {
        contextEpoch &+= 1
        cancelPendingGenerationWork()
        clearSuggestion()
        focusRefreshTask?.cancel()
        focusRefreshTask = nil
        CotypingWindowTextCapture.shared.setUpdateHandler(nil)
        CotypingAXHelper.forgetVisibleContext()
        CotypingAXHelper.releaseChromiumEnhancedAccessibility()
        visualCaret.reset()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        stopObservingReturnToTheMac()
        focusTracker.stop()
        inputMonitor.stop()
        isRunning = false
        escapePause = nil
        resetMeasurementState()
        activeMemoryContext = .empty
        memoryLookup.reset()
        activeVisibleContext = nil
        memoryContextSources = []
        memoryContextSearched = false
        if let reason { state = .disabled(reason) } else { state = .idle }
    }

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
        inputMonitor.onPointerDown = { [weak self] in
            self?.warmModelAfterPause()
            self?.refreshFocusSoon()
        }
        inputMonitor.onAcceptKey = { [weak self] scope in self?.acceptFromTap(scope) ?? false }
        inputMonitor.onDismissKey = { [weak self] in self?.dismissFromTap() ?? false }
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
