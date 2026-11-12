import Foundation

/// The Projects list as it is drawn: tracked projects by last activity, then
/// suggestions with where each came from, with every row's wording made.
struct ProjectsListContent: Equatable, Sendable {
    /// How recently anything named a project: its newest meeting, overnight
    /// review note, or day with window time.
    enum Activity: Equatable, Sendable {
        case nothingLinked
        case today
        case yesterday
        /// Within the last `quietAfterDays` days.
        case recent(Date)
        case quiet(since: Date)

        var isQuiet: Bool {
            if case .quiet = self { return true }
            return false
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        /// The project's id, which is also the list's selection.
        let id: String
        let name: String
        /// "Active today", "Quiet since Oct 22", "In 4 meetings"…
        let detail: String
        let isSuggestion: Bool
        /// Drawn a little fainter: nothing has named the project for weeks.
        let isQuiet: Bool
        /// The user's own open actions on the project.
        let openActions: Int
    }

    /// A project nothing has named for this many days reads "Quiet since…".
    /// The same two weeks after which the page stops treating other people's
    /// open work as recent.
    static let quietAfterDays = ProjectLinks.recentOthersActionDays

    var tracked: [Row] = []
    var suggested: [Row] = []

    /// Every row's project id, in the order shown.
    var projectIDs: [String] { (tracked + suggested).map(\.id) }
    var isEmpty: Bool { tracked.isEmpty && suggested.isEmpty }

    /// - Parameter query: matches a project's name or any of its other names.
    static func build(
        projects: [ProjectProfile],
        query: String = "",
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        localize: (String) -> String = { $0 }
    ) -> ProjectsListContent {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? projects : projects.filter { project in
            ([project.name] + project.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        // Most recently active first; a project nothing names yet goes last.
        let tracked = matching.filter(\.isTracked).sorted { left, right in
            let leftDate = left.lastActive ?? .distantPast, rightDate = right.lastActive ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        // Suggestions keep the order they are offered in: names from
        // meetings by how many meetings, then the overnight review's.
        let suggested = matching.filter { !$0.isTracked }
        return ProjectsListContent(
            tracked: tracked.map { project in
                let activity = activity(lastActive: project.lastActive, now: now, calendar: calendar)
                return Row(id: project.id, name: project.name,
                           detail: ProjectsWording.activityLine(
                               activity, now: now, calendar: calendar, locale: locale, localize: localize),
                           isSuggestion: false, isQuiet: activity.isQuiet, openActions: project.myActions.count)
            },
            suggested: suggested.map { project in
                Row(id: project.id, name: project.name,
                    detail: ProjectsWording.suggestionSource(project, localize: localize),
                    isSuggestion: true, isQuiet: false, openActions: 0)
            })
    }

    static func activity(lastActive: Date?, now: Date = Date(), calendar: Calendar = .current) -> Activity {
        guard let lastActive else { return .nothingLinked }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: lastActive), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case ..<quietAfterDays: return .recent(lastActive)
        default: return .quiet(since: lastActive)
        }
    }

    /// What opens once a suggestion leaves the list: the suggestion after
    /// it, else the first one left. Nil when it was the last suggestion, and
    /// then the page opens the first tracked project.
    func selection(afterRemoving id: String) -> String? {
        guard let index = suggested.firstIndex(where: { $0.id == id }) else { return suggested.first?.id }
        let rest = suggested[(index + 1)...] + suggested[..<index]
        return rest.first?.id
    }
}

/// Which tracked project a suggestion probably belongs to. Deterministic:
/// it compares the meetings that name each.
enum ProjectSuggestionHome {
    struct Match: Equatable, Sendable {
        let trackedID: UUID
        let name: String
        /// How many of the suggestion's meetings the project already has.
        let sharedMeetings: Int
    }

    /// How many of the suggestion's meetings the project already has, when
    /// that is at least half of them; nil otherwise, and for a suggestion no
    /// meeting names.
    static func sharedMeetings(suggestion: Set<UUID>, project: Set<UUID>) -> Int? {
        guard !suggestion.isEmpty else { return nil }
        let shared = suggestion.intersection(project).count
        return shared > 0 && shared * 2 >= suggestion.count ? shared : nil
    }

    /// The tracked project that already has at least half of the
    /// suggestion's meetings; the one sharing the most when several do, and
    /// the first in the list on a tie.
    static func match(for suggestion: ProjectProfile, among projects: [ProjectProfile]) -> Match? {
        guard !suggestion.isTracked else { return nil }
        let meetings = suggestion.meetingIDs
        var best: Match?
        for project in projects {
            guard let trackedID = project.trackedID,
                  let shared = sharedMeetings(suggestion: meetings, project: project.meetingIDs),
                  shared > (best?.sharedMeetings ?? 0) else { continue }
            best = Match(trackedID: trackedID, name: project.name, sharedMeetings: shared)
        }
        return best
    }
}

/// The side column's time: the last seven days, one bar each.
enum ProjectTimePresentation {
    struct Day: Identifiable, Equatable, Sendable {
        var id: String { dayKey }
        let dayKey: String
        let date: Date
        /// Zero for a day with no window time that names the project.
        let seconds: TimeInterval
        let isToday: Bool
    }

    /// Windows listed before "N more windows".
    static let visibleWindows = 3
    /// Time under a minute is not shown, as on Timeline.
    static let minimumSeconds: TimeInterval = 60

    /// The days `ProjectLinks` measures (`ProjectLinks.reviewDays`), oldest
    /// first and ending today, with zero for a day it reports no time on.
    static func days(_ days: [ProjectProfile.DayTime], now: Date = Date(),
                     calendar: Calendar = .current) -> [Day] {
        let seconds = Dictionary(days.map { ($0.dayKey, $0.seconds) }, uniquingKeysWith: +)
        let today = calendar.startOfDay(for: now)
        return (0..<ProjectLinks.reviewDays).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = ProjectLinks.dayKey(date, calendar: calendar)
            return Day(dayKey: key, date: date, seconds: seconds[key] ?? 0, isToday: offset == 0)
        }
    }

    /// How tall a day's bar is, from 0 to 1 of the tallest day.
    static func fraction(_ day: Day, in days: [Day]) -> Double {
        let top = days.map(\.seconds).max() ?? 0
        return top > 0 ? day.seconds / top : 0
    }

    /// The windows behind "N more windows" and their time together. The
    /// project counts every window; it lists only the longest.
    static func rest(of project: ProjectProfile) -> (count: Int, seconds: TimeInterval)? {
        let shown = project.windows.prefix(visibleWindows)
        let count = max(project.windowCount, project.windows.count) - shown.count
        let seconds = project.trackedSeconds - shown.reduce(0) { $0 + $1.seconds }
        return count > 0 && seconds >= minimumSeconds ? (count, seconds) : nil
    }
}

/// What a project's page lists and how much of it before "Show more".
enum ProjectPagePresentation {
    /// Other people's actions shown before "Show N more".
    static let visibleOthersActions = 3
    /// Meetings shown before "Show all N".
    static let visibleMeetings = 4

    /// Nothing names the project yet: no meeting, action, decision,
    /// overnight review note, person, or window time.
    static func isEmpty(_ project: ProjectProfile) -> Bool {
        project.meetings.isEmpty && project.myActions.isEmpty && project.othersActions.isEmpty
            && project.olderOthersActions.isEmpty && project.decisions.isEmpty && project.reviewNotes.isEmpty
            && project.people.isEmpty && project.trackedSeconds < ProjectTimePresentation.minimumSeconds
    }

    /// Other people's open work in one list: what was mentioned recently or
    /// is due ahead first, then the older work.
    static func othersActions(_ project: ProjectProfile) -> [ActionThread] {
        project.othersActions + project.olderOthersActions
    }
}

/// A link from a point of "Where it stands" to the meeting it cites.
enum ProjectNoteLink {
    static let scheme = "lokalbot-project-note"

    static func url(meetingID: UUID) -> URL? {
        URL(string: scheme + "://meeting/" + meetingID.uuidString)
    }

    static func meetingID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == "meeting" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// Wording on the Projects list and a project's page that is put together
/// from counts, dates and names. `localize` looks a catalog key up in the
/// interface language.
enum ProjectsWording {
    /// "Active today", "Active yesterday", "Last active Fri, Nov 6",
    /// "Quiet since Oct 22", or that nothing is linked yet.
    static func activityLine(
        _ activity: ProjectsListContent.Activity, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        switch activity {
        case .nothingLinked:
            return localize("Nothing linked yet")
        case .today:
            return localize("Active today")
        case .yesterday:
            return localize("Active yesterday")
        case .recent(let date):
            return String(format: localize("Last active %@"),
                          ActionListWording.day(date, now: now, calendar: calendar, locale: locale, localize: localize))
        case .quiet(let date):
            return String(format: localize("Quiet since %@"),
                          PeopleWording.shortDate(date, now: now, calendar: calendar, locale: locale))
        }
    }

    /// Where a suggestion came from: "In 4 meetings" for a name that recurs
    /// across meetings, "From overnight review" for work the review named.
    static func suggestionSource(_ project: ProjectProfile, localize: (String) -> String = { $0 }) -> String {
        if project.kind == .suggestedReview { return localize("From overnight review") }
        let count = project.meetings.count
        return String(format: localize(count == 1 ? "In %lld meeting" : "In %lld meetings"), count)
    }

    /// Beside the project's name in the toolbar: its last activity, "Tracked
    /// since Nov 1" while nothing names it, or "Suggested".
    static func subtitle(
        for project: ProjectProfile, trackedSince: Date?, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        // Its own key: beside one project the word is singular, and the
        // list's "Suggested" heading is not in every language.
        guard project.isTracked else { return localize("Suggested (one project)") }
        let activity = ProjectsListContent.activity(lastActive: project.lastActive, now: now, calendar: calendar)
        if activity == .nothingLinked, let trackedSince {
            return String(format: localize("Tracked since %@"),
                          PeopleWording.shortDate(trackedSince, now: now, calendar: calendar, locale: locale))
        }
        return activityLine(activity, now: now, calendar: calendar, locale: locale, localize: localize)
    }

    /// "2 open actions for you", read out for the number on a row.
    static func openActions(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "%lld open action for you" : "%lld open actions for you"), count)
    }

    /// "Show 2 hidden suggestions".
    static func showHidden(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "Show %lld hidden suggestion" : "Show %lld hidden suggestions"), count)
    }

    /// "40h 10m", "35m"; under a minute still reads as one.
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let minutes = max(1, Int(seconds / 60))
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow).locale(locale))
    }

    /// "3 more windows".
    static func moreWindows(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "%lld more window" : "%lld more windows"), count)
    }

    /// "Wed, Nov 4: 8h 20m", read out for a day's bar; a day without time
    /// says so with a zero.
    static func dayTime(_ day: ProjectTimePresentation.Day, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        let time = day.seconds >= ProjectTimePresentation.minimumSeconds
            ? duration(day.seconds, locale: locale)
            : Duration.zero.formatted(.units(allowed: [.minutes], width: .narrow).locale(locale))
        return ActionListWording.weekdayDate(day.date, calendar: calendar, locale: locale) + ": " + time
    }

    /// The one-letter weekday under a day's bar.
    static func weekdayLetter(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.narrow))
    }

    /// When "Where it stands" was written, by which model, and where it
    /// ran: "Written today, 9:12 AM, by Qwen3.5 4B on this Mac", or with the
    /// server's host for a model that ran elsewhere.
    static func provenance(
        _ summary: ProjectStatusSummary, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let isToday = calendar.isDate(summary.generatedAt, inSameDayAs: now)
        let when = isToday
            ? summary.generatedAt.formatted(style.hour().minute())
            : PeopleWording.shortDate(summary.generatedAt, now: now, calendar: calendar, locale: locale)
        if summary.location == ProjectStatusSummary.localLocation {
            return String(format: localize(isToday ? "Written today, %1$@, by %2$@ on this Mac"
                                                   : "Written %1$@ by %2$@ on this Mac"),
                          when, summary.engineName)
        }
        return String(format: localize(isToday ? "Written today, %1$@, by %2$@ on %3$@"
                                               : "Written %1$@ by %2$@ on %3$@"),
                      when, summary.engineName, summary.location)
    }

    /// "Writing where it stands from 4 meetings…", naming what the model is
    /// given.
    static func writing(meetings: Int, hasReviewNotes: Bool, localize: (String) -> String = { $0 }) -> String {
        if meetings == 0 { return localize("Writing where it stands from the overnight review…") }
        let key: String
        switch (meetings == 1, hasReviewNotes) {
        case (true, false): key = "Writing where it stands from %lld meeting…"
        case (false, false): key = "Writing where it stands from %lld meetings…"
        case (true, true): key = "Writing where it stands from %lld meeting and the overnight review…"
        case (false, true): key = "Writing where it stands from %lld meetings and the overnight review…"
        }
        return String(format: localize(key), meetings)
    }

    /// The heading of a suggestion's decision: "Redis came up in 4 meetings
    /// since Oct 29", or that the overnight review found the work.
    static func suggestionTitle(
        for project: ProjectProfile, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        if project.kind == .suggestedReview {
            return String(format: localize("The overnight review found work on %@"), project.name)
        }
        guard let first = project.meetings.map(\.startedAt).min() else { return project.name }
        let count = project.meetings.count
        return String(
            format: localize(count == 1 ? "%1$@ came up in %2$lld meeting since %3$@"
                                        : "%1$@ came up in %2$lld meetings since %3$@"),
            project.name, count, PeopleWording.shortDate(first, now: now, calendar: calendar, locale: locale))
    }

    /// Why the first answer is the one offered: the tracked project that
    /// already has most of the suggestion's meetings, or that none covers it.
    static func suggestionReason(home: ProjectSuggestionHome.Match?,
                                 localize: (String) -> String = { $0 }) -> String {
        guard let home else { return localize("No tracked project covers it.") }
        let key = home.sharedMeetings == 1
            ? "%1$lld of its meetings is already linked to %2$@, so it may be part of that project rather than a project of its own."
            : "%1$lld of its meetings are already linked to %2$@, so it may be part of that project rather than a project of its own."
        return String(format: localize(key), home.sharedMeetings, home.name)
    }

    /// "Overnight review · Nov 9" under the review's own words.
    static func reviewCitation(
        dayKey: String, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        guard let date = AskDayScope.date(for: dayKey, calendar: calendar) else { return localize("Overnight review") }
        return localize("Overnight review") + " · "
            + PeopleWording.shortDate(date, now: now, calendar: calendar, locale: locale)
    }

    /// The names a project is matched by, for "Time in windows whose titles
    /// name Atlas, Larkspur".
    static func timeSource(for project: ProjectProfile, localize: (String) -> String = { $0 }) -> String {
        String(format: localize("Time in windows whose titles name %@"),
               ([project.name] + project.otherNames).joined(separator: ", "))
    }
}
