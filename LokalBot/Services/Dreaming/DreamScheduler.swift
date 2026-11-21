import Foundation

@MainActor
final class DreamScheduler: ObservableObject {
    nonisolated static let catchUpDays = 7
    nonisolated static let transientAttemptsBeforeFallback = 3

    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var hour: Int
        var firstEligibleDayKey: String

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    struct Target: Equatable, Sendable {
        let day: Date
        let dayKey: String
        let calendar: Calendar
        var isAutomatic: Bool = false
        var transientFailures: Int = 0
    }

    typealias Dream = @MainActor (_ target: Target) async throws -> Void

    @Published private(set) var isDreaming = false
    @Published private(set) var lastDreamedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var activeDayKey: String?
    @Published private(set) var remainingCatchUpDays = 0

    private let fixedCalendar: Calendar?
    private let now: () -> Date
    private var configuration: Configuration?
    private var dream: Dream?
    private var hasReport: ((String) -> Bool)?
    private var canRun: () -> Bool = { true }
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var dreamTask: Task<Void, Never>?
    private var lastFailure: Date?
    private var scanCursorDayKey: String?
    private var scanCalendar: Calendar?
    private var generation = 0
    private var transientFailures: [String: Int] = [:]

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
            remainingCatchUpDays = 0
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
        remainingCatchUpDays = 0
        isDreaming = false
    }

    func reconsiderReports(invalidating dayKeys: Set<String> = [], cancellingInFlight: Bool = false) {
        if let activeDayKey, cancellingInFlight || dayKeys.contains(activeDayKey) {
            generation &+= 1
            dreamTask?.cancel()
            dreamTask = nil
            self.activeDayKey = nil
            remainingCatchUpDays = 0
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
        if let lastFailure, current.timeIntervalSince(lastFailure) < 15 * 60 { return }
        guard canRun() else { return }
        let scanStart = scanCursorDayKey ?? configuration.firstEligibleDayKey
        guard let target = Self.oldestMissingTarget(
            firstEligibleDayKey: scanStart,
            through: yesterday,
            hasReport: hasReport,
            calendar: calendar) else {
            if !Self.isCanonicalFutureDayKey(
                scanStart,
                after: yesterday,
                calendar: calendar),
               let next = calendar.date(byAdding: .day, value: 1, to: yesterday) {
                scanCursorDayKey = DreamDay.key(for: next, calendar: calendar)
            }
            return
        }
        remainingCatchUpDays = Self.missingDayCount(
            after: target.day, through: yesterday, hasReport: hasReport, calendar: calendar)
        start(target: target, advancesScanCursor: true)
    }

    func dreamNow() {
        guard dreamTask == nil,
              configuration != nil,
              dream != nil else { return }
        let calendar = calendarSnapshot()
        let day = Self.previousDay(of: now(), calendar: calendar)
        remainingCatchUpDays = 0
        start(target: Self.target(for: day, calendar: calendar), advancesScanCursor: false)
    }

    private func start(target: Target, advancesScanCursor: Bool) {
        guard let dream else { return }
        let target = Target(day: target.day, dayKey: target.dayKey,
                            calendar: target.calendar, isAutomatic: advancesScanCursor,
                            transientFailures: transientFailures[target.dayKey] ?? 0)
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
                transientFailures[target.dayKey] = nil
                if advancesScanCursor,
                   let next = target.calendar.date(byAdding: .day, value: 1, to: target.day) {
                    scanCalendar = target.calendar
                    scanCursorDayKey = DreamDay.key(for: next, calendar: target.calendar)
                }
                continueCatchUp = advancesScanCursor
            } catch is CancellationError {
            } catch is DreamService.Deferred {
                guard generation == runGeneration else { return }
                lastFailure = now()
                transientFailures[target.dayKey, default: 0] += 1
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
            remainingCatchUpDays = 0
            if continueCatchUp { tick() }
        }
    }

    private func calendarSnapshot() -> Calendar {
        fixedCalendar ?? Calendar.current
    }

    nonisolated static func oldestMissingTarget(
        firstEligibleDayKey: String,
        through yesterday: Date,
        hasReport: (String) -> Bool,
        calendar: Calendar,
        catchUpDays: Int = catchUpDays
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
        if let windowStart = calendar.date(byAdding: .day, value: -(max(1, catchUpDays) - 1), to: lastDay) {
            day = max(day, calendar.startOfDay(for: windowStart))
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

    nonisolated static func missingDayCount(
        after day: Date,
        through yesterday: Date,
        hasReport: (String) -> Bool,
        calendar: Calendar
    ) -> Int {
        let lastDay = calendar.startOfDay(for: yesterday)
        var count = 0
        var current = calendar.startOfDay(for: day)
        while let next = calendar.date(byAdding: .day, value: 1, to: current), next > current, next <= lastDay {
            if !hasReport(DreamDay.key(for: next, calendar: calendar)) { count += 1 }
            current = next
        }
        return count
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

    nonisolated static func previousDay(of date: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-86_400)
    }

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

    nonisolated static func powerAllowsDreaming(isOnBattery: Bool) -> Bool {
        !isOnBattery
    }
}
