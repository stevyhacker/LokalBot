import Foundation

extension Notification.Name {
    /// Stored coding-agent evidence gained, lost, or corrected bursts.
    static let codingAgentEvidenceChanged = Notification.Name("codingAgentEvidenceChanged")
}

/// Keeps stored coding-agent evidence in step with the agents' transcripts.
///
/// Scans run off the main actor over a recent window. Only settled bursts
/// are stored, so a digest's inputs cannot change while it is written. New
/// bursts are plain additions. Removing or correcting a stored burst (a
/// deleted session, a new folder exclusion) revokes dependent products
/// through the same path as deleting screen evidence. A read failure is
/// never taken as a deletion.
@MainActor
final class CodingAgentEvidenceIngestor {
    struct Configuration: Equatable, Sendable {
        var agents: Set<CodingAgentKind>
        var excludedFolders: [String]
        /// Agent text expires with screen text; `nil` keeps it indefinitely.
        var retentionDays: Int?

        init(agents: Set<CodingAgentKind>, excludedFolders: [String] = [], retentionDays: Int? = nil) {
            self.agents = agents
            self.excludedFolders = excludedFolders
            self.retentionDays = retentionDays
        }

        init(settings: AppSettings) {
            self.init(
                agents: settings.enabledCodingAgents,
                excludedFolders: settings.codingAgentExcludedFolderList,
                retentionDays: settings.keepOCRTextForever ? nil : settings.retentionDays)
        }

        /// Setup shows this choice, so a new install reads nothing until setup
        /// is finished. From then on the settings alone decide.
        init(settings: AppSettings, onboardingFinished: Bool) {
            self.init(settings: settings)
            if !onboardingFinished { agents = [] }
        }
    }

    typealias Scan = @Sendable (
        _ configuration: Configuration, _ firstDay: Date, _ lastDay: Date, _ cache: CodingAgentParseCache?
    ) -> CodingAgentDayScan
    typealias EvidenceMutation = (_ days: [Date], _ mutation: () throws -> Void) throws -> Void

    /// Matches the digest scheduler's catch-up window.
    static let windowDays = DayDigestScheduler.catchUpDays
    static let refreshInterval: TimeInterval = 10 * 60

    private let store: ActivityStore
    private let configuration: () -> Configuration
    private let scan: Scan
    private let mutateEvidence: EvidenceMutation
    private let onChange: ([Date]) -> Void
    private let now: () -> Date
    private let calendar: Calendar
    private var timer: Timer?
    private var latestRefresh: Task<Void, Never>?
    /// Reused across window refreshes, so a refresh parses only the
    /// transcripts written since the last one.
    private let parseCache = CodingAgentParseCache()
    private(set) var lastError: String?

    init(
        store: ActivityStore,
        configuration: @escaping () -> Configuration,
        scan: @escaping Scan = { configuration, first, last, cache in
            CodingAgentEvidenceIngestor.scanTranscripts(configuration, from: first, through: last, cache: cache)
        },
        mutateEvidence: @escaping EvidenceMutation,
        onChange: @escaping ([Date]) -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.configuration = configuration
        self.scan = scan
        self.mutateEvidence = mutateEvidence
        self.onChange = onChange
        self.now = now
        self.calendar = calendar
    }

    nonisolated static func scanTranscripts(
        _ configuration: Configuration, from firstDay: Date, through lastDay: Date,
        cache: CodingAgentParseCache?
    ) -> CodingAgentDayScan {
        CodingAgentSessionScanner.standard(
            agents: configuration.agents, excludedFolders: configuration.excludedFolders
        ).scan(from: firstDay, through: lastDay, cache: cache)
    }

    /// Refresh now and then on a fixed interval while any agent is enabled.
    func start() {
        stop()
        guard !configuration().agents.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Scan the recent window, plus `day` when it is older, and store what
    /// changed. Refreshes run one after another, never concurrently.
    func refresh(including day: Date? = nil) async {
        let previous = latestRefresh
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh(including: day)
        }
        latestRefresh = task
        await task.value
    }

    private func performRefresh(including day: Date?) async {
        let configuration = configuration()
        guard !configuration.agents.isEmpty else { return }
        let scanTime = now()
        let today = calendar.startOfDay(for: scanTime)
        let windowStart = calendar.date(byAdding: .day, value: -(Self.windowDays - 1), to: today) ?? today
        var ranges: [(first: Date, last: Date, cache: CodingAgentParseCache?)] = [(windowStart, today, parseCache)]
        if let day, calendar.startOfDay(for: day) < windowStart {
            // A one-off older day would evict the window's cached files.
            ranges.append((calendar.startOfDay(for: day), calendar.startOfDay(for: day), nil))
        }
        let scan = self.scan
        for (first, last, cache) in ranges {
            let result = await Task.detached(priority: .utility) {
                scan(configuration, first, last, cache)
            }.value
            // Turning the feature off, deleting saved sessions, or adding an
            // exclusion during the scan must not be undone by its result.
            guard self.configuration() == configuration else { return }
            do {
                try apply(result, configuration: configuration, scannedAt: scanTime)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                lokalbotLog("coding-agent evidence update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Store settled bursts from `scan`, replacing what the store holds for
    /// the scanned agents and days.
    func apply(_ scan: CodingAgentDayScan, configuration: Configuration, scannedAt: Date) throws {
        let cutoff = configuration.retentionDays.map {
            scannedAt.addingTimeInterval(-Double($0) * 86_400)
        }
        var fresh = scan.bursts.filter { burst in
            burst.isSettled(at: scannedAt) && configuration.agents.contains(burst.agent)
                && cutoff.map { burst.end >= $0 } != false
        }
        var existing = store.codingAgentBursts(in: scan.interval)
            .filter { configuration.agents.contains($0.agent) }
        // A finished day keeps the bursts its digest and Dream review were
        // written with until a session's work there changes or the session
        // is gone. On 2026-10-20 and 21, sessions that moved to another
        // branch relabeled earlier days' bursts, and each relabel rebuilt
        // those days' digests, several times a day.
        let today = calendar.startOfDay(for: scannedAt)
        let unchanged = sessionDaysWithUnchangedWork(existing: existing, fresh: fresh, before: today)
        fresh.removeAll { unchanged.contains(sessionDay(of: $0)) }
        existing.removeAll { unchanged.contains(sessionDay(of: $0)) }
        let freshIDs = Set(fresh.map(\.id))
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let added = fresh.filter { existingByID[$0.id] == nil }
        let corrected = fresh.filter { burst in
            guard let stored = existingByID[burst.id], stored != burst else { return false }
            return burst.start >= today || !stored.hasSameWork(as: burst)
        }
        // An unreadable transcript is not a deleted one.
        let removed = scan.unreadableFiles.isEmpty ? existing.filter { !freshIDs.contains($0.id) } : []

        let revokedDays = days(of: removed + corrected)
        if !revokedDays.isEmpty {
            try mutateEvidence(revokedDays) {
                try store.deleteCodingAgentBursts(ids: removed.map(\.id))
                try store.upsertCodingAgentBursts(corrected)
            }
        }
        try store.upsertCodingAgentBursts(added)

        let changedDays = days(of: added + removed + corrected)
        if !changedDays.isEmpty {
            onChange(changedDays)
            NotificationCenter.default.post(name: .codingAgentEvidenceChanged, object: nil)
        }
    }

    private func days(of bursts: [CodingAgentBurst]) -> [Date] {
        Array(Set(bursts.map { calendar.startOfDay(for: $0.start) })).sorted()
    }

    /// Sessions on days before `today` whose stored bursts hold the same
    /// work, in order, as the scan's. Ids follow a burst's first event, so
    /// a moved edge reads as a different burst; the work does not.
    private func sessionDaysWithUnchangedWork(
        existing: [CodingAgentBurst], fresh: [CodingAgentBurst], before today: Date
    ) -> Set<String> {
        func bySessionDay(_ bursts: [CodingAgentBurst]) -> [String: [CodingAgentBurst]] {
            Dictionary(grouping: bursts.filter { $0.start < today }.sorted { $0.start < $1.start },
                       by: sessionDay(of:))
        }
        let rescanned = bySessionDay(fresh)
        return Set(bySessionDay(existing).compactMap { key, stored in
            guard let scanned = rescanned[key], scanned.count == stored.count,
                  zip(stored, scanned).allSatisfy({ $0.hasSameWork(as: $1) }) else { return nil }
            return key
        })
    }

    private func sessionDay(of burst: CodingAgentBurst) -> String {
        "\(burst.agent.rawValue):\(burst.sessionID):\(calendar.startOfDay(for: burst.start).timeIntervalSince1970)"
    }
}
