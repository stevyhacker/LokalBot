import Foundation

struct ProjectsListContent: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case nothingLinked
        case today
        case yesterday
        case recent(Date)
        case quiet(since: Date)

        var isQuiet: Bool {
            if case .quiet = self { return true }
            return false
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let detail: String
        let isSuggestion: Bool
        let isQuiet: Bool
        let openActions: Int
    }

    static let quietAfterDays = ProjectLinks.recentOthersActionDays

    var tracked: [Row] = []
    var suggested: [Row] = []

    var projectIDs: [String] { (tracked + suggested).map(\.id) }
    var isEmpty: Bool { tracked.isEmpty && suggested.isEmpty }

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
        let tracked = matching.filter(\.isTracked).sorted { left, right in
            let leftDate = left.lastActive ?? .distantPast, rightDate = right.lastActive ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
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

    func selection(afterRemoving id: String) -> String? {
        guard let index = suggested.firstIndex(where: { $0.id == id }) else { return suggested.first?.id }
        let rest = suggested[(index + 1)...] + suggested[..<index]
        return rest.first?.id
    }
}

enum ProjectSuggestionHome {
    struct Match: Equatable, Sendable {
        let trackedID: UUID
        let name: String
        let sharedMeetings: Int
    }

    static func sharedMeetings(suggestion: Set<UUID>, project: Set<UUID>) -> Int? {
        guard !suggestion.isEmpty else { return nil }
        let shared = suggestion.intersection(project).count
        return shared > 0 && shared * 2 >= suggestion.count ? shared : nil
    }

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

enum ProjectTimePresentation {
    struct Day: Identifiable, Equatable, Sendable {
        var id: String { dayKey }
        let dayKey: String
        let date: Date
        let seconds: TimeInterval
        let isToday: Bool
    }

    static let visibleWindows = 3
    static let minimumSeconds: TimeInterval = 60

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

    static func fraction(_ day: Day, in days: [Day]) -> Double {
        let top = days.map(\.seconds).max() ?? 0
        return top > 0 ? day.seconds / top : 0
    }

    static func rest(of project: ProjectProfile) -> (count: Int, seconds: TimeInterval)? {
        let shown = project.windows.prefix(visibleWindows)
        let count = max(project.windowCount, project.windows.count) - shown.count
        let seconds = project.trackedSeconds - shown.reduce(0) { $0 + $1.seconds }
        return count > 0 && seconds >= minimumSeconds ? (count, seconds) : nil
    }
}

enum ProjectPagePresentation {
    static let visibleOthersActions = 3
    static let visibleMeetings = 4

    static func isEmpty(_ project: ProjectProfile) -> Bool {
        project.meetings.isEmpty && project.myActions.isEmpty && project.othersActions.isEmpty
            && project.olderOthersActions.isEmpty && project.decisions.isEmpty && project.reviewNotes.isEmpty
            && project.people.isEmpty && project.trackedSeconds < ProjectTimePresentation.minimumSeconds
    }

    static func othersActions(_ project: ProjectProfile) -> [ActionThread] {
        project.othersActions + project.olderOthersActions
    }
}

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

enum ProjectsWording {
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

    static func suggestionSource(_ project: ProjectProfile, localize: (String) -> String = { $0 }) -> String {
        if project.kind == .suggestedReview { return localize("From overnight review") }
        let count = project.meetings.count
        return String(format: localize(count == 1 ? "In %lld meeting" : "In %lld meetings"), count)
    }

    static func subtitle(
        for project: ProjectProfile, trackedSince: Date?, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        guard project.isTracked else { return localize("Suggested (one project)") }
        let activity = ProjectsListContent.activity(lastActive: project.lastActive, now: now, calendar: calendar)
        if activity == .nothingLinked, let trackedSince {
            return String(format: localize("Tracked since %@"),
                          PeopleWording.shortDate(trackedSince, now: now, calendar: calendar, locale: locale))
        }
        return activityLine(activity, now: now, calendar: calendar, locale: locale, localize: localize)
    }

    static func openActions(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "%lld open action for you" : "%lld open actions for you"), count)
    }

    static func showHidden(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "Show %lld hidden suggestion" : "Show %lld hidden suggestions"), count)
    }

    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let minutes = max(1, Int(seconds / 60))
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow).locale(locale))
    }

    static func moreWindows(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "%lld more window" : "%lld more windows"), count)
    }

    static func dayTime(_ day: ProjectTimePresentation.Day, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        let time = day.seconds >= ProjectTimePresentation.minimumSeconds
            ? duration(day.seconds, locale: locale)
            : Duration.zero.formatted(.units(allowed: [.minutes], width: .narrow).locale(locale))
        return ActionListWording.weekdayDate(day.date, calendar: calendar, locale: locale) + ": " + time
    }

    static func weekdayLetter(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.narrow))
    }

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

    static func suggestionReason(home: ProjectSuggestionHome.Match?,
                                 localize: (String) -> String = { $0 }) -> String {
        guard let home else { return localize("No tracked project covers it.") }
        let key = home.sharedMeetings == 1
            ? "%1$lld of its meetings is already linked to %2$@, so it may be part of that project rather than a project of its own."
            : "%1$lld of its meetings are already linked to %2$@, so it may be part of that project rather than a project of its own."
        return String(format: localize(key), home.sharedMeetings, home.name)
    }

    static func reviewCitation(
        dayKey: String, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        guard let date = AskDayScope.date(for: dayKey, calendar: calendar) else { return localize("Overnight review") }
        return localize("Overnight review") + " · "
            + PeopleWording.shortDate(date, now: now, calendar: calendar, locale: locale)
    }

    static func timeSource(for project: ProjectProfile, localize: (String) -> String = { $0 }) -> String {
        String(format: localize("Time in windows whose titles name %@"),
               ([project.name] + project.otherNames).joined(separator: ", "))
    }
}
