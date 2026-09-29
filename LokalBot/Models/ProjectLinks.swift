import Foundation

/// A project joined to the evidence behind it: meetings, open action threads,
/// decisions, people, and tracked window time. Projects come from the
/// overnight review's memory or, when that names none, from topics that recur
/// across meetings. Matching is deterministic word matching; no model decides
/// what belongs to a project.
struct ProjectProfile: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case overnightReview
        case recurringTopic
    }

    struct MeetingRef: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
        /// The summary line that names the project, when there is one.
        var mention: String?
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
    let source: Source
    /// The overnight review's one-line status, or a factual line for topics.
    let status: String
    let lastActiveDay: String
    let pinned: Bool
    var meetings: [MeetingRef]
    var openActions: [ActionThread]
    var decisions: [PersonProfile.DecisionRef]
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
    static let maximumDecisions = 8
    static let maximumSummaryCharacters = 4_000
    static let maximumMentionCharacters = 180

    struct Input: Sendable {
        var memory: DreamMemory?
        var meetings: [Meeting]
        var summaries: [UUID: String] = [:]
        var projections: [MeetingOutcomeProjection] = []
        var activity: [ActivityBlock] = []
        var people: [PersonProfile] = []
        /// Words never offered as topics (people, the user, apps in use).
        var excludedTopicWords: Set<String> = []
    }

    private struct Context {
        let input: Input
        let meetings: [Meeting]
        let threads: [ActionThread]
        let windowStart: Date
        let now: Date
        let calendar: Calendar
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
        let context = Context(input: input, meetings: meetings, threads: threads,
                              windowStart: windowStart, now: now, calendar: calendar)

        let reviewProjects: [DreamMemory.Project] = input.memory?.activeProjects ?? []
        let reviewed: [ProjectProfile] = reviewProjects.map { (project: DreamMemory.Project) -> ProjectProfile in
            reviewProfile(for: project, context: context)
        }
        let reviewedTerms: [Set<String>] = reviewed.map { significantTerms($0.name) }
        let topics: [ProjectTopicDetector.Topic] = ProjectTopicDetector.topics(
            meetings: meetings, summaries: input.summaries, projections: input.projections,
            excludedWords: input.excludedTopicWords)
        let detected: [ProjectProfile] = topics
            .filter { (topic: ProjectTopicDetector.Topic) -> Bool in
                let key: String = PeopleDirectory.normalized(topic.name)
                return !reviewedTerms.contains { $0.contains(key) }
            }
            .map { (topic: ProjectTopicDetector.Topic) -> ProjectProfile in
                topicProfile(for: topic, context: context)
            }
        return reviewed + detected
    }

    // MARK: - Profiles

    private static func reviewProfile(for project: DreamMemory.Project, context: Context) -> ProjectProfile {
        let terms: Set<String> = significantTerms(project.name)
        let linked: [Meeting] = linkedMeetings(terms: terms, meetings: context.meetings,
                                               summaries: context.input.summaries)
        let linkedIDs: Set<UUID> = Set(linked.map(\.id))
        let actions: [ActionThread] = context.threads.filter { (thread: ActionThread) -> Bool in
            if matches(terms, in: thread.text) { return true }
            return thread.references.contains { linkedIDs.contains($0.meetingID) }
        }
        return profile(
            id: "review:" + PeopleDirectory.normalized(project.name), name: project.name,
            source: .overnightReview, status: project.status, lastActiveDay: project.lastActiveDay,
            pinned: project.pinned, terms: terms, linked: linked, actions: actions, context: context)
    }

    private static func topicProfile(for topic: ProjectTopicDetector.Topic, context: Context) -> ProjectProfile {
        let terms: Set<String> = [PeopleDirectory.normalized(topic.name)]
        let linked: [Meeting] = context.meetings
            .filter { topic.meetingIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        let actions: [ActionThread] = context.threads.filter { matches(terms, in: $0.text) }
        let count: Int = topic.meetingIDs.count
        let last: String = topic.lastMentioned.formatted(date: .abbreviated, time: .omitted)
        return profile(
            id: "topic:" + PeopleDirectory.normalized(topic.name), name: topic.name,
            source: .recurringTopic,
            status: "Mentioned in \(count) meetings, most recently \(last).",
            lastActiveDay: dayKey(topic.lastMentioned, calendar: context.calendar),
            pinned: false, terms: terms, linked: linked, actions: actions, context: context)
    }

    private static func profile(
        id: String, name: String, source: ProjectProfile.Source, status: String,
        lastActiveDay: String, pinned: Bool, terms: Set<String>, linked: [Meeting],
        actions: [ActionThread], context: Context
    ) -> ProjectProfile {
        let linkedIDs: Set<UUID> = Set(linked.map(\.id))
        let time = trackedTime(terms: terms, activity: context.input.activity,
                               windowStart: context.windowStart, now: context.now,
                               calendar: context.calendar)
        let meetingRefs: [ProjectProfile.MeetingRef] = linked.map { (meeting: Meeting) -> ProjectProfile.MeetingRef in
            ProjectProfile.MeetingRef(
                id: meeting.id, title: meeting.displayTitle, startedAt: meeting.startedAt,
                mention: context.input.summaries[meeting.id].flatMap { mention(of: terms, in: $0) })
        }
        return ProjectProfile(
            id: id, name: name, source: source, status: status, lastActiveDay: lastActiveDay,
            pinned: pinned, meetings: meetingRefs,
            openActions: ActionAttentionOrder.sorted(actions, now: context.now, calendar: context.calendar),
            decisions: decisions(terms: terms, linkedIDs: linkedIDs, projections: context.input.projections),
            days: time.days, windows: time.windows,
            people: people(in: linkedIDs, from: context.input.people))
    }

    // MARK: - Evidence

    private static func linkedMeetings(terms: Set<String>, meetings: [Meeting],
                                       summaries: [UUID: String]) -> [Meeting] {
        let linked: [Meeting] = meetings.filter { (meeting: Meeting) -> Bool in
            let summary: String = summaries[meeting.id].map { String($0.prefix(maximumSummaryCharacters)) } ?? ""
            let text: String = meeting.displayTitle + "\n" + (meeting.calendarTitle ?? "") + "\n" + summary
            return matches(terms, in: text)
        }
        return linked.sorted { $0.startedAt > $1.startedAt }
    }

    /// Decisions from the project's meetings that name it.
    private static func decisions(terms: Set<String>, linkedIDs: Set<UUID>,
                                  projections: [MeetingOutcomeProjection]) -> [PersonProfile.DecisionRef] {
        var result: [PersonProfile.DecisionRef] = []
        for projection in projections where linkedIDs.contains(projection.meeting.id) && !projection.isArchived {
            for decision in projection.outcomes.decisionRecords where matches(terms, in: decision.text) {
                result.append(PersonProfile.DecisionRef(
                    id: projection.meeting.id.uuidString + ":" + decision.id, text: decision.text,
                    meetingID: projection.meeting.id, meetingTitle: projection.meeting.displayTitle,
                    meetingDate: projection.meeting.startedAt))
            }
        }
        let sorted: [PersonProfile.DecisionRef] = result.sorted { $0.meetingDate > $1.meetingDate }
        return Array(sorted.prefix(maximumDecisions))
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

    /// The first summary line naming every term, without markdown markers.
    static func mention(of terms: Set<String>, in summary: String) -> String? {
        for rawLine in summary.components(separatedBy: "\n") {
            let line: String = rawLine
                .replacingOccurrences(of: #"^\s*(#+|[-*•]|\d+\.)\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard line.count >= 12, !rawLine.hasPrefix("# "), matches(terms, in: line) else { continue }
            return line.count > maximumMentionCharacters
                ? String(line.prefix(maximumMentionCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
                : line
        }
        return nil
    }

    // MARK: - Matching

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
