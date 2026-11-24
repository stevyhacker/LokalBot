import Foundation
import AppKit
import Combine

struct SystemAudioSamePIDRetryBudget: Equatable {
    static let maximumAttempts = 2

    private(set) var attempts = 0

    var canRetry: Bool { attempts < Self.maximumAttempts }

    mutating func beginRetry() -> Bool {
        guard canRetry else { return false }
        recordRetry()
        return true
    }

    mutating func recordRetry() {
        attempts = min(attempts + 1, Self.maximumAttempts)
    }

    mutating func reset() {
        attempts = 0
    }
}

enum RecordingSystemAudioPolicy: Equatable {
    case microphoneOnly
    case meetingAppWhenAvailable

    func captureApp(
        detectedApp: MeetingDetector.DetectedApp?,
        fallback: () -> MeetingDetector.DetectedApp?
    ) -> MeetingDetector.DetectedApp? {
        switch self {
        case .microphoneOnly:
            return nil
        case .meetingAppWhenAvailable:
            return detectedApp ?? fallback()
        }
    }
}

enum RecordingSystemAudioSource: Equatable {
    case verified(MeetingDetector.DetectedApp)
    case held(MeetingDetector.DetectedApp)

    static let bindingAudibleDuration = MeetingDetector.nativeAudioMinimumConfirmationDuration

    static func find(for intent: Meeting.CaptureIntent) -> Self? {
        if let app = MeetingDetector.captureCandidateApp(
            expectedMeetingURL: intent.meetingURL, expectedBundleID: intent.appBundleID) {
            return .verified(app)
        }
        guard intent.appBundleID == nil, intent.meetingURL == nil,
              let app = MeetingDetector.alwaysOpenCaptureCandidate() else { return nil }
        return .held(app)
    }
}

enum SystemAudioRecoveryCandidatePolicy {
    static func shouldRetrySamePID(
        framesSinceAttach: Int64,
        audibleDuration: TimeInterval,
        minimumAudibleDuration: TimeInterval
    ) -> Bool {
        framesSinceAttach == 0 || audibleDuration < minimumAudibleDuration
    }
}

struct SystemAudioTapLedger: Equatable {
    private(set) var provenPID: pid_t?
    private(set) var retiredPIDs: Set<pid_t> = []
    private var audibleAtAttach: TimeInterval = 0

    mutating func attached(to pid: pid_t, audibleDuration: TimeInterval) {
        audibleAtAttach = audibleDuration
        retiredPIDs.remove(pid)
    }

    func hasProvedItself(audibleDuration: TimeInterval, minimum: TimeInterval) -> Bool {
        audibleDuration - audibleAtAttach >= minimum
    }

    mutating func observe(pid: pid_t, audibleDuration: TimeInterval, minimum: TimeInterval) {
        guard hasProvedItself(audibleDuration: audibleDuration, minimum: minimum) else { return }
        provenPID = pid
    }

    mutating func retire(_ pid: pid_t) {
        retiredPIDs.insert(pid)
        if provenPID == pid { provenPID = nil }
    }

    func silenceGrace(for pid: pid_t,
                      ordinary: TimeInterval,
                      proven: TimeInterval,
                      activelyEmittingAlternative: Bool = false) -> TimeInterval {
        activelyEmittingAlternative || pid != provenPID ? ordinary : proven
    }

    mutating func reset() { self = SystemAudioTapLedger() }
}

struct SilentSystemAudioWarningState: Equatable {
    private(set) var isPresented = false

    mutating func present() -> Bool {
        guard !isPresented else { return false }
        isPresented = true
        return true
    }

    mutating func withdraw() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        return true
    }
}

struct RecordingMemoryHealthSnapshot: Equatable, Sendable {
    var isRecording: Bool
    var microphoneStatus: String
    var microphoneLastWriteAt: Date?
    var microphoneDroppedBuffers: Int
    var systemAudioStatus: String
    var systemAudioLastWriteAt: Date?
    var systemAudioDroppedBuffers: Int
    var lastRecoveryAt: Date?
    var systemAudioLevel: Double?

    static let notAttachedStatus = "Not attached"

    var recordsMicrophoneOnly: Bool { isRecording && systemAudioStatus == Self.notAttachedStatus }

    static func recording(
        microphone: MicRecorder.CaptureHealth,
        system: SystemAudioRecorder.CaptureHealth,
        hasSystemTarget: Bool,
        lastRecoveryAt: Date?,
        at current: Date
    ) -> Self {
        let microphoneStatus: String = switch microphone.recoveryState {
        case .healthy:
            !microphone.isEngineRunning ? "Stopped"
                : microphone.lastAudioWriteAt == nil ? "Waiting for audio"
                : !isRecent(microphone.lastAudioWriteAt, at: current) ? "No recent audio"
                : isRecent(microphone.lastSignalAt, at: current) ? "Receiving audio" : "Receiving silence"
        case .recovering(let attempt): "Recovering (attempt \(attempt))"
        case .degraded(let description): "Degraded: \(description)"
        }
        let systemStatus: String
        if !hasSystemTarget {
            systemStatus = notAttachedStatus
        } else if system.lastAudioWriteAt == nil {
            systemStatus = "Waiting for audio"
        } else if !isRecent(system.lastAudioWriteAt, at: current) {
            systemStatus = "No recent audio"
        } else if !isRecent(system.lastAudibleWriteAt, at: current) {
            systemStatus = "Silent"
        } else {
            systemStatus = "Receiving audio"
        }
        return Self(
            isRecording: true,
            microphoneStatus: microphoneStatus,
            microphoneLastWriteAt: microphone.lastAudioWriteAt,
            microphoneDroppedBuffers: microphone.droppedBufferCount,
            systemAudioStatus: systemStatus,
            systemAudioLastWriteAt: system.lastAudioWriteAt,
            systemAudioDroppedBuffers: system.droppedBufferCount,
            lastRecoveryAt: lastRecoveryAt,
            systemAudioLevel: hasSystemTarget && system.lastAudioWriteAt.map {
                (0...1).contains(current.timeIntervalSince($0))
            } == true && system.lastRMSLevel.isFinite
                ? min(1, max(0, (20 * log10(max(Double(system.lastRMSLevel), 0.000001)) + 60) / 60)) : nil)
    }

    private static func isRecent(_ date: Date?, at current: Date) -> Bool {
        date.map { current.timeIntervalSince($0) <= 10 } ?? false
    }
}

@MainActor
final class RecordingController: ObservableObject {

    enum Status: Equatable {
        case idle
        case starting
        case recording(meetingID: UUID)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var currentMeeting: Meeting?
    @Published private(set) var captureWarnings: [String] = []
    @Published private(set) var callObservationUnavailable = false
    private var healthReport = RecordingHealthReport()
    private var captureNotifications = CaptureWarningNotifications()
    private var lastDiskCheckAt: Date?
    private var lastHealthReportAt: Date?
    private var diskWarning: String?
    private(set) var detectorSessionID: UUID?
    private(set) var startedByUser = false
    @Published private(set) var now = Date()
    private(set) var isSplittingForCalendarHandoff = false

    private let storage: StorageManager
    private let settingsStore: SettingsStore
    private let audioMonitor: AudioSourceMonitor
    private let pipeline: ProcessingPipeline
    private struct PendingFinalization {
        var meeting: Meeting
        var transcribe: Bool
        var summarize: Bool
        var metadataSaved = false
        var stopNotice: String?
    }
    private var pendingFinalizations: [UUID: PendingFinalization] = [:]
    static let silentSystemAudioMessage =
        "System audio capture is silent; LokalBot is keeping the microphone "
        + "recording and will reattach if the meeting audio process changes."
    private let onError: (String?) -> Void
    private let onMicPermissionDenied: () -> Void
    private let onMeetingFinished: (Meeting) -> Void
    private let isInteractive: () -> Bool

    private let micRecorder = MicRecorder()
    private let systemRecorder = SystemAudioRecorder()
    private var speakerAudioClock: RecordingAudioClock?
    private var audioTimeline: RecordingAudioTimeline?
    private var microphoneAudioClock: RecordingAudioClock?
    private var soundMeter: RecordingSoundMeter?
    private var silenceWatch: RecordingSilenceWatch?
    static let silenceStopNotice =
        "Recording stopped: no one spoke for \(Int(RecordingSilenceWatch.quietLimit / 60)) minutes"

    private struct SystemAudioTarget {
        var bundleID: String
        var pid: pid_t
        var hostPID: pid_t?
        var isHeld = false
    }
    private var systemAudioTarget: SystemAudioTarget?
    private var awaitsVerifiedSystemAudio: Bool { systemAudioTarget?.isHeld ?? true }
    private var recordingHealthWatchdog: AnyCancellable?
    private let healthSampler = RecordingHealthSampler()
    private var lastWatchdogCheckAt: Date?
    private var lastMicRestartAt: Date?
    private var didWarnAboutMicCaptureStall = false
    private var lastSystemAudioReattachAt: Date?
    private var silentSystemAudioWarning = SilentSystemAudioWarningState()
    private var samePIDSystemAudioRetryBudget = SystemAudioSamePIDRetryBudget()
    private var systemAudioTapLedger = SystemAudioTapLedger()
    private static let recordingHealthWatchdogInterval: TimeInterval = 1
    private static let micCaptureInitialGrace: TimeInterval = 5
    private static let micCaptureStallGrace: TimeInterval = 5
    private static let micCaptureRestartCooldown: TimeInterval = 10
    static let degradedMicRetryInterval: TimeInterval = 30
    private static let systemAudioInitialGrace: TimeInterval = 5
    private static let systemAudioSilentGrace: TimeInterval = 8
    private static let provenSystemAudioSilentGrace: TimeInterval = 90
    private static let systemAudioReattachCooldown: TimeInterval = 10
    private var lastCalendarEventID: String?
    private var lastCalendarEventEndedAt: Date?
    private static let calendarRepeatCooldown: TimeInterval = 5 * 60
    private static let automaticStartSources: Set<String> = [
        "detector", "audio-monitor",
    ]

    private var recordingTick: AnyCancellable?
    private var startTask: Task<Void, Never>?
    private var systemAudioHandoffTask: Task<Void, Never>?
    private let systemAudioRecovery = MeetingAudioRecovery()
    private var activeSystemAudioPolicy: RecordingSystemAudioPolicy?

    init(storage: StorageManager,
         settingsStore: SettingsStore,
         audioMonitor: AudioSourceMonitor,
         pipeline: ProcessingPipeline,
         isInteractive: @escaping () -> Bool,
         onError: @escaping (String?) -> Void,
         onMicPermissionDenied: @escaping () -> Void = {},
         onMeetingFinished: @escaping (Meeting) -> Void) {
        self.storage = storage
        self.settingsStore = settingsStore
        self.audioMonitor = audioMonitor
        self.pipeline = pipeline
        self.isInteractive = isInteractive
        self.onError = onError
        self.onMicPermissionDenied = onMicPermissionDenied
        self.onMeetingFinished = onMeetingFinished
        systemRecorder.onCapturedProcessTerminated = { [weak self] pid in
            self?.handleCapturedProcessTermination(pid)
        }
    }

    private var settings: AppSettings { settingsStore.current }

    var isRecording: Bool { if case .recording = status { true } else { false } }
    var isStarting: Bool { if case .starting = status { true } else { false } }
    var elapsed: TimeInterval {
        guard let m = currentMeeting else { return 0 }
        return max(0, now.timeIntervalSince(m.startedAt))
    }

    var menuBarTimer: String {
        let total = Int(elapsed)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    func memoryHealthSnapshot(at current: Date = Date()) -> RecordingMemoryHealthSnapshot {
        guard isRecording else {
            return RecordingMemoryHealthSnapshot(
                isRecording: false,
                microphoneStatus: "Idle",
                microphoneLastWriteAt: nil,
                microphoneDroppedBuffers: 0,
                systemAudioStatus: "Idle",
                systemAudioLastWriteAt: nil,
                systemAudioDroppedBuffers: 0,
                lastRecoveryAt: latestRecoveryDate)
        }
        guard let sample = healthSampler.latest else {
            return RecordingMemoryHealthSnapshot(
                isRecording: true, microphoneStatus: "Waiting for audio", microphoneLastWriteAt: nil,
                microphoneDroppedBuffers: 0,
                systemAudioStatus: systemAudioTarget == nil
                    ? RecordingMemoryHealthSnapshot.notAttachedStatus : "Waiting for audio",
                systemAudioLastWriteAt: nil, systemAudioDroppedBuffers: 0, lastRecoveryAt: latestRecoveryDate)
        }
        return RecordingMemoryHealthSnapshot.recording(
            microphone: sample.microphone,
            system: sample.system,
            hasSystemTarget: systemAudioTarget != nil,
            lastRecoveryAt: latestRecoveryDate,
            at: current)
    }

    private var latestRecoveryDate: Date? {
        switch (lastMicRestartAt, lastSystemAudioReattachAt) {
        case (.none, .none): nil
        case (.some(let mic), .none): mic
        case (.none, .some(let system)): system
        case (.some(let mic), .some(let system)): max(mic, system)
        }
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        let retryable = Array(pendingFinalizations.values)
        systemAudioRecovery.cancel()
        if isRecording || isStarting { stop(process: false, deferProcessing: true) }
        for pending in retryable { _ = persistFinalization(pending, deferProcessing: true) }
        return pendingFinalizations.isEmpty
    }

    func forgetFinalization(meetingIDs: Set<UUID>) {
        for id in meetingIDs { pendingFinalizations.removeValue(forKey: id) }
    }

    static func shouldSuppressCalendarRepeat(
        source: String,
        eventID: String?,
        lastEventID: String?,
        lastEndedAt: Date?,
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        automaticStartSources.contains(source)
            && MeetingMatcher.shouldSuppressRepeat(
                eventID: eventID,
                lastEventID: lastEventID,
                lastEndedAt: lastEndedAt,
                now: now,
                cooldown: cooldown)
    }

    func start(
        context: MeetingDetectionContext? = nil,
        source: String = "ui",
        systemAudioPolicy: RecordingSystemAudioPolicy
    ) {
        guard case .idle = status, startTask == nil else { return }
        let detectedApp = context?.detectedApp
        let calendarEvent = context?.calendarEvent
        if Self.shouldSuppressCalendarRepeat(
            source: source,
            eventID: calendarEvent?.externalID,
            lastEventID: lastCalendarEventID,
            lastEndedAt: lastCalendarEventEndedAt,
            now: Date(),
            cooldown: Self.calendarRepeatCooldown) {
            lokalbotLog("startRecording suppressed: calendar event \(calendarEvent?.externalID ?? "?") within cooldown")
            return
        }
        if let advisory = DiskSpacePrecheck.recordingAdvisory(
            availableBytes: DiskSpacePrecheck.availableBytes(at: storage.rootURL)) {
            lokalbotLog("startRecording refused: low disk space")
            onError(advisory)
            return
        }
        status = .starting
        detectorSessionID = context?.detectorSessionID
        startedByUser = !Self.automaticStartSources.contains(source)
        activeSystemAudioPolicy = systemAudioPolicy
        audioMonitor.isRecordingActive = true
        audioMonitor.accept()
        lokalbotLog("startRecording source=\(source) app=\(detectedApp?.name ?? "manual") calendar=\(calendarEvent?.title ?? "none")")
        startTask = Task { [weak self] in
            guard let self else { return }
            var created: Meeting?
            defer {
                self.startTask = nil
                if case .starting = self.status {
                    self.status = .idle
                    self.detectorSessionID = nil
                    self.activeSystemAudioPolicy = nil
                }
            }
            guard await MicRecorder.requestPermission() else {
                guard !Task.isCancelled else { return }
                onMicPermissionDenied()
                audioMonitor.isRecordingActive = false
                audioMonitor.reseed()
                return
            }
            do {
                try Task.checkCancellation()
                if ["detector", "audio-monitor", "notification"].contains(source),
                   let detectedApp, !(await detectedCallIsAvailable(detectedApp)) {
                    audioMonitor.isRecordingActive = false
                    audioMonitor.reseed()
                    onError("The detected call is no longer available. Start recording manually if needed.")
                    return
                }
                try Task.checkCancellation()
                let title = MeetingMatcher.recordingTitle(
                    calendarTitle: calendarEvent?.title,
                    useCalendarTitles: settings.useCalendarTitles,
                    appName: detectedApp?.name)
                var meeting = try storage.createMeetingFolder(title: title,
                                                              appName: detectedApp?.name ?? "Manual")
                created = meeting
                if let calendarEvent {
                    meeting.calendarProvider = calendarEvent.provider
                    meeting.calendarEventID = calendarEvent.externalID
                    meeting.calendarTitle = calendarEvent.title
                    meeting.scheduledStartAt = calendarEvent.startDate
                    meeting.scheduledEndAt = calendarEvent.endDate
                    meeting.meetingURL = calendarEvent.meetingURL
                    meeting.participantNameHints = calendarEvent.participantNames.isEmpty
                        ? nil
                        : calendarEvent.participantNames
                    let participants = calendarEvent.resolvedParticipantIdentities
                    meeting.calendarParticipantIdentities = participants.isEmpty
                        ? nil
                        : participants
                    if settings.useCalendarAgenda {
                        meeting.calendarAgenda = CalendarAgenda.sanitize(calendarEvent.agenda)
                    }
                    try? storage.saveMeta(meeting)
                }
                if let url = detectedApp?.meetingURL {
                    meeting.meetingURL = url
                    try storage.saveMeta(meeting)
                }
                meeting.captureIntent = .init(
                    systemAudioRequested: systemAudioPolicy == .meetingAppWhenAvailable,
                    appBundleID: detectedApp?.bundleID,
                    meetingURL: meeting.meetingURL.flatMap { url in
                        BrowserMeetingSession.roomURL(url.absoluteString).flatMap(URL.init(string:))
                    })
                try storage.saveMeta(meeting)
                healthReport = RecordingHealthReport()
                captureNotifications = CaptureWarningNotifications()
                captureWarnings = []
                callObservationUnavailable = false
                lastDiskCheckAt = nil
                lastHealthReportAt = nil
                stopRecordingHealthWatchdog()
                withdrawSilentSystemAudioWarning()
                diskWarning = nil
                created = meeting
                speakerAudioClock = RecordingAudioClock()
                microphoneAudioClock = RecordingAudioClock()
                let elapsedSinceCreation = max(0, Date().timeIntervalSince(meeting.startedAt))
                let timeline = RecordingAudioTimeline(
                    originHostTime: RecordingAudioClock.now - elapsedSinceCreation,
                    originInstant: ContinuousClock.now.advanced(by: .seconds(-elapsedSinceCreation)))
                audioTimeline = timeline
                systemRecorder.speakerAudioClock = speakerAudioClock
                micRecorder.speakerAudioClock = microphoneAudioClock
                let meter = RecordingSoundMeter()
                soundMeter = meter
                systemRecorder.soundMeter = meter
                micRecorder.soundMeter = meter
                silenceWatch = RecordingSilenceWatch(startedAt: Date())
                try Task.checkCancellation()
                try micRecorder.start(
                    writingTo: meeting.folderURL(in: storage).appendingPathComponent("mic.m4a"),
                    previewTee: meeting.folderURL(in: storage)
                        .appendingPathComponent(AudioPreviewTee.micFileName),
                    timeline: timeline)
                try Task.checkCancellation()

                var heldApp: MeetingDetector.DetectedApp?
                let captureApp = systemAudioPolicy.captureApp(
                    detectedApp: detectedApp,
                    fallback: {
                        switch meeting.captureIntent.flatMap(RecordingSystemAudioSource.find(for:)) {
                        case .verified(let app): return app
                        case .held(let app): heldApp = app; return nil
                        case nil: return nil
                        }
                    })
                if let captureApp {
                    _ = startSystemAudioCapture(captureApp, meeting: &meeting, detectedApp: detectedApp)
                } else if let heldApp {
                    _ = startSystemAudioCapture(heldApp, meeting: &meeting, detectedApp: nil, held: true)
                } else {
                    lokalbotLog(
                        "system audio capture pending detected=\(detectedApp != nil) "
                            + "expectedURL=\(calendarEvent?.meetingURL?.absoluteString ?? "none")")
                }
                try Task.checkCancellation()
                currentMeeting = meeting
                status = .recording(meetingID: meeting.id)
                updateCaptureWarnings()
                startRecordingHealthWatchdog()
                if systemAudioPolicy == .meetingAppWhenAvailable, awaitsVerifiedSystemAudio {
                    scheduleLateSystemAudioCapture(expectedMeetingURL: meeting.meetingURL)
                }
                startRecordingTick()
                if isInteractive() {
                    RecordingNotifier.shared.recordingStarted(title: meeting.title)
                }
            } catch is CancellationError {
                cleanupCancelledStart(created: created)
            } catch {
                onError("Could not start recording: \(error.localizedDescription)")
                lokalbotLog("startRecording FAILED: \(error.localizedDescription)")
                stopRecordingHealthWatchdog()
                systemAudioTarget = nil
                audioMonitor.isRecordingActive = false
                audioMonitor.reseed()
                micRecorder.stop()
                systemRecorder.stop()
                resetAudioClocks()
                preserveAudioFromInterruptedStart(created)
            }
        }
    }

    private func detectedCallIsAvailable(_ app: MeetingDetector.DetectedApp) async -> Bool {
        if app.usesMicrophoneDetection {
            if MeetingDetector.microphoneBrowsers.contains(app.bundleID) {
                guard settings.detectOtherBrowserCalls,
                      await BrowserMeetingSession.microphoneFallbackWindows(processIDs: [app.pid])[app.pid]?
                        .allowsStart == true
                else { return false }
            } else if MeetingDetector.knownApps[app.bundleID] == nil,
                      !settings.additionalCallBundleIDs.contains(app.bundleID.lowercased()) {
                return false
            }
            return MeetingDetector.microphoneIsActive(for: app)
        }
        guard MeetingDetector.documentCallHosts.contains(app.bundleID) else { return true }
        let host = CaptureEnvironment.current.workspace.runningApplications().first { $0.bundleIdentifier == app.bundleID }
        let session = host.flatMap {
            BrowserMeetingSession.snapshot(processID: $0.processIdentifier, expectedURL: app.meetingURL)
        }
        return session?.state == .inCall && session?.url == app.meetingURL
    }

    func stop(process: Bool = true, contentEndedAt: Date? = nil, deferProcessing: Bool = false,
              allowsAutomaticRestart: Bool = false, stopNotice: String? = nil) {
        if isStarting {
            startTask?.cancel()
            systemAudioRecovery.cancel()
            activeSystemAudioPolicy = nil
            status = .idle
            detectorSessionID = nil
            audioMonitor.isRecordingActive = false
            audioMonitor.reseed()
            return
        }
        guard isRecording, var meeting = currentMeeting else { return }
        systemAudioRecovery.cancel()
        systemAudioHandoffTask?.cancel()
        systemAudioHandoffTask = nil
        withdrawSilentSystemAudioWarningIfRecovered()
        updateCaptureWarnings()
        stopRecordingHealthWatchdog()
        micRecorder.stop()
        systemRecorder.stop()
        let timing = RecordingAudioTiming(version: 2,
                                          microphone: microphoneAudioClock?.archive() ?? [],
                                          system: speakerAudioClock?.archive() ?? [],
                                          timelineOriginHostTime: audioTimeline?.originHostTime)
        do {
            try JSONEncoder().encode(timing).write(to: meeting.folderURL(in: storage)
                .appendingPathComponent(RecordingAudioTiming.fileName), options: .atomic)
        } catch { lokalbotLog("Recording timing could not be saved: \(error.localizedDescription)") }
        resetAudioClocks()
        systemAudioTarget = nil
        activeSystemAudioPolicy = nil
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        stopRecordingTick()
        let endedAt = Date()
        healthReport.completedAt = endedAt
        do {
            try JSONEncoder().encode(healthReport).write(to: meeting.folderURL(in: storage)
                .appendingPathComponent(RecordingHealthReport.fileName), options: .atomic)
        } catch { onError("Audio retained, but the final capture-health report could not be saved.") }
        meeting.endedAt = endedAt
        let folder = meeting.folderURL(in: storage)
        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
        let micDuration = MeetingAudioFiles.duration(for: .mic, in: folder)
        let systemDuration = MeetingAudioFiles.duration(for: .system, in: folder)
        meeting.hasSystemTrack = MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil
        meeting.recordedDuration = [micDuration, systemDuration].compactMap { $0 }.max()
        if let contentEndedAt, let duration = meeting.recordedDuration {
            let end = min(duration, max(0, contentEndedAt.timeIntervalSince(meeting.startedAt)))
            if end > 0, meeting.contentRange == nil {
                meeting.contentRange = .init(start: 0, end: end)
                meeting.contentRangeSource = .confirmedCallEnd
            }
        }
        let wallDuration = endedAt.timeIntervalSince(meeting.startedAt)
        lokalbotLog(
            "recording stopped wall=\(String(format: "%.2fs", wallDuration)) recorded=\(String(format: "%.2fs", meeting.recordedDuration ?? 0)) mic=\(Self.formatAudioDuration(micDuration)) system=\(Self.formatAudioDuration(systemDuration)) hasSystem=\(meeting.hasSystemTrack)")
        if let recordedDuration = meeting.recordedDuration,
           wallDuration - recordedDuration > 60,
           recordedDuration < wallDuration * 0.8 {
            onError("Recording saved, but only \(meeting.durationLabel) of audio was captured from a \(Self.formatMinutes(wallDuration)) session.")
        }
        finalize(meeting, process: process, deferProcessing: deferProcessing, stopNotice: stopNotice)
        captureWarnings = []
        callObservationUnavailable = false
        if allowsAutomaticRestart { lastCalendarEventEndedAt = nil }
    }

    @discardableResult
    func joinDetectorSession(_ context: MeetingDetectionContext) -> Bool {
        guard isRecording, detectorSessionID == nil,
              let sessionID = context.detectorSessionID, let app = context.detectedApp,
              Self.recordsSameCall(capturedBundleID: systemAudioTarget?.bundleID,
                                   recordingURL: currentMeeting?.meetingURL, detected: app) else { return false }
        detectorSessionID = sessionID
        lokalbotLog("recording joined detector session app=\(app.bundleID)")
        return true
    }

    func considerDetectedSource(_ context: MeetingDetectionContext) {
        guard isRecording, let meeting = currentMeeting, let app = context.detectedApp else { return }
        guard meeting.captureIntent?.accepts(appBundleID: app.bundleID, meetingURL: app.meetingURL) == true else { return }
        if awaitsVerifiedSystemAudio {
            systemAudioRecovery.offer(app, recordingID: meeting.id)
        } else if let target = systemAudioTarget, target.hostPID != Self.hostPID(for: app.bundleID) {
            retargetSystemAudio(to: app)
        }
    }

    func updateCallObservation(sessionID: UUID, unavailable: Bool, lastVerifiedAt: Date?) {
        guard isRecording, detectorSessionID == sessionID else { return }
        callObservationUnavailable = unavailable
        healthReport.lastVerifiedCallAt = lastVerifiedAt
    }

    nonisolated static func recordsSameCall(capturedBundleID: String?, recordingURL: URL?,
                                            detected: MeetingDetector.DetectedApp) -> Bool {
        guard capturedBundleID == detected.bundleID else { return false }
        guard let recordingURL, let detectedURL = detected.meetingURL else { return true }
        let room = { (url: URL) in BrowserMeetingSession.roomURL(url.absoluteString) ?? url.absoluteString }
        return room(recordingURL) == room(detectedURL)
    }

    @discardableResult
    func finalize(_ meeting: Meeting, process: Bool, deferProcessing: Bool = false,
                  stopNotice: String? = nil) -> Bool {
        let endedAt = meeting.endedAt ?? Date()
        let pending = PendingFinalization(meeting: meeting,
            transcribe: (process || deferProcessing) && settings.autoTranscribe,
            summarize: settings.autoSummarize, stopNotice: stopNotice)
        pendingFinalizations[meeting.id] = pending
        lastCalendarEventID = meeting.calendarEventID
        lastCalendarEventEndedAt = endedAt
        currentMeeting = nil
        status = .idle
        detectorSessionID = nil
        let saved = persistFinalization(pending, deferProcessing: deferProcessing)
        onMeetingFinished(meeting)
        return saved
    }

    private func persistFinalization(_ pending: PendingFinalization, deferProcessing: Bool) -> Bool {
        var pending = pending
        if let current = currentMetadata(for: pending.meeting) {
            pending.meeting = Self.mergingFinalization(pending.meeting, into: current)
            pendingFinalizations[pending.meeting.id] = pending
        }
        let meeting = pending.meeting
        if !pending.metadataSaved {
            do {
                try storage.saveMeta(meeting)
                pending.metadataSaved = true
                pendingFinalizations[meeting.id] = pending
            } catch {
                onError("Capture stopped and audio was retained, but meeting details could not be saved: \(error.localizedDescription). Resolve the storage error, then retry quitting to save them.")
                return false
            }
        }
        if pending.transcribe {
            let queued: Bool
            if deferProcessing {
                queued = pipeline.deferUntilNextLaunch(
                    meeting,
                    summarize: pending.summarize)
            } else {
                let outcome = pipeline.enqueue(
                    meeting,
                    transcribe: true,
                    summarize: pending.summarize,
                    origin: .automatic)
                queued = outcome != .persistenceFailed && outcome != .revoked
            }
            guard queued else {
                onError("Recording saved, but its processing job could not be saved. Resolve the storage error, then retry quitting to keep automatic processing queued.")
                return false
            }
        }
        pendingFinalizations.removeValue(forKey: meeting.id)
        guard !deferProcessing else { return true }
        let willTranscribe = pending.transcribe
        let waitingForModels = willTranscribe
            && !ModelReadinessSnapshot.transcriptionReady(settings)
        if isInteractive() {
            let content = meeting.contentRange.flatMap { $0.isValid ? $0.end - $0.start : nil }
            RecordingNotifier.shared.recordingStopped(
                title: meeting.title,
                duration: content ?? meeting.recordedDuration
                    ?? meeting.endedAt?.timeIntervalSince(meeting.startedAt) ?? 0,
                willTranscribe: willTranscribe && !waitingForModels,
                waitingForModels: waitingForModels,
                headline: pending.stopNotice)
        }
        return true
    }

    private func currentMetadata(for meeting: Meeting) -> Meeting? {
        let url = meeting.folderURL(in: storage).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let current = try? decoder.decode(Meeting.self, from: data),
              current.id == meeting.id,
              current.relativePath == meeting.relativePath else { return nil }
        return current
    }

    static func mergingFinalization(_ finalized: Meeting, into current: Meeting) -> Meeting {
        guard finalized.id == current.id,
              finalized.relativePath == current.relativePath else { return finalized }
        var merged = current
        let wasInProgress = merged.endedAt == nil
        if wasInProgress {
            merged.endedAt = finalized.endedAt
            merged.hasSystemTrack = merged.hasSystemTrack || finalized.hasSystemTrack
            if merged.recordedDuration == nil { merged.recordedDuration = finalized.recordedDuration }
            if merged.contentRange == nil, merged.contentRangeSource != .userReviewed {
                merged.contentRange = finalized.contentRange
                merged.contentRangeSource = finalized.contentRangeSource
            }
            if merged.captureIntent == nil { merged.captureIntent = finalized.captureIntent }
        }
        return merged
    }

    func splitForCalendarHandoff(_ context: MeetingDetectionContext) {
        guard isRecording, !isStarting, let currentMeeting else { return }
        guard let nextEventID = context.calendarEvent?.externalID,
              MeetingMatcher.shouldSplitForCalendarHandoff(
                activeEventID: currentMeeting.calendarEventID,
                nextEventID: nextEventID) else {
            if let detectedApp = context.detectedApp {
                retargetSystemAudio(to: detectedApp)
            }
            return
        }
        lokalbotLog(
            "calendar handoff split old=\(currentMeeting.calendarEventID ?? "?") new=\(nextEventID)")
        isSplittingForCalendarHandoff = true
        defer { isSplittingForCalendarHandoff = false }
        stop()
        start(
            context: context,
            source: "calendar-handoff",
            systemAudioPolicy: .meetingAppWhenAvailable)
    }

    @discardableResult
    private func startSystemAudioCapture(
        _ captureApp: MeetingDetector.DetectedApp,
        meeting: inout Meeting,
        detectedApp: MeetingDetector.DetectedApp?,
        held: Bool = false
    ) -> Bool {
        if let intent = meeting.captureIntent,
           !intent.accepts(appBundleID: captureApp.bundleID, meetingURL: captureApp.meetingURL) { return false }
        let heldTarget = systemAudioTarget.flatMap { $0.isHeld ? $0 : nil }
        let captureProcess: AudioProcess?
        let pid: pid_t
        if let heldTarget, heldTarget.bundleID == captureApp.bundleID {
            captureProcess = nil
            pid = heldTarget.pid
        } else {
            captureProcess = MeetingDetector.currentCaptureTargetProcess(for: captureApp)
            pid = captureProcess?.id ?? captureApp.pid
        }
        let keepsTap = heldTarget?.pid == pid
        do {
            if let heldTarget {
                if !keepsTap { try systemRecorder.reattach(capturingPID: pid) }
            } else {
                try systemRecorder.start(
                    capturingPID: pid,
                    writingTo: meeting.folderURL(in: storage).appendingPathComponent("system.m4a"),
                    previewTee: meeting.folderURL(in: storage)
                        .appendingPathComponent(AudioPreviewTee.systemFileName),
                    timeline: audioTimeline)
            }
            meeting.hasSystemTrack = true
            if !held {
                meeting.captureIntent?.appBundleID = captureApp.bundleID
                meeting.captureIntent?.meetingURL = captureApp.meetingURL
            }
            systemAudioTarget = SystemAudioTarget(bundleID: captureApp.bundleID, pid: pid,
                hostPID: Self.hostPID(for: captureApp.bundleID), isHeld: held)
            if !keepsTap {
                systemAudioTapLedger.attached(
                    to: pid,
                    audibleDuration: heldTarget == nil ? 0 : systemRecorder.captureHealth().audibleDuration)
            }
            if !keepsTap, pid != captureApp.pid || captureProcess?.bundleID != captureApp.bundleID {
                lokalbotLog(
                    "system audio capture resolved detectedPID=\(captureApp.pid) capturePID=\(pid) "
                        + "captureBundle=\(captureProcess?.bundleID ?? "unknown") "
                        + "hostBundle=\(captureApp.bundleID)")
            }
            lokalbotLog(
                "system audio tap \(keepsTap ? "kept" : "started") pid=\(pid) bundle=\(captureApp.bundleID) "
                    + "detected=\(detectedApp != nil) fallback=\(detectedApp == nil) held=\(held) "
                    + "replacedHeldPID=\(heldTarget.map { String($0.pid) } ?? "none")")
            if let url = captureApp.meetingURL { meeting.meetingURL = url }
            do { try storage.saveMeta(meeting) } catch {
                onError("Audio capture started, but its source metadata could not be saved: \(error.localizedDescription)")
            }
            return true
        } catch {
            if detectedApp != nil {
                onError("System audio tap failed (\(error.localizedDescription)) — recording mic only.")
            }
            lokalbotLog(
                "system audio tap FAILED detected=\(detectedApp != nil): \(error.localizedDescription)")
            return false
        }
    }

    private func scheduleLateSystemAudioCapture(expectedMeetingURL: URL?) {
        guard activeSystemAudioPolicy == .meetingAppWhenAvailable,
              isRecording, let meeting = currentMeeting, awaitsVerifiedSystemAudio else { return }
        let intent = meeting.captureIntent ?? .init(
            systemAudioRequested: true, meetingURL: expectedMeetingURL)
        systemAudioRecovery.start(recordingID: meeting.id, intent: intent, find: { [weak self] intent in
            MeetingDetector.invalidateAudioProcessSnapshot()
            switch RecordingSystemAudioSource.find(for: intent) {
            case .verified(let app):
                return app
            case .held(let app):
                guard let self, self.currentMeeting?.id == meeting.id,
                      self.attachLateSystemAudio(app, held: true) else { return nil }
                self.updateCaptureWarnings()
                return nil
            case nil:
                return nil
            }
        }, attach: { [weak self] app in
            guard let self, self.currentMeeting?.id == meeting.id else { return false }
            let attached = self.attachLateSystemAudio(app)
            if attached { self.updateCaptureWarnings() }
            return attached
        })
    }

    @discardableResult
    private func attachLateSystemAudio(_ captureApp: MeetingDetector.DetectedApp, held: Bool = false) -> Bool {
        guard isRecording, held ? systemAudioTarget == nil : awaitsVerifiedSystemAudio,
              var meeting = currentMeeting else { return false }
        guard startSystemAudioCapture(captureApp, meeting: &meeting, detectedApp: nil, held: held) else { return false }
        currentMeeting = meeting
        return true
    }

    private func bindHeldSystemAudio(_ target: inout SystemAudioTarget, audible: TimeInterval) {
        guard target.isHeld, var meeting = currentMeeting else { return }
        target.isHeld = false
        systemAudioTarget = target
        systemAudioRecovery.cancel()
        meeting.captureIntent?.appBundleID = target.bundleID
        currentMeeting = meeting
        do { try storage.saveMeta(meeting) } catch {
            lokalbotLog("system audio binding could not be saved: \(error.localizedDescription)")
        }
        lokalbotLog(
            "system audio held tap bound pid=\(target.pid) bundle=\(target.bundleID) "
                + "audible=\(String(format: "%.2fs", audible))")
    }

    private func resetAudioClocks() {
        speakerAudioClock?.invalidate()
        microphoneAudioClock?.invalidate()
        speakerAudioClock = nil
        microphoneAudioClock = nil
        audioTimeline = nil
        systemRecorder.speakerAudioClock = nil
        micRecorder.speakerAudioClock = nil
        soundMeter = nil
        silenceWatch = nil
        systemRecorder.soundMeter = nil
        micRecorder.soundMeter = nil
    }

    private func cleanupCancelledStart(created: Meeting?) {
        detectorSessionID = nil
        systemAudioRecovery.cancel()
        stopRecordingHealthWatchdog()
        micRecorder.stop()
        systemRecorder.stop()
        resetAudioClocks()
        systemAudioTarget = nil
        activeSystemAudioPolicy = nil
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        preserveAudioFromInterruptedStart(created)
        lokalbotLog("recording start cancelled")
    }

    private func preserveAudioFromInterruptedStart(_ created: Meeting?) {
        guard var meeting = created else { return }
        let folder = meeting.folderURL(in: storage)
        guard let duration = MeetingAudioFiles.longestDuration(in: folder), duration > 0 else {
            let hasRecovery = MeetingAudioFiles.Track.allCases.contains {
                FileManager.default.fileExists(atPath: AudioRecoveryJournal.directory(
                    for: MeetingAudioFiles.recoveryURL(for: $0, in: folder)).path)
            }
            let hasAudioBytes = MeetingAudioFiles.Track.allCases.contains { track in
                [MeetingAudioFiles.primaryURL(for: track, in: folder),
                 MeetingAudioFiles.recoveryURL(for: track, in: folder)].contains { url in
                    ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
                }
            }
            if !hasRecovery && !hasAudioBytes {
                try? storage.deleteMeeting(meeting)
            } else {
                meeting.endedAt = Date()
                finalize(meeting, process: false)
            }
            return
        }
        meeting.endedAt = Date()
        meeting.recordedDuration = duration
        meeting.hasSystemTrack = MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil
        finalize(meeting, process: false)
    }

    private func startRecordingTick() {
        now = Date()
        recordingTick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
                self?.stopIfNobodyIsTalking(at: date)
            }
    }

    private func stopIfNobodyIsTalking(at date: Date) {
        guard isRecording, let meter = soundMeter, var watch = silenceWatch else { return }
        let quiet = watch.observe(soundSeconds: meter.soundSeconds, at: date)
        silenceWatch = watch
        guard quiet else { return }
        lokalbotLog("recording stopping: no one talking for "
            + "\(Int(date.timeIntervalSince(watch.lastActivityAt)))s, sound=\(Int(meter.soundSeconds))s")
        stop(contentEndedAt: watch.lastActivityAt, stopNotice: Self.silenceStopNotice)
    }

    private func stopRecordingTick() {
        recordingTick?.cancel()
        recordingTick = nil
    }

    private func startRecordingHealthWatchdog() {
        recordingHealthWatchdog = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sampleCaptureHealth() }
        sampleCaptureHealth()
    }

    private func sampleCaptureHealth() {
        guard isRecording, let meetingID = currentMeeting?.id else { return }
        healthSampler.request(
            microphone: { [micRecorder] in await micRecorder.captureHealthInBackground() },
            system: { [systemRecorder] in await systemRecorder.captureHealthInBackground() }
        ) { [weak self] sample in
            guard let self, self.isRecording, self.currentMeeting?.id == meetingID else { return }
            let time = Date()
            guard self.lastWatchdogCheckAt.map({ time.timeIntervalSince($0) >= Self.recordingHealthWatchdogInterval }) != false else { return }
            self.lastWatchdogCheckAt = time
            self.checkMicCapture(health: sample.microphone)
            self.checkSystemAudioCapture(health: sample.system)
            self.updateCaptureWarnings(mic: sample.microphone, system: sample.system)
        }
    }

    private func updateCaptureWarnings() {
        updateCaptureWarnings(mic: micRecorder.captureHealth(), system: systemRecorder.captureHealth())
    }

    private func updateCaptureWarnings(mic: MicRecorder.CaptureHealth, system: SystemAudioRecorder.CaptureHealth) {
        guard isRecording, let meeting = currentMeeting else { return }
        let time = Date()
        let elapsed = time.timeIntervalSince(meeting.startedAt)
        var messages = Self.captureWarnings(
            systemAudioRequested: activeSystemAudioPolicy == .meetingAppWhenAvailable,
            hasSystemTarget: systemAudioTarget != nil,
            microphoneLastWrite: mic.lastAudioWriteAt, systemLastWrite: system.lastAudioWriteAt,
            elapsed: elapsed, now: time)
        if elapsed >= 5, !messages.isEmpty { healthReport.hadMissingAudio = true }
        if mic.writeError != nil || system.writeError != nil { healthReport.hadWriteFailure = true }
        if RecordingHealthReport.dropsAreNoticeable(microphone: mic.droppedBufferCount,
                                                    system: system.droppedBufferCount) {
            messages.append(CaptureWarningNotifications.droppedBuffersWarning)
        }
        if callObservationUnavailable {
            messages.append(CaptureWarningNotifications.callStatusUnavailableWarning)
        }
        for (source, error) in [("Microphone", mic.writeError), ("System audio", system.writeError)] {
            if let error { messages.append("\(source) saving needs attention: \(error)") }
        }
        if lastDiskCheckAt.map({ time.timeIntervalSince($0) >= 15 }) != false {
            lastDiskCheckAt = time
            diskWarning = DiskSpacePrecheck.recordingAdvisory(
                availableBytes: DiskSpacePrecheck.availableBytes(at: storage.rootURL)) == nil ? nil
                : "Disk space is low. Free space now to keep saving this recording."
        }
        if let diskWarning { messages.append(diskWarning) }
        captureWarnings = messages
        if elapsed >= 5, isInteractive() {
            for message in captureNotifications.due(messages, elapsed: elapsed) {
                RecordingNotifier.shared.captureNeedsAttention(message)
            }
        }
        healthReport.microphoneDroppedBuffers = mic.droppedBufferCount
        healthReport.systemDroppedBuffers = system.droppedBufferCount
        healthReport.attachmentAttempts = max(healthReport.attachmentAttempts, systemAudioRecovery.attempts)
        let changed = healthReport.observe(messages, seconds: elapsed)
        if changed || lastHealthReportAt.map({ time.timeIntervalSince($0) >= 30 }) != false {
            do {
                try JSONEncoder().encode(healthReport).write(
                    to: meeting.folderURL(in: storage).appendingPathComponent(RecordingHealthReport.fileName),
                    options: .atomic)
                lastHealthReportAt = time
            } catch {
                captureWarnings.append("Recording health could not be saved. Check disk space.")
            }
        }
    }

    static func captureWarnings(systemAudioRequested: Bool, hasSystemTarget: Bool,
                                microphoneLastWrite: Date?, systemLastWrite: Date?,
                                elapsed: TimeInterval, now: Date) -> [String] {
        var warnings: [String] = []
        if systemAudioRequested, !hasSystemTarget {
            warnings.append("Looking for meeting audio; microphone only. Recovery is still active.")
        }
        if systemAudioRequested, hasSystemTarget, systemLastWrite == nil {
            warnings.append("Waiting for meeting audio to reach disk; microphone recording continues.")
        }
        guard elapsed >= 5 else { return warnings }
        if microphoneLastWrite.map({ now.timeIntervalSince($0) < 5 }) != true {
            warnings.append("Microphone audio is not arriving. Trying to recover it.")
        }
        if systemAudioRequested, hasSystemTarget,
           systemLastWrite.map({ now.timeIntervalSince($0) < 5 }) != true {
            warnings.append("Meeting audio is not arriving. Trying to recover it; the microphone continues.")
        }
        return warnings
    }

    private func stopRecordingHealthWatchdog() {
        recordingHealthWatchdog?.cancel()
        recordingHealthWatchdog = nil
        healthSampler.invalidate()
        lastWatchdogCheckAt = nil
        lastMicRestartAt = nil
        didWarnAboutMicCaptureStall = false
        lastSystemAudioReattachAt = nil
        samePIDSystemAudioRetryBudget.reset()
        systemAudioTapLedger.reset()
    }

    static func shouldRetryDegradedMicrophone(lastAttemptAt: Date?, now: Date) -> Bool {
        lastAttemptAt.map { now.timeIntervalSince($0) >= degradedMicRetryInterval } ?? true
    }

    private func checkMicCapture(health: MicRecorder.CaptureHealth) {
        guard isRecording, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.micCaptureInitialGrace else { return }

        switch health.recoveryState {
        case .healthy:
            if health.isEngineRunning { didWarnAboutMicCaptureStall = false }
        case .recovering:
            return
        case .degraded(let errorDescription):
            if !didWarnAboutMicCaptureStall {
                didWarnAboutMicCaptureStall = true
                onError(
                    "Microphone capture stopped (\(errorDescription)). LokalBot keeps trying to reconnect it; "
                        + "recording continues with system audio when available.")
            }
            guard Self.shouldRetryDegradedMicrophone(lastAttemptAt: lastMicRestartAt, now: now) else { return }
            lastMicRestartAt = now
            do {
                try micRecorder.restartCapture()
                lokalbotLog("mic recorder recovered after degradation elapsed=\(String(format: "%.2fs", elapsed))")
            } catch {
                lokalbotLog(
                    "mic recorder still unavailable elapsed=\(String(format: "%.2fs", elapsed)): \(error.localizedDescription)")
            }
            return
        }
        let captureLag = elapsed - health.duration
        let silentFor = now.timeIntervalSince(health.lastAudioWriteAt ?? meeting.startedAt)
        guard !health.isEngineRunning || silentFor >= Self.micCaptureStallGrace else { return }

        if let lastMicRestartAt,
           now.timeIntervalSince(lastMicRestartAt) < Self.micCaptureRestartCooldown {
            return
        }

        do {
            try micRecorder.restartCapture()
            lastMicRestartAt = now
            didWarnAboutMicCaptureStall = false
            lokalbotLog(
                "mic recorder restarted elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", health.duration)) lag=\(String(format: "%.2fs", captureLag)) silentFor=\(String(format: "%.2fs", silentFor)) engineRunning=\(health.isEngineRunning)")
        } catch {
            lastMicRestartAt = now
            lokalbotLog(
                "mic recorder restart deferred to bounded recovery elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", health.duration)) lag=\(String(format: "%.2fs", captureLag)): \(error.localizedDescription)")
        }
    }

    private func checkSystemAudioCapture(health: SystemAudioRecorder.CaptureHealth) {
        guard isRecording, var target = systemAudioTarget, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.systemAudioInitialGrace else { return }

        guard health.capturedPID == target.pid else { return }
        withdrawSilentSystemAudioWarningIfRecovered(health: health)
        systemAudioTapLedger.observe(pid: target.pid,
                                     audibleDuration: health.audibleDuration,
                                     minimum: AudioFileInspector.minimumTranscribableDuration)
        if target.isHeld, systemAudioTapLedger.hasProvedItself(
            audibleDuration: health.audibleDuration,
            minimum: RecordingSystemAudioSource.bindingAudibleDuration) {
            bindHeldSystemAudio(&target, audible: health.audibleDuration)
        }
        let noBuffers = health.lastAudioWriteAt.map { now.timeIntervalSince($0) >= 5 } ?? true
        let silentFor = noBuffers
            ? now.timeIntervalSince(health.lastAudioWriteAt ?? meeting.startedAt)
            : health.lastAudibleWriteAt.map { now.timeIntervalSince($0) } ?? elapsed
        guard silentFor >= (noBuffers ? 5 : Self.systemAudioSilentGrace) else { return }

        var emittingExclusions = systemAudioTapLedger.retiredPIDs
        emittingExclusions.insert(target.pid)
        let emittingAlternative = currentEmittingSystemAudioCandidate(
            for: target,
            excluding: emittingExclusions)
        let silenceGrace = systemAudioTapLedger.silenceGrace(
            for: target.pid,
            ordinary: Self.systemAudioSilentGrace,
            proven: Self.provenSystemAudioSilentGrace,
            activelyEmittingAlternative: emittingAlternative != nil)
        guard noBuffers || emittingAlternative != nil else { return }
        guard noBuffers || silentFor >= silenceGrace else { return }

        if let lastSystemAudioReattachAt,
           now.timeIntervalSince(lastSystemAudioReattachAt) < Self.systemAudioReattachCooldown {
            return
        }

        if health.framesSinceAttach == 0 {
            systemAudioTapLedger.retire(target.pid)
        }
        let alternativeCandidate = emittingAlternative ?? currentSystemAudioCandidate(
            for: target,
            excluding: systemAudioTapLedger.retiredPIDs)
        let candidate = alternativeCandidate
            ?? (systemAudioTapLedger.retiredPIDs.isEmpty
                ? nil
                : currentSystemAudioCandidate(for: target))
        guard let candidate else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
        }

        let shouldRetrySamePID = noBuffers || SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: health.framesSinceAttach,
            audibleDuration: health.audibleDuration,
            minimumAudibleDuration: AudioFileInspector.minimumTranscribableDuration)
        let isSamePIDRetry = candidate.id == target.pid && shouldRetrySamePID
        guard candidate.id != target.pid || shouldRetrySamePID else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
        }
        if isSamePIDRetry, !samePIDSystemAudioRetryBudget.beginRetry() {
            if noBuffers, lastSystemAudioReattachAt.map({ now.timeIntervalSince($0) >= 30 }) != false {
                samePIDSystemAudioRetryBudget.reset()
            } else {
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
            }
        }

        do {
            try systemRecorder.reattach(capturingPID: candidate.id)
            let previousPID = target.pid
            target.pid = candidate.id
            systemAudioTarget = target
            systemAudioTapLedger.attached(to: candidate.id,
                                          audibleDuration: health.audibleDuration)
            lastSystemAudioReattachAt = now
            if !isSamePIDRetry {
                samePIDSystemAudioRetryBudget.reset()
            }
            withdrawSilentSystemAudioWarning()
            lokalbotLog(
                "system audio reattached oldPID=\(previousPID) newPID=\(candidate.id) "
                    + "bundle=\(candidate.bundleID ?? "unknown") "
                    + "framesSinceAttach=\(health.framesSinceAttach) "
                    + "captured=\(String(format: "%.2fs", health.duration)) "
                    + "audible=\(String(format: "%.2fs", health.audibleDuration)) "
                    + "silentFor=\(String(format: "%.2fs", silentFor)) "
                    + "rms=\(String(format: "%.6f", health.lastRMSLevel)) "
                    + "peakRMS=\(String(format: "%.6f", health.peakRMSLevel))")
        } catch {
            lastSystemAudioReattachAt = now
            onError("System audio capture was interrupted (\(error.localizedDescription)); still recording microphone.")
            lokalbotLog("system audio reattach FAILED: \(error.localizedDescription)")
        }
    }

    private func currentSystemAudioCandidate(
        for target: SystemAudioTarget,
        excluding excludedPIDs: Set<pid_t> = []
    ) -> AudioProcess? {
        guard mayRecoverSource(target) else { return nil }
        return MeetingDetector.currentCaptureTargetProcess(
            for: MeetingDetector.DetectedApp(
                name: target.bundleID,
                bundleID: target.bundleID,
                pid: target.pid),
            excluding: excludedPIDs)
    }

    private static func hostPID(for bundleID: String) -> pid_t? {
        CaptureEnvironment.current.workspace.runningApplications().first { $0.bundleIdentifier == bundleID }?.processIdentifier
    }

    private func mayRecoverSource(_ target: SystemAudioTarget) -> Bool {
        !MeetingDetector.documentCallHosts.contains(target.bundleID)
            || (target.hostPID != nil && target.hostPID == Self.hostPID(for: target.bundleID))
    }

    private func currentEmittingSystemAudioCandidate(
        for target: SystemAudioTarget,
        excluding excludedPIDs: Set<pid_t>
    ) -> AudioProcess? {
        guard mayRecoverSource(target) else { return nil }
        return MeetingDetector.emittingCaptureAlternative(
            for: MeetingDetector.DetectedApp(
                name: target.bundleID,
                bundleID: target.bundleID,
                pid: target.pid),
            tapping: target.pid,
            in: MeetingDetector.currentAudioProcesses(),
            excluding: excludedPIDs)
    }

    private func handleCapturedProcessTermination(_ terminatedPID: pid_t) {
        guard isRecording, let recordingID = currentMeeting?.id, systemAudioTarget?.pid == terminatedPID else { return }
        systemAudioHandoffTask?.cancel()
        systemAudioHandoffTask = Task { [weak self] in
            guard let self else { return }
            let delays: [TimeInterval] = [0.15, 0.35, 0.7, 1.2, 2.0]
            for delay in delays {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, self.currentMeeting?.id == recordingID,
                      self.isRecording, var target = self.systemAudioTarget,
                      target.pid == terminatedPID else { return }
                MeetingDetector.invalidateAudioProcessSnapshot()
                guard let candidate = self.currentSystemAudioCandidate(
                    for: target,
                    excluding: [terminatedPID]
                ) else { continue }
                do {
                    try self.systemRecorder.reattach(capturingPID: candidate.id)
                    target.pid = candidate.id
                    self.systemAudioTarget = target
                    self.systemAudioTapLedger.attached(
                        to: candidate.id,
                        audibleDuration: self.systemRecorder.captureHealth().audibleDuration)
                    self.lastSystemAudioReattachAt = Date()
                    self.samePIDSystemAudioRetryBudget.reset()
                    self.withdrawSilentSystemAudioWarning()
                    lokalbotLog(
                        "system audio helper handoff oldPID=\(terminatedPID) newPID=\(candidate.id) bundle=\(candidate.bundleID ?? "unknown")")
                    self.systemAudioHandoffTask = nil
                    return
                } catch {
                    lokalbotLog("system audio helper handoff retry failed: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, self.currentMeeting?.id == recordingID,
                  self.isRecording, self.systemAudioTarget?.pid == terminatedPID else { return }
            self.onError("System audio capture was interrupted; LokalBot is still recording the microphone and will keep looking for the meeting app.")
            self.systemAudioHandoffTask = nil
        }
    }

    private func retargetSystemAudio(to app: MeetingDetector.DetectedApp) {
        guard isRecording,
              currentMeeting?.captureIntent?.accepts(appBundleID: app.bundleID, meetingURL: app.meetingURL) == true else { return }
        MeetingDetector.invalidateAudioProcessSnapshot()
        guard let candidate = MeetingDetector.currentCaptureTargetProcess(for: app) else { return }
        if systemAudioTarget?.bundleID == app.bundleID,
           systemAudioTarget?.pid == candidate.id { return }
        do {
            try systemRecorder.reattach(capturingPID: candidate.id)
            systemAudioTarget = SystemAudioTarget(bundleID: app.bundleID, pid: candidate.id, hostPID: Self.hostPID(for: app.bundleID))
            systemAudioTapLedger.attached(
                to: candidate.id,
                audibleDuration: systemRecorder.captureHealth().audibleDuration)
            lastSystemAudioReattachAt = Date()
            samePIDSystemAudioRetryBudget.reset()
            withdrawSilentSystemAudioWarning()
            lokalbotLog(
                "system audio meeting handoff app=\(app.bundleID) pid=\(candidate.id)")
        } catch {
            onError("Could not switch system audio capture to \(app.name); microphone recording is continuing.")
            lokalbotLog("system audio meeting handoff FAILED: \(error.localizedDescription)")
        }
    }

    static func shouldWithdrawSilentSystemAudioWarning(
        hasWarned: Bool, audibleDuration: TimeInterval) -> Bool {
        hasWarned && audibleDuration >= AudioFileInspector.minimumTranscribableDuration
    }

    @discardableResult
    private func withdrawSilentSystemAudioWarningIfRecovered(
        health: SystemAudioRecorder.CaptureHealth? = nil) -> Bool {
        guard silentSystemAudioWarning.isPresented else { return false }
        let health = health ?? systemRecorder.captureHealth()
        guard Self.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: silentSystemAudioWarning.isPresented,
            audibleDuration: health.audibleDuration)
        else { return false }
        withdrawSilentSystemAudioWarning()
        lokalbotLog(
            "system audio recovered audible=\(String(format: "%.2fs", health.audibleDuration))")
        return true
    }

    private func withdrawSilentSystemAudioWarning() {
        guard silentSystemAudioWarning.withdraw() else { return }
        onError(nil)
    }

    private func warnOnceAboutSilentSystemAudio(elapsed: TimeInterval, captured: TimeInterval,
                                                audible: TimeInterval, rms: Float, peakRMS: Float) {
        guard elapsed >= 30,
              audible < AudioFileInspector.minimumTranscribableDuration,
              silentSystemAudioWarning.present()
        else { return }
        lokalbotLog(
            "system audio silent elapsed=\(String(format: "%.2fs", elapsed)) captured=\(String(format: "%.2fs", captured)) audible=\(String(format: "%.2fs", audible)) rms=\(String(format: "%.6f", rms)) peakRMS=\(String(format: "%.6f", peakRMS))")
        onError(Self.silentSystemAudioMessage)
    }

    private static func formatAudioDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "missing" }
        return String(format: "%.2fs", duration)
    }

    private static func formatMinutes(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration / 60))
        return "\(minutes) min"
    }
}
