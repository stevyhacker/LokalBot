import Foundation

/// Owns the complete Day Digest lifecycle shared by manual, scheduled, and
/// headless entry points. Callers choose when to request a digest; this module
/// owns what evidence belongs to that request, where the journal lives, how
/// freshness is derived, and how automatic repair is scheduled.
@MainActor
final class DayDigestLifecycle {
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
        _ settings: AppSettings
    ) async throws -> DayDigestGenerationResult

    private let storageRoot: URL
    private let blocks: (Date) -> [ActivityBlock]
    private let screenContexts: (Date) -> [DayScreenContext]
    private let meetings: () -> [Meeting]
    private let latestActivityEvidenceAt: (Date) -> Date?
    private let settings: () -> AppSettings
    private let generator: Generator
    private let onGenerated: (Date) -> Void
    private let calendar: Calendar
    private let scheduler: DayDigestScheduler
    private var invalidatedDays: Set<String> = []

    init(
        storageRoot: URL,
        calendar: Calendar = .current,
        scheduler: DayDigestScheduler? = nil,
        blocks: @escaping (Date) -> [ActivityBlock],
        screenContexts: @escaping (Date) -> [DayScreenContext],
        meetings: @escaping () -> [Meeting],
        latestActivityEvidenceAt: @escaping (Date) -> Date?,
        settings: @escaping () -> AppSettings,
        generator: @escaping Generator,
        onGenerated: @escaping (Date) -> Void = { _ in }
    ) {
        self.storageRoot = storageRoot
        self.calendar = calendar
        self.scheduler = scheduler ?? DayDigestScheduler()
        self.blocks = blocks
        self.screenContexts = screenContexts
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
        onGenerated: @escaping (Date) -> Void = { _ in }
    ) {
        self.init(
            storageRoot: storage.rootURL,
            blocks: { activityStore.blocks(on: $0) },
            screenContexts: { activityStore.screenContexts(on: $0) },
            meetings: meetings,
            latestActivityEvidenceAt: { activityStore.latestEvidenceAt(on: $0) },
            settings: settings,
            generator: { evidence, settings in
                try await pipeline.generateDayDigest(
                    from: evidence,
                    config: settings)
            },
            onGenerated: onGenerated)
    }

    func journalURL(for day: Date) -> URL {
        storageRoot.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
    }

    func snapshot(for day: Date) -> Snapshot {
        let url = journalURL(for: day)
        let text = try? String(contentsOf: url, encoding: .utf8)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let signature = text == nil ? nil : try? evidenceInput(for: day).digestEvidence(calendar: calendar).contentSignature
        return Snapshot(
            text: text,
            modifiedAt: attributes?[.modificationDate] as? Date,
            latestEvidenceAt: latestEvidenceAt(for: day),
            evidenceMatches: text == nil || signature.map {
                DayDigestGenerationMetadataStore.isCurrent(for: url, evidenceSignature: $0)
            } == true)
    }

    /// Capture the meeting list on its owner, then validate files and complete
    /// evidence fingerprints on the worker that owns the day read connection.
    func backgroundSnapshotLoader(for day: Date) -> @Sendable (ActivityStore) -> Snapshot {
        let root = storageRoot, calendar = calendar
        let finished = meetings(for: day, includeInProgress: false)
        return { store in
            let url = root.appendingPathComponent("journal/\(DreamDay.key(for: day, calendar: calendar)).md")
            let text = try? String(contentsOf: url, encoding: .utf8)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let signature = text == nil ? nil : try? FileDailyEvidenceSource(root: root, calendar: calendar)
                .snapshot(for: day, meetings: finished, activityBlocks: store.blocks(on: day),
                          screenContexts: store.screenContexts(on: day), includeScreenSummary: false)
                .digestEvidence(calendar: calendar).contentSignature
            let latestArtifact = finished.compactMap {
                DayDigestMeetingArtifacts.latestModifiedAt(in: root.appendingPathComponent($0.relativePath))
            }.max()
            return Snapshot(
                text: text, modifiedAt: attributes?[.modificationDate] as? Date,
                latestEvidenceAt: [store.latestEvidenceAt(on: day), finished.compactMap(\.endedAt).max(), latestArtifact]
                    .compactMap { $0 }.max(),
                evidenceMatches: text == nil || signature.map {
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
        let evidence = try evidenceInput(for: day)
        let result = try await generator(
            evidence,
            override ?? settings())
        onGenerated(evidence.day)
        return result
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
                // A deleted last meeting still leaves an owned journal to repair.
                return self.latestEvidenceAt(for: day)
                    ?? DayDigestGenerationMetadataStore.load(for: self.journalURL(for: day))?.generatedAt
            },
            canRun: canRun,
            generate: { [weak self] day in
                guard let self else {
                    throw TextEngineError.unavailable("LokalBot is shutting down.")
                }
                let evidence = try self.evidenceInput(for: day)
                let url = self.journalURL(for: day)
                let ownedJournal = DayDigestGenerationMetadataStore.load(for: url).map {
                    DayDigestGenerationMetadataStore.journalMatches($0, at: url)
                } == true
                guard !evidence.isEmpty || ownedJournal else { return .deferred }
                let result = try await self.generator(
                    evidence,
                    self.settings())
                self.invalidatedDays.remove(DreamDay.key(for: day, calendar: self.calendar))
                self.onGenerated(evidence.day)
                return result.quality.needsRepair ? .needsRepair : .completed
            },
            onError: onError)
    }

    func stopAutomaticGeneration() {
        scheduler.stop()
    }

    /// A user correction or completion can make the current journal stale
    /// without changing meeting metadata. Re-evaluate immediately instead of
    /// waiting for the next minute tick.
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
            includeScreenSummary: false)
    }

    /// Summaries, outcomes, and the user's outcome overlay are consumed by
    /// `ProcessingPipeline.generateDayDigest`. Their writes must therefore
    /// advance the evidence watermark even when `endedAt` is unchanged.
    private func latestArtifactWriteAt(for meeting: Meeting) -> Date? {
        let folder = storageRoot.appendingPathComponent(
            meeting.relativePath,
            isDirectory: true)
        return DayDigestMeetingArtifacts.latestModifiedAt(in: folder)
    }

    /// Preserve the scheduler's once-per-evening policy for ordinary activity,
    /// but invalidate its completion marker when a digest predates meeting
    /// artifacts it actually consumes. This makes the next quiet tick repair
    /// the journal without regenerating it for every later activity sample.
    private func automaticCompletionAt(for day: Date) -> Date? {
        let url = journalURL(for: day)
        if let metadata = DayDigestGenerationMetadataStore.load(for: url), metadata.journalDigest != nil {
            // Preserve manual edits even if the file's timestamp is restored.
            guard DayDigestGenerationMetadataStore.journalMatches(metadata, at: url) else {
                return .distantFuture
            }
        }
        // Ownership is checked before quality: editing even a degraded digest
        // must opt it out of automatic replacement.
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
