import Foundation

/// One civil-date boundary shared by recall, answer tools and saved questions.
/// Existing single-day keys remain readable; ranges use inclusive end dates.
struct AskDateScope: Equatable, Sendable {
    let firstDay: String
    let lastDay: String

    init(day: Date, calendar: Calendar = .current) {
        firstDay = AskDayScope.key(for: day, calendar: calendar)
        lastDay = firstDay
    }

    init?(storageKey: String) {
        let parts = storageKey.components(separatedBy: "...")
        guard (1...2).contains(parts.count), let first = parts.first, let last = parts.last,
              AskDayScope.isCanonicalKey(first), AskDayScope.isCanonicalKey(last), first <= last else { return nil }
        firstDay = first
        lastDay = last
    }

    var storageKey: String { firstDay == lastDay ? firstDay : "\(firstDay)...\(lastDay)" }

    static func lastSevenDays(now: Date = Date(), calendar: Calendar = .current) -> Self {
        let start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        return Self(firstDay: AskDayScope.key(for: start, calendar: calendar),
                    lastDay: AskDayScope.key(for: now, calendar: calendar))
    }

    private init(firstDay: String, lastDay: String) {
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    func interval(calendar: Calendar = .current) -> DateInterval? {
        guard let start = AskDayScope.date(for: firstDay, calendar: calendar),
              let last = AskDayScope.date(for: lastDay, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return DateInterval(start: start, end: end)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = interval(calendar: calendar) else { return false }
        return date >= interval.start && date < interval.end
    }

    func contains(dayKey: String) -> Bool {
        AskDayScope.isCanonicalKey(dayKey) && dayKey >= firstDay && dayKey <= lastDay
    }

    var dateLabel: String {
        guard let first = AskDayScope.date(for: firstDay), let last = AskDayScope.date(for: lastDay) else { return storageKey }
        let startLabel = first.formatted(date: .abbreviated, time: .omitted)
        return firstDay == lastDay ? startLabel : "\(startLabel) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    func label(now: Date = Date(), calendar: Calendar = .current) -> String {
        if self == Self(day: now, calendar: calendar) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           self == Self(day: yesterday, calendar: calendar) { return "Yesterday" }
        if self == Self.lastSevenDays(now: now, calendar: calendar) { return "Last 7 days" }
        return dateLabel
    }
}
