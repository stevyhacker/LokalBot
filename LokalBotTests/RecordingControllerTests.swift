import XCTest
@testable import LokalBot

/// Construction and pure-state coverage for the recording lifecycle owner.
/// The audio path itself needs real devices and TCC grants, so these tests
/// stay on the side of the controller that runs before any capture starts:
/// initial state, timer formatting, idle health reporting, and idle stop.
@MainActor
final class RecordingControllerTests: XCTestCase {
    func testDeviceReconnectRearmsOnlyAnActiveExhaustedRecovery() {
        XCTAssertTrue(MicRecorder.shouldRearmAfterDeviceEvent(
            isRecording: true, recovery: .degraded(errorDescription: "Unavailable")))
        XCTAssertFalse(MicRecorder.shouldRearmAfterDeviceEvent(
            isRecording: false, recovery: .degraded(errorDescription: "Unavailable")))
        XCTAssertFalse(MicRecorder.shouldRearmAfterDeviceEvent(isRecording: true, recovery: .healthy))
        XCTAssertFalse(MicRecorder.shouldRearmAfterDeviceEvent(isRecording: true, recovery: .recovering(attempt: 2)))
    }

    func testFailedMetadataFinalizationReloadsLaterEditsAndFinishesOnlyOnce() throws {
        let (storage, meeting) = try makeFinalizationFixture()
        let metadata = meeting.folderURL(in: storage).appendingPathComponent("meta.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let jobs = PipelineJobStore(databaseURL: storage.rootURL.appendingPathComponent("jobs.sqlite"))
        let pipeline = ProcessingPipeline(storage: storage, jobStore: jobs, settings: { AppSettings() })
        var errors: [String] = []
        var finishedIDs: [UUID] = []
        let controller = RecordingController(storage: storage,
            settingsStore: SettingsStore(initialSettings: automaticProcessingSettings()),
            audioMonitor: AudioSourceMonitor(), pipeline: pipeline, isInteractive: { false },
            onError: { if let error = $0 { errors.append(error) } },
            onMeetingFinished: { finishedIDs.append($0.id) })

        XCTAssertFalse(controller.finalize(meeting, process: true, deferProcessing: true))
        XCTAssertFalse(controller.prepareForTermination())
        XCTAssertTrue(errors.contains { $0.contains("details could not be saved") })
        XCTAssertNil(jobs.job(meetingID: meeting.id))
        XCTAssertFalse(pipeline.hasActiveWork)

        try FileManager.default.removeItem(at: metadata)
        var edited = meeting
        edited.title = "Title edited after failed finalization"
        edited.endedAt = nil
        edited.contentRange = .init(start: 5, end: 45)
        try storage.saveMeta(edited)
        XCTAssertTrue(controller.prepareForTermination())
        let saved = try XCTUnwrap(SessionLookup.loadAllMeetings(root: storage.rootURL).first)
        XCTAssertEqual(saved.title, edited.title)
        XCTAssertEqual(saved.contentRange, edited.contentRange)
        XCTAssertEqual(saved.endedAt?.timeIntervalSince1970 ?? 0,
                       meeting.endedAt?.timeIntervalSince1970 ?? 0, accuracy: 1)
        let job = try XCTUnwrap(jobs.job(meetingID: meeting.id))
        XCTAssertTrue(job.transcribe)
        XCTAssertTrue(job.summarize)
        XCTAssertTrue(job.summaryFollowsSetting)
        XCTAssertEqual(finishedIDs, [meeting.id])
        XCTAssertFalse(pipeline.hasActiveWork)
    }

    func testQueueFailureRetriesWithoutOverwritingSavedMeetingEdits() throws {
        let (storage, meeting) = try makeFinalizationFixture()
        let databaseURL = storage.rootURL.appendingPathComponent("jobs.sqlite")
        let jobs = PipelineJobStore(databaseURL: databaseURL)
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        try database.execute("""
            CREATE TRIGGER reject_job BEFORE INSERT ON pipeline_jobs
            BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END;
            """)
        let pipeline = ProcessingPipeline(storage: storage, jobStore: jobs, settings: { AppSettings() })
        var errors: [String] = []
        let controller = RecordingController(storage: storage,
            settingsStore: SettingsStore(initialSettings: automaticProcessingSettings()),
            audioMonitor: AudioSourceMonitor(), pipeline: pipeline, isInteractive: { false },
            onError: { if let error = $0 { errors.append(error) } }, onMeetingFinished: { _ in })

        XCTAssertFalse(controller.finalize(meeting, process: true, deferProcessing: true))
        XCTAssertFalse(controller.prepareForTermination())
        XCTAssertTrue(errors.contains { $0.contains("processing job could not be saved") })
        XCTAssertNil(jobs.job(meetingID: meeting.id))
        var edited = meeting
        edited.title = "Title edited after stopping"
        try storage.saveMeta(edited)
        try database.execute("DROP TRIGGER reject_job")

        XCTAssertTrue(controller.prepareForTermination())
        XCTAssertEqual(try SessionLookup.loadAllMeetings(root: storage.rootURL).first?.title, edited.title)
        XCTAssertNotNil(jobs.job(meetingID: meeting.id))
        XCTAssertFalse(pipeline.hasActiveWork)
    }

    func testFinalizationMergePreservesExplicitEditsOnCompletedMetadata() throws {
        let (_, meeting) = try makeFinalizationFixture()
        var finalized = meeting
        finalized.recordedDuration = 60
        finalized.contentRange = .init(start: 5, end: 45)
        var edited = finalized
        edited.title = "Later title"
        edited.contentRange = nil

        let merged = RecordingController.mergingFinalization(finalized, into: edited)

        XCTAssertEqual(merged.title, edited.title)
        XCTAssertNil(merged.contentRange, "an explicit later boundary reset must not be restored from stale state")
        XCTAssertEqual(merged.endedAt, edited.endedAt)
        XCTAssertEqual(merged.recordedDuration, edited.recordedDuration)
    }

    func testDeletingFailedFinalizationDiscardsTheRetry() throws {
        let (storage, meeting) = try makeFinalizationFixture()
        let folder = meeting.folderURL(in: storage)
        try storage.deleteMeeting(meeting)
        let jobs = PipelineJobStore(databaseURL: storage.rootURL.appendingPathComponent("jobs.sqlite"))
        let pipeline = ProcessingPipeline(storage: storage, jobStore: jobs, settings: { AppSettings() })
        let controller = RecordingController(storage: storage,
            settingsStore: SettingsStore(initialSettings: automaticProcessingSettings()),
            audioMonitor: AudioSourceMonitor(), pipeline: pipeline, isInteractive: { false },
            onError: { _ in }, onMeetingFinished: { _ in })

        XCTAssertFalse(controller.finalize(meeting, process: true, deferProcessing: true))
        controller.forgetFinalization(meetingIDs: [meeting.id])
        XCTAssertTrue(controller.prepareForTermination())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(jobs.job(meetingID: meeting.id))
    }

    private func makeFinalizationFixture() throws -> (StorageManager, Meeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finalization-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        var meeting = try storage.createMeetingFolder(title: "Synthetic recording", appName: "Fixture")
        meeting.endedAt = meeting.startedAt.addingTimeInterval(60)
        return (storage, meeting)
    }

    private func automaticProcessingSettings() -> AppSettings {
        var settings = AppSettings()
        settings.autoTranscribe = true
        settings.autoSummarize = true
        return settings
    }

    private func makeController() -> RecordingController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-controller-\(UUID().uuidString)",
                                    isDirectory: true)
        let storage = StorageManager(rootURL: root)
        return RecordingController(
            storage: storage,
            settingsStore: SettingsStore(initialSettings: AppSettings()),
            audioMonitor: AudioSourceMonitor(),
            pipeline: ProcessingPipeline(storage: storage, settings: { AppSettings() }),
            isInteractive: { false },
            onError: { message in
                if let message { XCTFail("unexpected error surfaced: \(message)") }
            },
            onMeetingFinished: { _ in XCTFail("no meeting should finish") })
    }

    private var teamsApp: MeetingDetector.DetectedApp {
        MeetingDetector.DetectedApp(
            name: "Teams",
            bundleID: "com.microsoft.teams2",
            pid: 100)
    }

    func testStartsIdleWithZeroElapsedTimer() {
        let controller = makeController()

        XCTAssertFalse(controller.isRecording)
        XCTAssertFalse(controller.isStarting)
        XCTAssertNil(controller.currentMeeting)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertEqual(controller.menuBarTimer, "00:00")
    }

    func testIdleMemoryHealthSnapshotReportsIdleRecorders() {
        let snapshot = makeController().memoryHealthSnapshot()

        XCTAssertFalse(snapshot.isRecording)
        XCTAssertEqual(snapshot.microphoneStatus, "Idle")
        XCTAssertEqual(snapshot.systemAudioStatus, "Idle")
        XCTAssertEqual(snapshot.microphoneDroppedBuffers, 0)
        XCTAssertEqual(snapshot.systemAudioDroppedBuffers, 0)
        XCTAssertNil(snapshot.lastRecoveryAt)
    }

    func testHealthReportsSilenceAfterPreviouslyAudibleSystemAudio() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(health(at: now, lastAudible: now).systemAudioStatus, "Receiving audio")
        XCTAssertEqual(health(at: now, lastAudible: now.addingTimeInterval(-11)).systemAudioStatus, "Silent")
        XCTAssertEqual(health(at: now, lastAudible: nil).systemAudioStatus, "Silent")
    }

    func testHealthKeepsSourceLossIndependentOfTheOtherSource() {
        let now = Date(timeIntervalSince1970: 1_000)
        let staleMic = health(at: now, micWrite: now.addingTimeInterval(-11), lastAudible: now)
        XCTAssertEqual(staleMic.microphoneStatus, "No recent audio")
        XCTAssertEqual(staleMic.systemAudioStatus, "Receiving audio")

        let staleSystem = health(at: now, systemWrite: now.addingTimeInterval(-11), lastAudible: now)
        XCTAssertEqual(staleSystem.microphoneStatus, "Receiving audio")
        XCTAssertEqual(staleSystem.systemAudioStatus, "No recent audio")
        XCTAssertEqual(health(at: now, engineRunning: false).microphoneStatus, "Stopped")
        XCTAssertEqual(health(at: now, attached: false).systemAudioStatus, "Not attached")
    }

    func testHealthExposesRecoveryAndDegradationEvenWithRecentWrites() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recovering = health(at: now, recovery: .recovering(attempt: 2))
        XCTAssertEqual(recovering.microphoneStatus, "Recovering (attempt 2)")
        XCTAssertEqual(recovering.lastRecoveryAt, now)
        XCTAssertEqual(recovering.microphoneDroppedBuffers, 3)
        XCTAssertEqual(recovering.systemAudioDroppedBuffers, 2)
        XCTAssertEqual(health(at: now, recovery: .degraded(errorDescription: "Input unavailable"))
            .microphoneStatus, "Degraded: Input unavailable")
    }

    func testHealthDoesNotPresentUnstartedSourcesAsReceiving() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = RecordingMemoryHealthSnapshot.recording(
            microphone: .init(duration: 0, lastAudioWriteAt: nil, isEngineRunning: true,
                              droppedBufferCount: 0, recoveryState: .healthy),
            system: .init(duration: 0, audibleDuration: 0, framesSinceAttach: 0,
                          lastAudioWriteAt: nil, lastAudibleWriteAt: nil, capturedPID: 42,
                          lastRMSLevel: 0, peakRMSLevel: 0, droppedBufferCount: 0),
            hasSystemTarget: true, lastRecoveryAt: nil, at: now)
        XCTAssertEqual(snapshot.microphoneStatus, "Waiting for audio")
        XCTAssertEqual(snapshot.systemAudioStatus, "Waiting for audio")
    }

    private func health(
        at now: Date,
        micWrite: Date? = nil,
        systemWrite: Date? = nil,
        lastAudible: Date? = nil,
        engineRunning: Bool = true,
        attached: Bool = true,
        recovery: MicRecorder.RecoveryState = .healthy
    ) -> RecordingMemoryHealthSnapshot {
        .recording(
            microphone: .init(duration: 30, lastAudioWriteAt: micWrite ?? now, isEngineRunning: engineRunning,
                              droppedBufferCount: 3, recoveryState: recovery),
            system: .init(duration: 30, audibleDuration: 20, framesSinceAttach: 48_000,
                          lastAudioWriteAt: systemWrite ?? now, lastAudibleWriteAt: lastAudible,
                          capturedPID: 42, lastRMSLevel: 0, peakRMSLevel: 0.5, droppedBufferCount: 2),
            hasSystemTarget: attached, lastRecoveryAt: now, at: now)
    }

    /// A stray stop (menu bar action racing a finished meeting) must be a
    /// no-op, not a crash or a phantom meeting.
    func testStopWhileIdleIsANoOp() {
        let controller = makeController()

        controller.stop()

        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.currentMeeting)
    }

    func testPrepareForTerminationFromIdleKeepsControllerIdle() {
        let controller = makeController()

        XCTAssertTrue(controller.prepareForTermination())

        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.currentMeeting)
    }

    func testExplicitRecordNowBypassesCalendarRepeatCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(RecordingController.shouldSuppressCalendarRepeat(
            source: "ui",
            eventID: "event-1",
            lastEventID: "event-1",
            lastEndedAt: now.addingTimeInterval(-1),
            now: now,
            cooldown: 300))
        XCTAssertFalse(RecordingController.shouldSuppressCalendarRepeat(
            source: "menubar",
            eventID: "event-1",
            lastEventID: "event-1",
            lastEndedAt: now.addingTimeInterval(-1),
            now: now,
            cooldown: 300))
    }

    func testAutomaticCalendarRepeatStillRespectsCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RecordingController.shouldSuppressCalendarRepeat(
            source: "detector",
            eventID: "event-1",
            lastEventID: "event-1",
            lastEndedAt: now.addingTimeInterval(-1),
            now: now,
            cooldown: 300))
        XCTAssertTrue(RecordingController.shouldSuppressCalendarRepeat(
            source: "audio-monitor",
            eventID: "event-1",
            lastEventID: "event-1",
            lastEndedAt: now.addingTimeInterval(-1),
            now: now,
            cooldown: 300))
    }

    func testMicrophoneOnlyPolicyNeverResolvesASystemAudioApp() {
        var fallbackWasCalled = false

        let app = RecordingSystemAudioPolicy.microphoneOnly.captureApp(
            detectedApp: teamsApp,
            fallback: {
                fallbackWasCalled = true
                return teamsApp
            })

        XCTAssertNil(app)
        XCTAssertFalse(fallbackWasCalled)
        XCTAssertEqual(HeadlessCommandRunner.recordSystemAudioPolicy, .microphoneOnly)
    }

    func testMeetingAudioPolicyUsesFallbackOnlyWhenNoAppWasDetected() {
        var fallbackCalls = 0
        let policy = RecordingSystemAudioPolicy.meetingAppWhenAvailable

        XCTAssertEqual(policy.captureApp(
            detectedApp: teamsApp,
            fallback: {
                fallbackCalls += 1
                return nil
            }), teamsApp)
        XCTAssertEqual(fallbackCalls, 0)

        XCTAssertEqual(policy.captureApp(
            detectedApp: nil,
            fallback: {
                fallbackCalls += 1
                return teamsApp
            }), teamsApp)
        XCTAssertEqual(fallbackCalls, 1)
    }

    /// A zero-buffer attachment still takes the current PID out of the running.
    /// `SystemAudioTapLedger` now holds that decision, because the exclusion has
    /// to outlive the tick that made it — see the ledger tests below.
    func testZeroBufferAttachmentExcludesCurrentPIDFromRecovery() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 200, audibleDuration: 0)
        ledger.retire(200)
        XCTAssertEqual(ledger.retiredPIDs, [200])

        XCTAssertTrue(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 0,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
        XCTAssertFalse(SystemAudioRecoveryCandidatePolicy.shouldRetrySamePID(
            framesSinceAttach: 1,
            audibleDuration: 30,
            minimumAudibleDuration: 1))
    }

    func testSamePIDRetryBudgetIsConsumedBeforeTheAttemptOutcome() {
        var budget = SystemAudioSamePIDRetryBudget()

        XCTAssertTrue(budget.beginRetry())
        XCTAssertEqual(budget.attempts, 1)
        XCTAssertTrue(budget.beginRetry())
        XCTAssertEqual(budget.attempts, SystemAudioSamePIDRetryBudget.maximumAttempts)
        XCTAssertFalse(budget.beginRetry(), "failed reattachments must remain bounded")

        budget.reset()
        XCTAssertTrue(budget.canRetry)
        XCTAssertEqual(budget.attempts, 0)
    }

    // MARK: - Silent system audio advisory

    /// The advisory exists for a tap attached to a process that never emits,
    /// so a capture that stayed silent must keep it. Anything that did deliver
    /// a usable track takes it back — including at `stop()`, since the watchdog
    /// tick that would otherwise notice may never come.
    func testWithdrawsSilentSystemAudioWarningOnlyOnceATrackExists() {
        let audible = AudioFileInspector.minimumTranscribableDuration

        XCTAssertTrue(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible))
        XCTAssertTrue(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible * 10))

        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: 0))
        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: true, audibleDuration: audible / 2))

        // Nothing to take back when nothing was ever shown.
        XCTAssertFalse(RecordingController.shouldWithdrawSilentSystemAudioWarning(
            hasWarned: false, audibleDuration: audible * 10))
    }

    /// A reattach withdraws the warning for the failed target and leaves the
    /// replacement eligible to warn again if it also stays silent.
    func testSilentSystemAudioWarningWarnReattachWarnTransition() {
        var warning = SilentSystemAudioWarningState()

        XCTAssertTrue(warning.present())
        XCTAssertTrue(warning.isPresented)
        XCTAssertFalse(warning.present(), "the same target must warn only once")

        XCTAssertTrue(warning.withdraw(), "reattach must withdraw the visible warning")
        XCTAssertFalse(warning.isPresented)
        XCTAssertFalse(warning.withdraw(), "withdrawal must be idempotent")

        XCTAssertTrue(warning.present(), "a silent replacement may surface a fresh warning")
    }

    /// A genuinely silent capture keeps its advisory after stop, but the next
    /// capture start must withdraw it so an old banner cannot outlive the state
    /// that originally presented it.
    func testSilentSystemAudioWarningSurvivesStopUntilNextCaptureStarts() {
        var warning = SilentSystemAudioWarningState()

        XCTAssertTrue(warning.present())
        XCTAssertTrue(warning.isPresented, "stop deliberately preserves a true warning")
        XCTAssertTrue(warning.withdraw(), "the next capture start retires the old warning")
        XCTAssertFalse(warning.isPresented)
    }

    // MARK: - System audio tap ledger

    private var minimumAudible: TimeInterval { AudioFileInspector.minimumTranscribableDuration }

    /// `CaptureHealth.audibleDuration` counts the whole file, so a tap that
    /// inherits a healthy total must not inherit the standing that goes with
    /// it — otherwise the first process the watchdog moves to counts as proven
    /// before it has written a sample, and earns the long grace for nothing.
    func testProofIsAttributedToTheTapThatEarnedIt() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 132.76, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8430)

        // Moving to a sibling carries the session total across untouched.
        ledger.attached(to: 8449, audibleDuration: 132.76)
        ledger.observe(pid: 8449, audibleDuration: 132.76, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8430)

        // Only audio this tap wrote itself transfers the standing.
        ledger.observe(pid: 8449, audibleDuration: 140, minimum: minimumAudible)
        XCTAssertEqual(ledger.provenPID, 8449)
    }

    /// Eight seconds of silence is a pause between two sentences. A tap that has
    /// written audible audio is not the reason for it and stays put; one that
    /// has proved nothing is still worth moving that quickly.
    func testProvenTapWaitsOutAnOrdinaryPause() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 8)

        ledger.observe(pid: 8430, audibleDuration: 12, minimum: minimumAudible)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 90)
        // The patience is for that tap alone, not for silence in general.
        XCTAssertEqual(ledger.silenceGrace(for: 8449, ordinary: 8, proven: 90), 8)
    }

    /// The long grace protects a proven tap only while there is no better
    /// evidence. If a different helper is actively emitting, recovery should
    /// use the ordinary threshold and follow the call there.
    func testProvenTapDoesNotWaitForLongGraceWhenSiblingIsEmitting() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 12, minimum: minimumAudible)

        XCTAssertEqual(ledger.silenceGrace(
            for: 8430,
            ordinary: 8,
            proven: 90,
            activelyEmittingAlternative: true), 8)
        XCTAssertEqual(ledger.silenceGrace(
            for: 8430,
            ordinary: 8,
            proven: 90,
            activelyEmittingAlternative: false), 90)
    }

    /// Replays the flap in the log of 2026-08-25 10:36–10:57: modulehost carried
    /// the call, a helper delivered nothing, and the watchdog swapped between
    /// them every 10–15 s because each lookup was free to hand back the empty
    /// one. Excluding only the tap in hand cannot stop that; the exclusion has
    /// to persist.
    func testARetiredTapIsNeverHandedBack() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 132.76, minimum: minimumAudible)

        // One bounce onto the helper, which delivers not a single buffer.
        ledger.attached(to: 8449, audibleDuration: 132.76)
        ledger.retire(8449)
        XCTAssertEqual(ledger.retiredPIDs, [8449])
        XCTAssertEqual(ledger.provenPID, 8430)

        // Back on modulehost, and the helper stays out of the running.
        ledger.attached(to: 8430, audibleDuration: 132.76)
        XCTAssertEqual(ledger.retiredPIDs, [8449])
    }

    /// A PID that proved itself earlier and now delivers nothing has stopped
    /// being the answer; standing follows the evidence in both directions.
    func testRetiringClearsStandingAndAttachingRestoresEligibility() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 20, minimum: minimumAudible)
        ledger.retire(8430)
        XCTAssertNil(ledger.provenPID)
        XCTAssertEqual(ledger.silenceGrace(for: 8430, ordinary: 8, proven: 90), 8)

        // Teams reuses the process; a fresh attachment gets a fresh hearing.
        ledger.attached(to: 8430, audibleDuration: 20)
        XCTAssertTrue(ledger.retiredPIDs.isEmpty)
    }

    /// Each recording starts with no knowledge of the last one's processes.
    func testLedgerResetForgetsEverything() {
        var ledger = SystemAudioTapLedger()
        ledger.attached(to: 8430, audibleDuration: 0)
        ledger.observe(pid: 8430, audibleDuration: 20, minimum: minimumAudible)
        ledger.retire(8449)
        ledger.reset()
        XCTAssertEqual(ledger, SystemAudioTapLedger())
        XCTAssertNil(ledger.provenPID)
        XCTAssertTrue(ledger.retiredPIDs.isEmpty)
    }
}
