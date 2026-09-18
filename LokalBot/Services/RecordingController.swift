import Foundation
import AppKit
import Combine

struct SystemAudioSamePIDRetryBudget: Equatable {
    static let maximumAttempts = 2

    private(set) var attempts = 0

    var canRetry: Bool { attempts < Self.maximumAttempts }

    /// Claims one retry before the reattach is attempted, so failed Core Audio
    /// setup cannot bypass the bound and retry forever on every watchdog tick.
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

enum SystemAudioRecoveryCandidatePolicy {
    static func shouldRetrySamePID(
        framesSinceAttach: Int64,
        audibleDuration: TimeInterval,
        minimumAudibleDuration: TimeInterval
    ) -> Bool {
        framesSinceAttach == 0 || audibleDuration < minimumAudibleDuration
    }
}

/// What the watchdog has learned about the processes it tapped during one
/// recording. Two facts, both earned rather than assumed.
///
/// A tap that has written audible audio *of its own* is pointed at the process
/// the call comes out of, and is worth being patient with. A tap that has not
/// delivered one buffer since it attached is pointed at a process with no open
/// output stream; no amount of waiting turns that into audio, and nothing
/// should send the tap back there.
///
/// Excluding only the tap in hand is not enough, because the exclusion lasts
/// one tick. Measured on a real call (log, 2026-08-25 10:36–10:57) the watchdog
/// alternated between two Teams siblings every 10–15 s for 21 minutes: an
/// ordinary pause moved the tap off the process carrying audio onto a helper
/// that delivered nothing, the empty helper moved it straight back, and the
/// audible total grew 28 s in those 21 minutes because each swap discards the
/// audio in flight.
struct SystemAudioTapLedger: Equatable {
    /// The tap known to carry this call's audio, if one has proved itself.
    private(set) var provenPID: pid_t?
    /// Taps that delivered nothing at all while attached.
    private(set) var retiredPIDs: Set<pid_t> = []
    /// The session's audible total when the current tap attached. `CaptureHealth`
    /// counts the whole file, so only growth past this mark belongs to this
    /// attachment — without the mark, a tap inherits its predecessor's proof.
    private var audibleAtAttach: TimeInterval = 0

    mutating func attached(to pid: pid_t, audibleDuration: TimeInterval) {
        audibleAtAttach = audibleDuration
        // Teams reuses its processes; a fresh attachment gets a fresh hearing.
        retiredPIDs.remove(pid)
    }

    /// Whether the current attachment has written audible audio itself.
    func hasProvedItself(audibleDuration: TimeInterval, minimum: TimeInterval) -> Bool {
        audibleDuration - audibleAtAttach >= minimum
    }

    mutating func observe(pid: pid_t, audibleDuration: TimeInterval, minimum: TimeInterval) {
        guard hasProvedItself(audibleDuration: audibleDuration, minimum: minimum) else { return }
        provenPID = pid
    }

    /// Retires a tap that delivered nothing. A PID that had proved itself on an
    /// earlier attachment loses that standing: whatever it carried then, it is
    /// carrying nothing now.
    mutating func retire(_ pid: pid_t) {
        retiredPIDs.insert(pid)
        if provenPID == pid { provenPID = nil }
    }

    /// How long this tap may stay quiet before the watchdog goes looking. A
    /// proven tap keeps the long grace through ordinary silence, but a different
    /// process that is actively emitting is direct evidence that the call moved
    /// and restores the ordinary recovery threshold.
    func silenceGrace(for pid: pid_t,
                      ordinary: TimeInterval,
                      proven: TimeInterval,
                      activelyEmittingAlternative: Bool = false) -> TimeInterval {
        activelyEmittingAlternative || pid != provenPID ? ordinary : proven
    }

    mutating func reset() { self = SystemAudioTapLedger() }
}

/// Tracks whether the silent-system-audio advisory is currently presented.
/// Returning a Bool from each transition lets the controller emit UI updates
/// exactly once while keeping the state machine independently testable.
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

    /// Presentation follows recent writes from each source independently.
    /// A source that produced sound earlier can subsequently become silent;
    /// historical audible data is not evidence that it is audible now.
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
                : isRecent(microphone.lastAudioWriteAt, at: current) ? "Receiving audio" : "No recent audio"
        case .recovering(let attempt): "Recovering (attempt \(attempt))"
        case .degraded(let description): "Degraded: \(description)"
        }
        let systemStatus: String
        if !hasSystemTarget {
            systemStatus = "Not attached"
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
            lastRecoveryAt: lastRecoveryAt)
    }

    private static func isRecent(_ date: Date?, at current: Date) -> Bool {
        date.map { current.timeIntervalSince($0) <= 10 } ?? false
    }
}

/// Owns the meeting-recording lifecycle: the two recorders (mic + system tap),
/// the start/stop state machine, the capture-health watchdog, the menu-bar
/// timer tick, and transcription-model prewarm. `AppState` keeps a reference,
/// republishes changes, and folds finished meetings into the library via
/// `onMeetingFinished`.
@MainActor
final class RecordingController: ObservableObject {

    enum Status: Equatable {
        case idle
        case starting
        case recording(meetingID: UUID)
    }

    @Published private(set) var status: Status = .idle
    /// The live recording (shown at the top of the library while running).
    @Published private(set) var currentMeeting: Meeting?
    /// Drives `elapsed`; bumped each second by `recordingTick`.
    @Published private(set) var now = Date()
    /// True only around the synchronous stop/start boundary of a calendar split.
    private(set) var isSplittingForCalendarHandoff = false

    private let storage: StorageManager
    private let settingsStore: SettingsStore
    private let audioMonitor: AudioSourceMonitor
    private let pipeline: ProcessingPipeline
    /// Surfaces user-facing problems (feeds `AppState.lastError`).
    /// Exposed so the presenter can withdraw exactly this message and never a
    /// newer, unrelated one.
    static let silentSystemAudioMessage =
        "System audio capture is silent; LokalBot is keeping the microphone "
        + "recording and will reattach if the meeting audio process changes."
    /// `nil` withdraws ``silentSystemAudioMessage`` if it is still showing.
    private let onError: (String?) -> Void
    private let onMicPermissionDenied: () -> Void
    /// A finished meeting leaves the controller here; the app inserts it into
    /// the library list.
    private let onMeetingFinished: (Meeting) -> Void
    /// Gates notifications + prewarm to the real interactive launch
    /// (not headless / UI tests).
    private let isInteractive: () -> Bool

    private let micRecorder = MicRecorder()
    private let systemRecorder = SystemAudioRecorder()
    private let speakerObserver: MeetingSpeakerObserver?
    private var speakerAudioClock: RecordingAudioClock?
    private var microphoneAudioClock: RecordingAudioClock?

    private struct SystemAudioTarget {
        var bundleID: String
        var pid: pid_t
    }
    private var systemAudioTarget: SystemAudioTarget?
    private var recordingHealthWatchdog: AnyCancellable?
    private var lastMicRestartAt: Date?
    private var didWarnAboutMicCaptureStall = false
    private var lastSystemAudioReattachAt: Date?
    private var silentSystemAudioWarning = SilentSystemAudioWarningState()
    private var samePIDSystemAudioRetryBudget = SystemAudioSamePIDRetryBudget()
    private var systemAudioTapLedger = SystemAudioTapLedger()
    private static let recordingHealthWatchdogInterval: TimeInterval = 5
    private static let micCaptureInitialGrace: TimeInterval = 8
    private static let micCaptureStallGrace: TimeInterval = 15
    private static let micCaptureRestartCooldown: TimeInterval = 10
    private static let systemAudioInitialGrace: TimeInterval = 8
    private static let systemAudioSilentGrace: TimeInterval = 8
    /// The same wait, for a tap that has already written audible audio of its
    /// own. Eight seconds is a pause between two sentences, so on a proven tap
    /// that threshold measures the conversation rather than the capture.
    ///
    /// Ninety seconds is a judgement, not a measurement: comfortably longer
    /// than a meeting goes quiet while someone reads or shares a screen, and
    /// short enough to still find the audio inside a couple of minutes if it
    /// really did move. `retiredPIDs` is what stops the churn; this only keeps
    /// a working tap from being disturbed for nothing. The microphone keeps
    /// recording throughout either way.
    private static let provenSystemAudioSilentGrace: TimeInterval = 90
    private static let systemAudioReattachCooldown: TimeInterval = 10
    /// Calendar event id + stop time of the last calendar-backed recording, so
    /// the same scheduled meeting can't immediately re-record (helper-PID churn,
    /// brief audio drops). See `MeetingMatcher.shouldSuppressRepeat`.
    private var lastCalendarEventID: String?
    private var lastCalendarEventEndedAt: Date?
    private static let calendarRepeatCooldown: TimeInterval = 5 * 60
    private static let automaticStartSources: Set<String> = [
        "detector", "audio-monitor",
    ]

    /// Ticks once a second while recording so the menu bar timer (and popover)
    /// stay live even with no window open. Nil when idle.
    private var recordingTick: AnyCancellable?
    private var transcriptionPrewarmTask: Task<Void, Never>?
    private var summaryPrewarmTask: Task<Void, Never>?
    private var diarizationPrewarmTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var systemAudioHandoffTask: Task<Void, Never>?
    /// Manual capture can begin during a transient Accessibility gap. Keep a
    /// bounded retry alive until the browser's verified meeting document is
    /// visible, then attach the system tap to the same meeting folder.
    private var pendingSystemAudioCaptureTask: Task<Void, Never>?
    private var activeSystemAudioPolicy: RecordingSystemAudioPolicy?
    private static let lateSystemAudioCaptureRetryDelays: [TimeInterval] = [
        0.5, 1, 2, 4, 8, 15, 30, 30, 30,
    ]

    init(storage: StorageManager,
         settingsStore: SettingsStore,
         audioMonitor: AudioSourceMonitor,
         pipeline: ProcessingPipeline,
         speakerObserver: MeetingSpeakerObserver? = nil,
         isInteractive: @escaping () -> Bool,
         onError: @escaping (String?) -> Void,
         onMicPermissionDenied: @escaping () -> Void = {},
         onMeetingFinished: @escaping (Meeting) -> Void) {
        self.storage = storage
        self.settingsStore = settingsStore
        self.audioMonitor = audioMonitor
        self.pipeline = pipeline
        self.speakerObserver = speakerObserver
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

    /// Compact "MM:SS" (or "H:MM:SS") elapsed string for the menu bar label.
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
        return RecordingMemoryHealthSnapshot.recording(
            microphone: micRecorder.captureHealth(),
            system: systemRecorder.captureHealth(),
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

    func prepareForTermination() {
        transcriptionPrewarmTask?.cancel()
        transcriptionPrewarmTask = nil
        summaryPrewarmTask?.cancel()
        summaryPrewarmTask = nil
        diarizationPrewarmTask?.cancel()
        diarizationPrewarmTask = nil
        pendingSystemAudioCaptureTask?.cancel()
        pendingSystemAudioCaptureTask = nil
        if isRecording || isStarting { stop(process: false) }
    }

    // MARK: - Start / stop

    /// Only automatic detector starts are protected from immediately
    /// re-recording the same calendar event. Explicit user actions such as
    /// Record now must always honor the user's request.
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
        // Automatic detector retries must not immediately re-record the same
        // scheduled event after one ended; explicit user starts bypass this.
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
        // Refuse up front on a nearly-full volume: a recording that dies
        // mid-meeting from ENOSPC loses the meeting; a clear refusal doesn't.
        if let advisory = DiskSpacePrecheck.recordingAdvisory(
            availableBytes: DiskSpacePrecheck.availableBytes(at: storage.rootURL)) {
            lokalbotLog("startRecording refused: low disk space")
            onError(advisory)
            return
        }
        status = .starting
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
                   let detectedApp, MeetingDetector.browsers.contains(detectedApp.bundleID) {
                    let host = NSRunningApplication.runningApplications(withBundleIdentifier: detectedApp.bundleID).first
                    let session = host.flatMap { BrowserMeetingSession.snapshot(processID: $0.processIdentifier,
                        expectedURL: detectedApp.meetingURL) }
                    guard session?.state == .inCall, session?.url == detectedApp.meetingURL else {
                        audioMonitor.isRecordingActive = false
                        audioMonitor.reseed()
                        onError("The detected Meet call is no longer available. Start recording manually if needed.")
                        return
                    }
                }
                let title = MeetingMatcher.recordingTitle(
                    calendarTitle: calendarEvent?.title,
                    useCalendarTitles: settings.useCalendarTitles,
                    appName: detectedApp?.name)
                var meeting = try storage.createMeetingFolder(title: title,
                                                              appName: detectedApp?.name ?? "Manual")
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
                    try? storage.saveMeta(meeting)
                }
                if let url = detectedApp?.meetingURL {
                    meeting.meetingURL = url
                    try storage.saveMeta(meeting)
                }
                created = meeting
                speakerAudioClock = RecordingAudioClock()
                microphoneAudioClock = RecordingAudioClock()
                systemRecorder.speakerAudioClock = speakerAudioClock
                micRecorder.speakerAudioClock = microphoneAudioClock
                try Task.checkCancellation()
                try micRecorder.start(
                    writingTo: meeting.folderURL(in: storage).appendingPathComponent("mic.m4a"),
                    previewTee: meeting.folderURL(in: storage)
                        .appendingPathComponent(AudioPreviewTee.micFileName))
                startRecordingHealthWatchdog()
                try Task.checkCancellation()

                // Meeting-intent callers may fall back to a running meeting app
                // before it emits audio, giving the watchdog a target to repair.
                // The fallback verifies a browser's in-call document first, so
                // manual recovery can capture Chrome without widening scope to
                // an arbitrary browser tab. Mic-only callers never evaluate it.
                let captureApp = systemAudioPolicy.captureApp(
                    detectedApp: detectedApp,
                    fallback: {
                        MeetingDetector.captureCandidateApp(
                            expectedMeetingURL: calendarEvent?.meetingURL)
                    })
                if let captureApp {
                    _ = startSystemAudioCapture(captureApp, meeting: &meeting, detectedApp: detectedApp)
                } else {
                    lokalbotLog(
                        "system audio capture pending detected=\(detectedApp != nil) "
                            + "expectedURL=\(calendarEvent?.meetingURL?.absoluteString ?? "none")")
                }
                try Task.checkCancellation()
                currentMeeting = meeting
                status = .recording(meetingID: meeting.id)
                if let speakerAudioClock, let target = systemAudioTarget {
                    speakerObserver?.start(meeting: meeting, clock: speakerAudioClock, capturedBundleID: target.bundleID)
                }
                if systemAudioPolicy == .meetingAppWhenAvailable, systemAudioTarget == nil {
                    scheduleLateSystemAudioCapture(expectedMeetingURL: meeting.meetingURL)
                }
                startRecordingTick()
                if isInteractive() {
                    RecordingNotifier.shared.recordingStarted(title: meeting.title)
                    prewarmSelectedTranscriptionModel(reason: source)
                    prewarmSelectedSummaryModel(reason: source)
                    prewarmDiarizationModels(reason: source)
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
                // Don't leave a 0-minute husk in the library.
                micRecorder.stop()
                systemRecorder.stop()
                resetAudioClocks()
                if let husk = created { try? storage.deleteMeeting(husk) }
            }
        }
    }

    func stop(process: Bool = true, contentEndedAt: Date? = nil) {
        if isStarting {
            startTask?.cancel()
            pendingSystemAudioCaptureTask?.cancel()
            pendingSystemAudioCaptureTask = nil
            activeSystemAudioPolicy = nil
            status = .idle
            audioMonitor.isRecordingActive = false
            audioMonitor.reseed()
            return
        }
        guard isRecording, var meeting = currentMeeting else { return }
        speakerObserver?.stop()
        pendingSystemAudioCaptureTask?.cancel()
        pendingSystemAudioCaptureTask = nil
        systemAudioHandoffTask?.cancel()
        systemAudioHandoffTask = nil
        // Before the watchdog goes away: it is the only thing that notices
        // recovery, so a meeting ending between the arrival of audio and the
        // next tick would leave the advisory standing over a recording that
        // does have a system track.
        withdrawSilentSystemAudioWarningIfRecovered()
        stopRecordingHealthWatchdog()
        micRecorder.stop()
        systemRecorder.stop()
        let timing = RecordingAudioTiming(microphone: microphoneAudioClock?.archive() ?? [],
                                          system: speakerAudioClock?.archive() ?? [])
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
        meeting.endedAt = endedAt
        let folder = meeting.folderURL(in: storage)
        // Only discard a preview tee after its finalized AAC track is known to
        // decode. If finalization failed, the CAF may be the sole recovery copy.
        MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
        let micDuration = MeetingAudioFiles.duration(for: .mic, in: folder)
        let systemDuration = MeetingAudioFiles.duration(for: .system, in: folder)
        meeting.hasSystemTrack = MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil
        // The wall-clock span can outlast the captured audio (e.g. a device
        // disruption truncates the tracks while the session stays live), so
        // store the actual playable length — the longest track — for the UI.
        meeting.recordedDuration = [micDuration, systemDuration].compactMap { $0 }.max()
        if let contentEndedAt, let duration = meeting.recordedDuration {
            let end = min(duration, max(0, contentEndedAt.timeIntervalSince(meeting.startedAt)))
            if end > 0 { meeting.contentRange = .init(start: 0, end: end) }
        }
        let wallDuration = endedAt.timeIntervalSince(meeting.startedAt)
        lokalbotLog(
            "recording stopped wall=\(String(format: "%.2fs", wallDuration)) recorded=\(String(format: "%.2fs", meeting.recordedDuration ?? 0)) mic=\(Self.formatAudioDuration(micDuration)) system=\(Self.formatAudioDuration(systemDuration)) hasSystem=\(meeting.hasSystemTrack)")
        if let recordedDuration = meeting.recordedDuration,
           wallDuration - recordedDuration > 60,
           recordedDuration < wallDuration * 0.8 {
            onError("Recording saved, but only \(meeting.durationLabel) of audio was captured from a \(Self.formatMinutes(wallDuration)) session.")
        }
        try? storage.saveMeta(meeting)
        lastCalendarEventID = meeting.calendarEventID
        lastCalendarEventEndedAt = endedAt
        currentMeeting = nil
        status = .idle
        onMeetingFinished(meeting)
        let willTranscribe = process && settings.autoTranscribe
        // The pipeline parks automatic jobs whose models are missing instead
        // of ambush-downloading them; the notification says so up front.
        let waitingForModels = willTranscribe
            && !ModelReadinessSnapshot.transcriptionReady(settings)
        if isInteractive() {
            RecordingNotifier.shared.recordingStopped(
                title: meeting.title,
                duration: meeting.recordedDuration ?? endedAt.timeIntervalSince(meeting.startedAt),
                willTranscribe: willTranscribe && !waitingForModels,
                waitingForModels: waitingForModels)
        }
        if willTranscribe {
            pipeline.enqueue(meeting, transcribe: true, summarize: settings.autoSummarize,
                             origin: .automatic)
        }
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

    /// Starts the system tap and records the target in the same place for both
    /// the normal start path and a late manual attachment. Keeping this update
    /// atomic prevents metadata from claiming a system track when Core Audio
    /// never accepted the tap.
    @discardableResult
    private func startSystemAudioCapture(
        _ captureApp: MeetingDetector.DetectedApp,
        meeting: inout Meeting,
        detectedApp: MeetingDetector.DetectedApp?
    ) -> Bool {
        let captureProcess = MeetingDetector.currentCaptureTargetProcess(for: captureApp)
        let pid = captureProcess?.id ?? captureApp.pid
        do {
            try systemRecorder.start(
                capturingPID: pid,
                writingTo: meeting.folderURL(in: storage).appendingPathComponent("system.m4a"),
                previewTee: meeting.folderURL(in: storage)
                    .appendingPathComponent(AudioPreviewTee.systemFileName))
            meeting.hasSystemTrack = true
            systemAudioTarget = SystemAudioTarget(bundleID: captureApp.bundleID, pid: pid)
            systemAudioTapLedger.attached(to: pid, audibleDuration: 0)
            if pid != captureApp.pid || captureProcess?.bundleID != captureApp.bundleID {
                lokalbotLog(
                    "system audio capture resolved detectedPID=\(captureApp.pid) capturePID=\(pid) "
                        + "captureBundle=\(captureProcess?.bundleID ?? "unknown") "
                        + "hostBundle=\(captureApp.bundleID)")
            }
            lokalbotLog(
                "system audio tap started pid=\(pid) bundle=\(captureApp.bundleID) "
                    + "detected=\(detectedApp != nil) fallback=\(detectedApp == nil)")
            if detectedApp == nil, let url = captureApp.meetingURL {
                meeting.meetingURL = url
                try? storage.saveMeta(meeting)
            }
            return true
        } catch {
            // Degrade gracefully: the microphone remains authoritative. A
            // meeting that began during an AX gap gets a bounded late retry;
            // a detected start still receives the existing actionable error.
            if detectedApp != nil {
                onError("System audio tap failed (\(error.localizedDescription)) — recording mic only.")
            }
            lokalbotLog(
                "system audio tap FAILED detected=\(detectedApp != nil): \(error.localizedDescription)")
            return false
        }
    }

    /// Accessibility snapshots are occasionally unavailable exactly when the
    /// user presses Record. Do not freeze that first miss into a mic-only
    /// meeting: look again for a verified browser call while the recording is
    /// already active, with a finite retry budget and no broader browser tabs.
    private func scheduleLateSystemAudioCapture(expectedMeetingURL: URL?) {
        guard activeSystemAudioPolicy == .meetingAppWhenAvailable,
              isRecording,
              systemAudioTarget == nil,
              pendingSystemAudioCaptureTask == nil else { return }
        pendingSystemAudioCaptureTask = Task { [weak self] in
            for (index, delay) in Self.lateSystemAudioCaptureRetryDelays.enumerated() {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self,
                      !Task.isCancelled,
                      self.isRecording,
                      self.activeSystemAudioPolicy == .meetingAppWhenAvailable,
                      self.systemAudioTarget == nil else { return }
                MeetingDetector.invalidateAudioProcessSnapshot()
                guard let captureApp = MeetingDetector.captureCandidateApp(
                    expectedMeetingURL: expectedMeetingURL) else {
                    lokalbotLog(
                        "system audio late attach retry=\(index + 1) unavailable "
                            + "expectedURL=\(expectedMeetingURL?.absoluteString ?? "none")")
                    continue
                }
                if self.attachLateSystemAudio(captureApp) {
                    lokalbotLog(
                        "system audio late attach succeeded retry=\(index + 1) "
                            + "bundle=\(captureApp.bundleID) pid=\(captureApp.pid)")
                    self.pendingSystemAudioCaptureTask = nil
                    return
                }
            }
            guard let self else { return }
            if self.isRecording, self.systemAudioTarget == nil {
                lokalbotLog("system audio late attach exhausted; continuing microphone capture")
            }
            self.pendingSystemAudioCaptureTask = nil
        }
    }

    @discardableResult
    private func attachLateSystemAudio(_ captureApp: MeetingDetector.DetectedApp) -> Bool {
        guard isRecording, systemAudioTarget == nil, var meeting = currentMeeting else { return false }
        guard startSystemAudioCapture(captureApp, meeting: &meeting, detectedApp: nil) else { return false }
        currentMeeting = meeting
        if let speakerAudioClock, let target = systemAudioTarget {
            speakerObserver?.start(meeting: meeting, clock: speakerAudioClock, capturedBundleID: target.bundleID)
        }
        return true
    }

    private func resetAudioClocks() {
        speakerAudioClock?.invalidate()
        microphoneAudioClock?.invalidate()
        speakerAudioClock = nil
        microphoneAudioClock = nil
        systemRecorder.speakerAudioClock = nil
        micRecorder.speakerAudioClock = nil
    }

    private func cleanupCancelledStart(created: Meeting?) {
        speakerObserver?.stop()
        pendingSystemAudioCaptureTask?.cancel()
        pendingSystemAudioCaptureTask = nil
        stopRecordingHealthWatchdog()
        micRecorder.stop()
        systemRecorder.stop()
        resetAudioClocks()
        systemAudioTarget = nil
        activeSystemAudioPolicy = nil
        audioMonitor.isRecordingActive = false
        audioMonitor.reseed()
        if let created { try? storage.deleteMeeting(created) }
        lokalbotLog("recording start cancelled")
    }

    private func prewarmSelectedTranscriptionModel(reason: String) {
        guard settings.autoTranscribe else { return }
        guard transcriptionPrewarmTask == nil else { return }
        let config = settings
        // Prewarm only warms models that already exist on disk. A missing
        // model would make `prepare()` download gigabytes mid-recording that
        // the user never asked for — the pipeline parks the meeting as
        // "waiting for models" instead.
        guard ModelReadinessSnapshot.transcriptionReady(config) else {
            lokalbotLog("transcription prewarm skipped: model not downloaded")
            return
        }
        let choice = config.transcriptionModel
        let engine = config.transcriptionEngine()
        transcriptionPrewarmTask = Task { [weak self, choice, engine, reason] in
            let started = Date()
            lokalbotLog("transcription prewarm start model=\(choice.rawValue) reason=\(reason)")
            do {
                try await engine.prepare()
                let elapsed = Date().timeIntervalSince(started)
                lokalbotLog("transcription prewarm ready model=\(choice.rawValue) elapsed=\(String(format: "%.2fs", elapsed))")
            } catch {
                lokalbotLog("transcription prewarm FAILED model=\(choice.rawValue): \(error.localizedDescription)")
            }
            await MainActor.run { self?.transcriptionPrewarmTask = nil }
        }
    }

    /// Verify and warm the built-in summary model while the meeting is in
    /// progress. Warm-only: a model that is not downloaded is left alone —
    /// the pipeline parks the summary as "waiting for models" rather than
    /// starting a multi-gigabyte download the user never asked for.
    private func prewarmSelectedSummaryModel(reason: String) {
        let config = settings
        guard config.autoSummarize, config.summarizerBackend == .builtIn else { return }
        guard ModelReadinessSnapshot.thinkReady(config, storage: storage) else {
            lokalbotLog("summary prewarm skipped: model not downloaded")
            return
        }
        guard summaryPrewarmTask == nil else { return }
        summaryPrewarmTask = Task { [weak self, config, reason] in
            let started = Date()
            lokalbotLog("summary prewarm start model=\(config.builtInModelID) reason=\(reason)")
            do {
                try await self?.pipeline.thinkExecution.prepareBuiltInModel(config)
                let elapsed = Date().timeIntervalSince(started)
                lokalbotLog(
                    "summary prewarm ready model=\(config.builtInModelID) elapsed=\(String(format: "%.2fs", elapsed))")
            } catch is CancellationError {
                lokalbotLog("summary prewarm cancelled model=\(config.builtInModelID)")
            } catch {
                // Processing retries the same preparation and surfaces the
                // error beside the meeting if the transient problem persists.
                lokalbotLog(
                    "summary prewarm FAILED model=\(config.builtInModelID): \(error.localizedDescription)")
            }
            await MainActor.run { self?.summaryPrewarmTask = nil }
        }
    }

    private func prewarmDiarizationModels(reason: String) {
        guard settings.multiSpeakerDiarization, diarizationPrewarmTask == nil else { return }
        diarizationPrewarmTask = Task { [weak self, reason] in
            lokalbotLog("diarization prewarm start reason=\(reason)")
            await self?.pipeline.prepareDiarizationModels()
            guard !Task.isCancelled else { return }
            lokalbotLog("diarization prewarm ready reason=\(reason)")
            self?.diarizationPrewarmTask = nil
        }
    }

    /// Start/stop the once-a-second clock that keeps the menu bar timer live.
    private func startRecordingTick() {
        now = Date()
        recordingTick = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    private func stopRecordingTick() {
        recordingTick?.cancel()
        recordingTick = nil
    }

    // MARK: - Capture-health watchdog

    private func startRecordingHealthWatchdog() {
        stopRecordingHealthWatchdog()
        // A truly silent warning intentionally survives stop so the user can
        // still see what happened. Starting a new capture retires that scoped
        // warning through AppState's guarded nil callback before this attempt.
        withdrawSilentSystemAudioWarning()
        lastMicRestartAt = nil
        didWarnAboutMicCaptureStall = false
        lastSystemAudioReattachAt = nil
        samePIDSystemAudioRetryBudget.reset()
        systemAudioTapLedger.reset()
        recordingHealthWatchdog = Timer.publish(
            every: Self.recordingHealthWatchdogInterval,
            on: .main,
            in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMicCapture()
                self?.checkSystemAudioCapture()
            }
    }

    private func stopRecordingHealthWatchdog() {
        recordingHealthWatchdog?.cancel()
        recordingHealthWatchdog = nil
        lastMicRestartAt = nil
        didWarnAboutMicCaptureStall = false
        lastSystemAudioReattachAt = nil
        samePIDSystemAudioRetryBudget.reset()
        systemAudioTapLedger.reset()
    }

    private func checkMicCapture() {
        guard isRecording, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.micCaptureInitialGrace else { return }

        let health = micRecorder.captureHealth()
        switch health.recoveryState {
        case .healthy:
            if health.isEngineRunning { didWarnAboutMicCaptureStall = false }
        case .recovering:
            // MicRecorder owns the bounded device-reconfiguration recovery.
            // Avoid racing it with a second graph rebuild from this watchdog.
            return
        case .degraded(let errorDescription):
            if !didWarnAboutMicCaptureStall {
                didWarnAboutMicCaptureStall = true
                onError(
                    "Microphone capture could not recover (\(errorDescription)). "
                        + "Recording is continuing with system audio when available.")
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

    private func checkSystemAudioCapture() {
        guard isRecording, var target = systemAudioTarget, let meeting = currentMeeting else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(meeting.startedAt)
        guard elapsed >= Self.systemAudioInitialGrace else { return }

        let health = systemRecorder.captureHealth()
        withdrawSilentSystemAudioWarningIfRecovered(health: health)
        systemAudioTapLedger.observe(pid: target.pid,
                                     audibleDuration: health.audibleDuration,
                                     minimum: AudioFileInspector.minimumTranscribableDuration)
        let silentFor = health.lastAudibleWriteAt.map { now.timeIntervalSince($0) } ?? elapsed
        // Do not enumerate process siblings during sub-threshold fluctuations.
        guard silentFor >= Self.systemAudioSilentGrace else { return }

        // A proven tap ordinarily stays put for the long grace, but it should
        // not wait while Core Audio already shows a different process in the
        // same app family actively emitting. Excluding both the current tap and
        // session-retired taps makes this a real alternative, not another
        // selection of the process whose file is currently silent.
        var emittingExclusions = systemAudioTapLedger.retiredPIDs
        emittingExclusions.insert(target.pid)
        let emittingAlternative = currentEmittingSystemAudioCandidate(
            for: target,
            excluding: emittingExclusions)
        // Silence is the question this watchdog cannot answer on its own: a
        // meeting between two sentences and a tap on the wrong process look
        // identical from here. A proven tap sits out an ordinary pause unless a
        // currently-emitting sibling answers the question directly.
        let silenceGrace = systemAudioTapLedger.silenceGrace(
            for: target.pid,
            ordinary: Self.systemAudioSilentGrace,
            proven: Self.provenSystemAudioSilentGrace,
            activelyEmittingAlternative: emittingAlternative != nil)
        guard silentFor >= silenceGrace else { return }

        if let lastSystemAudioReattachAt,
           now.timeIntervalSince(lastSystemAudioReattachAt) < Self.systemAudioReattachCooldown {
            return
        }

        // A tap that has not delivered a single buffer since it attached is not
        // quiet: it is pointed at a process with no open output stream. Retire
        // it — and look past everything retired earlier in this recording, not
        // just the tap in hand, or the watchdog keeps rediscovering the same
        // empty sibling and swapping back onto it.
        if health.framesSinceAttach == 0 {
            systemAudioTapLedger.retire(target.pid)
        }
        let alternativeCandidate = emittingAlternative ?? currentSystemAudioCandidate(
            for: target,
            excluding: systemAudioTapLedger.retiredPIDs)
        // Rebuilding a tap on the same PID is still useful when that is the
        // only process left: the process may have opened its stream after the
        // original tap was created. Same-PID retries remain budgeted below.
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

        // If the tap has never delivered audio, retry even on the same PID.
        // Once samples exist, reattach only when Core Audio reports a different
        // active process for the same meeting app/browser family.
        let shouldRetrySamePID = SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
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
            warnOnceAboutSilentSystemAudio(elapsed: elapsed, captured: health.duration,
                                           audible: health.audibleDuration,
                                           rms: health.lastRMSLevel,
                                           peakRMS: health.peakRMSLevel)
            return
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
        MeetingDetector.currentCaptureTargetProcess(
            for: MeetingDetector.DetectedApp(
                name: target.bundleID,
                bundleID: target.bundleID,
                pid: target.pid),
            excluding: excludedPIDs)
    }

    /// A currently-emitting sibling is stronger recovery evidence than a quiet
    /// capture target. Unlike the broader capture lookup, this never returns an
    /// always-open or merely-present fallback.
    private func currentEmittingSystemAudioCandidate(
        for target: SystemAudioTarget,
        excluding excludedPIDs: Set<pid_t>
    ) -> AudioProcess? {
        MeetingDetector.currentOutputAudioProcess(
            for: MeetingDetector.DetectedApp(
                name: target.bundleID,
                bundleID: target.bundleID,
                pid: target.pid),
            excluding: excludedPIDs)
    }

    /// Helper processes routinely exit during a live browser/Zoom meeting.
    /// Give Core Audio a short window to publish the replacement and reattach
    /// the existing writer; the detector, not helper churn, owns whole-meeting
    /// termination. Microphone recording continues throughout.
    private func handleCapturedProcessTermination(_ terminatedPID: pid_t) {
        guard isRecording, systemAudioTarget?.pid == terminatedPID else { return }
        systemAudioHandoffTask?.cancel()
        systemAudioHandoffTask = Task { [weak self] in
            guard let self else { return }
            let delays: [TimeInterval] = [0.15, 0.35, 0.7, 1.2, 2.0]
            for delay in delays {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard self.isRecording, var target = self.systemAudioTarget,
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
            guard self.isRecording, self.systemAudioTarget?.pid == terminatedPID else { return }
            self.onError("System audio capture was interrupted; LokalBot is still recording the microphone and will keep looking for the meeting app.")
            self.systemAudioHandoffTask = nil
        }
    }

    private func retargetSystemAudio(to app: MeetingDetector.DetectedApp) {
        guard isRecording else { return }
        MeetingDetector.invalidateAudioProcessSnapshot()
        guard let candidate = MeetingDetector.currentCaptureTargetProcess(for: app) else { return }
        if systemAudioTarget?.bundleID == app.bundleID,
           systemAudioTarget?.pid == candidate.id { return }
        if systemAudioTarget?.bundleID != app.bundleID { speakerObserver?.rejectChangedAudioSource() }
        do {
            try systemRecorder.reattach(capturingPID: candidate.id)
            systemAudioTarget = SystemAudioTarget(bundleID: app.bundleID, pid: candidate.id)
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

    /// Takes back the silent-capture advisory once a system track has in fact
    /// been written. Without it the banner latches for the whole recording and
    /// keeps claiming the capture is silent — indistinguishable from the
    /// genuine "tap attached to a process that never emits" case the warning
    /// exists for. Only a capture that stayed silent keeps its warning.
    /// The rule itself, kept pure so it is testable without a live capture.
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

    /// A successful reattach starts a new capture attempt. Withdraw the
    /// advisory for the failed target now; if the replacement is also silent,
    /// the watchdog can present a fresh warning after its grace period.
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
