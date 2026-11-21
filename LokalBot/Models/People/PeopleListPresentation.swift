import Foundation

struct PeopleListContent: Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case comingUp, recent, earlier

        var title: String {
            switch self {
            case .comingUp: "Coming up"
            case .recent: "Last 2 weeks"
            case .earlier: "Earlier"
            }
        }
    }

    enum Badge: Equatable, Sendable {
        case youOwe(Int)
        case owesYou(Int)

        init?(youOwe: Int, owesYou: Int) {
            if youOwe > 0 {
                self = .youOwe(youOwe)
            } else if owesYou > 0 {
                self = .owesYou(owesYou)
            } else {
                return nil
            }
        }

        var needsAttention: Bool {
            if case .youOwe = self { return true }
            return false
        }

        func text(localize: (String) -> String = { $0 }) -> String {
            switch self {
            case .youOwe(let count): String(format: localize("You owe %lld"), count)
            case .owesYou(let count): String(format: localize("Owes you %lld"), count)
            }
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let detail: String
        let when: String
        let badge: Badge?
    }

    struct Section: Identifiable, Equatable, Sendable {
        let group: Group
        let rows: [Row]
        var id: String { group.rawValue }
    }

    static let recentDays = 14

    var sections: [Section] = []

    var personIDs: [String] { sections.flatMap { $0.rows.map(\.id) } }
    var isEmpty: Bool { sections.isEmpty }

    static func build(
        people: [PersonProfile],
        upcoming: [String: PersonUpcomingMeeting] = [:],
        query: String = "",
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        localize: (String) -> String = { $0 }
    ) -> PeopleListContent {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? people : people.filter { person in
            ([person.name] + person.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let recentStart = calendar.date(byAdding: .day, value: -recentDays, to: calendar.startOfDay(for: now))
            ?? .distantPast

        var grouped: [Group: [PersonProfile]] = [:]
        for person in matching {
            let group: Group
            if upcoming[person.id] != nil {
                group = .comingUp
            } else if let last = person.lastMetAt, last >= recentStart {
                group = .recent
            } else {
                group = .earlier
            }
            grouped[group, default: []].append(person)
        }

        func byRecency(_ left: PersonProfile, _ right: PersonProfile) -> Bool {
            let leftDate = left.lastMetAt ?? .distantPast, rightDate = right.lastMetAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        let comingUp = (grouped[.comingUp] ?? []).sorted { left, right in
            let leftStart = upcoming[left.id]?.start ?? .distantFuture
            let rightStart = upcoming[right.id]?.start ?? .distantFuture
            return leftStart == rightStart ? byRecency(left, right) : leftStart < rightStart
        }
        let ordered: [(Group, [PersonProfile])] = [
            (.comingUp, comingUp),
            (.recent, (grouped[.recent] ?? []).sorted(by: byRecency)),
            (.earlier, (grouped[.earlier] ?? []).sorted(by: byRecency)),
        ]
        let sections = ordered.filter { !$0.1.isEmpty }.map { group, members in
            Section(group: group, rows: members.map { person in
                row(person, next: group == .comingUp ? upcoming[person.id] : nil,
                    now: now, calendar: calendar, locale: locale, localize: localize)
            })
        }
        return PeopleListContent(sections: sections)
    }

    private static func row(
        _ person: PersonProfile, next: PersonUpcomingMeeting?, now: Date, calendar: Calendar,
        locale: Locale, localize: (String) -> String
    ) -> Row {
        let detail: String
        let when: String
        if let next {
            detail = next.title
            when = PeopleWording.upcomingTime(next, now: now, calendar: calendar, locale: locale, localize: localize)
        } else {
            detail = person.occasions.first?.title ?? localize("Named in actions")
            when = person.lastMetAt.map {
                ActionListWording.day($0, now: now, calendar: calendar, locale: locale, localize: localize)
            } ?? ""
        }
        return Row(id: person.id, name: person.name, detail: detail, when: when,
                   badge: Badge(youOwe: person.myActions.count, owesYou: person.theirActions.count))
    }
}

enum PeopleWording {
    static let visibleDecisions = 3
    static let visibleSeries = 8
    static let visibleInvitees = 3

    static func subtitle(
        for person: PersonProfile, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        let occasions = person.occasions
        guard let first = occasions.last?.startedAt else { return localize("Named in actions") }
        let day = shortDate(first, now: now, calendar: calendar, locale: locale)
        if occasions.count == 1 { return String(format: localize("Met once, %@"), day) }
        return String(format: localize("%lld meetings since %@"), occasions.count, day)
    }

    static func upcomingTime(
        _ meeting: PersonUpcomingMeeting, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        let style = style(calendar: calendar, locale: locale)
        if calendar.isDate(meeting.start, inSameDayAs: now) {
            return meeting.start.formatted(style.hour().minute())
        }
        return meeting.start.formatted(style.weekday(.abbreviated).hour().minute())
    }

    static func nextMeetingLine(
        _ meeting: PersonUpcomingMeeting, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        let lead: String
        if meeting.isInProgress(at: now) {
            lead = localize("In progress")
        } else {
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: meeting.start)).day ?? 0
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            lead = String(format: localize("Next meeting %@"),
                          formatter.localizedString(from: DateComponents(day: max(0, days))))
        }
        let style = style(calendar: calendar, locale: locale)
        let day = meeting.start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        let time: String
        if meeting.end > meeting.start, calendar.isDate(meeting.start, inSameDayAs: meeting.end) {
            time = (meeting.start..<meeting.end).formatted(
                Date.IntervalFormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone))
        } else {
            time = meeting.start.formatted(style.hour().minute())
        }
        return lead + " · " + day + ", " + time
    }

    static func invited(_ others: [String], localize: (String) -> String = { $0 }) -> String {
        guard !others.isEmpty else { return localize("Just the two of you") }
        var names = others.prefix(visibleInvitees).joined(separator: ", ")
        if others.count > visibleInvitees { names += " +\(others.count - visibleInvitees)" }
        return String(format: localize("Also invited: %@"), names)
    }

    static func meetingLink(
        title: String, date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        title + " · " + shortDate(date, now: now, calendar: calendar, locale: locale)
    }

    static func seriesDetail(
        _ series: PersonProfile.Series, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> String {
        let day = shortDate(series.latest.startedAt, now: now, calendar: calendar, locale: locale)
        let count = series.occasions.count
        guard count > 1 else { return day }
        return String(format: localize("%lld meetings"), count) + " · " + day
    }

    static func restoreHidden(_ count: Int, localize: (String) -> String = { $0 }) -> String {
        String(format: localize(count == 1 ? "Restore %lld hidden entry" : "Restore %lld hidden entries"), count)
    }

    static func shortDate(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let monthDay = style(calendar: calendar, locale: locale).month(.abbreviated).day()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? monthDay : monthDay.year())
    }

    static func formattingLocale(_ locale: Locale, reader: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: locale)
        components.hourCycle = reader.hourCycle
        return Locale(components: components)
    }

    static func hiddenCount(total: Int, visible: Int) -> Int { max(0, total - max(0, visible)) }

    private static func style(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}

enum PersonPreparation {
    static func launchContext(for person: PersonProfile) -> AgentLaunchContext {
        AgentLaunchContext(
            title: "Prepare for \(person.name)",
            prompt: prompt(for: person),
            meetingID: person.meetings.first?.id,
            actionID: nil)
    }

    static func prompt(for person: PersonProfile) -> String {
        var lines = ["Help me prepare for my next conversation with \(person.name)."]
        if let notes = person.recentNotes {
            let day = notes.meetingDate.formatted(date: .abbreviated, time: .omitted)
            lines.append("From my notes of \(notes.meetingTitle) on \(day):")
            for point in notes.points {
                let speaker = point.speaker.map { "\($0): " } ?? ""
                lines.append("- " + speaker + point.text)
            }
        }
        if !person.projects.isEmpty {
            lines.append("Projects that come up with them: " + person.projects.map(\.name).joined(separator: ", "))
        }
        if !person.myActions.isEmpty {
            lines.append("What I owe them:")
            lines += person.myActions.prefix(8).map { "- \($0.text)" + ($0.due.map { " (due \($0))" } ?? "") }
        }
        if !person.theirActions.isEmpty {
            lines.append("What they owe me:")
            lines += person.theirActions.prefix(8).map { "- \($0.text)" + ($0.due.map { " (due \($0))" } ?? "") }
        }
        if !person.decisions.isEmpty {
            lines.append("Recent decisions together:")
            lines += person.decisions.prefix(5).map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}
