import Foundation

@MainActor
final class DayDigestScheduler {
    enum GenerationOutcome: Equatable, Sendable {
        case completed
        case deferred
        case needsRepair
    }

    nonisolated static let catchUpDays = 7
    nonisolated static let failureBackoff: TimeInterval = 15 * 60

    struct PastDay: Equatable, Sendable {
        var day: Date
        var latestEvidenceAt: Date?
        var digestModifiedAt: Date?
    }

    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var hour: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

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
    private var scanCursorDay: Date?
    private var scanToday: Date?
    private var deferredDays: Set<Date> = []
    private var repairAfter: [Date: Date] = [:]
    private var justFinishedDay: Date?

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
        if let lastFailure, current.timeIntervalSince(lastFailure) < Self.failureBackoff { return }
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
            if continueCatchUp {
                justFinishedDay = runDay
                tick()
            }
        }
    }

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

    nonisolated static func needsFinalization(_ past: PastDay, calendar: Calendar) -> Bool {
        guard past.latestEvidenceAt != nil else { return false }
        let dayStart = calendar.startOfDay(for: past.day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return true }
        return past.digestModifiedAt.map { $0 < nextDay } ?? true
    }
}
