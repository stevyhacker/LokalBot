import Foundation

@MainActor
final class DayDigestLifecycle: ObservableObject {
    struct ActiveRun: Identifiable, Equatable, Sendable {
        let id: UUID
        let day: Date
        var progress: DayDigestProgress?
    }

    struct Snapshot: Equatable, Sendable {
        var text: String?
        var modifiedAt: Date?
        var latestEvidenceAt: Date?
        var evidenceMatches: Bool = true

        var isStale: Bool {
            !evidenceMatches || DayDigestFreshness.isStale(
                digestModifiedAt: modifiedAt,
                latestEvidenceAt: latestEvidenceAt)
        }
    }

    typealias Generator = @MainActor (
        _ evidence: DailyEvidenceSnapshot,
        _ settings: AppSettings,
        _ validateEvidence: EvidenceValidator,
        _ progress: @escaping DayDigestProgressHandler
    ) async throws -> DayDigestGenerationResult

    typealias EvidenceValidator = @MainActor () throws -> Void

    enum GenerationError: LocalizedError {
        case evidenceChangedDuringGeneration

        var errorDescription: String? {
            "The day's source evidence changed while its digest was being generated. Generate it again to use the current evidence."
        }
    }

    private let storageRoot: URL
    private let blocks: (Date) -> [ActivityBlock]
    private let screenContexts: (Date) -> [DayScreenContext]
    private let codingAgentBursts: (Date) -> [CodingAgentBurst]
    private let prepareEvidence: @MainActor (Date) async -> Void
    private let meetings: () -> [Meeting]
    private let latestActivityEvidenceAt: (Date) -> Date?
    private let settings: () -> AppSettings
    private let generator: Generator
    private let onGenerated: (Date) -> Void
    private let calendar: Calendar
    private let now: () -> Date
    private let scheduler: DayDigestScheduler
    private var invalidatedDays: Set<String> = []
    @Published private(set) var activeRuns: [ActiveRun] = []

    func isGenerating(on day: Date) -> Bool {
        activeRuns.contains { calendar.isDate($0.day, inSameDayAs: day) }
    }

    init(
        storageRoot: URL,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        scheduler: DayDigestScheduler? = nil,
        blocks: @escaping (Date) -> [ActivityBlock],
        screenContexts: @escaping (Date) -> [DayScreenContext],
        codingAgentBursts: @escaping (Date) -> [CodingAgentBurst] = { _ in [] },
        prepareEvidence: @escaping @MainActor (Date) async -> Void = { _ in },
        meetings: @escaping () -> [Meeting],
        latestActivityEvidenceAt: @escaping (Date) -> Date?,
        settings: @escaping () -> AppSettings,
        generator: @escaping Generator,
        onGenerated: @escaping (Date) -> Void = { _ in }
    ) {
        self.storageRoot = storageRoot
        self.calendar = calendar
        self.now = now
        self.scheduler = scheduler ?? DayDigestScheduler()
        self.blocks = blocks
        self.screenContexts = screenContexts
        self.codingAgentBursts = codingAgentBursts
        self.prepareEvidence = prepareEvidence
        self.meetings = meetings
        self.latestActivityEvidenceAt = latestActivityEvidenceAt
        self.settings = settings
        self.generator = generator
        self.onGenerated = onGenerated
    }

    convenience init(
        storage: StorageManager,
        activityStore: ActivityStore,
        pipeline: ProcessingPipeline,
        meetings: @escaping () -> [Meeting],
        settings: @escaping () -> AppSettings,
        prepareEvidence: @escaping @MainActor (Date) async -> Void = { _ in },
        onGenerated: @escaping (Date) -> Void = { _ in }
    ) {
        self.init(
            storageRoot: storage.rootURL,
            scheduler: DayDigestScheduler(evidenceSettleDelay: 20),
            blocks: { activityStore.blocks(on: $0) },
            screenContexts: { activityStore.screenContexts(on: $0) },
            codingAgentBursts: { activityStore.codingAgentBursts(on: $0) },
            prepareEvidence: prepareEvidence,
            meetings: meetings,
            latestActivityEvidenceAt: { activityStore.latestEvidenceAt(on: $0) },
            settings: settings,
            generator: { evidence, settings, validateEvidence, progress in
                try await pipeline.generateDayDigest(
                    from: evidence,
                    config: settings,
                    validateEvidence: validateEvidence,
                    progress: progress)
            },
            onGenerated: onGenerated)
    }

    func journalURL(for day: Date) -> URL {
        storageRoot.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
    }

    func retractGeneratedJournals(for days: [Date]) throws {
        for day in Set(days.map { calendar.startOfDay(for: $0) }) {
            let url = journalURL(for: day)
            guard let metadata = DayDigestGenerationMetadataStore.load(for: url),
                  DayDigestGenerationMetadataStore.journalMatches(metadata, at: url) else { continue }
            try FileManager.default.removeItem(at: url)
            for artifact in [
                DayDigestGenerationMetadataStore.metadataURL(for: url),
                DayDigestJournalWriter.transactionURL(for: url),
            ] where FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
        }
    }

    func snapshot(for day: Date) -> Snapshot {
        let url = journalURL(for: day)
        let text = try? String(contentsOf: url, encoding: .utf8)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let checksEvidence = text != nil && !evidenceHasExpired(on: day)
        let signature = !checksEvidence ? nil
            : try? evidenceInput(for: day).digestEvidence(calendar: calendar).contentSignature
        return Snapshot(
            text: text,
            modifiedAt: attributes?[.modificationDate] as? Date,
            latestEvidenceAt: latestEvidenceAt(for: day),
            evidenceMatches: !checksEvidence || signature.map {
                DayDigestGenerationMetadataStore.isCurrent(for: url, evidenceSignature: $0)
            } == true)
    }

    private func evidenceHasExpired(on day: Date) -> Bool {
        let retainedSince = now().addingTimeInterval(-Double(settings().retentionDays) * 86_400)
        return calendar.startOfDay(for: day) < retainedSince
    }

    func backgroundSnapshotLoader(for day: Date) -> @Sendable (ActivityStore) -> Snapshot {
        let root = storageRoot, calendar = calendar
        let finished = meetings(for: day, includeInProgress: false)
        let expired = evidenceHasExpired(on: day)
        return { store in
            let url = root.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
            let text = try? String(contentsOf: url, encoding: .utf8)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let checksEvidence = text != nil && !expired
            let signature = !checksEvidence ? nil : try? FileDailyEvidenceSource(root: root, calendar: calendar)
                .snapshot(for: day, meetings: finished, activityBlocks: store.blocks(on: day),
                          screenContexts: store.screenContexts(on: day),
                          codingAgentBursts: store.codingAgentBursts(on: day), includeScreenSummary: false)
                .digestEvidence(calendar: calendar).contentSignature
            let latestArtifact = finished.compactMap {
                DayDigestMeetingArtifacts.latestModifiedAt(in: root.appendingPathComponent($0.relativePath))
            }.max()
            return Snapshot(
                text: text, modifiedAt: attributes?[.modificationDate] as? Date,
                latestEvidenceAt: [store.latestEvidenceAt(on: day), finished.compactMap(\.endedAt).max(), latestArtifact]
                    .compactMap { $0 }.max(),
                evidenceMatches: !checksEvidence || signature.map {
                    DayDigestGenerationMetadataStore.isCurrent(for: url, evidenceSignature: $0)
                } == true)
        }
    }

    func meetings(for day: Date, includeInProgress: Bool = true) -> [Meeting] {
        meetings().filter { meeting in
            calendar.isDate(meeting.startedAt, inSameDayAs: day)
                && (includeInProgress || meeting.endedAt != nil)
        }
    }

    func latestEvidenceAt(for day: Date) -> Date? {
        let finishedMeetings = meetings(for: day, includeInProgress: false)
        let meetingEnd = finishedMeetings.compactMap(\.endedAt).max()
        let meetingArtifactWrite = finishedMeetings
            .compactMap(latestArtifactWriteAt(for:))
            .max()
        return [latestActivityEvidenceAt(day), meetingEnd, meetingArtifactWrite]
            .compactMap { $0 }
            .max()
    }

    @discardableResult
    func generate(
        for day: Date,
        settings override: AppSettings? = nil
    ) async throws -> DayDigestGenerationResult {
        await prepareEvidence(day)
        let evidence = try evidenceInput(for: day)
        let validateEvidence = evidenceValidator(for: evidence)
        let result = try await trackingRun(for: evidence.day) { progress in
            try await self.generator(
                evidence,
                override ?? self.settings(),
                validateEvidence,
                progress)
        }
        try validateEvidence()
        onGenerated(evidence.day)
        return result
    }

    private func trackingRun<T>(
        for day: Date,
        _ body: (@escaping DayDigestProgressHandler) async throws -> T
    ) async throws -> T {
        let id = UUID()
        activeRuns.append(ActiveRun(id: id, day: day))
        defer { activeRuns.removeAll { $0.id == id } }
        return try await body { [weak self] progress in
            guard let self, let index = self.activeRuns.firstIndex(where: { $0.id == id }) else { return }
            self.activeRuns[index].progress = progress
        }
    }

    func configureAutomaticGeneration(
        _ configuration: DayDigestScheduler.Configuration,
        canRun: @escaping () -> Bool,
        onError: @escaping (String) -> Void
    ) {
        scheduler.configure(
            configuration,
            digestModifiedAt: { [weak self] day in
                guard let self else { return nil }
                return self.automaticCompletionAt(for: day)
            },
            latestEvidenceAt: { [weak self] day in
                guard let self else { return nil }
                return self.latestEvidenceAt(for: day)
                    ?? DayDigestGenerationMetadataStore.load(for: self.journalURL(for: day))?.generatedAt
            },
            canRun: canRun,
            generate: { [weak self] day in
                guard let self else {
                    throw TextEngineError.unavailable("LokalBot is shutting down.")
                }
                guard self.settings().allowsAutomaticMainInference else { return .deferred }
                await self.prepareEvidence(day)
                let evidence = try self.evidenceInput(for: day)
                let validateEvidence = self.evidenceValidator(for: evidence)
                let url = self.journalURL(for: day)
                let ownedJournal = DayDigestGenerationMetadataStore.load(for: url).map {
                    DayDigestGenerationMetadataStore.journalMatches($0, at: url)
                } == true
                guard !evidence.isEmpty || ownedJournal else { return .deferred }
                let result = try await self.trackingRun(for: evidence.day) { progress in
                    try await self.generator(
                        evidence,
                        self.settings(),
                        validateEvidence,
                        progress)
                }
                try validateEvidence()
                self.invalidatedDays.remove(DreamDay.key(for: day, calendar: self.calendar))
                self.onGenerated(evidence.day)
                return result.quality.needsRepair ? .needsRepair : .completed
            },
            onError: onError)
    }

    func stopAutomaticGeneration() {
        scheduler.stop()
    }

    func reconsiderEvidence(for day: Date? = nil) {
        reconsiderEvidence(for: day.map { [$0] } ?? [])
    }

    func reconsiderEvidence(for days: [Date]) {
        invalidatedDays.formUnion(days.map { DreamDay.key(for: $0, calendar: calendar) })
        scheduler.reconsiderEvidence()
    }

    private func evidenceInput(for day: Date) throws -> DailyEvidenceSnapshot {
        try FileDailyEvidenceSource(root: storageRoot, calendar: calendar).snapshot(
            for: day,
            meetings: meetings(for: day, includeInProgress: false),
            activityBlocks: blocks(day),
            screenContexts: screenContexts(day),
            codingAgentBursts: codingAgentBursts(day),
            includeScreenSummary: false)
    }

    private func evidenceValidator(for original: DailyEvidenceSnapshot) -> EvidenceValidator {
        let expectedSignature = original.digestEvidence(calendar: calendar).contentSignature
        let blockIDs = Set(original.activityBlocks.map(\.id))
        let contextIDs = Set(original.screenContexts.map(\.snapshotID))
        let meetingIDs = Set(original.meetings.map { $0.meeting.id })
        let burstIDs = Set(original.codingAgentBursts.map(\.id))
        let day = original.day
        return { [weak self] in
            guard let self else {
                throw TextEngineError.unavailable("LokalBot is shutting down.")
            }
            var current = try self.evidenceInput(for: day)
            current.activityBlocks.removeAll { !blockIDs.contains($0.id) }
            current.screenContexts.removeAll { !contextIDs.contains($0.snapshotID) }
            current.meetings.removeAll { !meetingIDs.contains($0.meeting.id) }
            current.codingAgentBursts.removeAll { !burstIDs.contains($0.id) }
            let currentSignature = current.digestEvidence(calendar: self.calendar).contentSignature
            guard currentSignature == expectedSignature else {
                throw GenerationError.evidenceChangedDuringGeneration
            }
        }
    }

    private func latestArtifactWriteAt(for meeting: Meeting) -> Date? {
        let folder = storageRoot.appendingPathComponent(
            meeting.relativePath,
            isDirectory: true)
        return DayDigestMeetingArtifacts.latestModifiedAt(in: folder)
    }

    private func automaticCompletionAt(for day: Date) -> Date? {
        let url = journalURL(for: day)
        if let metadata = DayDigestGenerationMetadataStore.load(for: url), metadata.journalDigest != nil {
            guard DayDigestGenerationMetadataStore.journalMatches(metadata, at: url) else {
                return .distantFuture
            }
        }
        guard let completedAt = DayDigestGenerationMetadataStore.completedAt(for: url) else { return nil }
        if let metadata = DayDigestGenerationMetadataStore.load(for: url), metadata.journalDigest != nil {
            if let evidence = try? evidenceInput(for: day).digestEvidence(calendar: calendar) {
                if let saved = metadata.meetingEvidenceSignature, saved != evidence.meetingSignature {
                    return nil
                }
                if invalidatedDays.contains(DreamDay.key(for: day, calendar: calendar)),
                   metadata.evidenceSignature != evidence.contentSignature { return nil }
            }
        }
        let latestArtifactWrite = meetings(for: day, includeInProgress: false)
            .compactMap(latestArtifactWriteAt(for:))
            .max()
        guard let latestArtifactWrite, latestArtifactWrite > completedAt else {
            return completedAt
        }
        return nil
    }
}
