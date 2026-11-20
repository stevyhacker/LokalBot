import Foundation

@MainActor
final class LibraryHealthScheduler {
    static let defaultHour = 9
    static let catchUpAge: TimeInterval = 24 * 60 * 60
    static let enabledDefaultsKey = "LokalBotDailyHealthCheck"

    nonisolated static var isEnabledForThisBuild: Bool {
#if DEBUG
        true
#else
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
#endif
    }

    nonisolated static func shouldRun(at date: Date, lastRun: Date?, hour: Int, calendar: Calendar) -> Bool {
        guard let lastRun else { return true }
        if date.timeIntervalSince(lastRun) >= catchUpAge { return true }
        let target = calendar.date(bySettingHour: min(23, max(0, hour)), minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        return date >= target && lastRun < target
    }

    private let calendar: Calendar
    private let now: () -> Date
    private var timer: Timer?
    private var hour = defaultHour
    private var lastRun: () -> Date? = { nil }
    private var run: () -> Void = {}

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func start(hour: Int = defaultHour, lastRun: @escaping () -> Date?, run: @escaping () -> Void) {
        stop()
        self.hour = hour
        self.lastRun = lastRun
        self.run = run
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard Self.shouldRun(at: now(), lastRun: lastRun(), hour: hour, calendar: calendar) else { return }
        run()
    }
}
