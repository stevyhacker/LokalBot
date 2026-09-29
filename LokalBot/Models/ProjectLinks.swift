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
        let meetings = input.meetings.filter { $0.mergedIntoMeetingID == nil }
        let threads = ActionThreadClusterer.cluster(
            input.projections.filter { !$0.isArchived }.flatMap(\.actionReferences))
            .filter { $0.status != .done }
        let windowStart = calendar.date(byAdding: .day, value: -(reviewDays - 1),
                                        to: calendar.startOfDay(for: now)) ?? now

        return input.memory.activeProjects.map { project in
            let terms = significantTerms(project.name)
            let linkedMeetings = meetings.filter { meeting in
                let summary = input.summaries[meeting.id].map { String($0.prefix(maximumSummaryCharacters)) } ?? ""
                return matches(terms, in: [meeting.displayTitle, meeting.calendarTitle ?? "", summary]
                    .joined(separator: "\n"))
            }
            .sorted { $0.startedAt > $1.startedAt }
            let linkedIDs = Set(linkedMeetings.map(\.id))
            let actions = threads.filter { thread in
                matches(terms, in: thread.text)
                    || thread.references.contains { linkedIDs.contains($0.meetingID) }
            }

            var perDay: [String: TimeInterval] = [:]
            var perWindow: [String: (app: String, title: String, seconds: TimeInterval)] = [:]
            for block in input.activity where block.end > windowStart && block.start < now {
                guard matches(terms, in: block.title) else { continue }
                let start = max(block.start, windowStart)
                let end = min(block.end, now)
                guard end > start else { continue }
                let seconds = end.timeIntervalSince(start)
                perDay[dayKey(start, calendar: calendar), default: 0] += seconds
                let title = TimelineWorkSession.strippingBrowserChrome(block.title)
                let key = block.app + "|" + title
                perWindow[key] = (block.app, title, (perWindow[key]?.seconds ?? 0) + seconds)
            }

            let people = input.people
                .filter { !$0.meetingIDs.isDisjoint(with: linkedIDs) }
                .sorted { $0.meetingIDs.intersection(linkedIDs).count > $1.meetingIDs.intersection(linkedIDs).count }
                .map(\.name)

            return ProjectProfile(
                id: PeopleDirectory.normalized(project.name),
                name: project.name,
                status: project.status,
                lastActiveDay: project.lastActiveDay,
                pinned: project.pinned,
                meetings: linkedMeetings.map { .init(id: $0.id, title: $0.displayTitle, startedAt: $0.startedAt) },
                openActions: ActionAttentionOrder.sorted(actions, now: now, calendar: calendar),
                days: perDay.map { ProjectProfile.DayTime(dayKey: $0.key, seconds: $0.value) }.sorted { $0.dayKey > $1.dayKey },
                windows: perWindow.values
                    .map { ProjectProfile.WindowTime(app: $0.app, title: $0.title, seconds: $0.seconds) }
                    .sorted { $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds }
                    .prefix(maximumWindows).map { $0 },
                people: Array(people.prefix(8)))
        }
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
