import Foundation

/// Clock label for an hour-of-day setting, following the Mac's 12- or 24-hour
/// preference so settings read like times elsewhere in the app.
enum HourLabel {
    static func format(_ hour: Int, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? Date()
        return date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))
    }
}
