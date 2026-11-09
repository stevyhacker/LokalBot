import Foundation

/// Text formats shared by every screen. Each takes its locale and calendar so
/// tests can pin them.
public struct LBFormat: Sendable {
    public var locale: Locale
    public var calendar: Calendar

    public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
        self.locale = locale
        self.calendar = calendar
    }

    public static let current = LBFormat()

    // MARK: Offsets and durations

    /// A transcript offset as the Mac shows it: `00:12:01`.
    public static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A meeting's length as the Mac's meeting list shows it: "42 min", "1 hr 5 min".
    public static func meetingDuration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds)) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    /// Tracked time as the Mac's Timeline shows it: "<1m", "42m", "1h 5m".
    public static func hm(_ seconds: Double) -> String {
        if seconds > 0, seconds < 60 { return "<1m" }
        let minutes = max(0, Int(seconds)) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: Times

    /// A time of day, in `timeZone` (the Mac's offset for a meeting).
    public func time(_ date: Date, in timeZone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        style.timeZone = timeZone ?? calendar.timeZone
        return date.formatted(style)
    }

    /// The local time of a moment in a meeting, as it was on the Mac.
    public func time(in meeting: Meeting, at offset: Double) -> String {
        time(meeting.startedAt.addingTimeInterval(offset), in: meeting.timeZone)
    }

    public func timeRange(_ start: Date, _ end: Date, in timeZone: TimeZone? = nil) -> String {
        "\(time(start, in: timeZone))–\(time(end, in: timeZone))"
    }

    // MARK: Days

    /// "Today", "Yesterday", the weekday within the last week, otherwise a date.
    public func dayTitle(_ day: DayKey, today: DayKey) -> String {
        let distance = day.days(until: today, calendar: calendar)
        switch distance {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return format(day, .dateTime.weekday(.wide))
        default: return format(day, .dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// "Friday, 31 October" for page subtitles.
    public func longDay(_ day: DayKey) -> String {
        format(day, .dateTime.weekday(.wide).day().month(.wide))
    }

    /// "Thu 30" for the day strip.
    public func weekday(_ day: DayKey) -> String {
        format(day, .dateTime.weekday(.abbreviated))
    }

    public func shortDate(_ day: DayKey) -> String {
        format(day, .dateTime.day().month(.abbreviated))
    }

    public func meetingDate(_ meeting: Meeting) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
        style.timeZone = meeting.timeZone
        return meeting.startedAt.formatted(style)
    }

    private func format(_ day: DayKey, _ style: Date.FormatStyle) -> String {
        var style = style
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.date(in: calendar).formatted(style)
    }

    // MARK: Due dates

    public struct Due: Sendable, Hashable {
        public var text: String
        public var isOverdue: Bool
    }

    /// "Overdue · Thu", "Due today", "Due Mon", "Due Wed, 12 Nov". Only open
    /// actions can be overdue.
    public func due(_ dueDate: String?, status: ActionStatus, today: DayKey) -> Due? {
        guard let dueDate, let day = DayKey(dueDate) else { return nil }
        let distance = today.days(until: day, calendar: calendar)
        if distance < 0 && status == .open {
            let when = distance >= -6 ? format(day, .dateTime.weekday(.abbreviated)) : shortDate(day)
            return Due(text: "Overdue · \(when)", isOverdue: true)
        }
        switch distance {
        case 0 where status == .open: return Due(text: "Due today", isOverdue: false)
        case 1 where status == .open: return Due(text: "Due tomorrow", isOverdue: false)
        case 2...6 where status == .open: return Due(text: "Due \(format(day, .dateTime.weekday(.abbreviated)))", isOverdue: false)
        default: return Due(text: "Due \(format(day, .dateTime.weekday(.abbreviated).day().month(.abbreviated)))", isOverdue: false)
        }
    }

    // MARK: Sync

    /// "just now", "2 min ago", "3 hr ago", "yesterday", "28 Oct".
    public func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let today = DayKey(now, calendar: calendar)
        let then = DayKey(date, calendar: calendar)
        if then == today { return "\(Int(seconds / 3600)) hr ago" }
        if then.days(until: today, calendar: calendar) == 1 { return "yesterday" }
        return shortDate(then)
    }
}
