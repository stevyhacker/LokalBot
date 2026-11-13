import Foundation

/// Wall-clock scheduler for the automatic day digest. Same minute-tick design
/// as `DailyMemoryExportScheduler` (correct across sleep/wake and DST), with
/// two digest-specific twists:
///
/// - the durable marker is the journal file's modification time:
///   written at/after today's scheduled hour means done (survives relaunch,
///   and a manual regenerate after the hour counts too), while a digest the
///   user generated in the morning is refreshed at the scheduled hour with
///   the fuller day;
/// - past days are finalized once after the local date changes, oldest first
///   and at most `catchUpDays` back. Rewriting a journal after its day ended
///   makes the mtime a durable finalization marker, so late work after the
///   evening preview is included without an extra database flag;
/// - a day with nothing to digest yet is not a failure — the generate closure
///   reports it and the scheduler simply retries on a later tick, so a
///   meeting that ends at 19:00 still gets digested the same evening.
@MainActor
final class DayDigestScheduler {
    enum GenerationOutcome: Equatable, Sendable {
        case completed
        case deferred
        case needsRepair
    }

    /// Yesterday plus the six days before it.
    nonisolated static let catchUpDays = 7
    /// Wait before retrying a failed or degraded generation.
    nonisolated static let failureBackoff: TimeInterval = 15 * 60

    /// A local day before today, with the markers the policy needs.
    struct PastDay: Equatable, Sendable {
        var day: Date
        var latestEvidenceAt: Date?
        var digestModifiedAt: Date?
    }

    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// Local wall-clock hour (0...23) after which today's digest is
        /// generated.
        var hour: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    /// Generates and persists the digest for the day containing `date`. A
    /// degraded journal remains readable but receives a quiet later repair
    /// under the same backoff as a failed generation.
    typealias Generate = @MainActor (Date) async throws -> GenerationOutcome

    private let calendar: Calendar
    private let now: () -> Date
    private var configuration: Configuration?
    private var digestModifiedAt: ((Date) -> Date?)?
    private var latestEvidenceAt: ((Date) -> Date?)?
    private var canRun: () -> Bool = { true }
    private var generate: Generate?
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var generateTask: Task<Void, Never>?
    private var lastFailure: Date?
    private var generation = 0
    /// Oldest day before yesterday not yet proven final, for the current
    /// `scanToday`. Days before it are skipped without re-reading evidence;
    /// yesterday is always re-evaluated because its evidence may still settle.
    private var scanCursorDay: Date?
    private var scanToday: Date?
    /// Past days whose generation deferred (no usable evidence). Skipped until
    /// evidence changes, so one empty day cannot block later days or today.
    private var deferredDays: Set<Date> = []
    /// Past days whose digest needs a quiet repair, with the time the repair
    /// may run. Other missed days proceed meanwhile instead of waiting behind
    /// the shared failure backoff.
    private var repairAfter: [Date: Date] = [:]
    /// A past day that just finished, so the chained catch-up tick cannot
    /// select it again before its durable marker is observed.
    private var justFinishedDay: Date?

    /// Quiet period after an evidence change before a fresh run starts, so a
    /// meeting finishing (notes, outcomes, search index) produces one rerun
    /// instead of a start-cancel-start burst.
    private let evidenceSettleDelay: TimeInterval
    private var settleUntil: Date?
    private var settleTimer: Timer?

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         evidenceSettleDelay: TimeInterval = 0) {
        self.calendar = calendar
        self.now = now
        self.evidenceSettleDelay = evidenceSettleDelay
    }

    func configure(
        _ configuration: Configuration,
        digestModifiedAt: @escaping (Date) -> Date?,
        latestEvidenceAt: @escaping (Date) -> Date?,
        canRun: @escaping () -> Bool,
        generate: @escaping Generate,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.digestModifiedAt = digestModifiedAt
        self.latestEvidenceAt = latestEvidenceAt
        self.canRun = canRun
        self.generate = generate
        errorHandler = onError
        if changed {
            generation &+= 1
            generateTask?.cancel()
            generateTask = nil
            lastFailure = nil
            resetScan()
        }
        timer?.invalidate()
        timer = nil
        guard configuration.enabled else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        settleUntil = nil
        generateTask?.cancel()
        generateTask = nil
        resetScan()
    }

    /// Primary evidence changed while the scheduler may have been awaiting a
    /// model. Cancel that snapshot-bound run and let policy choose a fresh one.
    ///
    /// A recent model failure keeps its backoff: on 2026-10-01 every finished
    /// meeting cleared it, so a rate-limited provider was asked again at once.
    func reconsiderEvidence() {
        generation &+= 1
        generateTask?.cancel()
        generateTask = nil
        resetScan()
        guard evidenceSettleDelay > 0 else {
            tick()
            return
        }
        settleUntil = now().addingTimeInterval(evidenceSettleDelay)
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: evidenceSettleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func resetScan() {
        scanCursorDay = nil
        scanToday = nil
        deferredDays = []
        repairAfter = [:]
    }

    func tick() {
        if let settleUntil, now() < settleUntil { return }
        settleUntil = nil
        guard generateTask == nil,
              let configuration,
              configuration.enabled,
              let digestModifiedAt,
              let latestEvidenceAt,
              let generate else { return }
        let finishedDay = justFinishedDay
        justFinishedDay = nil
        let current = now()
        let todayStart = calendar.startOfDay(for: current)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: todayStart)
            ?? todayStart.addingTimeInterval(-86_400)
        if scanToday != todayStart {
            scanToday = todayStart
            scanCursorDay = nil
            deferredDays = []
            repairAfter = [:]
        }
        let windowStart = calendar.date(
            byAdding: .day, value: -Self.catchUpDays, to: todayStart) ?? previousDay
        var pastDays: [PastDay] = []
        var cursor = scanCursorDay ?? windowStart
        var firstPendingOlderDay: Date?
        while cursor < todayStart {
            let past = PastDay(
                day: cursor,
                latestEvidenceAt: latestEvidenceAt(cursor),
                digestModifiedAt: digestModifiedAt(cursor))
            let coolingDown = repairAfter[cursor].map { current < $0 } ?? false
            if !deferredDays.contains(cursor), !coolingDown { pastDays.append(past) }
            if cursor < previousDay, firstPendingOlderDay == nil,
               Self.needsFinalization(past, calendar: calendar) {
                firstPendingOlderDay = cursor
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor else { break }
            cursor = next
        }
        scanCursorDay = firstPendingOlderDay ?? previousDay
        guard let day = Self.generationDay(
            at: current,
            hour: configuration.normalizedHour,
            pastDays: pastDays,
            currentDayDigestModifiedAt: digestModifiedAt(current),
            calendar: calendar) else { return }
        if let finishedDay, calendar.isDate(day, inSameDayAs: finishedDay) { return }
        // A failed generation (model unreachable, disk error) should be
        // visible but not retried every minute; generation itself can take a
        // while, so give the system room between attempts.
        if let lastFailure, current.timeIntervalSince(lastFailure) < Self.failureBackoff { return }
        // Not downtime yet — recording, processing, dictation, or cotyping is
        // active. Don't burn the backoff; just wait for a quieter tick.
        guard canRun() else { return }
        let runGeneration = generation
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let runDay = calendar.startOfDay(for: day)
            var continueCatchUp = false
            do {
                let outcome = try await generate(day)
                if generation == runGeneration {
                    continueCatchUp = runDay < todayStart
                    switch outcome {
                    case .completed:
                        lastFailure = nil
                    case .deferred:
                        lastFailure = nil
                        if runDay < todayStart { deferredDays.insert(runDay) }
                    case .needsRepair:
                        // The fallback/partial journal stays visible. Its
                        // sidecar keeps the durable completion marker absent,
                        // and the backoff prevents a retry every minute. A
                        // past day backs off alone so later days still run.
                        if runDay < todayStart {
                            lastFailure = nil
                            repairAfter[runDay] = self.now().addingTimeInterval(Self.failureBackoff)
                        } else {
                            lastFailure = self.now()
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                if generation == runGeneration {
                    lastFailure = self.now()
                    errorHandler?("Day digest failed: \(error.localizedDescription)")
                }
            }
            guard generation == runGeneration else { return }
            generateTask = nil
            // Finish the missed-day backlog without waiting a minute per day.
            if continueCatchUp {
                justFinishedDay = runDay
                tick()
            }
        }
    }

    /// Pure policy: run once the clock passes today's configured hour, unless
    /// the journal file was already written at/after that time. A morning
    /// manual digest (mtime before the target) is refreshed; an evening one
    /// (manual or scheduled) suppresses the run for the rest of the day.
    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        digestModifiedAt: Date?,
        calendar: Calendar
    ) -> Bool {
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        guard date >= target else { return false }
        if let digestModifiedAt, digestModifiedAt >= target { return false }
        return true
    }

    /// Past days (oldest first) take priority until each has been rewritten
    /// after its own midnight. Afterwards the normal scheduled preview policy
    /// applies to today. Pure so DST and durable-marker behavior stay
    /// regression-tested.
    nonisolated static func generationDay(
        at date: Date,
        hour: Int,
        pastDays: [PastDay],
        currentDayDigestModifiedAt: Date?,
        calendar: Calendar
    ) -> Date? {
        let todayStart = calendar.startOfDay(for: date)
        if let pending = pastDays
            .filter({ $0.day < todayStart && needsFinalization($0, calendar: calendar) })
            .min(by: { $0.day < $1.day }) {
            return pending.day
        }
        return shouldRun(
            at: date,
            hour: hour,
            digestModifiedAt: currentDayDigestModifiedAt,
            calendar: calendar) ? date : nil
    }

    /// A past day with evidence is final once its journal was written at or
    /// after the start of the following day.
    nonisolated static func needsFinalization(_ past: PastDay, calendar: Calendar) -> Bool {
        guard past.latestEvidenceAt != nil else { return false }
        let dayStart = calendar.startOfDay(for: past.day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return true }
        return past.digestModifiedAt.map { $0 < nextDay } ?? true
    }
}
