import Foundation

struct TimelineDayList: Equatable {
    enum Part: Int, CaseIterable, Sendable {
        case morning, afternoon, evening

        var title: String {
            switch self {
            case .morning: "Morning"
            case .afternoon: "Afternoon"
            case .evening: "Evening"
            }
        }

        static func part(of date: Date, calendar: Calendar = .current) -> Part {
            let hour = calendar.component(.hour, from: date)
            return hour < 12 ? .morning : hour < 17 ? .afternoon : .evening
        }
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case work(TimelineWorkSession.ID)
            case meeting(Meeting.ID, isLive: Bool)
        }

        let id: String
        let kind: Kind
        let start: Date
        let end: Date
        let title: String
        let detail: String
        let duration: TimeInterval
        let colorKey: String?
        let isQuiet: Bool
        var foldedSessionIDs: [TimelineWorkSession.ID] = []

        var isMeeting: Bool {
            if case .meeting = kind { return true }
            return false
        }

        static func id(session: TimelineWorkSession.ID) -> String { "work-\(session)" }
        static func id(meeting: Meeting.ID) -> String { "meeting-\(meeting.uuidString)" }
    }

    enum Entry: Identifiable, Equatable {
        case row(Row)
        case away(start: Date, end: Date)

        var id: String {
            switch self {
            case .row(let row): row.id
            case .away(let start, _): "away-\(Int(start.timeIntervalSince1970))"
            }
        }
    }

    struct Section: Identifiable, Equatable {
        let part: Part
        var entries: [Entry]
        var id: Part { part }
    }

    let sections: [Section]

    var rows: [Row] {
        sections.flatMap { section in
            section.entries.compactMap { entry -> Row? in
                if case .row(let row) = entry { return row }
                return nil
            }
        }
    }

    var isEmpty: Bool { sections.isEmpty }

    static let minimumGap: TimeInterval = 30 * 60
    static let foldShare = 0.6

    init(
        sessions: [TimelineWorkSession],
        meetings: [Meeting],
        now: Date,
        usesProjectColors: Bool = false,
        calendar: Calendar = .current,
        localize: (String) -> String = { $0 }
    ) {
        let timed = meetings.map { (meeting: $0, end: CaptureTrackItem.meetingEnd($0, now: now)) }
        var folded: [Meeting.ID: [TimelineWorkSession.ID]] = [:]
        var foldedSessions = Set<TimelineWorkSession.ID>()
        for session in sessions {
            guard let host = Self.meeting(covering: session, in: timed) else { continue }
            folded[host, default: []].append(session.id)
            foldedSessions.insert(session.id)
        }

        var sections: [Section] = []
        var latestEnd: Date?
        let items = TimelineDayItem.items(sessions: sessions, meetings: meetings, now: now).sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            if left.isMeeting != right.isMeeting { return left.isMeeting }
            return left.id < right.id
        }
        for item in items {
            if let latestEnd, item.start.timeIntervalSince(latestEnd) >= Self.minimumGap, !sections.isEmpty {
                sections[sections.count - 1].entries.append(.away(start: latestEnd, end: item.start))
            }
            latestEnd = max(latestEnd ?? item.end, item.end)
            let row: Row
            switch item {
            case .work(let session):
                if foldedSessions.contains(session.id) { continue }
                let text = Self.workText(for: session, localize: localize)
                row = Row(
                    id: Row.id(session: session.id), kind: .work(session.id),
                    start: session.start, end: session.end,
                    title: text.title, detail: text.detail, duration: session.activeDuration,
                    colorKey: session.project ?? (usesProjectColors ? nil : session.primaryApp),
                    isQuiet: text.isQuiet)
            case .meeting(let meeting, let end):
                let isLive = meeting.endedAt == nil
                row = Row(
                    id: Row.id(meeting: meeting.id), kind: .meeting(meeting.id, isLive: isLive),
                    start: meeting.startedAt, end: end,
                    title: meeting.displayTitle,
                    detail: Self.meetingDetail(app: meeting.appName, isLive: isLive, localize: localize),
                    duration: max(0, end.timeIntervalSince(meeting.startedAt)),
                    colorKey: nil, isQuiet: false,
                    foldedSessionIDs: folded[meeting.id] ?? [])
            }
            let part = Part.part(of: row.start, calendar: calendar)
            if sections.last?.part == part {
                sections[sections.count - 1].entries.append(.row(row))
            } else {
                sections.append(Section(part: part, entries: [.row(row)]))
            }
        }
        self.sections = sections
    }

    static func meeting(
        covering session: TimelineWorkSession,
        in meetings: [(meeting: Meeting, end: Date)]
    ) -> Meeting.ID? {
        guard session.agentBursts.isEmpty, !session.titleNamesProject else { return nil }
        let span = session.end.timeIntervalSince(session.start)
        guard span > 0 else { return nil }
        var best: (id: Meeting.ID, overlap: TimeInterval)?
        for (meeting, end) in meetings where isSameApp(session.primaryApp, meeting.appName) {
            let overlap = min(session.end, end).timeIntervalSince(max(session.start, meeting.startedAt))
            if overlap / span >= foldShare, overlap > (best?.overlap ?? 0) {
                best = (meeting.id, overlap)
            }
        }
        return best?.id
    }

    static func isSameApp(_ sessionApp: String, _ meetingApp: String) -> Bool {
        let left = appKey(sessionApp), right = appKey(meetingApp)
        guard left.count >= 3, right.count >= 3 else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func appKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    static func workText(
        for session: TimelineWorkSession,
        localize: (String) -> String = { $0 }
    ) -> (title: String, detail: String, isQuiet: Bool) {
        let outcomes = TimelineOutcomeWording.parts(session.outcomes, localize: localize)
        let apps = TimelineWorkSession.appSummary(session.usedApps)
        if session.titleNamesProject, let project = session.projectLabel {
            if let task = session.taskTitle {
                return (task, joined([project] + outcomes), false)
            }
            return (project, joined(outcomes.isEmpty ? [apps] : outcomes), false)
        }
        if session.titleNamesApps {
            return (session.title, joined(outcomes), true)
        }
        return (session.title, joined([apps] + outcomes), false)
    }

    static func meetingDetail(app: String, isLive: Bool, localize: (String) -> String = { $0 }) -> String {
        joined([localize(isLive ? "Recording" : "Meeting"), app.trimmingCharacters(in: .whitespaces)])
    }

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func row(id: String?) -> Row? {
        guard let id else { return nil }
        return rows.first { $0.id == id }
    }

    func rowID(showing session: TimelineWorkSession.ID) -> String? {
        rows.first { $0.id == Row.id(session: session) || $0.foldedSessionIDs.contains(session) }?.id
    }

    func workRow(inTimeRange text: String, day: Date, calendar: Calendar = .current) -> Row? {
        guard let interval = Self.interval(fromTimeRange: text, day: day, calendar: calendar) else { return nil }
        var best: (row: Row, overlap: TimeInterval)?
        for row in rows where !row.isMeeting {
            let overlap = min(row.end, interval.end).timeIntervalSince(max(row.start, interval.start))
            if overlap > (best?.overlap ?? 0) { best = (row, overlap) }
        }
        return best?.row
    }

    static func interval(fromTimeRange text: String, day: Date, calendar: Calendar = .current) -> DateInterval? {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 4, numbers[0] < 24, numbers[2] < 24, numbers[1] < 60, numbers[3] < 60 else {
            return nil
        }
        let dayInterval = ActivityStore.dayInterval(containing: day, calendar: calendar)
        guard let start = calendar.date(bySettingHour: numbers[0], minute: numbers[1], second: 0,
                                        of: dayInterval.start),
              let rawEnd = calendar.date(bySettingHour: numbers[2], minute: numbers[3], second: 0,
                                         of: dayInterval.start) else { return nil }
        let end = rawEnd > start ? rawEnd : dayInterval.end
        return end > start ? DateInterval(start: start, end: end) : nil
    }
}

enum TimelineOutcomeWording {
    static func parts(_ outcomes: TimelineAgentOutcomes, localize: (String) -> String = { $0 }) -> [String] {
        var parts: [String] = []
        let opened = outcomes.openedPullRequests.count
        if opened > 0 {
            parts.append(String(format: localize(opened == 1 ? "%lld PR opened" : "%lld PRs opened"), opened))
        }
        let merged = outcomes.mergedPullRequests
        if merged > 0 { parts.append(String(format: localize("%lld merged"), merged)) }
        let commits = outcomes.commits
        if parts.isEmpty, commits > 0 {
            parts.append(String(format: localize(commits == 1 ? "%lld commit" : "%lld commits"), commits))
        }
        return parts
    }

    static func text(_ outcomes: TimelineAgentOutcomes, localize: (String) -> String = { $0 }) -> String? {
        let parts = parts(outcomes, localize: localize)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum TimelineListSelection: Equatable {
    case digest
    case row(String)
    case raw
    case none

    static func order(of list: TimelineDayList) -> [TimelineListSelection] {
        [.digest] + list.rows.map { .row($0.id) } + [.raw]
    }

    func moved(by step: Int, in list: TimelineDayList) -> TimelineListSelection {
        let order = Self.order(of: list)
        guard let index = order.firstIndex(of: self) else { return .digest }
        return order[min(max(index + step, 0), order.count - 1)]
    }
}

enum TimelineListClock {
    static func pattern(locale: Locale) -> String {
        let full = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        var kept = ""
        var quoted = false
        var isTwelveHour = false
        for character in full {
            if character == "'" { quoted.toggle() }
            if !quoted, "aAbB".contains(character) { continue }
            if !quoted, "hK".contains(character) { isTwelveHour = true }
            kept.append(character)
        }
        if isTwelveHour {
            kept = kept.replacingOccurrences(of: "hh", with: "h").replacingOccurrences(of: "KK", with: "K")
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    static func text(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        formatter(locale: locale, timeZone: timeZone).string(from: date)
    }

    private struct Key: Equatable {
        let locale: Locale
        let timeZone: TimeZone
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (key: Key, formatter: DateFormatter)?

    private static func formatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = Key(locale: locale, timeZone: timeZone)
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.key == key { return cached.formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern(locale: locale)
        cached = (key, formatter)
        return formatter
    }
}
