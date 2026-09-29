import Foundation

/// A Dream project joined to the evidence behind it: meetings whose title or
/// summary names it, open action threads from those meetings, and tracked
/// time in windows whose titles name it. Matching is deterministic word
/// matching on the project name; no model decides what belongs to a project.
struct ProjectProfile: Identifiable, Equatable, Sendable {
    struct MeetingRef: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
    }

    struct WindowTime: Identifiable, Equatable, Sendable {
        var id: String { app + "|" + title }
        let app: String
        let title: String
        let seconds: TimeInterval
    }

    struct DayTime: Identifiable, Equatable, Sendable {
        var id: String { dayKey }
        let dayKey: String
        let seconds: TimeInterval
    }

    let id: String
    let name: String
    let status: String
    let lastActiveDay: String
    let pinned: Bool
    var meetings: [MeetingRef]
    var openActions: [ActionThread]
    /// Tracked time in the reviewed window, newest day first.
    var days: [DayTime]
    var windows: [WindowTime]
    var people: [String]

    var trackedSeconds: TimeInterval { days.reduce(0) { $0 + $1.seconds } }
    var meetingIDs: Set<UUID> { Set(meetings.map(\.id)) }
}

enum ProjectLinks {
    static let reviewDays = 7
    static let maximumWindows = 6
    static let maximumSummaryCharacters = 4_000

    struct Input: Sendable {
        var memory: DreamMemory
        var meetings: [Meeting]
        var summaries: [UUID: String] = [:]
        var projections: [MeetingOutcomeProjection] = []
        var activity: [ActivityBlock] = []
        var people: [PersonProfile] = []
    }

    static func build(_ input: Input, now: Date = Date(), calendar: Calendar = .current) -> [ProjectProfile] {
        let meetings: [Meeting] = input.meetings.filter { $0.mergedIntoMeetingID == nil }
        let references: [OutcomeActionReference] = input.projections
            .filter { !$0.isArchived }
            .flatMap(\.actionReferences)
        let threads: [ActionThread] = ActionThreadClusterer.cluster(references)
            .filter { $0.status != .done }
        let windowStart: Date = calendar.date(byAdding: .day, value: -(reviewDays - 1),
                                              to: calendar.startOfDay(for: now)) ?? now
        return input.memory.activeProjects.map { (project: DreamMemory.Project) -> ProjectProfile in
            profile(for: project, input: input, meetings: meetings, threads: threads,
                    windowStart: windowStart, now: now, calendar: calendar)
        }
    }

    // Split into small, explicitly typed steps: one large closure exceeded
    // the CI compiler's type-checking time limit.
    private static func profile(
        for project: DreamMemory.Project, input: Input, meetings: [Meeting],
        threads: [ActionThread], windowStart: Date, now: Date, calendar: Calendar
    ) -> ProjectProfile {
        let terms: Set<String> = significantTerms(project.name)
        let linkedMeetings: [Meeting] = linkedMeetings(terms: terms, meetings: meetings,
                                                       summaries: input.summaries)
        let linkedIDs: Set<UUID> = Set(linkedMeetings.map(\.id))
        let actions: [ActionThread] = threads.filter { (thread: ActionThread) -> Bool in
            if matches(terms, in: thread.text) { return true }
            return thread.references.contains { linkedIDs.contains($0.meetingID) }
        }
        let time = trackedTime(terms: terms, activity: input.activity,
                               windowStart: windowStart, now: now, calendar: calendar)
        let meetingRefs: [ProjectProfile.MeetingRef] = linkedMeetings.map {
            ProjectProfile.MeetingRef(id: $0.id, title: $0.displayTitle, startedAt: $0.startedAt)
        }
        return ProjectProfile(
            id: PeopleDirectory.normalized(project.name),
            name: project.name,
            status: project.status,
            lastActiveDay: project.lastActiveDay,
            pinned: project.pinned,
            meetings: meetingRefs,
            openActions: ActionAttentionOrder.sorted(actions, now: now, calendar: calendar),
            days: time.days,
            windows: time.windows,
            people: people(in: linkedIDs, from: input.people))
    }

    private static func linkedMeetings(terms: Set<String>, meetings: [Meeting],
                                       summaries: [UUID: String]) -> [Meeting] {
        let linked: [Meeting] = meetings.filter { (meeting: Meeting) -> Bool in
            let summary: String = summaries[meeting.id].map { String($0.prefix(maximumSummaryCharacters)) } ?? ""
            let text: String = meeting.displayTitle + "\n" + (meeting.calendarTitle ?? "") + "\n" + summary
            return matches(terms, in: text)
        }
        return linked.sorted { $0.startedAt > $1.startedAt }
    }

    private static func trackedTime(
        terms: Set<String>, activity: [ActivityBlock], windowStart: Date, now: Date, calendar: Calendar
    ) -> (days: [ProjectProfile.DayTime], windows: [ProjectProfile.WindowTime]) {
        var perDay: [String: TimeInterval] = [:]
        var perWindow: [String: ProjectProfile.WindowTime] = [:]
        for block in activity where block.end > windowStart && block.start < now {
            guard matches(terms, in: block.title) else { continue }
            let start: Date = max(block.start, windowStart)
            let end: Date = min(block.end, now)
            guard end > start else { continue }
            let seconds: TimeInterval = end.timeIntervalSince(start)
            perDay[dayKey(start, calendar: calendar), default: 0] += seconds
            let title: String = TimelineWorkSession.strippingBrowserChrome(block.title)
            let key: String = block.app + "|" + title
            let previous: TimeInterval = perWindow[key]?.seconds ?? 0
            perWindow[key] = ProjectProfile.WindowTime(app: block.app, title: title, seconds: previous + seconds)
        }
        let days: [ProjectProfile.DayTime] = perDay
            .map { ProjectProfile.DayTime(dayKey: $0.key, seconds: $0.value) }
            .sorted { $0.dayKey > $1.dayKey }
        let windows: [ProjectProfile.WindowTime] = perWindow.values.sorted {
            $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds
        }
        return (days, Array(windows.prefix(maximumWindows)))
    }

    private static func people(in linkedIDs: Set<UUID>, from people: [PersonProfile]) -> [String] {
        let related: [PersonProfile] = people.filter { !$0.meetingIDs.isDisjoint(with: linkedIDs) }
        let ranked: [PersonProfile] = related.sorted { (lhs: PersonProfile, rhs: PersonProfile) -> Bool in
            lhs.meetingIDs.intersection(linkedIDs).count > rhs.meetingIDs.intersection(linkedIDs).count
        }
        return Array(ranked.prefix(8)).map(\.name)
    }

    /// Words of a project name that can identify it: at least three
    /// characters and not a generic work word.
    static func significantTerms(_ name: String) -> Set<String> {
        let words = PeopleDirectory.normalized(name).split(separator: " ").map(String.init)
        let significant = words.filter { $0.count >= 3 && !genericWords.contains($0) }
        return Set(significant.isEmpty ? words.filter { $0.count >= 2 } : significant)
    }

    /// Every significant term must appear as a whole word.
    static func matches(_ terms: Set<String>, in text: String) -> Bool {
        guard !terms.isEmpty else { return false }
        let words = Set(PeopleDirectory.normalized(text).split(separator: " ").map(String.init))
        return terms.isSubset(of: words)
    }

    private static let genericWords: Set<String> = [
        "the", "and", "for", "with", "project", "work", "team", "new", "update", "updates",
        "review", "plan", "planning", "launch", "release", "meeting", "sync", "weekly",
        "migration", "improvements", "support", "feature", "features", "app",
    ]

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
