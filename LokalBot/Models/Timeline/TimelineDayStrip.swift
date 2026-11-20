import CoreGraphics
import Foundation

struct TimelineDayStrip: Equatable {
    struct Bar: Identifiable, Equatable {
        let id: String
        let start: Double
        let end: Double
        let colorKey: String?
    }

    struct Tick: Equatable {
        let position: Double
        let date: Date
        let namesDayPeriod: Bool
    }

    let span: DateInterval
    let meetings: [Bar]
    let work: [Bar]
    let ticks: [Tick]

    init?(rows: [TimelineDayList.Row], day: Date, calendar: Calendar = .current) {
        let dayInterval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        let clipped: [(row: TimelineDayList.Row, start: Date, end: Date)] = rows.compactMap { row in
            let start = max(row.start, dayInterval.start), end = min(row.end, dayInterval.end)
            return end > start ? (row, start, end) : nil
        }
        guard let first = clipped.map(\.start).min(), let last = clipped.map(\.end).max() else { return nil }
        let spanStart = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var spanEnd = last
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
            let next = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? cursor.addingTimeInterval(3600)
            cursor = next > cursor ? next : cursor.addingTimeInterval(3600)
        }
        self.ticks = ticks
    }

    func labelledTicks(fitting count: Int) -> [Tick] {
        guard count > 0, ticks.count > count else { return count > 0 ? ticks : [] }
        let stride = Int((Double(ticks.count) / Double(count)).rounded(.up))
        return ticks.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
    }

    static func frame(of bar: Bar, in width: CGFloat, minimumWidth: CGFloat = 3) -> (x: CGFloat, width: CGFloat) {
        guard width > 0 else { return (0, 0) }
        let start = CGFloat(min(max(bar.start, 0), 1)) * width
        let end = CGFloat(min(max(bar.end, 0), 1)) * width
        let barWidth = min(width, max(minimumWidth, end - start))
        return (min(start, width - barWidth), barWidth)
    }
}

enum TimelineDayLegend {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case app, otherApps, project, otherProjects, otherActivity }
        let label: String
        let seconds: TimeInterval
        let kind: Kind
        var id: String { "\(kind)-\(label)" }

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

enum TimelineDayActions {
    enum Summary: Equatable {
        case open(Int)
        case allDone(Int)
        case noneOpen(Int)
    }

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
}

enum TimelineDigestPreview {
    static func menuTitle(isWriting: Bool, hasDigest: Bool, isStale: Bool) -> String {
        if isWriting { return "Writing digest…" }
        if !hasDigest { return "Write digest" }
        return isStale ? "Update digest" : "Rewrite digest"
    }
}
