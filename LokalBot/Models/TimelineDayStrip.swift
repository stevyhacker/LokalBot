import CoreGraphics
import Foundation

/// The day strip on Timeline's digest page: the hours left to right, meetings
/// in a lane above work. Each bar stands for a row of the day's list, so
/// clicking one selects that row. Positions are fractions of the strip's
/// span, which runs over whole hours and never leaves the civil day.
struct TimelineDayStrip: Equatable {
    struct Bar: Identifiable, Equatable {
        /// The list row the bar selects.
        let id: String
        /// Where the bar starts and ends, 0 at the leading edge and 1 at the trailing one.
        let start: Double
        let end: Double
        /// See `TimelineDayList.Row.colorKey`.
        let colorKey: String?
    }

    struct Tick: Equatable {
        let position: Double
        let date: Date
        /// The first hour and noon say AM or PM where the clock has them.
        let namesDayPeriod: Bool
    }

    let span: DateInterval
    let meetings: [Bar]
    let work: [Bar]
    /// One per hour, from the first hour to the last one that starts inside the span.
    let ticks: [Tick]

    /// Nil for a day with no rows inside it.
    init?(rows: [TimelineDayList.Row], day: Date, calendar: Calendar = .current) {
        let dayInterval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let clipped: [(row: TimelineDayList.Row, start: Date, end: Date)] = rows.compactMap { row in
            let start = max(row.start, dayInterval.start), end = min(row.end, dayInterval.end)
            return end > start ? (row, start, end) : nil
        }
        guard let first = clipped.map(\.start).min(), let last = clipped.map(\.end).max() else { return nil }
        let spanStart = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var spanEnd = last
        // An end on the hour needs no extra hour; any other rounds up.
        if let hour = calendar.dateInterval(of: .hour, for: last), hour.start < last { spanEnd = hour.end }
        spanEnd = min(max(spanEnd, spanStart.addingTimeInterval(3600)), dayInterval.end)
        let span = DateInterval(start: spanStart, end: max(spanEnd, spanStart.addingTimeInterval(60)))
        let length = span.duration
        var meetings: [Bar] = []
        var work: [Bar] = []
        for item in clipped {
            let start: Double = item.start.timeIntervalSince(span.start) / length
            let end: Double = item.end.timeIntervalSince(span.start) / length
            let bar = Bar(id: item.row.id, start: start, end: end, colorKey: item.row.colorKey)
            if item.row.isMeeting { meetings.append(bar) } else { work.append(bar) }
        }
        self.span = span
        self.meetings = meetings
        self.work = work

        var ticks: [Tick] = []
        var cursor = span.start
        while cursor < span.end {
            let hour = calendar.component(.hour, from: cursor)
            let position: Double = cursor.timeIntervalSince(span.start) / length
            let namesDayPeriod = ticks.isEmpty || hour == 12
            ticks.append(Tick(position: position, date: cursor, namesDayPeriod: namesDayPeriod))
            // Step by the calendar so a daylight-saving day keeps its hours.
            let next = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
            cursor = next > cursor ? next : cursor.addingTimeInterval(3600)
        }
        self.ticks = ticks
    }

    /// The ticks that get a label when only `count` labels fit: every
    /// second or third hour on a long day, always starting with the first.
    func labelledTicks(fitting count: Int) -> [Tick] {
        guard count > 0, ticks.count > count else { return count > 0 ? ticks : [] }
        let stride = Int((Double(ticks.count) / Double(count)).rounded(.up))
        return ticks.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
    }

    /// A bar's place in a lane `width` points wide. A short bar keeps
    /// `minimumWidth` so it can be seen and clicked, and never leaves the lane.
    static func frame(of bar: Bar, in width: CGFloat, minimumWidth: CGFloat = 3) -> (x: CGFloat, width: CGFloat) {
        guard width > 0 else { return (0, 0) }
        let start = CGFloat(min(max(bar.start, 0), 1)) * width
        let end = CGFloat(min(max(bar.end, 0), 1)) * width
        let barWidth = min(width, max(minimumWidth, end - start))
        return (min(start, width - barWidth), barWidth)
    }
}

/// Where the day's tracked time went, for the strip's legend: by project
/// when coding-agent sessions name projects, else by app.
enum TimelineDayLegend {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case app, otherApps, project, otherProjects, otherActivity }
        let label: String
        let seconds: TimeInterval
        let kind: Kind
        var id: String { "\(kind)-\(label)" }

        /// An app or a project has its own colour; the folded entries are neutral.
        var colorKey: String? { kind == .app || kind == .project ? label : nil }
    }

    static func entries(
        perApp: [(label: String, seconds: TimeInterval)],
        split: TimelineProjectAttribution.DaySplit
    ) -> [Entry] {
        split.projects.isEmpty ? appEntries(perApp) : projectEntries(split)
    }

    static func appEntries(_ perApp: [(label: String, seconds: TimeInterval)]) -> [Entry] {
        AppTimePresentation.rows(perApp: perApp).map {
            Entry(label: $0.label, seconds: $0.seconds, kind: $0.isOther ? .otherApps : .app)
        }
    }

    /// The four busiest projects, the rest folded together, then the time no
    /// project claims.
    static func projectEntries(_ split: TimelineProjectAttribution.DaySplit, cap: Int = 4) -> [Entry] {
        var entries: [Entry] = []
        var otherSeconds: TimeInterval = 0
        for share in split.projects {
            if entries.count < cap, share.seconds >= 60 {
                entries.append(Entry(label: share.project, seconds: share.seconds, kind: .project))
            } else {
                otherSeconds += share.seconds
            }
        }
        if otherSeconds >= 60 {
            entries.append(Entry(label: "Other projects", seconds: otherSeconds, kind: .otherProjects))
        }
        if split.unattributedSeconds >= 60 {
            entries.append(Entry(label: "Other activity", seconds: split.unattributedSeconds, kind: .otherActivity))
        }
        return entries
    }
}

/// The one line for the day's actions on Timeline's digest page: the user's
/// actions that a meeting of that day mentioned, done ones included.
enum TimelineDayActions {
    enum Summary: Equatable {
        case open(Int)
        case allDone(Int)
        /// Nothing is open, and some are deferred rather than done.
        case noneOpen(Int)
    }

    /// Open work first, then the rest, each in the index's order.
    static func threads(_ all: [ActionThread], on day: Date, calendar: Calendar = .current) -> [ActionThread] {
        let ofDay = all.filter { thread in
            thread.references.contains { calendar.isDate($0.meetingStartedAt, inSameDayAs: day) }
        }
        return ofDay.filter { $0.status == .open } + ofDay.filter { $0.status != .open }
    }

    static func summary(of threads: [ActionThread]) -> Summary? {
        guard !threads.isEmpty else { return nil }
        let open = threads.filter { $0.status == .open }.count
        if open > 0 { return .open(open) }
        return threads.allSatisfy { $0.status == .done } ? .allDone(threads.count) : .noneOpen(threads.count)
    }

    static func label(_ summary: Summary, localize: (String) -> String = { $0 }) -> String {
        switch summary {
        case .open(let count):
            String(format: localize(count == 1 ? "%lld open action from this day’s meetings"
                                    : "%lld open actions from this day’s meetings"), count)
        case .allDone(let count):
            String(format: localize(count == 1 ? "%lld action from this day’s meetings, done"
                                    : "%lld actions from this day’s meetings, all done"), count)
        case .noneOpen(let count):
            String(format: localize(count == 1 ? "%lld action from this day’s meetings, deferred"
                                    : "%lld actions from this day’s meetings, none open"), count)
        }
    }
}

/// What the list's Day digest row says under its title, and what the day
/// menu's digest item is called.
enum TimelineDigestPreview {
    /// The catalog key of the menu item that writes the digest. It names what
    /// choosing it will do: write the first digest, update one that has newer
    /// activity, or rewrite a current one. Each is an explicit action; a
    /// digest is never rewritten without being asked.
    static func menuTitle(isWriting: Bool, hasDigest: Bool, isStale: Bool) -> String {
        if isWriting { return "Writing digest…" }
        if !hasDigest { return "Write digest" }
        return isStale ? "Update digest" : "Rewrite digest"
    }

    /// The digest's first highlight as one plain line.
    static func firstHighlight(_ highlights: String) -> String? {
        for line in highlights.components(separatedBy: .newlines) {
            var text = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
            }
            if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty,
               text[text.index(after: dot)...].hasPrefix(" ") {
                text = String(text[text.index(dot, offsetBy: 2)...])
            }
            text = text.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !text.hasPrefix("#") { return text }
        }
        return nil
    }
}
