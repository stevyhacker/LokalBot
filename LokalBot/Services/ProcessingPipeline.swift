import Foundation

/// Serial post-meeting queue (design doc §6): transcribe each track,
/// merge by timestamp into a speaker-attributed transcript, then summarize
/// with the configured local LLM. Writes transcript.json / transcript.md /
/// summary.md next to the audio.
@MainActor
final class ProcessingPipeline: ObservableObject {

    typealias BuiltInModelPreparer = ThinkExecution.BuiltInModelPreparer

    enum Stage: Equatable {
        case queued
        case waitingForModels
        case preparingTranscriptionModel
        case preparingDiarizationModel
        case preparingSummaryModel
        case transcribing
        case diarizing
        case summarizing
        case failed(String)

        var label: String {
            switch self {
            case .queued: "Queued…"
            case .waitingForModels:
                "Waiting for models — the recording is saved. Download the selected models in Settings → Models, or use Download & process to fetch them now."
            case .preparingTranscriptionModel:
                "Preparing transcription model (download size depends on your selection)…"
            case .preparingDiarizationModel:
                "Preparing speaker diarization model…"
            case .preparingSummaryModel:
                "Preparing summary model (download size depends on your selection)…"
            case .transcribing: "Transcribing…"
            case .diarizing: "Identifying speakers…"
            case .summarizing: "Summarizing…"
            case .failed(let message): "Failed: \(message)"
            }
        }

        /// Compact vocabulary for meeting-list rows. The detail pane keeps
        /// the more descriptive label above; rows need to stay scannable.
        var rowLabel: String {
            switch self {
            case .queued: "Queued"
            case .waitingForModels: "Waiting for models"
            case .preparingTranscriptionModel: "Preparing speech model"
            case .preparingDiarizationModel: "Preparing speaker model"
            case .preparingSummaryModel: "Preparing summary model"
            case .transcribing: "Transcribing"
            case .diarizing: "Identifying speakers"
            case .summarizing: "Summarizing"
            case .failed: "Failed"
            }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }

        /// The job is parked because processing would trigger a model download
        /// the user never asked for. Neither a failure nor active work.
        var isWaitingForModels: Bool { self == .waitingForModels }
    }

    /// Who asked for this job. Automatic jobs (auto-transcribe after a
    /// recording, launch crash-resume) must never trigger a model download —
    /// they park as `.waitingForModels` instead. A user-initiated job (Retry,
    /// the Process menu, `--process`) downloads missing models on demand,
    /// because the user just asked for exactly that.
    enum JobOrigin: Equatable {
        case automatic
        case userInitiated
    }

    enum EnqueueOutcome: Equatable {
        case enqueued
        case coalesced
        case updatedActive
        case alreadyProcessing
        case persistenceFailed
    }

    struct Job {
        var meeting: Meeting
        var transcribe: Bool
        var summarize: Bool
        var summaryFollowsSetting: Bool = false
        /// Re-enqueued from the persisted queue after a crash/quit — keep any
        /// per-track checkpoints instead of starting from scratch.
        var resumed: Bool = false
        var origin: JobOrigin = .userInitiated
        var enqueuedAt = Date()
    }

    struct RetryWork: Equatable {
        var transcribe: Bool
        var summarize: Bool
    }

    /// Resume the exact durable request from its latest completed artifact.
    /// Failed rows retain their explicit/automatic summary provenance, even
    /// after they exhaust the launch-resume attempt budget. Only jobs from an
    /// older build with no durable row fall back to the current setting.
    func retryWork(for meeting: Meeting, autoSummarize: Bool) -> RetryWork {
        let transcriptURL = meeting.folderURL(in: storage)
            .appendingPathComponent("transcript.json")
        return Self.retryWork(
            hasTranscript: FileManager.default.fileExists(atPath: transcriptURL.path),
            autoSummarize: autoSummarize,
            persistedJob: jobStore?.job(meetingID: meeting.id))
    }

    nonisolated static func retryWork(
        hasTranscript: Bool,
        autoSummarize: Bool,
        persistedJob: PipelineJobStore.PendingJob?
    ) -> RetryWork {
        guard let persistedJob else {
            // With no saved intent, never overwrite a completed transcript.
            // The explicit Process menu remains available for a deliberate
            // re-transcription.
            return RetryWork(
                transcribe: !hasTranscript,
                summarize: autoSummarize)
        }
        let resumed = resumedWork(
            pending: Work(
                transcribe: persistedJob.transcribe,
                summarize: persistedJob.summarize),
            summaryFollowsSetting: persistedJob.summaryFollowsSetting,
            autoSummarize: autoSummarize,
            hasTranscript: hasTranscript)
        return RetryWork(
            transcribe: resumed.transcribe,
            summarize: resumed.summarize)
    }

    /// Injectable model-readiness checks so unit tests can exercise the
    /// automation gate without touching real model folders (or the network).
    struct AutomationReadiness {
        var transcription: (AppSettings) -> Bool
        var think: @MainActor (AppSettings, StorageManager) -> Bool

        static let live = AutomationReadiness(
            transcription: ModelReadinessSnapshot.transcriptionReady,
            think: ModelReadinessSnapshot.thinkReady)
    }

    /// Stage per meeting. `.failed` sticks around until the next attempt;
    /// successful meetings are removed (the files on disk are the result).
    @Published private(set) var stages: [Meeting.ID: Stage] = [:]

    private let storage: StorageManager
    private let settings: () -> AppSettings
    let thinkExecution: ThinkExecution
    private let automationReadiness: AutomationReadiness
    /// In-memory work list; `jobStore` mirrors it on disk so a crash mid-queue
    /// loses nothing — see `resumePending(meetings:)`.
    private var queue: [Job] = []
    /// Automatic jobs parked because their models are not downloaded yet.
    /// Their durable rows stay pending (no attempt burned), so a relaunch
    /// re-checks them; `retryJobsWaitingForModels()` re-checks mid-session.
    private var waitingForModelsJobs: [Job] = []
    private var isDraining = false
    private var activeMeetingID: Meeting.ID?
    private var activeJob: Job?
    private enum ActivePhase {
        case transcribing
        case summarizing
    }
    private var activePhase: ActivePhase?
    /// Optional lifecycle seam for focused queue tests; production leaves it nil.
    private let transcriptionStarted: ((Meeting.ID) async -> Void)?
    var hasActiveWork: Bool { isDraining || activeMeetingID != nil }
    var hasJobsWaitingForModels: Bool { !waitingForModelsJobs.isEmpty }
    private let diarizer = NeuralDiarizationEngine()
    private let speakerIdentity: MeetingSpeakerIdentityService?
    private let jobStore: PipelineJobStore?
    /// Fired after transcript/summary files land on disk (search re-index).
    var onArtifactsWritten: ((Meeting) -> Void)?

    init(storage: StorageManager, jobStore: PipelineJobStore? = nil,
         settings: @escaping () -> AppSettings,
         thinkExecution: ThinkExecution? = nil,
         speakerIdentity: MeetingSpeakerIdentityService? = nil,
         builtInModelPreparer: @escaping BuiltInModelPreparer = { entry, storage in
             try await ModelDownloadManager.shared.ensureAvailable(entry, storage: storage)
         },
         automationReadiness: AutomationReadiness = .live,
         transcriptionStarted: ((Meeting.ID) async -> Void)? = nil) {
        self.storage = storage
        self.jobStore = jobStore
        self.speakerIdentity = speakerIdentity
        self.settings = settings
        self.thinkExecution = thinkExecution ?? ThinkExecution(
            storage: storage,
            builtInModelPreparer: builtInModelPreparer)
        self.automationReadiness = automationReadiness
        self.transcriptionStarted = transcriptionStarted
    }

    /// One job's requested work, and how a fresh enqueue combines with work
    /// already queued or parked for the same meeting.
    struct Work: Equatable {
        var transcribe: Bool
        var summarize: Bool
    }

    /// Transcription merges by OR — it is the prerequisite for everything
    /// downstream, so a pending one must never be dropped. Summarization does
    /// not: it is the discretionary half, and OR-ing it let a queued job
    /// silently upgrade an explicit "Transcribe" click into "Transcribe &
    /// Summarize". A user-initiated enqueue states the summary intent
    /// outright and the older job defers to it; automatic work still merges,
    /// so a parked summary survives an auto re-enqueue. Pure, so the
    /// escalation rule is testable without a live queue.
    nonisolated static func merged(pending: Work, incoming: Work,
                                   origin: JobOrigin) -> Work {
        Work(
            transcribe: pending.transcribe || incoming.transcribe,
            summarize: origin == .userInitiated
                ? incoming.summarize
                : pending.summarize || incoming.summarize)
    }

    /// Whether merged summary work should be cancelled when auto-summarize is
    /// off at crash-resume time. An explicit summary already waiting remains
    /// explicit; otherwise automatic work follows the current setting.
    nonisolated static func mergedSummaryFollowsSetting(
        pending: Work,
        pendingFollowsSetting: Bool,
        incoming: Work,
        origin: JobOrigin
    ) -> Bool {
        if origin == .userInitiated { return false }
        if pending.summarize, !pendingFollowsSetting { return false }
        return incoming.summarize || pending.summarize
    }

    nonisolated static func resumedWork(
        pending: Work,
        summaryFollowsSetting: Bool,
        autoSummarize: Bool,
        hasTranscript: Bool
    ) -> Work {
        Work(
            transcribe: pending.transcribe && !hasTranscript,
            summarize: pending.summarize
                && (!summaryFollowsSetting || autoSummarize))
    }

    @discardableResult
    func enqueue(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true,
                 origin: JobOrigin = .userInitiated) -> EnqueueOutcome {
        // A fresh enqueue supersedes a parked waiting-for-models job: merge its
        // requested work so the new attempt (and its origin) covers both.
        var work = Work(transcribe: transcribe, summarize: summarize)
        var summaryFollowsSetting = origin == .automatic
        if let waitingIndex = waitingForModelsJobs.firstIndex(
            where: { $0.meeting.id == meeting.id }) {
            let waiting = waitingForModelsJobs.remove(at: waitingIndex)
            let pending = Work(
                transcribe: waiting.transcribe,
                summarize: waiting.summarize)
            summaryFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: waiting.summaryFollowsSetting,
                incoming: work,
                origin: origin)
            work = Self.merged(pending: pending, incoming: work, origin: origin)
        }
        let transcribe = work.transcribe
        let summarize = work.summarize
        if let index = queue.firstIndex(where: { $0.meeting.id == meeting.id }) {
            let pending = Work(
                transcribe: queue[index].transcribe,
                summarize: queue[index].summarize)
            let mergedFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: queue[index].summaryFollowsSetting,
                incoming: work,
                origin: origin)
            let coalesced = Self.merged(
                pending: pending,
                incoming: work,
                origin: origin)
            let mergedTranscribe = coalesced.transcribe
            let mergedSummarize = coalesced.summarize
            if let jobStore,
               !jobStore.enqueue(
                    meetingID: meeting.id,
                    transcribe: mergedTranscribe,
                    summarize: mergedSummarize,
                    summaryFollowsSetting: mergedFollowsSetting) {
                stages[meeting.id] = .failed("Could not persist the processing queue update.")
                return .persistenceFailed
            }
            queue[index].transcribe = mergedTranscribe
            queue[index].summarize = mergedSummarize
            queue[index].summaryFollowsSetting = mergedFollowsSetting
            queue[index].resumed = false
            if origin == .userInitiated { queue[index].origin = .userInitiated }
            lokalbotLog(
                "pipeline coalesced queued meeting=\(meeting.id) "
                    + "transcribe=\(mergedTranscribe) summarize=\(mergedSummarize)")
            return .coalesced
        }
        if activeMeetingID == meeting.id, var activeJob {
            guard activePhase == .transcribing else {
                lokalbotLog(
                    "pipeline request too late while summarizing meeting=\(meeting.id)")
                return .alreadyProcessing
            }
            let pending = Work(
                transcribe: activeJob.transcribe,
                summarize: activeJob.summarize)
            let updated = Self.merged(pending: pending, incoming: work, origin: origin)
            let updatedFollowsSetting = Self.mergedSummaryFollowsSetting(
                pending: pending,
                pendingFollowsSetting: activeJob.summaryFollowsSetting,
                incoming: work,
                origin: origin)
            if let jobStore,
               !jobStore.updateIntent(
                    meetingID: meeting.id,
                    transcribe: updated.transcribe,
                    summarize: updated.summarize,
                    summaryFollowsSetting: updatedFollowsSetting) {
                return .persistenceFailed
            }
            activeJob.transcribe = updated.transcribe
            activeJob.summarize = updated.summarize
            activeJob.summaryFollowsSetting = updatedFollowsSetting
            if origin == .userInitiated { activeJob.origin = .userInitiated }
            self.activeJob = activeJob
            lokalbotLog(
                "pipeline updated active meeting=\(meeting.id) "
                    + "transcribe=\(updated.transcribe) summarize=\(updated.summarize)")
            return .updatedActive
        }
        if let jobStore,
           !jobStore.enqueue(
                meetingID: meeting.id,
                transcribe: transcribe,
                summarize: summarize,
                summaryFollowsSetting: summaryFollowsSetting) {
            stages[meeting.id] = .failed("Could not persist the processing job.")
            return .persistenceFailed
        }
        queue.append(Job(
            meeting: meeting,
            transcribe: transcribe,
            summarize: summarize,
            summaryFollowsSetting: summaryFollowsSetting,
            origin: origin))
        lokalbotLog(
            "pipeline enqueued meeting=\(meeting.id) transcribe=\(transcribe) "
                + "summarize=\(summarize) origin=\(origin == .userInitiated ? "user" : "auto")")
        stages[meeting.id] = .queued
        drain()
        return .enqueued
    }

    /// Re-check every job parked on missing models — call when a model
    /// download finishes or the selection changes. Jobs whose models are still
    /// missing simply park again; nothing downloads from this path.
    func retryJobsWaitingForModels() {
        guard !waitingForModelsJobs.isEmpty else { return }
        let parked = waitingForModelsJobs
        waitingForModelsJobs = []
        for job in parked {
            queue.append(job)
            stages[job.meeting.id] = .queued
        }
        lokalbotLog("pipeline rechecking \(parked.count) job(s) waiting for models")
        drain()
    }

    /// Drop all pipeline state for deleted meetings so a parked or queued job
    /// cannot resurrect processing for a folder that no longer exists.
    func forget(meetingIDs: Set<Meeting.ID>) {
        guard !meetingIDs.isEmpty else { return }
        queue.removeAll { meetingIDs.contains($0.meeting.id) }
        waitingForModelsJobs.removeAll { meetingIDs.contains($0.meeting.id) }
        for id in meetingIDs where stages[id] != nil {
            stages[id] = nil
        }
        if let jobStore {
            for id in meetingIDs { jobStore.markCompleted(meetingID: id) }
        }
    }

    /// Crash recovery, called once at launch: re-enqueue every persisted job
    /// that never reached completion. Jobs whose transcript already made it to
    /// disk skip straight to summarization; jobs that burned through
    /// `PipelineJobStore.maxAutoResumeAttempts` starts stay parked until the
    /// user retries explicitly — a meeting that reliably kills the app must
    /// not crash-loop every launch.
    func resumePending(meetings: [Meeting]) {
        guard let jobStore else { return }
        if !jobStore.prune(existing: Set(meetings.map(\.id))) {
            lokalbotLog("pipeline resume continued after queue prune failure")
        }
        let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let autoSummarize = settings().autoSummarize
        for job in jobStore.pendingJobs() {
            guard let meeting = byID[job.meetingID], stages[meeting.id] == nil else { continue }
            let hasTranscript = FileManager.default.fileExists(
                atPath: meeting.folderURL(in: storage)
                    .appendingPathComponent("transcript.json").path)
            lokalbotLog(
                "pipeline resume meeting=\(meeting.id) attempts=\(job.attempts) hasTranscript=\(hasTranscript)")
            let work = Self.resumedWork(
                pending: .init(
                    transcribe: job.transcribe,
                    summarize: job.summarize),
                summaryFollowsSetting: job.summaryFollowsSetting,
                autoSummarize: autoSummarize,
                hasTranscript: hasTranscript)
            queue.append(Job(
                meeting: meeting,
                transcribe: work.transcribe,
                summarize: work.summarize,
                summaryFollowsSetting: job.summaryFollowsSetting,
                resumed: true,
                origin: .automatic))
            stages[meeting.id] = .queued
        }
        for parked in jobStore.parkedJobs() {
            guard byID[parked.meetingID] != nil, stages[parked.meetingID] == nil else { continue }
            stages[parked.meetingID] = .failed(
                parked.lastError ?? "Processing didn't finish after several attempts.")
        }
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                activeMeetingID = job.meeting.id
                activeJob = job
                await process(job)
                activePhase = nil
                activeJob = nil
                activeMeetingID = nil
            }
            isDraining = false
        }
    }

    private func process(_ job: Job) async {
        let meeting = job.meeting
        let folder = meeting.folderURL(in: storage)
        let config = settings()
        // Automatic work never ambush-downloads a model: park the job instead
        // (before markStarted, so waiting burns no auto-resume attempts and
        // the durable row is re-checked on the next launch). A user-initiated
        // job passes through and downloads on demand.
        if job.origin == .automatic {
            let needsTranscription = job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path)
            if needsTranscription, !automationReadiness.transcription(config) {
                waitingForModelsJobs.append(job)
                stages[meeting.id] = .waitingForModels
                lokalbotLog(
                    "pipeline parked meeting=\(meeting.id) waiting for the transcription model")
                return
            }
            // A transcript may already exist because an earlier attempt
            // completed transcription before parking its summary. Check Think
            // before markStarted in that case: merely waiting for a model must
            // never consume the crash-loop attempt budget.
            if !needsTranscription, job.summarize,
               !automationReadiness.think(config, storage) {
                waitingForModelsJobs.append(Job(
                    meeting: meeting, transcribe: false, summarize: true,
                    summaryFollowsSetting: job.summaryFollowsSetting,
                    resumed: job.resumed, origin: .automatic))
                stages[meeting.id] = .waitingForModels
                lokalbotLog(
                    "pipeline parked summary meeting=\(meeting.id) waiting for the Think model")
                return
            }
        }
        if let jobStore, !jobStore.markStarted(meetingID: meeting.id) {
            stages[meeting.id] = .failed("Could not durably start this processing job.")
            return
        }
        let queueSeconds = max(0, Date().timeIntervalSince(job.enqueuedAt))
        var transcriptWrittenThisJob = false
        do {
            if job.transcribe || !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path) {
                activePhase = .transcribing
                if let transcriptionStarted {
                    await transcriptionStarted(meeting.id)
                }
                // A fresh enqueue means "transcribe with today's settings" —
                // stale checkpoints from an earlier failed attempt may have
                // been produced by a different model. Only a crash resume
                // trusts them.
                if !job.resumed { clearCheckpoints(in: folder) }
                stages[meeting.id] = .preparingTranscriptionModel
                let engine = config.transcriptionEngine()   // engines prepare lazily inside transcribe

                stages[meeting.id] = .transcribing
                let batch = try await transcribeTracks(meeting: meeting, folder: folder, engine: engine, config: config)
                var transcript = batch.transcript
                // Lexical similarity only marks uncertainty. Removing a full
                // duplicate additionally requires matching waveform evidence.
                let echoEvidence = try await EchoWaveformEvidence.verified(in: transcript, folder: folder)
                let bleed = SpeakerBleedFilter.filter(transcript, acousticallyVerifiedIndices: echoEvidence)
                transcript = bleed.transcript
                if bleed.changed {
                    lokalbotLog(
                        "transcript speaker bleed removedSegments=\(bleed.removedSegments) "
                            + "removedWords=\(bleed.removedWords)")
                }
                if let speakerIdentity,
                   let audioURL = MeetingAudioFiles.transcribableURL(for: .system, in: folder)
                    ?? MeetingAudioFiles.transcribableURL(for: .mic, in: folder) {
                    let safeSamples = [SpeakerAttribution.Source.microphone, .system].flatMap {
                        AttributedTrackTranscriber.samples(batch.samples, transcript: transcript, source: $0)
                    }
                    transcript = await speakerIdentity.process(transcript: transcript, meeting: meeting,
                        turns: batch.turns, samples: safeSamples, audioURL: audioURL)
                } else {
                    transcript = SpeakerAutoNamer.applyingAliases(to: transcript,
                        participants: meeting.resolvedCalendarParticipantIdentities)
                }
                let mergedSanitization = TranscriptSanitizer.sanitize(transcript)
                transcript = mergedSanitization.transcript
                if mergedSanitization.changed {
                    lokalbotLog(
                        "transcript cleanup after merge changedSegments="
                            + "\(mergedSanitization.changedSegments) removedWords="
                            + "\(mergedSanitization.removedWords) removedCharacters="
                            + "\(mergedSanitization.removedCharacters)")
                }
                transcript = speakerIdentity?.applyingLatestDecision(to: transcript, meetingID: meeting.id) ?? transcript
                try write(transcript, to: folder)
                // A finalized AAC track makes its CAF duplicate redundant. A
                // crash-recovery CAF remains when the AAC container is broken,
                // preserving playable audio after the transcript is written.
                MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
                clearCheckpoints(in: folder)
                transcriptWrittenThisJob = true
            }
            let resolvedJob = activeJob ?? job
            activePhase = .summarizing
            if resolvedJob.summarize {
                // Missing Think model on automatic work: keep the transcript
                // that just landed and park only the summary. The durable row
                // stays pending, so the summary still happens once the model
                // is downloaded (or the user asks explicitly).
                if resolvedJob.origin == .automatic,
                   !automationReadiness.think(config, storage) {
                    waitingForModelsJobs.append(Job(
                        meeting: meeting, transcribe: false, summarize: true,
                        summaryFollowsSetting: resolvedJob.summaryFollowsSetting,
                        resumed: resolvedJob.resumed, origin: .automatic))
                    stages[meeting.id] = .waitingForModels
                    lokalbotLog(
                        "pipeline parked summary meeting=\(meeting.id) waiting for the Think model")
                    if transcriptWrittenThisJob { onArtifactsWritten?(meeting) }
                    return
                }
                stages[meeting.id] = .summarizing
                var transcript = try loadTranscript(from: folder)
                if let speakerIdentity,
                   FileManager.default.fileExists(atPath: folder.appendingPathComponent("speaker-evidence/identity.sealed").path) {
                    transcript = try await speakerIdentity.recover(meeting: meeting, transcript: transcript)
                    transcript = speakerIdentity.applyingLatestDecision(to: transcript, meetingID: meeting.id)
                    try write(transcript, to: folder)
                }
                let sanitization = TranscriptSanitizer.sanitize(transcript)
                if sanitization.changed {
                    transcript = sanitization.transcript
                    try write(transcript, to: folder)
                    lokalbotLog(
                        "transcript cleanup before summary changedSegments="
                            + "\(sanitization.changedSegments) removedWords="
                            + "\(sanitization.removedWords) removedCharacters="
                            + "\(sanitization.removedCharacters)")
                }
                let budget = MeetingGenerationBudget(limits: config.generationBudgetPreset.limits)
                await budget.recordPhase("queue", seconds: queueSeconds)
                do {
                    let generated = try await budget.run {
                        try await self.summarize(transcript, meeting: meeting, config: config, budget: budget)
                    }
                    try Task.checkCancellation()
                    try MeetingAttributionArtifacts.requireCurrent(transcript, in: folder)
                    let outcomes = generated.outcomes
                    let previous = MeetingOutcomes.load(from: folder) ?? MeetingAttributionArtifacts.previous(in: folder)
                    let previousState = MeetingOutcomeStore.loadState(from: folder)
                    try outcomes.write(to: folder)
                    if let previous {
                        let reconciled = MeetingOutcomeStore.reconcileState(previousState, from: previous, to: outcomes)
                        try MeetingOutcomeStore.writeState(reconciled, to: folder)
                    }
                    // Explicit user edits remain the authority for both cards
                    // and the action/decision sections rendered beside them.
                    let authoritative = MeetingOutcomeProjection.load(for: meeting, storage: storage)?.correctedOutcomes
                        ?? outcomes
                    let summary = MeetingSummaryOutcomeSynchronizer.synchronize(
                        generated.body, outcomes: authoritative, template: config.noteTemplate)
                    try MeetingAttributionArtifacts.requireCurrent(transcript, in: folder)
                    try SummaryClaimEvidence.commit(transcript: transcript, in: folder)
                    try Data(summary.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
                    MeetingSummaryGenerator.removeCheckpoint(in: folder)
                    MeetingOutcomesGenerator.removeCheckpoint(in: folder)
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(MeetingAttributionArtifacts.refreshMarker))
                    await budget.saveMetrics(in: folder, outcome: "complete")
                } catch {
                    await budget.saveMetrics(in: folder, outcome: "incomplete")
                    onArtifactsWritten?(meeting)
                    throw error
                }
            }
            if let jobStore, !jobStore.markCompleted(meetingID: meeting.id) {
                stages[meeting.id] = .failed(
                    "Artifacts were saved, but the durable processing queue could not be completed.")
                onArtifactsWritten?(meeting)
                return
            }
            stages[meeting.id] = nil
            onArtifactsWritten?(meeting)
        } catch {
            // The persisted job row stays — the next launch re-enqueues it
            // (until the attempt cap) so a crash or transient failure never
            // silently drops a meeting. The message is persisted so a job
            // that ends up parked still explains itself after a relaunch.
            jobStore?.markFailed(meetingID: meeting.id, message: error.localizedDescription)
            stages[meeting.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    /// The microphone track with the remote side subtracted, or nil to
    /// transcribe the recording as it is.
    ///
    /// Returns nil rather than a marginal copy when the filter found little to
    /// cancel. The worker runs outside this type's main-actor isolation, while
    /// cancellation is propagated so a cancelled job never starts ASR anyway.
    private static func echoCancelledMicrophone(in folder: URL, microphone: URL,
                                                config: AppSettings) async throws -> (URL?, TranscriptEchoReport) {
        guard config.echoCancellation else { return (nil, .init(status: .disabled)) }
        guard let reference = MeetingAudioFiles.transcribableURL(for: .system, in: folder) else {
            return (nil, .init(status: .noReference))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-aec-\(UUID().uuidString).wav")
        do {
            let started = Date()
            let timing = (try? Data(contentsOf: folder.appendingPathComponent(RecordingAudioTiming.fileName)))
                .flatMap { try? JSONDecoder().decode(RecordingAudioTiming.self, from: $0) }
            let report = try await EchoCancelledTrack.write(microphone: microphone,
                                                            reference: reference,
                                                            to: destination, timing: timing)
            let elapsed = Date().timeIntervalSince(started)
            lokalbotLog(
                "echo cancellation delay=\(String(format: "%.0fms", report.delaySeconds * 1000)) "
                    + "erle=\(String(format: "%.1fdB", report.echoReturnLossDB)) "
                    + "elapsed=\(String(format: "%.1fs", elapsed))")
            guard EchoCancelledTrack.shouldUse(report) else {
                lokalbotLog("echo cancellation discarded reason=insufficient-confidence")
                try? FileManager.default.removeItem(at: destination)
                return (nil, .init(status: .uncertain, reductionDB: report.echoReturnLossDB,
                    delaySeconds: report.delaySeconds))
            }
            return (destination, .init(status: .applied, reductionDB: report.echoReturnLossDB,
                delaySeconds: report.delaySeconds, alignmentVerified: report.alignmentVerified))
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            lokalbotLog("echo cancellation failed error=\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destination)
            return (nil, .init(status: .failed))
        }
    }

    private struct TranscribedTracks {
        var transcript: Transcript
        var turns: [SpeakerAudioTurn]
        var samples: [SpeakerVoiceSample]
    }

    private struct TrackCheckpoint: Codable {
        var version = 1
        var input: Data
        var transcript: Transcript
    }

    private func transcribeTracks(meeting: Meeting, folder: URL,
                                  engine: TranscriptionEngine, config: AppSettings) async throws -> TranscribedTracks {
        let sources = [MeetingAudioFiles.Track.mic, .system].compactMap { track -> (MeetingAudioFiles.Track, URL)? in
            guard let url = MeetingAudioFiles.transcribableURL(for: track, in: folder) else { return nil }
            return (track, url)
        }
        // Reject missing or unreadable recordings before any model download.
        guard !sources.isEmpty else { throw PipelineError.noAudio }
        if config.multiSpeakerDiarization { await prepareDiarizationModels() }
        let language = config.transcriptionLanguage.code
        var tracks: [Transcript] = []
        var voiceSamples: [SpeakerVoiceSample] = []
        var acousticTurns: [SpeakerAudioTurn] = []
        var trackError: Error?
        let audioRevision = try await Task.detached(priority: .utility) {
            try MeetingSpeakerIdentityService.recordingRevision(folder: folder)
        }.value

        for (track, url) in sources {
            let name = track.rawValue
            let speaker = track == .mic ? "me" : "them"
            // Per-track checkpoint: a finished track's transcript survives a
            // crash — and the *other* track failing — so a retry never redoes
            // an hour of completed transcription.
            let checkpoint = Self.checkpointURL(track: name, in: folder)
            do {
                let checkpointInput = try JSONEncoder().encode([audioRevision, name, engine.displayName,
                    language ?? "", config.transcriptionPrompt,
                    String(config.multiSpeakerDiarization), String(config.echoCancellation)])
                let prepared = track == .mic
                    ? try await Self.echoCancelledMicrophone(in: folder, microphone: url, config: config)
                    : (nil, TranscriptEchoReport(status: .noReference))
                let source: SpeakerAttribution.Source = track == .mic ? .microphone : .system
                defer { if let cleaned = prepared.0 { try? FileManager.default.removeItem(at: cleaned) } }
                let audio = prepared.0 ?? url
                let diarization = config.multiSpeakerDiarization
                    ? await diarizer.diarizeDetailed(url: audio, includeVoiceSamples: config.rememberSpeakersOnMac)
                    : SpeakerDiarizationResult(segments: [], samples: [])
                var result: Transcript?
                if let data = try? Data(contentsOf: checkpoint),
                   let cached = try? JSONDecoder().decode(TrackCheckpoint.self, from: data),
                   cached.version == 1, cached.input == checkpointInput,
                   cached.transcript.echoReport == (track == .mic ? prepared.1 : nil) {
                    result = cached.transcript
                } else {
                    result = try await transcribeTrack(name: name, url: audio, speaker: speaker, engine: engine,
                        language: language, prompt: config.transcriptionPrompt,
                        diarization: diarization.segments, source: source)
                }
                if var transcript = result {
                    if track == .mic { transcript.echoReport = prepared.1 }
                    let saved = TrackCheckpoint(input: checkpointInput, transcript: transcript)
                    if let data = try? JSONEncoder().encode(saved) { try? data.write(to: checkpoint, options: .atomic) }
                    acousticTurns += AttributedTrackTranscriber.turns(diarization.segments, transcript: transcript, source: source)
                    voiceSamples += AttributedTrackTranscriber.samples(diarization.samples, transcript: transcript, source: source)
                    tracks.append(transcript)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep going: the other track may still succeed, and its
                // checkpoint means only this track is redone on retry.
                lokalbotLog("transcription track failed track=\(name) error=\(error.localizedDescription)")
                trackError = trackError ?? error
            }
        }
        if let trackError { throw trackError }
        guard !tracks.isEmpty else {
            throw PipelineError.noAudio
        }
        let merged = Transcript.merged(tracks)
        return TranscribedTracks(transcript: merged, turns: acousticTurns, samples: voiceSamples)
    }

    /// Where a track's finished-but-not-yet-merged transcript is checkpointed.
    /// Deleted once the merged transcript.json lands (or on a fresh enqueue).
    static func checkpointURL(track: String, in folder: URL) -> URL {
        folder.appendingPathComponent("transcript.\(track).partial.json")
    }

    private func clearCheckpoints(in folder: URL) {
        for name in ["mic", "system"] {
            try? FileManager.default.removeItem(at: Self.checkpointURL(track: name, in: folder))
        }
        MeetingSummaryGenerator.removeCheckpoint(in: folder)
    }

    private func transcribeTrack(name: String, url: URL, speaker: String,
                                 engine: TranscriptionEngine,
                                 language: String?,
                                 prompt: String?, diarization: [DiarizedSegment],
                                 source: SpeakerAttribution.Source) async throws -> Transcript? {
        guard let duration = AudioFileInspector.duration(at: url),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            lokalbotLog("transcription track skipped track=\(name) reason=no-audio")
            return nil
        }
        // Skip a track with no detected speech (e.g. your mic while muted the
        // whole call) — feeding silence to the ASR model can hallucinate words.
        // Conservative: only skip on a confident "nothing here"; VAD errors
        // return nil and we transcribe anyway, never dropping real audio.
        if let speech = await SpeechActivity.shared.speechSeconds(in: url), speech < 0.5 {
            lokalbotLog("transcription track skipped track=\(name) reason=no-speech")
            return nil
        }

        let started = Date()
        lokalbotLog(
            "transcription track start track=\(name) engine=\(engine.displayName) duration=\(Self.formatSeconds(duration)) language=\(language ?? "auto")")
        var transcript = try await AttributedTrackTranscriber.transcribe(url: url, duration: duration,
            diarization: diarization, source: source, engine: engine, language: language, prompt: prompt)
        let sanitization = TranscriptSanitizer.sanitize(transcript)
        transcript = sanitization.transcript
        if sanitization.changed {
            lokalbotLog(
                "transcript cleanup track=\(name) changedSegments="
                    + "\(sanitization.changedSegments) removedWords="
                    + "\(sanitization.removedWords) removedCharacters="
                    + "\(sanitization.removedCharacters)")
        }

        let elapsed = Date().timeIntervalSince(started)
        let rtfx = elapsed > 0 ? duration / elapsed : 0
        lokalbotLog(
            "transcription track done track=\(name) engine=\(engine.displayName) duration=\(Self.formatSeconds(duration)) elapsed=\(Self.formatSeconds(elapsed)) rtfx=\(Self.formatMultiplier(rtfx)) segments=\(transcript.segments.count)")
        return transcript
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    /// Shared by recording-time prewarm and the post-meeting stage. The
    /// `NeuralDiarizationEngine` instance is retained by this pipeline, so the
    /// downloaded/prepared models are reused instead of rebuilt per job.
    func prepareDiarizationModels() async {
        await diarizer.prepareModels()
        // A recording-time prewarm may already own the engine's preparation.
        // `prepareModels()` is idempotent and returns for secondary callers, so
        // wait for that retained instance to finish before entering diarization.
        while diarizer.isPreparing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func write(_ transcript: Transcript, to folder: URL) throws {
        if let old = try? loadTranscript(from: folder), old.evidenceRevision != transcript.evidenceRevision {
            try MeetingAttributionArtifacts.invalidate(in: folder)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(
            to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try transcript.markdown.data(using: .utf8)?.write(
            to: folder.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func loadTranscript(from folder: URL) throws -> Transcript {
        let url = folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { throw PipelineError.noTranscript }
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        try write(transcript, to: meeting.folderURL(in: storage))
    }

    // MARK: - Summarization

    private func summarize(_ transcript: Transcript, meeting: Meeting,
                           config: AppSettings, budget: MeetingGenerationBudget) async throws -> MeetingNotesGenerator.Result {
        let started = Date()
        stages[meeting.id] = .preparingSummaryModel
        let preparing = ProcessInfo.processInfo.systemUptime
        let engine = try await thinkExecution.makeTextEngine(config)
        await budget.recordPhase("modelPreparation", seconds: ProcessInfo.processInfo.systemUptime - preparing)
        stages[meeting.id] = .summarizing
        let wordCount = transcript.languageDetectionText
            .split(whereSeparator: { $0.isWhitespace }).count
        // Resolve `.matchTranscript` against raw spoken text now so both the
        // chunk extractions and the final synthesis share the same language
        // directive. Do not use rendered Markdown here: timestamps and speaker
        // labels can skew NaturalLanguage on short transcripts.
        let language = SummaryLanguage.resolvedForTranscript(config.summaryLanguage,
                                                             transcript: transcript)
        let noteContext = MeetingNotes.promptContext(in: meeting.folderURL(in: storage))
        var generated = try await MeetingNotesGenerator.generate(
            transcript: transcript, engine: engine, template: config.noteTemplate,
            language: language, context: noteContext,
            contextTokens: MeetingSummaryGenerator.contextTokenLimit(for: config),
            meetingID: meeting.id, folder: meeting.folderURL(in: storage), budget: budget)

        let date = meeting.startedAt.formatted(date: .long, time: .shortened)
        var header = "# \(meeting.title) — \(date)\n"
        header += "**Duration:** \(meeting.durationLabel) · **App:** \(meeting.appName)"
        header += " · **Words:** \(WordCountFormatter.format(words: wordCount))"
        header += " · **Template:** \(config.noteTemplate.displayName)"
        if let promptLanguage = language.promptLanguageName {
            header += " · **Language:** \(promptLanguage)"
        }
        header += " · **Model:** \(engine.displayName)\n\n"
        GenerationMetricsStore.shared.record(
            label: "Summary · \(engine.displayName)",
            durationSec: Date().timeIntervalSince(started),
            approxTokens: TokenCountEstimator.estimate(generated.body))
        generated.body = header + generated.body + "\n"
        return generated
    }

    /// Day digest (M4/M6) — shared by the Timeline UI, scheduler, and
    /// `--digest`. The model writes only the task-first overview. LokalBot
    /// renders the complete chronological activity/meeting log and time table
    /// directly as optional evidence, so filtering summary noise never loses
    /// the underlying workday record.
    func generateDayDigest(
        from snapshot: DailyEvidenceSnapshot,
        config: AppSettings
    ) async throws -> DayDigestGenerationResult {
        let evidence = snapshot.digestEvidence()
        let name = DreamDay.key(for: snapshot.day)
        let url = storage.rootURL.appendingPathComponent("journal/\(name).md")
        let revision = try DayDigestJournalWriter.revision(at: url)

        let overview: DayDigestOverviewGeneration
        if evidence.isEmpty {
            overview = DayDigestOverviewGeneration(
                summary: DayDigestOverviewGenerator.fallback(evidence),
                quality: .complete)
        } else {
            do {
                try Task.checkCancellation()
                let engine = try await thinkExecution.makeTextEngine(
                    config,
                    purpose: "day digest")
                overview = try await generateDayOverview(
                    evidence: evidence,
                    engine: engine,
                    customPrompt: config.dayDigestCustomPrompt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lokalbotLog(
                    "day digest overview fallback error=\(error.localizedDescription)")
                overview = DayDigestOverviewGeneration(
                    summary: DayDigestOverviewGenerator.fallback(evidence),
                    quality: .fallback)
            }
        }

        try Task.checkCancellation()
        let text = evidence.renderDocument(summary: overview.summary)
        try DayDigestJournalWriter.write(text, to: url, replacing: revision,
                                        evidence: evidence, quality: overview.quality)
        return DayDigestGenerationResult(
            text: text,
            url: url,
            quality: overview.quality)
    }

    /// Code owns evidence coverage and persistence. The model rejects
    /// metadata-only segments, extracts substantive work, and groups it by task.
    private func generateDayOverview(
        evidence: DayDigestEvidence,
        engine: TextEngine,
        customPrompt: String
    ) async throws -> DayDigestOverviewGeneration {
        try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence,
            engine: engine,
            customPrompt: customPrompt)
    }

    enum PipelineError: LocalizedError {
        case noAudio, noTranscript
        var errorDescription: String? {
            switch self {
            case .noAudio: "No audio tracks found in the meeting folder."
            case .noTranscript: "No transcript yet — transcribe the meeting first."
            }
        }
    }
}
