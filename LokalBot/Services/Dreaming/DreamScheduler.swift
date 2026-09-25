import Foundation

/// Wall-clock scheduler for the overnight dream. Same minute-tick design as
/// `DailyMemoryExportScheduler` (correct across sleep/wake and DST), with two
/// dreaming-specific twists:
///
/// - the durable once-per-day marker is the report file itself (via the
///   injected `hasReport`), so a night the Mac slept through is caught up at
///   the next launch or wake, right before the user opens Today;
/// - a `canRun` downtime gate keeps the dream from competing with recording,
///   processing, dictation, or cotyping — it simply waits for the next tick.
@MainActor
final class DreamScheduler: ObservableObject {
    /// Match screen-memory's definition of an inactive session: no keyboard,
    /// pointer, or other combined-session input for three minutes.
    nonisolated static let minimumSystemIdleSeconds: TimeInterval = 180

    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// Local wall-clock hour (0...23) after which the previous day may be
        /// dreamed. Before it, the previous day is considered still "in use"
        /// (a late session past midnight belongs to the evening's context).
        var hour: Int
        /// Persisted activation boundary for catch-up. The scheduler walks
        /// forward from this local day and dreams the oldest missing report.
        var firstEligibleDayKey: String

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    /// One immutable local-day interpretation shared by scheduling, evidence
    /// compilation, and persistence. `Calendar.current` may change when the
    /// user travels, so a run must not reconstruct any part of this target.
    struct Target: Equatable, Sendable {
        let day: Date
        let dayKey: String
        let calendar: Calendar
        var isAutomatic: Bool = false
    }

    typealias Dream = @MainActor (_ target: Target) async throws -> Void

    @Published private(set) var isDreaming = false
    @Published private(set) var lastDreamedAt: Date?
    @Published private(set) var lastError: String?

    /// Nil in production so every tick snapshots the then-current calendar.
    /// Tests can inject a fixed calendar through `init(calendar:now:)`.
    private let fixedCalendar: Calendar?
    private let now: () -> Date
    private var configuration: Configuration?
    private var dream: Dream?
    private var hasReport: ((String) -> Bool)?
    private var canRun: () -> Bool = { true }
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var dreamTask: Task<Void, Never>?
    private var activeDayKey: String?
    private var lastFailure: Date?
    /// In-memory high-water mark for the current calendar snapshot. A launch
    /// may scan the persisted activation range once, but subsequent minute
    /// ticks start at the first day not already proven complete.
    private var scanCursorDayKey: String?
    private var scanCalendar: Calendar?
    private var generation = 0

    init(now: @escaping () -> Date = Date.init) {
        fixedCalendar = nil
        self.now = now
    }

    init(calendar: Calendar, now: @escaping () -> Date = Date.init) {
        fixedCalendar = calendar
        self.now = now
    }

    func configure(
        _ configuration: Configuration,
        hasReport: @escaping (String) -> Bool,
        canRun: @escaping () -> Bool,
        dream: @escaping Dream,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.hasReport = hasReport
        self.canRun = canRun
        self.dream = dream
        errorHandler = onError
        if changed {
            generation &+= 1
            dreamTask?.cancel()
            dreamTask = nil
            activeDayKey = nil
            isDreaming = false
            lastFailure = nil
            scanCursorDayKey = nil
            scanCalendar = nil
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
        dreamTask?.cancel()
        dreamTask = nil
        activeDayKey = nil
        isDreaming = false
    }

    /// A generated artifact changed behind the in-memory scan cursor. Reset
    /// the high-water mark so the next tick can find and repair the hole.
    func reconsiderReports(invalidating dayKeys: Set<String> = [], cancellingInFlight: Bool = false) {
        // A newer dream can depend on an old source through durable memory,
        // even when its own day is outside the direct comparison window.
        if let activeDayKey, cancellingInFlight || dayKeys.contains(activeDayKey) {
            generation &+= 1
            dreamTask?.cancel()
            dreamTask = nil
            self.activeDayKey = nil
            isDreaming = false
        }
        lastFailure = nil
        scanCursorDayKey = nil
        scanCalendar = nil
        tick()
    }

    func tick() {
        guard dreamTask == nil,
              let configuration,
              configuration.enabled,
              let hasReport,
              dream != nil else { return }
        let current = now()
        let calendar = calendarSnapshot()
        if scanCalendar != calendar {
            scanCalendar = calendar
            scanCursorDayKey = nil
        }
        let yesterday = Self.previousDay(of: current, calendar: calendar)
        guard Self.shouldRun(
            at: current,
            hour: configuration.normalizedHour,
            hasReportForPreviousDay: false,
            calendar: calendar) else { return }
        // A failed dream (model unreachable mid-boot, disk error) should be
        // visible but not retried every minute; generation can also take a
        // while, so give the system room between attempts.
        if let lastFailure, current.timeIntervalSince(lastFailure) < 15 * 60 { return }
        // Not downtime yet — recording, processing, dictation, or cotyping is
        // active. Don't burn the backoff; just wait for a quieter tick.
        guard canRun() else { return }
        let scanStart = scanCursorDayKey ?? configuration.firstEligibleDayKey
        guard let target = Self.oldestMissingTarget(
            firstEligibleDayKey: scanStart,
            through: yesterday,
            hasReport: hasReport,
            calendar: calendar) else {
            // A canonical start after yesterday is either a future opt-in
            // boundary or the cursor parked on the next not-yet-eligible day.
            // Keep it intact. Otherwise the scanned range is complete, so park
            // directly after yesterday and avoid decoding it again next minute.
            if !Self.isCanonicalFutureDayKey(
                scanStart,
                after: yesterday,
                calendar: calendar),
               let next = calendar.date(byAdding: .day, value: 1, to: yesterday) {
                scanCursorDayKey = DreamDay.key(for: next, calendar: calendar)
            }
            return
        }
        start(target: target, advancesScanCursor: true)
    }

    /// Manual run from a user action: ignores whether overnight automation is
    /// enabled, the hour, the existing report (the day is re-dreamed and its
    /// files replaced), and the downtime gate. Still one dream at a time.
    func dreamNow() {
        guard dreamTask == nil,
              configuration != nil,
              dream != nil else { return }
        let calendar = calendarSnapshot()
        let day = Self.previousDay(of: now(), calendar: calendar)
        start(target: Self.target(for: day, calendar: calendar), advancesScanCursor: false)
    }

    private func start(target: Target, advancesScanCursor: Bool) {
        guard let dream else { return }
        let target = Target(day: target.day, dayKey: target.dayKey,
                            calendar: target.calendar, isAutomatic: advancesScanCursor)
        let runGeneration = generation
        isDreaming = true
        activeDayKey = target.dayKey
        lastError = nil
        dreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var continueCatchUp = false
            do {
                try await dream(target)
                guard !Task.isCancelled, generation == runGeneration else { return }
                lastDreamedAt = now()
                lastFailure = nil
                if advancesScanCursor,
                   let next = target.calendar.date(byAdding: .day, value: 1, to: target.day) {
                    scanCalendar = target.calendar
                    scanCursorDayKey = DreamDay.key(for: next, calendar: target.calendar)
                }
                continueCatchUp = advancesScanCursor
            } catch is CancellationError {
            } catch {
                guard generation == runGeneration else { return }
                lastFailure = now()
                let message = "Dreaming failed: \(error.localizedDescription)"
                lastError = message
                errorHandler?(message)
            }
            guard generation == runGeneration else { return }
            isDreaming = false
            dreamTask = nil
            activeDayKey = nil
            if continueCatchUp { tick() }
        }
    }

    private func calendarSnapshot() -> Calendar {
        fixedCalendar ?? Calendar.current
    }

    /// Finds the oldest undreamed local day between the persisted activation
    /// boundary and yesterday (inclusive). A malformed boundary is narrowed to
    /// yesterday for safe migration; a valid future boundary waits, preserving
    /// the user's opt-in boundary across date-line travel.
    nonisolated static func oldestMissingTarget(
        firstEligibleDayKey: String,
        through yesterday: Date,
        hasReport: (String) -> Bool,
        calendar: Calendar
    ) -> Target? {
        let lastDay = calendar.startOfDay(for: yesterday)
        let parsedStart = DreamDay.date(fromKey: firstEligibleDayKey, calendar: calendar)
        let canonicalStart = parsedStart.map { DreamDay.key(for: $0, calendar: calendar) }
        var day: Date
        if let parsedStart, canonicalStart == firstEligibleDayKey {
            day = calendar.startOfDay(for: parsedStart)
            guard day <= lastDay else { return nil }
        } else {
            day = lastDay
        }

        while day <= lastDay {
            let target = target(for: day, calendar: calendar)
            if !hasReport(target.dayKey) { return target }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  next > day else { return nil }
            day = next
        }
        return nil
    }

    nonisolated static func target(for day: Date, calendar: Calendar) -> Target {
        let start = calendar.startOfDay(for: day)
        return Target(
            day: start,
            dayKey: DreamDay.key(for: start, calendar: calendar),
            calendar: calendar)
    }

    nonisolated private static func isCanonicalFutureDayKey(
        _ dayKey: String,
        after day: Date,
        calendar: Calendar
    ) -> Bool {
        guard let parsed = DreamDay.date(fromKey: dayKey, calendar: calendar),
              DreamDay.key(for: parsed, calendar: calendar) == dayKey else {
            return false
        }
        return calendar.startOfDay(for: parsed) > calendar.startOfDay(for: day)
    }

    /// The day a dream analyzes: the local calendar day before `date`.
    nonisolated static func previousDay(of date: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-86_400)
    }

    /// Run once the clock passes today's configured hour, unless the previous
    /// day already has a report. No same-day memory needed: writing the report
    /// flips `hasReportForPreviousDay` durably.
    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        hasReportForPreviousDay: Bool,
        calendar: Calendar
    ) -> Bool {
        guard !hasReportForPreviousDay else { return false }
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        return date >= target
    }

    /// Dreaming is deferred on battery or in Low Power Mode — an unattended
    /// overnight model pass must never be the thing that drains the machine.
    /// Sleep already pauses the minute tick; this covers the lid-open case.
    nonisolated static func powerAllowsDreaming(isOnBattery: Bool,
                                                isLowPower: Bool) -> Bool {
        !isOnBattery && !isLowPower
    }

    nonisolated static func isSystemIdle(
        for idleSeconds: TimeInterval,
        minimum: TimeInterval = minimumSystemIdleSeconds
    ) -> Bool {
        idleSeconds.isFinite && idleSeconds >= max(0, minimum)
    }
}
