import Foundation

/// A calendar day as records carry it: `YYYY-MM-DD` in the Mac's local time
/// zone. Comparing keys as strings orders them by date.
public struct DayKey: Hashable, Comparable, Sendable, CustomStringConvertible, Identifiable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var id: String { description }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Noon on this day in `calendar`'s time zone: safe for formatting the
    /// weekday and date without crossing a day boundary.
    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: date(in: calendar)) ?? date(in: calendar), calendar: calendar)
    }

    public func days(until other: DayKey, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: date(in: calendar), to: other.date(in: calendar)).day ?? 0
    }
}
