import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class DictationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(startedAt: Date)
        case composing(startedAt: Date)

        var isRecording: Bool {
            if case .recording = self { true } else { false }
        }

        var isWorking: Bool {
            switch self {
            case .idle: false
            case .recording, .transcribing, .composing: true
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Recording"
            case .transcribing: "Transcribing"
            case .composing: "Composing"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isStarting = false
    @Published private(set) var now = Date()
    @Published private(set) var isShortcutMonitoringActive = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastComposedText: String?
    @Published private(set) var lastEngine: String?
    @Published private(set) var lastContextUse: DictationContextUse?
    /// Pasted text that the target field did not show afterwards.
    @Published private(set) var deliveryNotice: DictationDeliveryNotice?
    private var insertionCheckTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    @Published private(set) var liveTranscript = DictationLiveTranscript()
    @Published private(set) var livePreviewStatus = ""
    @Published private(set) var isLivePreviewWorking = false
    @Published private(set) var isLivePreviewEnabled = false
    @Published private(set) var captureStatus = ""
    /// Whether the microphone delivered audio within the last second. The HUD
    /// waveform moves only while this is true, so it cannot look healthy while
    /// the microphone is reconnecting.
    @Published private(set) var isReceivingAudio = false
    /// The microphone has delivered audio in this recording. Until then the
    /// HUD shows that the microphone is still starting.
    @Published private(set) var hasMicrophoneAudio = false
    var audioLevelMeter: AudioLevelMeter { recorder.levelMeter }
    @Published private(set) var modelPreparationStatus: String?
    @Published private(set) var modelPreparationProgress: Double?
    @Published private(set) var modelPreparationError: String?
    /// A status-only preparation reaches the HUD once it outlasts a short
    /// grace period. A warm model's check ends at once and used to flash the
    /// preparation panel at the start of every transcription.
    private var modelPreparationOutlastedGrace = false
    private var modelPreparationGraceTask: Task<Void, Never>?
    private static let modelPreparationGracePeriod: Duration = .milliseconds(600)

    private let storageRoot: URL
    private let settingsProvider: () -> AppSettings
    private let makeTextEngine: (AppSettings) async throws -> TextEngine
    private let screenContextProvider:
        (DictationScreenTarget, DictationScreenCapturePolicy) async -> DictationScreenContext?
    private let memoryContextProvider: (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot
    private let canStart: () -> Bool
    private let onBusy: () -> Void
    private let onError: (String) -> Void
    private let onMicPermissionDenied: () -> Void
    private let focusSnapshotExecutor: DictationFocusSnapshotExecutor
    private let recorder: MicRecorder
    private let inputMonitor = DictationInputMonitor()
    private let overlay: DictationOverlayController
    private let settingsStore: SettingsStore
    private lazy var inserter = CotypingInserter()
    private var tick: AnyCancellable?
    private var prewarmTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var startTaskGeneration: Int?
    private var livePreviewTask: Task<Void, Never>?
    /// Every preview and authoritative pass joins this chain. A cancelled
    /// decoder that does not cooperate immediately therefore remains owned and
    /// cannot overlap the shared model runtime with the next dictation.
    private var asrHandoffTask: Task<Void, Never>?
    private var livePreviewTaskID = 0
    private var transcribeTask: Task<Void, Never>?
    private var screenContextTask: Task<DictationScreenContext?, Never>?
    private var mediaCleanupTask: Task<Void, Never>?
    private var mediaCleanupGeneration = 0
    private struct PendingTranscriptionRetry {
        var audioURL: URL
        var startedAt: Date
        var source: String
        var generation: Int
    }
    private var pendingTranscriptionRetry: PendingTranscriptionRetry?
    private var pendingAudioHandoff: DictationAudioHandoff?
    private var activeAudioURL: URL?
    private var pausedMediaSession: MediaPlaybackController.PauseSession?
    private var deliveryTarget: DictationDeliveryTarget?
    /// Why no delivery target exists, when paste mode could not bind one.
    private var deliveryTargetIssue: DictationDeliveryCheck?
    private var deliveryTargetRetryTask: Task<Void, Never>?
    private var contextTarget: DictationScreenTarget?
    private var pendingFinishSource: String?
    private var generation = 0
    /// The session a push-to-talk shortcut actually started. The shortcut can
    /// be held while an earlier dictation is still transcribing; `start` then
    /// does nothing, and the shortcut must not cancel that earlier dictation.
    private var shortcutStartedGeneration: Int?
    /// When the latest start was requested, for the press-to-audio log.
    private var startPressedAt: Date?

    init(
        storageRoot: URL,
        settingsStore: SettingsStore,
        settingsProvider: @escaping () -> AppSettings,
        makeTextEngine: @escaping (AppSettings) async throws -> TextEngine,
        canStart: @escaping () -> Bool,
        onBusy: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onMicPermissionDenied: @escaping () -> Void = {},
        focusSnapshotExecutor: DictationFocusSnapshotExecutor = .shared,
        memoryContextProvider: @escaping (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot = { _, _ in .empty },
        screenContextProvider: @escaping (
            DictationScreenTarget,
            DictationScreenCapturePolicy
        ) async -> DictationScreenContext? = { target, policy in
            await DictationScreenContextCapture.shared.capture(
                target: target, policy: policy)
        }
    ) {
        self.storageRoot = storageRoot
        self.settingsStore = settingsStore
        self.recorder = MicRecorder(
            makeInput: { [settingsStore] in
                try MicRecorder.dictationInputFactory(settingsStore.current.dictationMicrophoneID)
            },
            flapPolicy: .dictation)
        self.overlay = DictationOverlayController(settingsStore: settingsStore)
        self.settingsProvider = settingsProvider
        self.makeTextEngine = makeTextEngine
        self.screenContextProvider = screenContextProvider
        self.memoryContextProvider = memoryContextProvider
        self.canStart = canStart
        self.onBusy = onBusy
        self.onError = onError
        self.onMicPermissionDenied = onMicPermissionDenied
        self.focusSnapshotExecutor = focusSnapshotExecutor
        inputMonitor.triggerModeProvider = { [weak self] in
            self?.settingsProvider().dictationTriggerMode ?? .pushToTalk
        }
        // Read on every key event, so go straight to the stored settings
        // rather than the dictation provider, which also builds vocabulary.
        inputMonitor.shortcutProvider = { [settingsStore] in settingsStore.current.dictationShortcut }
        inputMonitor.onStart = { [weak self] in self?.startFromShortcut() }
        inputMonitor.onStop = { [weak self] in self?.finishRecordingAndTranscribe(source: "shortcut") }
        inputMonitor.onToggle = { [weak self] in self?.toggle(source: "shortcut") }
        inputMonitor.onCancel = { [weak self] in self?.cancelShortcutStart() }
        inputMonitor.onEscape = { [weak self] in
            lokalbotLog("dictation cancelled with Esc")
            self?.cancel()
        }
        inputMonitor.isDictationActive = { [weak self] in
            guard let self else { return false }
            return self.isStarting || self.state.isRecording
        }
        Self.sweepOrphanedPreviewFiles(storageRoot: storageRoot)
    }

    var elapsed: TimeInterval {
        switch state {
        case .idle: return 0
        case .recording(let startedAt),
             .transcribing(let startedAt),
             .composing(let startedAt):
            return max(0, now.timeIntervalSince(startedAt))
        }
    }

    var timerLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var menuBarLabel: String {
        switch state {
        case .idle: return ""
        case .recording: return timerLabel
        case .transcribing, .composing: return "..."
        }
    }

    /// While the microphone starts, the settings captured at the press decide,
    /// so the HUD opens at the size recording keeps instead of growing from a
    /// pill into the transcript panel once audio flows.
    var shouldShowLiveTranscriptPanel: Bool {
        if isStarting, !state.isWorking, let activeConfig {
            return activeConfig.dictationShowOverlay && activeConfig.dictationLivePreview
        }
        return isLivePreviewEnabled && state.isWorking
    }

    var shouldShowModelPreparation: Bool {
        Self.shouldShowModelPreparation(
            state: state,
            hasStatus: modelPreparationStatus != nil && modelPreparationOutlastedGrace,
            hasProgress: modelPreparationProgress != nil,
            hasError: modelPreparationError != nil)
    }

    /// Whether the HUD surfaces model preparation. Preparation begins
    /// synchronously on every recording start, so `.recording` waits for
    /// real download progress (or a failure) — a warm model never flashes
    /// the panel — while `.transcribing` shows any status at all.
    static func shouldShowModelPreparation(
        state: State, hasStatus: Bool, hasProgress: Bool, hasError: Bool
    ) -> Bool {
        switch state {
        case .transcribing:
            return hasStatus || hasError
        case .recording:
            return hasProgress || hasError
        case .idle, .composing:
            return false
        }
    }

    var modelPreparationPresentation: ModelPreparationPresentation {
        if let modelPreparationError {
            return .init(
                state: .failed,
                title: "Dictation model needs attention",
                status: modelPreparationError,
                actionTitle: "Retry")
        }
        return .init(
            state: .preparing,
            title: "Preparing the dictation model",
            status: modelPreparationStatus ?? "Checking the selected speech model…",
            progress: modelPreparationProgress)
    }

    func applySettings() {
        let config = settingsProvider()
        if let activeConfig, !DictationGrounding.permissionsMatch(activeConfig, config) {
            discardScreenContext()
        }
        if config.dictationEnabled {
            isShortcutMonitoringActive = inputMonitor.start()
            if !isShortcutMonitoringActive {
                lokalbotLog("dictation shortcut monitor unavailable; Input Monitoring access may be missing")
            }
        } else {
            inputMonitor.stop(releasingHeldShortcut: true)
            isShortcutMonitoringActive = false
        }
        if case .recording = state, let activeAudioURL {
            if config.dictationShowOverlay, config.dictationLivePreview {
                if livePreviewTask == nil {
                    isLivePreviewEnabled = true
                    livePreviewStatus = "Listening"
                    startLivePreviewIfNeeded(
                        audioURL: activeAudioURL,
                        config: config,
                        generation: generation)
                }
            } else {
                cancelLivePreview(reset: true)
            }
        }
        refreshOverlay()
    }

    /// Lets Settings record a shortcut without the global one firing.
    func setShortcutRecording(_ recording: Bool) {
        inputMonitor.isSuspended = recording
    }

    func stop() {
        inputMonitor.stop()
        isShortcutMonitoringActive = false
        cancel()
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    private var activeConfig: AppSettings?

    /// Describe the same intent, context and models that the in-flight
    /// recording will use, even if the user edits Settings in another view.
    var presentedConfiguration: AppSettings {
        if isStarting || state.isWorking, let activeConfig { return activeConfig }
        return settingsProvider()
    }

    enum ToggleAction: Equatable {
        case start
        case finish
        case cancelStart
        case cancel
        case retryModelPreparation
        case ignore
    }

    /// The shortcut never cancels finished speech: in Toggle mode a second
    /// press while the text is being prepared (to start the next dictation, or
    /// because the HUD looked slow) used to delete the recording and the
    /// transcript. Push-to-talk already ignored it. While the speech model
    /// needs attention, the shortcut retries instead. Menu and on-screen
    /// controls keep their explicit Cancel.
    static func toggleAction(
        state: State,
        isStarting: Bool,
        hasPendingModelRetry: Bool,
        fromShortcut: Bool
    ) -> ToggleAction {
        if isStarting { return .cancelStart }
        switch state {
        case .idle:
            return .start
        case .recording:
            return .finish
        case .transcribing, .composing:
            guard fromShortcut else { return .cancel }
            return hasPendingModelRetry ? .retryModelPreparation : .ignore
        }
    }

    func toggle(source: String = "ui") {
        switch Self.toggleAction(
            state: state,
            isStarting: isStarting,
            hasPendingModelRetry: pendingTranscriptionRetry != nil,
            fromShortcut: source == "shortcut"
        ) {
        case .start:
            start(source: source)
        case .finish:
            finishRecordingAndTranscribe(source: source)
        case .cancelStart:
            invalidateStartingSession()
        case .cancel:
            cancel()
        case .retryModelPreparation:
            retryModelPreparation()
        case .ignore:
            lokalbotLog("dictation shortcut ignored while \(state.label.lowercased())")
        }
    }

    private func startFromShortcut() {
        let before = generation
        start(source: "shortcut")
        shortcutStartedGeneration = generation != before ? generation : nil
    }

    /// A modifier chord turned out to be another shortcut (⌃⌥ then T).
    private func cancelShortcutStart() {
        guard Self.shouldCancelShortcutStart(
            startedGeneration: shortcutStartedGeneration,
            currentGeneration: generation,
            isStarting: isStarting,
            isRecording: state.isRecording) else { return }
        shortcutStartedGeneration = nil
        cancel()
    }

    /// Only the recording this shortcut started, and only before it has been
    /// handed to transcription.
    nonisolated static func shouldCancelShortcutStart(
        startedGeneration: Int?,
        currentGeneration: Int,
        isStarting: Bool,
        isRecording: Bool
    ) -> Bool {
        guard let startedGeneration, startedGeneration == currentGeneration else { return false }
        return isStarting || isRecording
    }

    func start(source: String = "ui") {
        guard case .idle = state, !isStarting else { return }
        guard canStart() else {
            onBusy()
            return
        }
        insertionCheckTask?.cancel()
        insertionCheckTask = nil
        dismissDeliveryNotice()
        let startedAt = Date()
        startPressedAt = startedAt
        generation += 1
        let session = generation
        startTaskGeneration = session
        isStarting = true
        var initialConfig = settingsProvider()
        if source == "rehearsal" { initialConfig.dictationOutputMode = .showInLokalBot }
        activeConfig = initialConfig
        let outputMode = initialConfig.dictationOutputMode
        let screenTarget = DictationScreenTarget.frontmost()
        // One focus read, started at the shortcut. The microphone opens
        // alongside it; recording begins once it answers or its short deadline
        // passes, and a slow app's answer to the same read can still bind the
        // destination later. A fresh read during recording would bind
        // whichever app had focus by then.
        let fullFocusCapture = Task { [focusSnapshotExecutor] in
            await focusSnapshotExecutor.capture(
                deadlineMilliseconds: Self.deliveryCheckDeadlineMilliseconds)
        }
        let focusCaptureTask = Task {
            await Self.focusCapture(
                fullFocusCapture,
                within: .milliseconds(DictationFocusSnapshotExecutor.defaultDeadlineMilliseconds))
        }
        discardScreenContext()
        if initialConfig.dictationIntent == .compose, initialConfig.dictationUseScreenContext, let screenTarget {
            let policy = DictationScreenCapturePolicy(
                excludedApps: initialConfig.excludedAppList,
                excludedDomains: initialConfig.excludedScreenDomainList)
            screenContextTask = Task { [screenContextProvider] in
                let capture = await focusCaptureTask.value
                guard DictationScreenPrivacy.allowsCapture(
                        focus: capture, target: screenTarget),
                      !Task.isCancelled else { return nil }
                var boundTarget = screenTarget
                boundTarget.focusIdentityKey = capture.snapshot?.focusIdentityKey
                return await screenContextProvider(boundTarget, policy)
            }
        }
        deliveryTarget = nil
        deliveryTargetIssue = nil
        deliveryTargetRetryTask?.cancel()
        deliveryTargetRetryTask = nil
        contextTarget = nil
        pendingFinishSource = nil
        captureStatus = ""
        isReceivingAudio = false
        hasMicrophoneAudio = false
        lastTranscript = nil
        lastComposedText = nil
        lastEngine = nil
        lastContextUse = nil
        resetModelPreparation()
        resetLivePreview()
        refreshOverlay()
        let pendingMediaCleanup = mediaCleanupTask
        // A cancelled start keeps its task until its media pause and resume
        // finish. Queue behind it instead of ignoring the press: the shortcut
        // used to do nothing at all until that cleanup ended.
        let cancelledStartTask = startTask
        startTask = Task { [weak self] in
            if let cancelledStartTask { await cancelledStartTask.value }
            guard let self else { return }
            var keepScreenContext = false
            defer {
                focusCaptureTask.cancel()
                // A newer start owns the screen-context task once it begins.
                if !keepScreenContext, self.startTaskGeneration == session {
                    self.discardScreenContext()
                }
                if self.startTaskGeneration == session {
                    self.startTask = nil
                    self.startTaskGeneration = nil
                    if self.isStarting {
                        self.isStarting = false
                        self.refreshOverlay()
                    }
                }
            }
            guard await MicRecorder.requestPermission() else {
                guard self.generation == session, !Task.isCancelled else { return }
                self.onMicPermissionDenied()
                return
            }
            // An earlier cancel may still be restoring the exact players it
            // paused. Finish that bounded transition before taking a new media
            // snapshot, otherwise its late resume could interrupt this capture.
            if let pendingMediaCleanup { await pendingMediaCleanup.value }
            guard self.generation == session, !Task.isCancelled else { return }
            var localMediaSession: MediaPlaybackController.PauseSession?
            var candidateAudioURL: URL?
            do {
                let audioURL = try self.nextAudioURL(startedAt: startedAt)
                candidateAudioURL = audioURL
                let pausedMedia = await MediaPlaybackController.pauseActiveMediaPlayers(
                    reason: "dictation")
                localMediaSession = pausedMedia
                if !pausedMedia.isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard self.generation == session, !Task.isCancelled else {
                    await MediaPlaybackController.resume(pausedMedia, reason: "cancelled dictation start")
                    return
                }
                self.recorder.onFirstAudio = { [weak self] in
                    self?.microphoneDidDeliverFirstAudio(generation: session)
                }
                // The microphone opens while the focus read begun at the press
                // finishes. Waiting for that read first delayed every start by
                // up to its deadline, and words spoken meanwhile were lost.
                try await self.startRecorder(writingTo: audioURL)
                let focusCapture = await focusCaptureTask.value
                try Task.checkCancellation()
                guard self.generation == session else { throw CancellationError() }
                self.deliveryTarget = Self.deliveryTarget(for: outputMode, capture: focusCapture)
                self.deliveryTargetIssue = outputMode == .pasteIntoFocusedApp
                    ? Self.deliveryTargetIssue(for: focusCapture) : nil
                if let screenTarget,
                   DictationScreenPrivacy.allowsCapture(focus: focusCapture, target: screenTarget) {
                    self.contextTarget = screenTarget
                    self.contextTarget?.focusIdentityKey = focusCapture.snapshot?.focusIdentityKey
                }
                self.pausedMediaSession = pausedMedia
                localMediaSession = nil
                self.activeAudioURL = audioURL
                self.state = .recording(startedAt: startedAt)
                keepScreenContext = true
                self.startTick()
                let config = self.settingsProvider()
                self.isLivePreviewEnabled = config.dictationShowOverlay && config.dictationLivePreview
                self.livePreviewStatus = self.isLivePreviewEnabled ? "Listening" : ""
                self.refreshOverlay()
                self.prewarmSelectedModel(reason: source)
                self.startLivePreviewIfNeeded(audioURL: audioURL, config: config, generation: session)
                if focusCapture.timedOut, outputMode == .pasteIntoFocusedApp {
                    self.bindLateDeliveryTarget(
                        fullFocusCapture,
                        pressedProcessID: screenTarget?.processID,
                        generation: session)
                }
                lokalbotLog("dictation recording started source=\(source)")
                if let pendingFinishSource = self.pendingFinishSource {
                    self.pendingFinishSource = nil
                    self.isStarting = false
                    self.finishRecordingAndTranscribe(source: pendingFinishSource)
                }
            } catch where error is CancellationError || self.generation != session {
                if let localMediaSession {
                    await MediaPlaybackController.resume(
                        localMediaSession, reason: "cancelled dictation start")
                } else {
                    await self.resumePausedMedia(reason: "cancelled dictation start")
                }
                self.recorder.stop()
                if let candidateAudioURL {
                    try? FileManager.default.removeItem(at: candidateAudioURL)
                }
                self.activeAudioURL = nil
            } catch {
                if let localMediaSession {
                    await MediaPlaybackController.resume(
                        localMediaSession, reason: "failed dictation start")
                } else {
                    await self.resumePausedMedia(reason: "failed dictation start")
                }
                let message = "Could not start dictation: \(error.localizedDescription)"
                self.onError(message)
                lokalbotLog("dictation start FAILED source=\(source): \(error.localizedDescription)")
                if let candidateAudioURL {
                    try? FileManager.default.removeItem(at: candidateAudioURL)
                }
                self.activeAudioURL = nil
                self.state = .idle
                self.stopTick()
                self.resetLivePreview()
                self.refreshOverlay()
            }
        }
    }

    func finishRecordingAndTranscribe(source: String = "ui") {
        if isStarting {
            // Push-to-talk key-up can arrive while permission, focus, or media
            // setup is still finishing. Remember the release instead of
            // cancelling the start and silently dropping the invocation.
            pendingFinishSource = source
            return
        }
        guard case .recording(let startedAt) = state, let audioURL = activeAudioURL else { return }
        let captureDuration = recorder.captureHealth().duration
        cancelLivePreview(reset: false)
        let mediaSession = pausedMediaSession
        pausedMediaSession = nil
        recorder.stop()
        activeAudioURL = nil
        stopTick()
        state = .transcribing(startedAt: startedAt)
        lokalbotLog(
            "dictation recording stopped source=\(source) duration="
                + String(format: "%.2f", captureDuration))
        if isLivePreviewEnabled {
            livePreviewStatus = "Finalizing"
        }
        refreshOverlay()
        generation += 1
        let session = generation
        let mediaCleanup = mediaSession.map {
            scheduleMediaResume($0, reason: "dictation capture finished")
        }
        transcribeTask?.cancel()
        pendingAudioHandoff?.discard()
        let handoff = DictationAudioHandoff(audioURL: audioURL)
        pendingAudioHandoff = handoff
        transcribeTask = Task { [weak self] in
            if let mediaCleanup { await mediaCleanup.value }
            guard !Task.isCancelled, let self, self.generation == session else {
                handoff.discard()
                return
            }
            guard let ownedURL = handoff.take() else { return }
            if self.pendingAudioHandoff === handoff { self.pendingAudioHandoff = nil }
            await self.transcribeAndDeliver(audioURL: ownedURL, startedAt: startedAt,
                                           source: source, generation: session)
        }
    }

    func cancel() {
        if isStarting {
            invalidateStartingSession()
            prewarmTask?.cancel()
            prewarmTask = nil
            return
        }
        generation += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        pendingAudioHandoff?.discard()
        pendingAudioHandoff = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        discardPendingTranscriptionRetry()
        resetModelPreparation()
        discardScreenContext()
        cancelLivePreview(reset: true)
        if case .recording = state {
            recorder.stop()
        }
        if let activeAudioURL {
            try? FileManager.default.removeItem(at: activeAudioURL)
        }
        activeAudioURL = nil
        state = .idle
        stopTick()
        clearDeliveryTarget()
        pendingFinishSource = nil
        captureStatus = ""
        let mediaSession = pausedMediaSession
        pausedMediaSession = nil
        refreshOverlay()
        if let mediaSession {
            scheduleMediaResume(mediaSession, reason: "cancelled dictation")
        }
        lokalbotLog("dictation cancelled")
    }

    private func transcribeAndDeliver(
        audioURL: URL,
        startedAt: Date,
        source: String,
        generation session: Int
    ) async {
        var preserveAudioForRetry = false
        defer {
            if !preserveAudioForRetry, !settingsProvider().dictationRetainAudio {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        let config = activeConfig ?? settingsProvider()
        let choice = config.transcriptionModel
        let engine = config.transcriptionEngine()
        beginModelPreparation()
        do {
            try await engine.prepare { [weak self] update in
                self?.receiveModelPreparation(update, generation: session)
            }
            try Task.checkCancellation()
            guard generation == session else { return }
            resetModelPreparation()
        } catch is CancellationError {
            guard generation == session else { return }
            complete()
            return
        } catch {
            guard generation == session else { return }
            preserveAudioForRetry = true
            pendingTranscriptionRetry = .init(
                audioURL: audioURL,
                startedAt: startedAt,
                source: source,
                generation: session)
            modelPreparationStatus = nil
            modelPreparationProgress = nil
            modelPreparationError = Self.modelPreparationFailureMessage
            onError(
                "Dictation is paused while its speech model needs attention. "
                    + "Choose Retry in the dictation panel or press "
                    + "\(settingsStore.current.dictationShortcut.displayLabel).")
            lokalbotLog(
                "dictation model preparation FAILED model=\(choice.rawValue): "
                    + error.localizedDescription)
            refreshOverlay()
            return
        }
        do {
            let transcript = try await transcribeSerialized(
                audioURL, config: config, retriesWithoutVocabulary: true)
            try Task.checkCancellation()
            guard generation == session else { return }

            let spokenText = Transcript.normalizedText(
                transcript.segments.map(\.displayText).joined(separator: " "))
            guard !spokenText.isEmpty else {
                completeWithMessage("No speech detected.")
                return
            }

            lastTranscript = spokenText
            if isLivePreviewEnabled {
                liveTranscript = .init(committed: spokenText, tentative: "")
            }
            if config.dictationIntent == .compose {
                state = .composing(startedAt: startedAt)
                if isLivePreviewEnabled { livePreviewStatus = "Composing" }
                refreshOverlay()
            }
            let contextTask = screenContextTask
            screenContextTask = nil
            if config.dictationIntent == .transcribe || !DictationGrounding.requestsContext(spokenText) { contextTask?.cancel() }
            let prepared = try await DictationTextPreparation.prepare(
                speech: spokenText, settings: config,
                screenContext: { await contextTask?.value },
                visibleContext: { [self] in
                    guard let contextTarget else { return nil }
                    return await DictationVisibleContextCapture.shared.capture(
                        target: contextTarget, policy: DictationGrounding.visiblePolicy(config))
                }, memoryContext: memoryContextProvider, currentSettings: settingsProvider,
                validateVisibleContext: { [self] expected in
                    guard let contextTarget else { return false }
                    return await DictationVisibleContextCapture.shared.capture(
                        target: contextTarget, policy: DictationGrounding.visiblePolicy(settingsProvider())) == expected
                }, validateScreenContext: { [self] context in
                    guard let contextTarget, let identity = context.identity else { return false }
                    let current = settingsProvider()
                    return await DictationScreenContextCapture.shared.contextStillMatches(
                        contextTarget, identity: identity, policy: .init(
                            excludedApps: current.excludedAppList, excludedDomains: current.excludedScreenDomainList))
                }, makeEngine: makeTextEngine)
            guard generation == session else { return }
            guard prepared.contextIsCurrent() else { throw DictationComposeError.contextChanged }
            let text = prepared.text
            lastEngine = prepared.compositionModel.map { "\(transcript.engine) → \($0)" } ?? transcript.engine
            lastContextUse = prepared.contextUse
            let delivery = await deliver(
                text,
                mode: config.dictationOutputMode,
                generation: session,
                contextIsCurrent: prepared.contextIsCurrent)
            // Delivery can wait for the target app; a newer session may own
            // the coordinator by the time it returns.
            guard generation == session else { return }
            let insertedInto = deliveryTarget
            switch delivery {
            case .inserted:
                if let insertedInto { checkInsertion(of: text, into: insertedInto, excludedApps: config.excludedAppList) }
            case .copied, .displayed:
                break
            case .notDelivered(let check):
                onError(check.clipboardMessage ?? "")
            case .unconfirmed:
                onError("LokalBot could not confirm that the app accepted the paste, so the text was left on the clipboard.")
            case .failed:
                onError("Dictation finished, but LokalBot could not insert the text. It was copied to the clipboard.")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .cancelled:
                if generation == session, !prepared.contextIsCurrent() {
                    throw DictationComposeError.contextChanged
                }
                return
            }
            lastComposedText = text
            complete()
            lokalbotLog(
                "dictation composed source=\(source) chars=\(text.count) "
                    + "asr=\(transcript.engine) intent=\(config.dictationIntent.rawValue)")
        } catch is CancellationError {
            guard generation == session else { return }
            complete()
        } catch {
            guard generation == session else { return }
            let prefix: String
            if case .composing = state {
                prefix = "Could not compose dictation"
            } else {
                prefix = "Dictation failed"
            }
            completeWithMessage("\(prefix): \(error.localizedDescription)")
        }
    }

    /// The paste waits up to 1.5 s for the app to read the text. If the
    /// dictation was cancelled meanwhile (and another may already be
    /// recording), report it as cancelled so nothing touches the new session,
    /// and never type the fallback.
    static func pasteDeliveryResult(
        _ outcome: CotypingInserter.PasteOutcome,
        sessionIsCurrent: Bool,
        typeFallback: () -> Bool
    ) -> DeliveryResult {
        guard sessionIsCurrent else { return .cancelled }
        switch outcome {
        case .pasted:
            return .inserted
        case .unconfirmed:
            return .unconfirmed
        case .failed:
            return typeFallback() ? .inserted : .failed
        case .skipped:
            // Not pasted while this dictation is still current: copy it so
            // the session completes instead of waiting forever.
            return .failed
        }
    }

    enum DeliveryResult: Equatable {
        case displayed
        case inserted
        case copied
        /// Copied to the clipboard instead of pasted, for this reason.
        case notDelivered(DictationDeliveryCheck)
        /// Pasted, but no app read the text; it stays on the clipboard.
        case unconfirmed
        case failed
        case cancelled
    }

    private func deliver(
        _ text: String,
        mode: DictationOutputMode,
        generation session: Int,
        contextIsCurrent: () -> Bool = { true }
    ) async -> DeliveryResult {
        guard !Task.isCancelled, generation == session, contextIsCurrent() else { return .cancelled }
        switch mode {
        case .showInLokalBot:
            return .displayed
        case .pasteIntoFocusedApp:
            let check = await deliveryTargetCheck()
            guard !Task.isCancelled, generation == session, contextIsCurrent() else { return .cancelled }
            guard check == .deliverable else {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
                    ? .notDelivered(check) : .failed
            }
            guard !Task.isCancelled, generation == session else { return .cancelled }
            var queuedCheck: DictationDeliveryCheck?
            let outcome = await inserter.insertViaPaste(text) { [weak self] in
                // An earlier paste held the queue; check the field again.
                guard let self, self.generation == session else { return false }
                let check = await self.deliveryTargetCheck()
                queuedCheck = check
                return check == .deliverable && self.generation == session
            }
            let sessionIsCurrent = !Task.isCancelled && generation == session
            if outcome == .skipped, sessionIsCurrent, let queuedCheck, queuedCheck != .deliverable {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
                    ? .notDelivered(queuedCheck) : .failed
            }
            return Self.pasteDeliveryResult(
                outcome,
                sessionIsCurrent: sessionIsCurrent,
                typeFallback: { inserter.typeInChunks(text) })
        case .copyToClipboard:
            guard !Task.isCancelled, generation == session else { return .cancelled }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string) ? .copied : .failed
        }
    }

    private func complete() {
        pendingTranscriptionRetry = nil
        resetModelPreparation()
        discardScreenContext()
        state = .idle
        stopTick()
        resetLivePreview()
        captureStatus = ""
        clearDeliveryTarget()
        refreshOverlay()
    }

    /// Reads the field back after a paste. Only a field that can be read and
    /// still lacks the text raises the notice; an unreadable field (many
    /// Electron and web editors) is left alone rather than guessed at.
    private func checkInsertion(
        of text: String, into target: DictationDeliveryTarget, excludedApps: [String]
    ) {
        insertionCheckTask?.cancel()
        // Without a field identity the paste went to "the app"; reading
        // whatever field is focused now could be another (or a secure) one.
        guard target.focusIdentityKey?.isEmpty == false else { return }
        let appName = NSRunningApplication(processIdentifier: target.processID)?.localizedName ?? ""
        guard !DictationScreenPrivacy.isExcluded(
            target: DictationScreenTarget(processID: target.processID, appName: appName, bundleID: target.bundleID),
            excludedApps: excludedApps) else { return }
        insertionCheckTask = Task { [weak self] in
            var waited = 0
            for delay in DictationInsertionCheck.readDelaysMilliseconds {
                try? await Task.sleep(for: .milliseconds(delay - waited))
                waited = delay
                guard !Task.isCancelled else { return }
                let before = await Self.readTextBeforeCaret(in: target)
                switch DictationInsertionCheck.verdict(textBeforeCaret: before, inserted: text) {
                case .landed, .unknown:
                    return
                case .missing:
                    continue
                }
            }
            guard !Task.isCancelled, let self else { return }
            lokalbotLog("dictation paste was not found in the target field")
            self.showDeliveryNotice(text)
        }
    }

    nonisolated private static func readTextBeforeCaret(in target: DictationDeliveryTarget) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CotypingAXHelper.dictationTextBeforeCaret(
                    processID: target.processID, focusIdentityKey: target.focusIdentityKey))
            }
        }
    }

    private func showDeliveryNotice(_ text: String) {
        guard !state.isWorking, !isStarting else { return }
        deliveryNotice = DictationDeliveryNotice(text: text)
        refreshOverlay()
        scheduleNoticeDismissal(after: .seconds(12))
    }

    func copyDeliveryNoticeText() {
        guard let notice = deliveryNotice else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notice.text, forType: .string)
        deliveryNotice?.copied = true
        scheduleNoticeDismissal(after: .seconds(2))
    }

    func dismissDeliveryNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        guard deliveryNotice != nil else { return }
        deliveryNotice = nil
        refreshOverlay()
    }

    private func scheduleNoticeDismissal(after delay: Duration) {
        noticeDismissTask?.cancel()
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissDeliveryNotice()
        }
    }

    private func clearDeliveryTarget() {
        deliveryTarget = nil
        deliveryTargetIssue = nil
        deliveryTargetRetryTask?.cancel()
        deliveryTargetRetryTask = nil
    }

    nonisolated private static func deliveryTarget(
        for mode: DictationOutputMode,
        capture: DictationFocusCaptureResult
    ) -> DictationDeliveryTarget? {
        guard mode == .pasteIntoFocusedApp else { return nil }
        guard !capture.timedOut, let snapshot = capture.snapshot else { return nil }
        return DictationDeliveryTarget.captured(from: snapshot)
    }

    /// Why paste mode has no target, from the snapshot taken at the shortcut.
    nonisolated static func deliveryTargetIssue(
        for capture: DictationFocusCaptureResult
    ) -> DictationDeliveryCheck? {
        guard !capture.timedOut, let snapshot = capture.snapshot else { return .fieldUnreadable }
        return snapshot.isSecureOrBlocked ? .secureField : nil
    }

    /// The paste check is not on the shortcut's critical path, so slow apps
    /// (Electron, Chromium) get longer to answer than the start snapshot.
    nonisolated static let deliveryCheckDeadlineMilliseconds = 600

    private func deliveryTargetCheck() async -> DictationDeliveryCheck {
        guard let deliveryTarget else { return deliveryTargetIssue ?? .fieldUnreadable }
        let capture = await focusSnapshotExecutor.capture(
            deadlineMilliseconds: Self.deliveryCheckDeadlineMilliseconds)
        guard !capture.timedOut, let snapshot = capture.snapshot else { return .fieldUnreadable }
        return deliveryTarget.check(snapshot)
    }

    /// The start snapshot has a short deadline so the microphone opens without
    /// delay. When it times out, wait for the same read rather than copying
    /// every dictation into a slow app to the clipboard.
    private func bindLateDeliveryTarget(
        _ fullCapture: Task<DictationFocusCaptureResult, Never>,
        pressedProcessID: pid_t?,
        generation session: Int
    ) {
        deliveryTargetRetryTask?.cancel()
        deliveryTargetRetryTask = Task { [weak self] in
            let capture = await fullCapture.value
            guard let self, !Task.isCancelled, self.generation == session,
                  self.state.isRecording, self.deliveryTarget == nil else { return }
            let binding = Self.lateDeliveryBinding(capture: capture, pressedProcessID: pressedProcessID)
            self.deliveryTarget = binding.target
            self.deliveryTargetIssue = binding.issue
            self.deliveryTargetRetryTask = nil
        }
    }

    /// The late answer to the shortcut's focus read, accepted only for the app
    /// that was frontmost when the shortcut was pressed.
    nonisolated static func lateDeliveryBinding(
        capture: DictationFocusCaptureResult,
        pressedProcessID: pid_t?
    ) -> (target: DictationDeliveryTarget?, issue: DictationDeliveryCheck?) {
        if let snapshot = capture.snapshot, !capture.timedOut,
           let pressedProcessID, snapshot.processID != pressedProcessID {
            return (nil, .focusMoved)
        }
        if pressedProcessID == nil { return (nil, .fieldUnreadable) }
        let target = deliveryTarget(for: .pasteIntoFocusedApp, capture: capture)
        return (target, target == nil ? deliveryTargetIssue(for: capture) ?? .fieldUnreadable : nil)
    }

    /// `capture`'s result if it arrives within `deadline`, otherwise a
    /// timeout; `capture` itself keeps running for a later reader.
    nonisolated static func focusCapture(
        _ capture: Task<DictationFocusCaptureResult, Never>,
        within deadline: Duration
    ) async -> DictationFocusCaptureResult {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await capture.value) }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(.timeout)
            }
        }
    }

    private func invalidateStartingSession() {
        generation += 1
        // Do not cancel an in-flight media pause: it is bounded, and allowing
        // it to return gives that task the exact resume token it needs. The
        // generation guard prevents the recorder from starting afterward. Keep
        // the task retained until that pause-and-resume cleanup finishes so a
        // new start cannot race ahead of its late media restoration.
        isStarting = false
        state = .idle
        stopTick()
        clearDeliveryTarget()
        pendingFinishSource = nil
        captureStatus = ""
        discardScreenContext()
        resetLivePreview()
        refreshOverlay()
        lokalbotLog("dictation start cancelled before capture")
    }

    private func discardScreenContext() {
        screenContextTask?.cancel()
        screenContextTask = nil
    }

    private func resumePausedMedia(reason: String) async {
        guard let pausedMediaSession else { return }
        self.pausedMediaSession = nil
        await MediaPlaybackController.resume(pausedMediaSession, reason: reason)
    }

    @discardableResult
    private func scheduleMediaResume(
        _ session: MediaPlaybackController.PauseSession,
        reason: String
    ) -> Task<Void, Never> {
        mediaCleanupGeneration += 1
        let cleanupGeneration = mediaCleanupGeneration
        let precedingCleanup = mediaCleanupTask
        let task = Task { [weak self] in
            if let precedingCleanup { await precedingCleanup.value }
            await MediaPlaybackController.resume(session, reason: reason)
            guard let self, self.mediaCleanupGeneration == cleanupGeneration else { return }
            self.mediaCleanupTask = nil
        }
        mediaCleanupTask = task
        return task
    }

    private func completeWithMessage(_ message: String) {
        lokalbotLog("dictation ended without delivery: \(message)")
        onError(message)
        complete()
    }

    func retryModelPreparation() {
        // Both paths begin preparation, which clears the error while the
        // panel is still showing it, so the panel stays up for the retry.
        if let pending = pendingTranscriptionRetry {
            pendingTranscriptionRetry = nil
            beginModelPreparation()
            transcribeTask?.cancel()
            transcribeTask = Task { [weak self] in
                await self?.transcribeAndDeliver(
                    audioURL: pending.audioURL,
                    startedAt: pending.startedAt,
                    source: pending.source,
                    generation: pending.generation)
            }
        } else {
            prewarmSelectedModel(reason: "retry")
        }
        refreshOverlay()
    }

    private static func transcribe(
        _ audioURL: URL,
        config: AppSettings,
        retriesWithoutVocabulary: Bool
    ) async throws -> Transcript {
        guard let duration = AudioFileInspector.duration(at: audioURL),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw DictationError.noAudio
        }
        let speech = await SpeechActivity.shared.speechSeconds(in: audioURL)
        if let speech, speech < 0.5 {
            throw DictationError.noSpeech
        }
        let engine = config.transcriptionEngine()
        let language = config.transcriptionLanguage.code
        let transcript = try await engine.transcribe(
            audio: audioURL, language: language, prompt: config.transcriptionPrompt)
        guard retriesWithoutVocabulary,
              shouldRetryWithoutVocabulary(
                transcript: transcript, prompt: config.transcriptionPrompt, speechSeconds: speech)
        else { return transcript }
        try Task.checkCancellation()
        lokalbotLog("dictation transcript was empty with a vocabulary hint; retrying without it")
        return try await engine.transcribe(audio: audioURL, language: language, prompt: nil)
    }

    /// The engines drop rows made only of vocabulary-hint terms, because a
    /// near-silent span decodes to the hint itself. A dictation can genuinely
    /// be only those words ("Mila Novak, Orion Launch"), and it then ended as
    /// "No speech detected". With clear speech, decode once more without the
    /// hint, which cannot echo anything.
    static func shouldRetryWithoutVocabulary(
        transcript: Transcript,
        prompt: String?,
        speechSeconds: TimeInterval?
    ) -> Bool {
        guard TranscriptionPrompt.normalized(prompt) != nil,
              let speechSeconds, speechSeconds >= 1 else { return false }
        return Transcript.normalizedText(
            transcript.segments.map(\.displayText).joined(separator: " ")).isEmpty
    }

    private func transcribeSerialized(
        _ audioURL: URL,
        config: AppSettings,
        retriesWithoutVocabulary: Bool = false
    ) async throws -> Transcript {
        let precedingTask = asrHandoffTask
        let result = DictationASRResultBox()
        let task = Task {
            if let precedingTask { await precedingTask.value }
            do {
                try Task.checkCancellation()
                result.store(.success(try await Self.transcribe(
                    audioURL, config: config, retriesWithoutVocabulary: retriesWithoutVocabulary)))
            } catch {
                result.store(.failure(error))
            }
        }
        asrHandoffTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return try result.resolve()
    }

    private func startLivePreviewIfNeeded(
        audioURL: URL,
        config: AppSettings,
        generation session: Int
    ) {
        guard config.dictationShowOverlay, config.dictationLivePreview else { return }
        livePreviewTaskID += 1
        let taskID = livePreviewTaskID
        livePreviewTask?.cancel()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.runLivePreviewLoop(
                audioURL: audioURL,
                config: config,
                generation: session,
                taskID: taskID)
        }
        livePreviewTask = task
    }

    private func runLivePreviewLoop(
        audioURL: URL,
        config: AppSettings,
        generation session: Int,
        taskID: Int
    ) async {
        defer {
            if generation == session, livePreviewTaskID == taskID {
                livePreviewTask = nil
                isLivePreviewWorking = false
            }
        }
        var lastPreviewedDuration: TimeInterval = 0
        var accumulatedPreviewText = ""
        do {
            try await Task.sleep(for: .milliseconds(1_200))
            while !Task.isCancelled {
                guard generation == session,
                      livePreviewTaskID == taskID,
                      state.isRecording else { return }
                let duration = recorder.captureHealth().duration
                let minimumAdvance = duration < 10 ? 1.25 : 2.0
                guard duration >= 1.25,
                      duration - lastPreviewedDuration >= minimumAdvance else {
                    try await Task.sleep(for: .milliseconds(450))
                    continue
                }

                do {
                    let window = try await Self.makeIncrementalLivePreviewWindow(
                        from: audioURL,
                        storageRoot: storageRoot,
                        previousEnd: lastPreviewedDuration)
                    defer { try? FileManager.default.removeItem(at: window.url) }
                    try Task.checkCancellation()
                    guard generation == session,
                          livePreviewTaskID == taskID,
                          state.isRecording else { return }

                    isLivePreviewWorking = true
                    livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Updating"
                    refreshOverlay()

                    do {
                        let transcript = try await transcribeSerialized(window.url, config: config)
                        try Task.checkCancellation()
                        guard generation == session, livePreviewTaskID == taskID else { return }
                        let text = Transcript.normalizedText(
                            transcript.segments.map(\.displayText).joined(separator: " "))
                        lastPreviewedDuration = window.endTime
                        if !text.isEmpty {
                            // While the overlap still reaches the recording's
                            // beginning, this window is the complete prefix and
                            // can replace the earlier preview outright.
                            accumulatedPreviewText = window.startTime == 0
                                ? text
                                : DictationPreviewTextStitcher.stitch(
                                    previous: accumulatedPreviewText,
                                    incoming: text)
                            liveTranscript = DictationLiveTranscript.preview(
                                from: accumulatedPreviewText)
                            livePreviewStatus = "Live"
                            refreshOverlay()
                        }
                    } catch DictationError.noAudio {
                        // A valid snapshot can still be a fraction shorter than
                        // the recorder's health counter. Advance past that tiny
                        // silent/short window rather than retrying it forever.
                        lastPreviewedDuration = window.endTime
                    } catch DictationError.noSpeech {
                        lastPreviewedDuration = window.endTime
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if generation == session, livePreviewTaskID == taskID {
                        livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Live"
                        lokalbotLog("dictation live preview skipped: \(error.localizedDescription)")
                    }
                }
                guard generation == session,
                      livePreviewTaskID == taskID,
                      state.isRecording else { return }
                isLivePreviewWorking = false
                refreshOverlay()
                try await Task.sleep(
                    for: .milliseconds(Int(Self.livePreviewInterval(after: duration) * 1_000)))
            }
        } catch is CancellationError {
            if generation == session, livePreviewTaskID == taskID {
                isLivePreviewWorking = false
            }
        } catch {
            if generation == session, livePreviewTaskID == taskID {
                isLivePreviewWorking = false
                lokalbotLog("dictation live preview stopped: \(error.localizedDescription)")
            }
        }
    }

    private func cancelLivePreview(reset: Bool) {
        livePreviewTaskID += 1
        livePreviewTask?.cancel()
        livePreviewTask = nil
        isLivePreviewWorking = false
        if reset {
            resetLivePreview()
        }
    }

    private func resetLivePreview() {
        liveTranscript = DictationLiveTranscript()
        livePreviewStatus = ""
        isLivePreviewWorking = false
        isLivePreviewEnabled = false
    }

    private static func livePreviewInterval(after duration: TimeInterval) -> TimeInterval {
        min(4.0, max(1.4, duration / 8.0))
    }

    nonisolated static let previewScratchDirectoryName = "dictation-previews"

    nonisolated static func sweepOrphanedPreviewFiles(storageRoot: URL) {
        try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true))
    }

    private struct IncrementalLivePreviewWindow: Sendable {
        let url: URL
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Opens the append-safe CAF at its current length and materializes only the
    /// unprocessed suffix plus a short overlap. This keeps preview I/O bounded
    /// as dictation grows instead of copying the full recording on every pass.
    private static func makeIncrementalLivePreviewWindow(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) async throws -> IncrementalLivePreviewWindow {
        try await Task.detached(priority: .userInitiated) {
            try makeIncrementalLivePreviewWindowSynchronously(
                from: audioURL,
                storageRoot: storageRoot,
                previousEnd: previousEnd)
        }.value
    }

    private nonisolated static func makeIncrementalLivePreviewWindowSynchronously(
        from audioURL: URL,
        storageRoot: URL,
        previousEnd: TimeInterval
    ) throws -> IncrementalLivePreviewWindow {
        let reader = try AVAudioFile(forReading: audioURL)
        let format = reader.processingFormat
        guard format.sampleRate > 0 else { throw DictationError.noAudio }
        let currentEnd = Double(reader.length) / format.sampleRate
        guard let range = DictationPreviewWindowPlanner.range(
            previousEnd: previousEnd,
            currentEnd: currentEnd) else {
            throw DictationError.noAudio
        }

        guard let frameBounds = DictationPreviewWindowPlanner.frameBounds(
            for: range,
            sampleRate: format.sampleRate,
            totalFrameCount: Int64(reader.length)) else {
            throw DictationError.noAudio
        }
        let startFrame = AVAudioFramePosition(frameBounds.lowerBound)
        let endFrame = AVAudioFramePosition(frameBounds.upperBound)

        let scratch = storageRoot.appendingPathComponent(
            previewScratchDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ext = audioURL.pathExtension.isEmpty ? "caf" : audioURL.pathExtension
        let windowURL = scratch.appendingPathComponent(
            "dictation-live-window-\(UUID().uuidString).\(ext)")
        var keepWindow = false
        defer {
            if !keepWindow { try? FileManager.default.removeItem(at: windowURL) }
        }

        reader.framePosition = startFrame
        do {
            let writer = try AVAudioFile(
                forWriting: windowURL,
                settings: reader.fileFormat.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            let bufferCapacity: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferCapacity) else {
                throw DictationError.noAudio
            }
            var remaining = endFrame - startFrame
            var written: AVAudioFramePosition = 0
            while remaining > 0 {
                let requested = AVAudioFrameCount(min(
                    remaining,
                    AVAudioFramePosition(bufferCapacity)))
                try reader.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
                let count = AVAudioFramePosition(buffer.frameLength)
                remaining -= count
                written += count
            }
            guard written > 0 else { throw DictationError.noAudio }
        }

        keepWindow = true
        return .init(url: windowURL, startTime: range.start, endTime: range.end)
    }

    private func startRecorder(writingTo audioURL: URL) async throws {
        recorder.stop()
        try? FileManager.default.removeItem(at: audioURL)
        do {
            try recorder.start(writingTo: audioURL)
        } catch {
            lokalbotLog("dictation recorder start retrying after: \(error.localizedDescription)")
            recorder.stop()
            try? FileManager.default.removeItem(at: audioURL)
            try await Task.sleep(for: .milliseconds(150))
            try recorder.start(writingTo: audioURL)
        }
    }

    private func prewarmSelectedModel(reason: String) {
        prewarmTask?.cancel()
        let config = settingsProvider()
        let choice = config.transcriptionModel
        let engine = config.transcriptionEngine()
        let session = generation
        beginModelPreparation()
        prewarmTask = Task { [weak self, choice, engine, reason, session] in
            guard let self else { return }
            do {
                try await engine.prepare { [weak self] update in
                    self?.receiveModelPreparation(update, generation: session)
                }
                guard self.generation == session, !Task.isCancelled else { return }
                self.resetModelPreparation()
                lokalbotLog("dictation prewarm ready model=\(choice.rawValue) reason=\(reason)")
            } catch is CancellationError {
            } catch {
                guard self.generation == session, !Task.isCancelled else { return }
                self.modelPreparationStatus = nil
                self.modelPreparationProgress = nil
                self.modelPreparationError = Self.modelPreparationFailureMessage
                self.onError(
                    "Could not prepare the dictation model. It will retry when recording ends.")
                self.refreshOverlay()
                lokalbotLog("dictation prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private static let modelPreparationFailureMessage =
        "Check your connection and free disk space, then try again."

    private func beginModelPreparation() {
        // A panel already on screen (a Retry, a slow load) stays up.
        let alreadyShown = shouldShowModelPreparation
        modelPreparationError = nil
        modelPreparationProgress = nil
        modelPreparationStatus = "Checking the selected speech model…"
        modelPreparationOutlastedGrace = alreadyShown
        modelPreparationGraceTask?.cancel()
        modelPreparationGraceTask = alreadyShown ? nil : Task { [weak self] in
            try? await Task.sleep(for: Self.modelPreparationGracePeriod)
            guard let self, !Task.isCancelled, self.modelPreparationStatus != nil else { return }
            self.modelPreparationOutlastedGrace = true
            self.refreshOverlay()
        }
        refreshOverlay()
    }

    private func receiveModelPreparation(
        _ update: ModelPreparationUpdate,
        generation session: Int
    ) {
        guard generation == session else { return }
        if update.status == "Ready" {
            resetModelPreparation()
            return
        }
        modelPreparationError = nil
        modelPreparationProgress = update.fractionCompleted
        modelPreparationStatus = update.status
        refreshOverlay()
    }

    private func resetModelPreparation() {
        modelPreparationStatus = nil
        modelPreparationProgress = nil
        modelPreparationError = nil
        modelPreparationOutlastedGrace = false
        modelPreparationGraceTask?.cancel()
        modelPreparationGraceTask = nil
    }

    private func discardPendingTranscriptionRetry() {
        guard let pending = pendingTranscriptionRetry else { return }
        pendingTranscriptionRetry = nil
        if !settingsProvider().dictationRetainAudio {
            try? FileManager.default.removeItem(at: pending.audioURL)
        }
    }

    private func nextAudioURL(startedAt: Date) throws -> URL {
        let dir = storageRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seconds = Int(startedAt.timeIntervalSince1970)
        return dir.appendingPathComponent("dictation-\(seconds)-\(UUID().uuidString).caf")
    }

    private func startTick() {
        now = Date()
        isReceivingAudio = false
        // Twice a second so the waveform follows the microphone closely.
        tick = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
                self?.refreshCaptureHealth()
            }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
        isReceivingAudio = false
        hasMicrophoneAudio = false
    }

    private func refreshCaptureHealth() {
        guard case .recording(let startedAt) = state else {
            captureStatus = ""
            isReceivingAudio = false
            return
        }
        let health = recorder.captureHealth()
        let current = Date()
        isReceivingAudio = Self.isReceivingAudio(lastAudioWriteAt: health.lastAudioWriteAt, now: current)
        let previousStatus = captureStatus
        defer {
            // The compact HUD widens to fit a status, so resize the panel.
            if captureStatus != previousStatus, state.isRecording { refreshOverlay() }
        }
        switch health.recoveryState {
        case .healthy:
            if health.isEngineRunning {
                captureStatus = Self.idleMicrophoneStatus(
                    lastAudioWriteAt: health.lastAudioWriteAt, startedAt: startedAt, now: current)
            } else {
                // Recover after the recorder's settle delay. Rebuilding here
                // ran on the main thread, raced the reconfiguration notice,
                // and blocked the keyboard shortcut while a device reopened.
                captureStatus = "Reconnecting microphone"
                recorder.recoverCapture(reason: "The microphone stopped.")
            }
        case .recovering(let attempt):
            captureStatus = attempt == 0
                ? "Reconnecting microphone"
                : "Reconnecting microphone (\(attempt)/\(MicRecorder.maximumReconfigurationAttempts))"
        case .degraded(let errorDescription):
            captureStatus = ""
            lokalbotLog("dictation microphone recovery FAILED: \(errorDescription)")
            if Self.shouldTranscribeAfterMicrophoneFailure(capturedDuration: health.duration) {
                // Keep what was said before the microphone failed.
                onError("The microphone stopped, so dictation ended early. \(errorDescription)")
                finishRecordingAndTranscribe(source: "microphone-failure")
            } else {
                cancel()
                onError("Dictation stopped because the microphone could not recover: \(errorDescription)")
            }
        }
    }

    /// The HUD switches from "starting" to recording, and the optional cue
    /// plays, only once audio actually arrives: pressing the shortcut does not
    /// mean the microphone is listening yet.
    private func microphoneDidDeliverFirstAudio(generation session: Int) {
        guard generation == session, state.isRecording || isStarting, !hasMicrophoneAudio else { return }
        hasMicrophoneAudio = true
        isReceivingAudio = true
        if settingsProvider().dictationPlaysStartSound {
            Self.startSound?.play()
        }
        let sincePress = startPressedAt.map { Int(Date().timeIntervalSince($0) * 1_000) }
        lokalbotLog("dictation microphone delivered first audio press_to_audio=\(sincePress.map(String.init) ?? "?")ms")
    }

    private static let startSound: NSSound? = {
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.35
        return sound
    }()

    nonisolated static func isReceivingAudio(lastAudioWriteAt: Date?, now: Date) -> Bool {
        guard let lastAudioWriteAt else { return false }
        return now.timeIntervalSince(lastAudioWriteAt) < 1
    }

    /// Status for a running microphone that is not delivering audio. A
    /// Bluetooth headset takes a moment to switch into headset mode.
    nonisolated static func idleMicrophoneStatus(
        lastAudioWriteAt: Date?, startedAt: Date, now: Date
    ) -> String {
        if let lastAudioWriteAt {
            return now.timeIntervalSince(lastAudioWriteAt) >= 2 ? "No audio from the microphone" : ""
        }
        return now.timeIntervalSince(startedAt) >= 2 ? "Waiting for the microphone" : ""
    }

    nonisolated static func shouldTranscribeAfterMicrophoneFailure(capturedDuration: TimeInterval) -> Bool {
        capturedDuration >= 1
    }

    private func refreshOverlay() {
        // The preparation-error panel holds the only Retry button, so it shows
        // even when the floating status is turned off.
        overlay.update(
            for: self,
            visible: settingsProvider().dictationShowOverlay || modelPreparationError != nil
                || deliveryNotice != nil)
    }
}

private final class DictationASRResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Transcript, Error>?

    func store(_ result: Result<Transcript, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func resolve() throws -> Transcript {
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}

private enum DictationError: LocalizedError {
    case noAudio
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noAudio: "Recording was too short to transcribe."
        case .noSpeech: "No speech detected."
        }
    }
}

/// Resumes a continuation exactly once, from whichever racer finishes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
