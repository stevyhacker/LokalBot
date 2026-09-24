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
    @Published private(set) var liveTranscript = DictationLiveTranscript()
    @Published private(set) var livePreviewStatus = ""
    @Published private(set) var isLivePreviewWorking = false
    @Published private(set) var isLivePreviewEnabled = false
    @Published private(set) var captureStatus = ""
    @Published private(set) var modelPreparationStatus: String?
    @Published private(set) var modelPreparationProgress: Double?
    @Published private(set) var modelPreparationError: String?

    private let storageRoot: URL
    private let settingsProvider: () -> AppSettings
    private let makeTextEngine: (AppSettings) async throws -> TextEngine
    private let screenContextProvider:
        (DictationScreenTarget, [String]) async -> DictationScreenContext?
    private let canStart: () -> Bool
    private let onBusy: () -> Void
    private let onError: (String) -> Void
    private let onMicPermissionDenied: () -> Void
    private let focusSnapshotExecutor: DictationFocusSnapshotExecutor
    private let recorder = MicRecorder()
    private let inputMonitor = DictationInputMonitor()
    private let overlay = DictationOverlayController()
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
    private var pendingFinishSource: String?
    private var generation = 0

    init(
        storageRoot: URL,
        settingsProvider: @escaping () -> AppSettings,
        makeTextEngine: @escaping (AppSettings) async throws -> TextEngine,
        canStart: @escaping () -> Bool,
        onBusy: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onMicPermissionDenied: @escaping () -> Void = {},
        focusSnapshotExecutor: DictationFocusSnapshotExecutor = .shared,
        screenContextProvider: @escaping (
            DictationScreenTarget,
            [String]
        ) async -> DictationScreenContext? = { target, excludedApps in
            await DictationScreenContextCapture.shared.capture(
                target: target, excludedApps: excludedApps)
        }
    ) {
        self.storageRoot = storageRoot
        self.settingsProvider = settingsProvider
        self.makeTextEngine = makeTextEngine
        self.screenContextProvider = screenContextProvider
        self.canStart = canStart
        self.onBusy = onBusy
        self.onError = onError
        self.onMicPermissionDenied = onMicPermissionDenied
        self.focusSnapshotExecutor = focusSnapshotExecutor
        inputMonitor.triggerModeProvider = { [weak self] in
            self?.settingsProvider().dictationTriggerMode ?? .pushToTalk
        }
        inputMonitor.shortcutProvider = { .handyDefault }
        inputMonitor.onStart = { [weak self] in self?.start(source: "shortcut") }
        inputMonitor.onStop = { [weak self] in self?.finishRecordingAndTranscribe(source: "shortcut") }
        inputMonitor.onToggle = { [weak self] in self?.toggle(source: "shortcut") }
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

    var shouldShowLiveTranscriptPanel: Bool {
        isLivePreviewEnabled && state.isWorking
    }

    var shouldShowModelPreparation: Bool {
        Self.shouldShowModelPreparation(
            state: state,
            hasStatus: modelPreparationStatus != nil,
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

    func toggle(source: String = "ui") {
        if isStarting {
            invalidateStartingSession()
            return
        }
        switch state {
        case .idle:
            start(source: source)
        case .recording:
            finishRecordingAndTranscribe(source: source)
        case .transcribing, .composing:
            cancel()
        }
    }

    func start(source: String = "ui") {
        guard case .idle = state, startTask == nil else { return }
        guard canStart() else {
            onBusy()
            return
        }
        let startedAt = Date()
        generation += 1
        let session = generation
        startTaskGeneration = session
        isStarting = true
        var initialConfig = settingsProvider()
        if source == "rehearsal" { initialConfig.dictationOutputMode = .showInLokalBot }
        activeConfig = initialConfig
        let outputMode = initialConfig.dictationOutputMode
        let screenTarget = DictationScreenTarget.frontmost()
        let focusCaptureTask = Task { [focusSnapshotExecutor] in
            await focusSnapshotExecutor.capture()
        }
        discardScreenContext()
        if initialConfig.dictationIntent == .compose, initialConfig.dictationUseScreenContext, let screenTarget {
            let excludedApps = initialConfig.excludedAppList
            screenContextTask = Task { [screenContextProvider] in
                let capture = await focusCaptureTask.value
                guard DictationScreenPrivacy.allowsCapture(
                        focus: capture, target: screenTarget),
                      !Task.isCancelled else { return nil }
                return await screenContextProvider(screenTarget, excludedApps)
            }
        }
        deliveryTarget = nil
        pendingFinishSource = nil
        captureStatus = ""
        lastTranscript = nil
        lastComposedText = nil
        lastEngine = nil
        resetModelPreparation()
        resetLivePreview()
        refreshOverlay()
        let pendingMediaCleanup = mediaCleanupTask
        startTask = Task { [weak self] in
            guard let self else { return }
            var keepScreenContext = false
            defer {
                focusCaptureTask.cancel()
                if !keepScreenContext {
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
            let focusCapture = await focusCaptureTask.value
            let capturedDeliveryTarget = Self.deliveryTarget(
                for: outputMode, capture: focusCapture)
            // An earlier cancel may still be restoring the exact players it
            // paused. Finish that bounded transition before taking a new media
            // snapshot, otherwise its late resume could interrupt this capture.
            if let pendingMediaCleanup { await pendingMediaCleanup.value }
            guard self.generation == session, !Task.isCancelled else { return }
            self.deliveryTarget = capturedDeliveryTarget
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
                try await self.startRecorder(writingTo: audioURL)
                try Task.checkCancellation()
                guard self.generation == session else { throw CancellationError() }
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
                lokalbotLog("dictation recording started source=\(source)")
                if let pendingFinishSource = self.pendingFinishSource {
                    self.pendingFinishSource = nil
                    self.isStarting = false
                    self.finishRecordingAndTranscribe(source: pendingFinishSource)
                }
            } catch is CancellationError {
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
        deliveryTarget = nil
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
            onError("Dictation is paused while its speech model needs attention. Choose Retry in the dictation panel.")
            lokalbotLog(
                "dictation model preparation FAILED model=\(choice.rawValue): "
                    + error.localizedDescription)
            refreshOverlay()
            return
        }
        do {
            let transcript = try await transcribeSerialized(audioURL, config: config)
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
            if config.dictationIntent == .transcribe { contextTask?.cancel() }
            let prepared = try await DictationTextPreparation.prepare(
                speech: spokenText, settings: config,
                screenContext: { await contextTask?.value }, makeEngine: makeTextEngine)
            guard generation == session else { return }
            let text = prepared.text
            lastComposedText = text
            lastEngine = prepared.compositionModel.map { "\(transcript.engine) → \($0)" } ?? transcript.engine
            switch await deliver(
                text,
                mode: config.dictationOutputMode,
                generation: session
            ) {
            case .inserted, .copied, .displayed:
                break
            case .focusChanged:
                onError("Dictation finished after focus moved, so the text was copied to the clipboard instead of being inserted into another app.")
            case .failed:
                onError("Dictation finished, but LokalBot could not insert the text. It was copied to the clipboard.")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .cancelled:
                return
            }
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

    private enum DeliveryResult {
        case displayed
        case inserted
        case copied
        case focusChanged
        case failed
        case cancelled
    }

    private func deliver(
        _ text: String,
        mode: DictationOutputMode,
        generation session: Int
    ) async -> DeliveryResult {
        guard !Task.isCancelled, generation == session else { return .cancelled }
        switch mode {
        case .showInLokalBot:
            return .displayed
        case .pasteIntoFocusedApp:
            let targetMatches = await deliveryTargetMatchesCurrentFocus()
            guard !Task.isCancelled, generation == session else { return .cancelled }
            guard targetMatches else {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
                    ? .focusChanged : .failed
            }
            guard !Task.isCancelled, generation == session else { return .cancelled }
            return inserter.insertViaPaste(text) || inserter.insert(text) ? .inserted : .failed
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
        deliveryTarget = nil
        refreshOverlay()
    }

    nonisolated private static func deliveryTarget(
        for mode: DictationOutputMode,
        capture: DictationFocusCaptureResult
    ) -> DictationDeliveryTarget? {
        guard mode == .pasteIntoFocusedApp else { return nil }
        guard !capture.timedOut, let snapshot = capture.snapshot else { return nil }
        return DictationDeliveryTarget.captured(from: snapshot)
    }

    private func deliveryTargetMatchesCurrentFocus() async -> Bool {
        guard let deliveryTarget else { return false }
        let capture = await focusSnapshotExecutor.capture()
        guard !capture.timedOut, let snapshot = capture.snapshot else { return false }
        return deliveryTarget.matches(snapshot)
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
        deliveryTarget = nil
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
        modelPreparationError = nil
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

    private static func transcribe(_ audioURL: URL, config: AppSettings) async throws -> Transcript {
        guard let duration = AudioFileInspector.duration(at: audioURL),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw DictationError.noAudio
        }
        if let speech = await SpeechActivity.shared.speechSeconds(in: audioURL), speech < 0.5 {
            throw DictationError.noSpeech
        }
        return try await config.transcriptionEngine().transcribe(
            audio: audioURL,
            language: config.transcriptionLanguage.code,
            prompt: config.transcriptionPrompt)
    }

    private func transcribeSerialized(
        _ audioURL: URL,
        config: AppSettings
    ) async throws -> Transcript {
        let precedingTask = asrHandoffTask
        let result = DictationASRResultBox()
        let task = Task {
            if let precedingTask { await precedingTask.value }
            do {
                try Task.checkCancellation()
                result.store(.success(try await Self.transcribe(audioURL, config: config)))
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
        modelPreparationError = nil
        modelPreparationProgress = nil
        modelPreparationStatus = "Checking the selected speech model…"
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
        tick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
                self?.refreshCaptureHealth()
            }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }

    private func refreshCaptureHealth() {
        guard case .recording = state else {
            captureStatus = ""
            return
        }
        let health = recorder.captureHealth()
        switch health.recoveryState {
        case .healthy:
            if health.isEngineRunning {
                captureStatus = ""
            } else {
                captureStatus = "Reconnecting microphone"
                do {
                    try recorder.restartCapture()
                } catch {
                    lokalbotLog(
                        "dictation microphone restart retrying after: "
                            + error.localizedDescription)
                }
            }
        case .recovering(let attempt):
            captureStatus = attempt == 0
                ? "Reconnecting microphone"
                : "Reconnecting microphone (\(attempt)/\(MicRecorder.maximumReconfigurationAttempts))"
        case .degraded(let errorDescription):
            captureStatus = ""
            lokalbotLog("dictation microphone recovery FAILED: \(errorDescription)")
            cancel()
            onError("Dictation stopped because the microphone could not recover: \(errorDescription)")
        }
    }

    private func refreshOverlay() {
        overlay.update(for: self, visible: settingsProvider().dictationShowOverlay)
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
