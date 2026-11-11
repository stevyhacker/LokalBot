import Foundation

/// Timeline's list for one day: its work sessions and meetings in time order
/// under Morning, Afternoon and Evening, with long stretches of nothing kept
/// as gaps. A session spent in the app a recorded meeting ran in folds into
/// that meeting, so a call is listed once. Display only; nothing here is
/// stored, and a folded session's activity stays in All captured activity.
struct TimelineDayList: Equatable {
    enum Part: Int, CaseIterable, Sendable {
        case morning, afternoon, evening

        /// The heading's catalog key.
        var title: String {
            switch self {
            case .morning: "Morning"
            case .afternoon: "Afternoon"
            case .evening: "Evening"
            }
        }

        /// Before noon, before five, and the rest of the day.
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
        /// The second line: project and what was produced, or the apps, for
        /// work; "Meeting · app" for a meeting. Empty when the title says it all.
        let detail: String
        /// A session's active time; a meeting's length.
        let duration: TimeInterval
        /// What colours a session's dot and its bar in the day strip: its
        /// project, or its busiest app on a day without projects. Nil reads
        /// as other activity. Meetings keep their own tone.
        let colorKey: String?
        /// A title that only lists apps reads quieter than one that names work.
        let isQuiet: Bool
        /// Call-app sessions folded into this meeting.
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
        /// Nothing was recorded between two rows.
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

    /// Every session and meeting row, in list order.
    var rows: [Row] {
        sections.flatMap { section in
            section.entries.compactMap { entry -> Row? in
                if case .row(let row) = entry { return row }
                return nil
            }
        }
    }

    var isEmpty: Bool { sections.isEmpty }

    /// A stretch this long with nothing recorded gets its own "Away" line.
    static let minimumGap: TimeInterval = 30 * 60
    /// A call app's session folds into a meeting that covers this much of it.
    static let foldShare = 0.6

    /// - Parameters:
    ///   - usesProjectColors: the day's time is split by project, so a
    ///     session without one reads as other activity.
    ///   - localize: looks a catalog key up in the interface language.
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
        // A meeting leads a session that starts with it.
        let items = TimelineDayItem.items(sessions: sessions, meetings: meetings, now: now).sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            if left.isMeeting != right.isMeeting { return left.isMeeting }
            return left.id < right.id
        }
        for item in items {
            // The gap closes the part of the day it began in, like the list reads.
            if let latestEnd, item.start.timeIntervalSince(latestEnd) >= Self.minimumGap, !sections.isEmpty {
                sections[sections.count - 1].entries.append(.away(start: latestEnd, end: item.start))
            }
            latestEnd = max(latestEnd ?? item.end, item.end)
            let row: Row
            switch item {
            case .work(let session):
                // A folded call is recorded time, shown as its meeting's row.
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

    // MARK: - Folding a call into its meeting

    /// The meeting a call-app session belongs to: the one that covers most
    /// of it, when that is at least `foldShare`. Work with a project or
    /// agent sessions is never folded.
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

    /// The activity sampler stores an app's own name ("zoom.us", "Microsoft
    /// Teams") and a meeting the name LokalBot gives its call app ("Zoom",
    /// "Teams"), so one may contain the other.
    static func isSameApp(_ sessionApp: String, _ meetingApp: String) -> Bool {
        let left = appKey(sessionApp), right = appKey(meetingApp)
        guard left.count >= 3, right.count >= 3 else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func appKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    // MARK: - Row text

    /// A session's two lines. With a project the task leads and the project
    /// moves to the second line beside what the agents produced. Without
    /// one, the window that named the session leads and its apps follow. A
    /// session only its apps describe is one quiet line.
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

    /// "Meeting · Zoom", or "Recording · Zoom" while it is being recorded.
    static func meetingDetail(app: String, isLive: Bool, localize: (String) -> String = { $0 }) -> String {
        joined([localize(isLive ? "Recording" : "Meeting"), app.trimmingCharacters(in: .whitespaces)])
    }

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Finding rows

    func row(id: String?) -> Row? {
        guard let id else { return nil }
        return rows.first { $0.id == id }
    }

    /// The row that shows a session: its own, or the meeting it folded into.
    func rowID(showing session: TimelineWorkSession.ID) -> String? {
        rows.first { $0.id == Row.id(session: session) || $0.foldedSessionIDs.contains(session) }?.id
    }

    /// The session a digest task's "09:00–10:30" covers most, so an older
    /// digest's time range can open that session.
    func workRow(inTimeRange text: String, day: Date, calendar: Calendar = .current) -> Row? {
        guard let interval = Self.interval(fromTimeRange: text, day: day, calendar: calendar) else { return nil }
        var best: (row: Row, overlap: TimeInterval)?
        for row in rows where !row.isMeeting {
            let overlap = min(row.end, interval.end).timeIntervalSince(max(row.start, interval.start))
            if overlap > (best?.overlap ?? 0) { best = (row, overlap) }
        }
        return best?.row
    }

    /// "09:00–10:30" on `day`. A range that ends before it starts runs past
    /// midnight and is clipped to the day.
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

/// "3 PRs opened · 1 merged", or the commits when no pull request moved.
/// Each count is its own catalog entry, so every language words it.
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

/// What Timeline's list has selected: the digest, a session or meeting row,
/// or all captured activity. `none` is a moment opened from another page,
/// which belongs to no row.
enum TimelineListSelection: Equatable {
    case digest
    case row(String)
    case raw
    case none

    /// The list from top to bottom, for the arrow keys.
    static func order(of list: TimelineDayList) -> [TimelineListSelection] {
        [.digest] + list.rows.map { .row($0.id) } + [.raw]
    }

    /// The selection `step` rows away, stopping at either end. From a
    /// selection the list does not show, any step lands on the digest.
    func moved(by step: Int, in list: TimelineDayList) -> TimelineListSelection {
        let order = Self.order(of: list)
        guard let index = order.firstIndex(of: self) else { return .digest }
        return order[min(max(index + step, 0), order.count - 1)]
    }
}
