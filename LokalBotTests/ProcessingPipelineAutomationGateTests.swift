import XCTest
@testable import LokalBot

/// The automation gate: automatic jobs (auto-transcribe after a recording,
/// launch resume) must never trigger a model download — they park as
/// `.waitingForModels` without burning auto-resume attempts. User-initiated
/// jobs pass straight through.
@MainActor
final class ProcessingPipelineAutomationGateTests: XCTestCase {
    func testTerminationPersistsAJobWithoutStartingProcessing() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("jobs.sqlite")
        let jobs = PipelineJobStore(databaseURL: url)
        let pipeline = makePipeline(root: root, jobStore: jobs, readiness: ReadinessBox())
        let meeting = makeMeeting()
        XCTAssertTrue(pipeline.deferUntilNextLaunch(meeting, summarize: true))
        XCTAssertFalse(pipeline.hasActiveWork)
        XCTAssertTrue(pipeline.stages.isEmpty)
        let reopened = PipelineJobStore(databaseURL: url)
        let queued = try XCTUnwrap(reopened.job(meetingID: meeting.id))
        XCTAssertTrue(queued.transcribe)
        XCTAssertTrue(queued.summarize)
        XCTAssertTrue(queued.summaryFollowsSetting)
    }

    func testTerminationPreservesAnExistingExplicitProcessingRequest() throws {
        let root = try makeRoot()
        let jobs = PipelineJobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
        let pipeline = makePipeline(root: root, jobStore: jobs, readiness: ReadinessBox())
        let meeting = makeMeeting()
        XCTAssertTrue(jobs.enqueue(meetingID: meeting.id, transcribe: false, summarize: true,
                                   summaryFollowsSetting: false))
        XCTAssertTrue(jobs.markStarted(meetingID: meeting.id))
        let explicitRequest = try XCTUnwrap(jobs.job(meetingID: meeting.id))

        XCTAssertTrue(pipeline.deferUntilNextLaunch(meeting, summarize: false))

        XCTAssertEqual(jobs.job(meetingID: meeting.id), explicitRequest)
        XCTAssertFalse(pipeline.hasActiveWork)
        XCTAssertTrue(pipeline.stages.isEmpty)
    }

    func testTerminationCannotQueueWithoutADurableStore() throws {
        let root = try makeRoot()
        let pipeline = makePipeline(root: root, readiness: ReadinessBox())

        XCTAssertFalse(pipeline.deferUntilNextLaunch(makeMeeting(), summarize: true))
        XCTAssertFalse(pipeline.hasActiveWork)
        XCTAssertTrue(pipeline.stages.isEmpty)
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeMeeting() -> Meeting {
        Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                startedAt: Date(), endedAt: Date(),
                relativePath: "meetings/2026/08/17-standup-\(UUID().uuidString.prefix(8))")
    }

    /// Readiness stub whose answers can flip mid-test, standing in for a
    /// model download completing.
    private final class ReadinessBox {
        var transcriptionReady = false
        var thinkReady = false
    }

    private actor AsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private enum IntentTestError: Error {
        case stopAfterGate
    }

    private func makePipeline(root: URL,
                              jobStore: PipelineJobStore? = nil,
                              readiness: ReadinessBox) -> ProcessingPipeline {
        ProcessingPipeline(
            storage: StorageManager(rootURL: root),
            jobStore: jobStore,
            settings: { AppSettings() },
            automationReadiness: .init(
                transcription: { _ in readiness.transcriptionReady },
                think: { _, _ in readiness.thinkReady }))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStageVocabularyForWaitingForModels() {
        let stage = ProcessingPipeline.Stage.waitingForModels
        XCTAssertEqual(stage.rowLabel, "Waiting for models")
        XCTAssertFalse(stage.isFailure)
        XCTAssertTrue(stage.isWaitingForModels)
        XCTAssertFalse(ProcessingPipeline.Stage.queued.isWaitingForModels)
    }

    func testHeadlessSummaryOnlyKeepsTheExistingTranscript() throws {
        let folder = URL(fileURLWithPath: "/tmp/example-meeting", isDirectory: true)

        XCTAssertEqual(
            HeadlessCommand.parse([
                "LokalBot", "--process", folder.path, "--summary-only",
            ]),
            .process(folder: folder, transcribe: false, summarize: true))
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--process", folder.path]),
            .process(folder: folder, transcribe: true, summarize: true))
    }

    func testAutomaticJobParksWithoutBurningAttemptsWhenModelMissing() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)
        XCTAssertTrue(pipeline.hasJobsWaitingForModels)
        XCTAssertFalse(pipeline.hasActiveWork)
        let pending = jobStore.pendingJobs()
        XCTAssertEqual(pending.count, 1, "the durable row must survive parking")
        XCTAssertEqual(pending.first?.attempts, 0,
                       "waiting must not burn launch auto-resume attempts")
    }

    func testParkedJobProcessesOnceModelsArrive() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: false, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }
        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)

        // Still missing: a re-check parks again instead of downloading.
        pipeline.retryJobsWaitingForModels()
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }
        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)

        // "Download finished": the job passes the gate and actually runs —
        // this hermetic meeting has no audio, so passing the gate shows up
        // as the pipeline's no-audio failure rather than a parked stage.
        readiness.transcriptionReady = true
        pipeline.retryJobsWaitingForModels()
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
    }

    func testUserInitiatedJobBypassesTheGate() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        // Default origin is user-initiated (Retry, Process menu, --process):
        // the job runs — and fails on missing audio — instead of parking.
        pipeline.enqueue(meeting, transcribe: true, summarize: false)
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
    }

    func testExplicitRetryAbsorbsTheParkedJob() async throws {
        let root = try makeRoot()
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        // "Download & process" re-enqueues user-initiated: the parked copy is
        // merged away and the job runs.
        pipeline.enqueue(meeting, transcribe: true, summarize: true)
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
        XCTAssertEqual(pipeline.stages[meeting.id]?.isFailure, true)
        XCTAssertFalse(pipeline.hasJobsWaitingForModels,
                       "the parked copy must not linger after an explicit retry")
    }

    /// Pressing "Transcribe" must stay transcribe-only even when a job for the
    /// same meeting is already queued or parked asking for a summary.
    func testUserInitiatedEnqueueDoesNotInheritAQueuedSummary() {
        let pending = ProcessingPipeline.Work(transcribe: true, summarize: true)

        let user = ProcessingPipeline.merged(
            pending: pending,
            incoming: .init(transcribe: true, summarize: false),
            origin: .userInitiated)

        XCTAssertEqual(user, .init(transcribe: true, summarize: false))
    }

    /// The opposite direction still merges: automatic re-enqueues (launch
    /// resume, a model finishing its download) must not drop a parked summary.
    func testAutomaticEnqueueStillMergesPendingWork() {
        let automatic = ProcessingPipeline.merged(
            pending: .init(transcribe: false, summarize: true),
            incoming: .init(transcribe: true, summarize: false),
            origin: .automatic)

        XCTAssertEqual(automatic, .init(transcribe: true, summarize: true))
    }

    /// Transcription is the prerequisite for everything downstream, so it
    /// merges by OR regardless of who asked: "Re-summarize" on a meeting whose
    /// transcript is still queued must not cancel that transcription.
    func testTranscriptionIsNeverDroppedByAUserChoice() {
        let work = ProcessingPipeline.merged(
            pending: .init(transcribe: true, summarize: false),
            incoming: .init(transcribe: false, summarize: true),
            origin: .userInitiated)

        XCTAssertEqual(work, .init(transcribe: true, summarize: true))
    }

    func testActiveTranscriptionAcceptsAndPersistsNewUserSummaryIntent() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let gate = AsyncGate()
        let pipeline = ProcessingPipeline(
            storage: StorageManager(rootURL: root),
            jobStore: jobStore,
            settings: { AppSettings() },
            transcriptionStarted: { _ in await gate.suspend() })
        let meeting = makeMeeting()

        XCTAssertEqual(
            pipeline.enqueue(meeting, transcribe: true, summarize: true),
            .enqueued)
        await gate.waitUntilStarted()

        XCTAssertEqual(
            pipeline.enqueue(meeting, transcribe: true, summarize: false),
            .updatedActive)
        let persisted = try XCTUnwrap(jobStore.pendingJobs().first)
        XCTAssertFalse(persisted.summarize)
        XCTAssertFalse(persisted.summaryFollowsSetting)
        XCTAssertEqual(persisted.attempts, 1)

        await gate.release()
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
    }

    func testRequestAfterSummaryStartsReturnsVisibleFeedbackOutcome() async throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        let gate = AsyncGate()
        let pipeline = ProcessingPipeline(
            storage: storage,
            settings: { AppSettings() },
            builtInModelPreparer: { _, _ in
                await gate.suspend()
                throw IntentTestError.stopAfterGate
            })
        let meeting = makeMeeting()
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        try pipeline.saveTranscript(
            Transcript(
                segments: [.init(
                    start: 0,
                    end: 1,
                    speaker: "me",
                    text: "Status update",
                    confidence: 1,
                    timingPrecision: .span)],
                engine: "test"),
            for: meeting)

        pipeline.enqueue(meeting, transcribe: false, summarize: true)
        await gate.waitUntilStarted()

        XCTAssertEqual(
            pipeline.enqueue(meeting, transcribe: true, summarize: false),
            .alreadyProcessing)

        await gate.release()
        await waitUntil { pipeline.stages[meeting.id]?.isFailure == true }
    }

    func testResumedAutomaticSummaryHonorsCurrentOptOut() {
        let work = ProcessingPipeline.resumedWork(
            pending: .init(transcribe: true, summarize: true),
            summaryFollowsSetting: true,
            autoSummarize: false,
            transcriptionCompleted: false)

        XCTAssertEqual(work, .init(transcribe: true, summarize: false))
    }

    func testResumedExplicitSummarySurvivesCurrentAutoSetting() {
        let work = ProcessingPipeline.resumedWork(
            pending: .init(transcribe: false, summarize: true),
            summaryFollowsSetting: false,
            autoSummarize: false,
            transcriptionCompleted: true)

        XCTAssertEqual(work, .init(transcribe: false, summarize: true))
    }

    func testRetryWorkResumesAfterExistingTranscript() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        let meeting = makeMeeting()
        let folder = meeting.folderURL(in: storage)

        let missingTranscript = ProcessingPipeline.retryWork(
            hasTranscript: false,
            autoSummarize: true,
            persistedJob: nil)
        XCTAssertEqual(
            missingTranscript,
            .init(transcribe: true, summarize: true))

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("transcript.json"))

        let existingTranscript = ProcessingPipeline.retryWork(
            hasTranscript: true,
            autoSummarize: true,
            persistedJob: nil)
        XCTAssertEqual(
            existingTranscript,
            .init(transcribe: false, summarize: true))
    }

    /// With no durable intent, Retry must not destroy a completed transcript
    /// merely to avoid becoming a no-op.
    func testRetryWorkDoesNotOverwriteTranscriptWhenAutoSummarizeIsOff() {
        let work = ProcessingPipeline.retryWork(
            hasTranscript: true,
            autoSummarize: false,
            persistedJob: nil)

        XCTAssertEqual(work, .init(transcribe: false, summarize: false))
    }

    func testRetryWorkDoesNotLetAnOldTranscriptSatisfyFreshASRIntent() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("transcript.json"))
        jobStore.enqueue(
            meetingID: meeting.id,
            transcribe: true,
            summarize: true,
            summaryFollowsSetting: false)

        let work = pipeline.retryWork(for: meeting, autoSummarize: false)

        XCTAssertEqual(work, .init(transcribe: true, summarize: true),
                       "a transcript that predates this job cannot satisfy its ASR phase")
    }

    func testRetryWorkSkipsASROnlyAfterThisJobPersistsCompletion() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("transcript.json"))
        jobStore.enqueue(
            meetingID: meeting.id,
            transcribe: true,
            summarize: true,
            summaryFollowsSetting: false)
        XCTAssertTrue(jobStore.markTranscriptionCompleted(meetingID: meeting.id))

        let work = pipeline.retryWork(for: meeting, autoSummarize: false)

        XCTAssertEqual(work, .init(transcribe: false, summarize: true))
    }

    func testRetryWorkDoesNotInventSummaryForPersistedTranscriptOnlyJob() throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()
        jobStore.enqueue(
            meetingID: meeting.id,
            transcribe: true,
            summarize: false,
            summaryFollowsSetting: false)

        let work = pipeline.retryWork(for: meeting, autoSummarize: true)

        XCTAssertEqual(work, .init(transcribe: true, summarize: false))
    }

    func testAutomaticSummaryParksButKeepsExistingTranscript() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        readiness.transcriptionReady = true
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        // A transcript already on disk (live transcription, earlier run):
        // only the summary needs Think, so only the summary waits.
        let storage = StorageManager(rootURL: root)
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("transcript.json"))

        pipeline.enqueue(meeting, transcribe: false, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        XCTAssertEqual(pipeline.stages[meeting.id], .waitingForModels)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("transcript.json").path),
            "parking the summary must not disturb the transcript")

        // Repeated launch/download readiness checks while Think is still
        // absent must remain pure waits, not crash-loop processing attempts.
        for _ in 0..<(PipelineJobStore.maxAutoResumeAttempts + 1) {
            pipeline.retryJobsWaitingForModels()
            await waitUntil {
                pipeline.stages[meeting.id] == .waitingForModels
                    && !pipeline.hasActiveWork
            }
        }
        let pending = jobStore.pendingJobs()
        XCTAssertEqual(pending.first?.attempts, 0,
                       "summary-only waiting must preserve the auto-resume budget")
        XCTAssertTrue(jobStore.parkedJobs().isEmpty)
    }

    // MARK: - Readiness helpers

    func testThinkReadinessTracksBackendAndLocalModel() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn

        XCTAssertFalse(ModelReadinessSnapshot.thinkReady(settings, storage: storage),
                       "no GGUF on disk yet")

        let entry = try XCTUnwrap(ModelCatalog.entry(id: settings.builtInModelID))
        let url = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
        XCTAssertTrue(ModelReadinessSnapshot.thinkReady(settings, storage: storage))

        settings.summarizerBackend = .openAICompatible
        XCTAssertTrue(ModelReadinessSnapshot.thinkReady(settings, storage: storage),
                      "remote backends have their own approval flow — never gated here")
    }

    func testMissingCoreModelBytesCountsOnlyMissingGGUFs() throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        let think = ModelCatalog.Entry(
            id: "custom-think", displayName: "Think", fileName: "think.gguf",
            url: "https://example.com/think.gguf", sizeBytes: 1_000, sizeGB: 0.001,
            blurb: "", disablesThinking: false)
        let autocomplete = ModelCatalog.Entry(
            id: "custom-ac", displayName: "Autocomplete", fileName: "ac.gguf",
            url: "https://example.com/ac.gguf", sizeBytes: 500, sizeGB: 0.0005,
            blurb: "", disablesThinking: false)
        settings.customBuiltInModels = [think, autocomplete]
        settings.builtInModelID = think.id
        settings.cotypingBuiltInModelID = autocomplete.id

        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 1_500)

        let url = storage.rootURL.appendingPathComponent("models/\(autocomplete.fileName)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 1_000,
            "a model already on disk no longer counts as pending download")

        settings.summarizerBackend = .ollama
        XCTAssertEqual(
            ModelReadinessSnapshot.missingCoreModelBytes(settings, storage: storage), 0,
            "a remote Think backend needs no local Think download")
    }

    func testProcessingReadinessChangeTracksPipelineModelSelections() {
        let original = AppSettings()

        var changed = original
        changed.transcriptionModel = .parakeetV3
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.summarizerBackend = .ollama
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.builtInModelID = "another-think-model"
        XCTAssertTrue(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed))

        changed = original
        changed.autoSummarize.toggle()
        XCTAssertFalse(ModelReadinessSnapshot.processingReadinessChanged(
            from: original, to: changed),
            "non-readiness settings must not churn parked jobs")
    }

    func testForgetDropsParkedJobsForDeletedMeetings() async throws {
        let root = try makeRoot()
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let readiness = ReadinessBox()
        let pipeline = makePipeline(root: root, jobStore: jobStore, readiness: readiness)
        let meeting = makeMeeting()

        pipeline.enqueue(meeting, transcribe: true, summarize: true, origin: .automatic)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }

        await pipeline.forget(meetingIDs: [meeting.id])

        XCTAssertNil(pipeline.stages[meeting.id])
        XCTAssertFalse(pipeline.hasJobsWaitingForModels)
        XCTAssertTrue(jobStore.pendingJobs().isEmpty,
                      "a deleted meeting's durable row must not resurrect processing")
        XCTAssertEqual(
            pipeline.enqueue(meeting, transcribe: true, summarize: false),
            .revoked)
        pipeline.restoreForgottenMeetings([meeting.id])
        XCTAssertEqual(
            pipeline.enqueue(
                meeting,
                transcribe: true,
                summarize: false,
                origin: .automatic),
            .enqueued)
        await waitUntil { pipeline.stages[meeting.id] == .waitingForModels }
        await pipeline.forget(meetingIDs: [meeting.id])
    }

    func testForgetCancelsAndAwaitsActiveProcessingBeforeDeletion() async throws {
        let root = try makeRoot()
        let storage = StorageManager(rootURL: root)
        let jobStore = PipelineJobStore(
            databaseURL: root.appendingPathComponent("test.sqlite"))
        let gate = AsyncGate()
        let meeting = makeMeeting()
        let folder = meeting.folderURL(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipeline = ProcessingPipeline(
            storage: storage,
            jobStore: jobStore,
            settings: { AppSettings() },
            transcriptionStarted: { _ in await gate.suspend() })
        var artifactCallbackCount = 0
        pipeline.onArtifactsWritten = { _ in artifactCallbackCount += 1 }

        XCTAssertEqual(
            pipeline.enqueue(meeting, transcribe: true, summarize: true),
            .enqueued)
        await gate.waitUntilStarted()

        var forgetFinished = false
        let forgetting = Task { @MainActor in
            await pipeline.forget(meetingIDs: [meeting.id])
            forgetFinished = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(forgetFinished, "deletion must wait for the active job to stop")

        await gate.release()
        await forgetting.value
        try FileManager.default.removeItem(at: folder)
        await waitUntil { !pipeline.hasActiveWork }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(pipeline.stages[meeting.id])
        XCTAssertNil(jobStore.job(meetingID: meeting.id))
        XCTAssertEqual(artifactCallbackCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "cancelled diagnostics must not recreate a deleted meeting folder")
    }
}
