import Foundation

/// Lightweight wall-clock scheduler for the optional daily Markdown export.
/// The app normally lives in the menu bar, so a minute tick is sufficient and
/// remains correct across sleep/wake and daylight-saving changes.
///
/// Today's note is written at the export hour and refreshed when its evidence
/// changes. A Mac asleep or off at that hour never wrote that day's note, so
/// past days within the digest's catch-up window get a note if the folder has
/// none, and a past day's note is rewritten once its digest is finalized.
@MainActor
final class DailyMemoryExportScheduler {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var hour: Int
        /// Folder + format identity. Changing either should export to the new
        /// destination even when today's prior destination already succeeded.
        var destinationID: String

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    typealias Export = @Sendable (Date, DailyMemoryExportPass) async throws -> Void

    /// Yesterday plus the six days before it, as for the digest.
    nonisolated static let catchUpDays = DayDigestScheduler.catchUpDays

    private let calendar: Calendar
    private let now: () -> Date
    private var configuration: Configuration?
    private var export: Export?
    private var timer: Timer?
    private var exportTask: Task<Void, Never>?
    private var lastSuccessfulDay: Date?
    /// Past days already checked for a missing note in this session.
    private var caughtUpDays: Set<Date> = []
    /// Past days whose digest changed after their note was written.
    private var reopenedDays: Set<Date> = []
    private var lastAttempt: Date?
    private var errorHandler: ((String) -> Void)?
    private var generation = 0

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func configure(
        _ configuration: Configuration,
        export: @escaping Export,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.export = export
        errorHandler = onError
        if changed {
            generation &+= 1
            exportTask?.cancel()
            exportTask = nil
            lastAttempt = nil
            lastSuccessfulDay = nil
            caughtUpDays = []
            reopenedDays = []
        }
        timer?.invalidate()
        timer = nil
        guard configuration.enabled, !configuration.destinationID.isEmpty else { return }
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
        exportTask?.cancel()
        exportTask = nil
    }

    /// An action correction or late meeting artifact can change today's
    /// export after its scheduled run. Reopen only the affected current day;
    /// historical exports remain user-controlled and collision-safe.
    func reconsider(day: Date) {
        reconsider(days: [day])
    }

    func reconsider(days: [Date]) {
        let current = now()
        guard days.contains(where: { calendar.isDate($0, inSameDayAs: current) }) else { return }
        lastSuccessfulDay = nil
        restart()
    }

    /// A digest finished or rebuilt after its note was written. Today's note
    /// refreshes as for any evidence change; a past day's note within the
    /// catch-up window is rewritten with the finished digest.
    func digestDidChange(on day: Date) {
        let today = calendar.startOfDay(for: now())
        let start = calendar.startOfDay(for: day)
        guard start < today else {
            reconsider(day: day)
            return
        }
        guard let windowStart = calendar.date(byAdding: .day, value: -Self.catchUpDays, to: today),
              start >= windowStart else { return }
        reopenedDays.insert(start)
        restart()
    }

    /// Cancels an in-flight export so it cannot record a day as done with
    /// evidence that has since changed; policy then picks the next export.
    private func restart() {
        generation &+= 1
        exportTask?.cancel()
        exportTask = nil
        lastAttempt = nil
        tick()
    }

    func tick() {
        guard exportTask == nil,
              let configuration,
              configuration.enabled,
              !configuration.destinationID.isEmpty,
              let export else { return }
        let current = now()
        guard let next = Self.nextExport(
            at: current,
            hour: configuration.normalizedHour,
            lastSuccessfulDay: lastSuccessfulDay,
            caughtUpDays: caughtUpDays,
            reopenedDays: reopenedDays,
            calendar: calendar) else { return }
        // A failed filesystem write should be visible but not retried every
        // minute. Fifteen minutes gives removable/network volumes time to return.
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < 15 * 60 { return }
        lastAttempt = current
        let runGeneration = generation
        let isPastDay = next.day < calendar.startOfDay(for: current)
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                // The scheduler owns a structured utility-priority child. A
                // configure/stop cancellation therefore reaches the actual
                // filesystem worker instead of only cancelling an outer task
                // that is awaiting an unstructured detached task.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask(priority: .utility) {
                        try Task.checkCancellation()
                        try await export(next.day, next.pass)
                    }
                    try await group.waitForAll()
                }
                guard !Task.isCancelled else { return }
                guard generation == runGeneration else { return }
                finish(next.day, isPastDay: isPastDay)
                // The retry wait is for failures; the next export runs now.
                lastAttempt = nil
                succeeded = true
            } catch is CancellationError {
            } catch {
                if generation == runGeneration {
                    // A past day is tried once per session, so a note that
                    // cannot be written never holds back today's.
                    if isPastDay { finish(next.day, isPastDay: true) }
                    errorHandler?("Daily memory export failed: \(error.localizedDescription)")
                }
            }
            if generation == runGeneration {
                exportTask = nil
                if succeeded { tick() }
            }
        }
    }

    private func finish(_ day: Date, isPastDay: Bool) {
        if isPastDay {
            caughtUpDays.insert(day)
            reopenedDays.remove(day)
        } else {
            lastSuccessfulDay = day
        }
    }

    /// Reopened past days first, then past days not yet checked for a
    /// missing note (oldest first), then today once its hour arrives.
    nonisolated static func nextExport(
        at date: Date,
        hour: Int,
        lastSuccessfulDay: Date?,
        caughtUpDays: Set<Date>,
        reopenedDays: Set<Date>,
        calendar: Calendar
    ) -> (day: Date, pass: DailyMemoryExportPass)? {
        let today = calendar.startOfDay(for: date)
        let windowStart = calendar.date(byAdding: .day, value: -catchUpDays, to: today) ?? today
        if let day = reopenedDays.filter({ $0 >= windowStart && $0 < today }).min() {
            return (day, .refresh)
        }
        var cursor = windowStart
        while cursor < today {
            if !caughtUpDays.contains(cursor) { return (cursor, .catchUp) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
        }
        return shouldRun(at: date, hour: hour, lastSuccessfulDay: lastSuccessfulDay, calendar: calendar)
            ? (today, .refresh)
            : nil
    }

    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        lastSuccessfulDay: Date?,
        calendar: Calendar
    ) -> Bool {
        let day = calendar.startOfDay(for: date)
        if let lastSuccessfulDay,
           calendar.isDate(lastSuccessfulDay, inSameDayAs: day) {
            return false
        }
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? day
        return date >= target
    }
}
