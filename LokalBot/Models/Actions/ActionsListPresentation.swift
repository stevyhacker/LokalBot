import Foundation

extension OutcomeStatus {
    /// The catalog key for the status as a state. "Open" on its own is the
    /// verb on buttons, which most languages translate differently.
    var stateKey: String { self == .open ? "Open (status)" : label }
}

/// What the Actions page lists: one status, a search, and the choices of its
/// Filter menu.
struct ActionsListFilter: Equatable, Sendable {
    enum Due: String, CaseIterable, Sendable {
        case any, overdue, dated, undated
    }

    enum Grouping: String, CaseIterable, Sendable {
        case due, meeting, none
    }

    var status: OutcomeStatus = .open
    var query = ""
    var due: Due = .any
    var personID: String?
    var projectID: String?
    /// Every meeting with this title, so a weekly standup is one choice.
    var meetingTitle: String?
    /// Open actions nobody has mentioned for three weeks (`ActionThread.isStale`).
    var staleOnly = false
    var grouping: Grouping = .due

    /// The stale review only exists among open actions.
    var isStaleReview: Bool { status == .open && staleOnly }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Filter menu choices that narrow the list; each shows as a chip.
    var hasMenuFilters: Bool {
        due != .any || personID != nil || projectID != nil || meetingTitle != nil || isStaleReview
    }
    var narrowsList: Bool { hasMenuFilters || !trimmedQuery.isEmpty }

    mutating func clearFilters() {
        query = ""
        due = .any
        personID = nil
        projectID = nil
        meetingTitle = nil
        staleOnly = false
    }

    /// Done actions are outside the People and Projects read models, and the
    /// stale review is about open work, so leaving Open drops what cannot apply.
    mutating func show(_ status: OutcomeStatus) {
        self.status = status
        if status != .open { staleOnly = false }
        if status == .done {
            personID = nil
            projectID = nil
        }
    }

    enum ChipKind: Hashable, Sendable { case due, person, project, meeting, stale }

    struct Chip: Identifiable, Equatable, Sendable {
        let kind: ChipKind
        let label: String
        var id: ChipKind { kind }
    }

    /// The active Filter menu choices, in the order the menu lists them.
    func chips(links: ActionThreadLinks = .init(), localize: (String) -> String = { $0 }) -> [Chip] {
        var chips: [Chip] = []
        switch due {
        case .any: break
        case .overdue: chips.append(Chip(kind: .due, label: localize("Overdue")))
        case .dated: chips.append(Chip(kind: .due, label: localize("Has a date")))
        case .undated: chips.append(Chip(kind: .due, label: localize("No date")))
        }
        if let personID {
            let name = links.personName(personID) ?? localize("Person")
            chips.append(Chip(kind: .person, label: String(format: localize("With %@"), name)))
        }
        if let projectID {
            let name = links.projectName(projectID) ?? localize("Project")
            chips.append(Chip(kind: .project, label: String(format: localize("Project: %@"), name)))
        }
        if let meetingTitle {
            chips.append(Chip(kind: .meeting, label: String(format: localize("From %@"), meetingTitle)))
        }
        if isStaleReview {
            chips.append(Chip(kind: .stale, label: localize("Not mentioned in 3 weeks")))
        }
        return chips
    }

    mutating func remove(_ chip: ChipKind) {
        switch chip {
        case .due: due = .any
        case .person: personID = nil
        case .project: projectID = nil
        case .meeting: meetingTitle = nil
        case .stale: staleOnly = false
        }
    }
}

/// The people and projects an action belongs to, looked up backwards from
/// the People and Projects read models. Those models list the user's open
/// and deferred work per person and per project; nothing new is derived here.
struct ActionThreadLinks: Equatable, Sendable {
    struct Link: Identifiable, Equatable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// People and projects with at least one of the user's actions.
    private(set) var people: [Link] = []
    private(set) var projects: [Link] = []
    /// Action reference id to positions in `people` and `projects`. A thread
    /// is found by its references, so re-threading does not lose the link.
    private var peopleByReference: [String: [Int]] = [:]
    private var projectsByReference: [String: [Int]] = [:]
    /// Ids of people folded into another person.
    private var personAliases: [String: String] = [:]

    init(people: [PersonProfile] = [], projects: [ProjectProfile] = []) {
        for person in people where !person.myActions.isEmpty {
            let index = self.people.count
            self.people.append(Link(id: person.id, name: person.name))
            for member in person.memberIDs where member != person.id { personAliases[member] = person.id }
            for reference in Set(person.myActions.flatMap(\.references).map(\.id)) {
                peopleByReference[reference, default: []].append(index)
            }
        }
        // Projects the user tracks lead; suggested ones follow.
        let ordered = projects.filter(\.isTracked) + projects.filter { !$0.isTracked }
        for project in ordered where !project.myActions.isEmpty {
            let index = self.projects.count
            self.projects.append(Link(id: project.id, name: project.name))
            for reference in Set(project.myActions.flatMap(\.references).map(\.id)) {
                projectsByReference[reference, default: []].append(index)
            }
        }
    }

    func people(for thread: ActionThread) -> [Link] {
        Self.links(for: thread, in: people, by: peopleByReference)
    }

    func projects(for thread: ActionThread) -> [Link] {
        Self.links(for: thread, in: projects, by: projectsByReference)
    }

    func personName(_ id: String) -> String? {
        let id = personAliases[id] ?? id
        return people.first { $0.id == id }?.name
    }

    func projectName(_ id: String) -> String? {
        projects.first { $0.id == id }?.name
    }

    func thread(_ thread: ActionThread, isWith personID: String) -> Bool {
        let id = personAliases[personID] ?? personID
        return people(for: thread).contains { $0.id == id }
    }

    func thread(_ thread: ActionThread, isIn projectID: String) -> Bool {
        projects(for: thread).contains { $0.id == projectID }
    }

    private static func links(for thread: ActionThread, in list: [Link], by reference: [String: [Int]]) -> [Link] {
        var seen = Set<Int>()
        return thread.references.flatMap { reference[$0.id] ?? [] }
            .filter { seen.insert($0).inserted }
            .sorted()
            .map { list[$0] }
    }
}

/// Day and due wording for the Actions page. Catalog keys go through
/// `localize`, so a view passes the interface language and a test reads
/// plain English.
enum ActionListWording {
    /// "Thu, Nov 12".
    static func weekdayDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(style(calendar: calendar, locale: locale).weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
    /// "Oct 27", with the year once it is not this year.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
                    localize: (String) -> String = { $0 }) -> String {
        let daysAgo = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if daysAgo == 0 { return localize("Today") }
        if daysAgo == 1 { return localize("Yesterday") }
        if (2...6).contains(daysAgo) { return weekdayDate(date, calendar: calendar, locale: locale) }
        let monthDay = style(calendar: calendar, locale: locale).month(.abbreviated).day()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? monthDay : monthDay.year())
    }

    /// The due text on a row. Overdue open work reads as "Was due", due
    /// today or within the week keeps the amber tone, and a later date, a
    /// phrase that names no day, and work that is no longer open stay quiet.
    /// The Done list shows when the action was completed instead.
    static func dueLabel(for thread: ActionThread, listing: OutcomeStatus = .open, now: Date = Date(),
                         calendar: Calendar = .current, locale: Locale = .current,
                         localize: (String) -> String = { $0 }) -> ActionsListContent.DueLabel? {
        if listing == .done, thread.status == .done {
            let day = day(completionDate(of: thread), now: now, calendar: calendar, locale: locale, localize: localize)
            return .init(text: String(format: localize("Done %@"), day), tone: .calm)
        }
        guard let phrase = thread.due?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty else {
            return nil
        }
        guard let date = thread.resolvedDueDate else {
            return .init(text: String(format: localize("Due “%@”"), phrase), tone: .calm)
        }
        let isOpen = thread.status == .open
        let today = calendar.startOfDay(for: now)
        let daysAhead = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        let dateText = weekdayDate(date, calendar: calendar, locale: locale)
        if daysAhead < 0, isOpen {
            return .init(text: String(format: localize("Was due %@"), dateText), tone: .late)
        }
        let tone: ActionsListContent.DueLabel.Tone =
            isOpen && (0...ActionAttentionOrder.dueSoonWindowDays).contains(daysAhead) ? .soon : .calm
        if daysAhead == 0 { return .init(text: localize("Due today"), tone: tone) }
        if daysAhead == 1 { return .init(text: localize("Due tomorrow"), tone: tone) }
        return .init(text: String(format: localize("Due %@"), dateText), tone: tone)
    }

    /// When the action's last mention was marked done.
    static func completionDate(of thread: ActionThread) -> Date {
        thread.references.filter { $0.status == .done }.map(\.stateUpdatedAt).max()
            ?? thread.latestReference.stateUpdatedAt
    }

    /// "Design review meeting", or "In 2 meetings" for an action said twice.
    static func source(of thread: ActionThread, localize: (String) -> String = { $0 }) -> String {
        thread.hasMultipleMeetings
            ? String(format: localize("In %lld meetings"), thread.meetingCount)
            : thread.latestReference.meetingTitle
    }

    /// Under a meeting heading the row only says where else it was said.
    static func otherMeetings(of thread: ActionThread, localize: (String) -> String = { $0 }) -> String {
        switch thread.meetingCount - 1 {
        case ..<1: ""
        case 1: localize("Also in 1 other meeting")
        default: String(format: localize("Also in %lld other meetings"), thread.meetingCount - 1)
        }
    }

    /// "8 open actions haven’t been mentioned in 3 weeks."
    static func staleSummary(count: Int, localize: (String) -> String = { $0 }) -> String {
        count == 1
            ? localize("1 open action hasn’t been mentioned in 3 weeks.")
            : String(format: localize("%lld open actions haven’t been mentioned in 3 weeks."), count)
    }

    static func emptyText(for filter: ActionsListFilter, localize: (String) -> String = { $0 }) -> String {
        switch (filter.status, filter.narrowsList) {
        case (.open, true): localize("No open actions match these filters.")
        case (.deferred, true): localize("No deferred actions match these filters.")
        case (.done, true): localize("No done actions match these filters.")
        case (.open, false): localize("Nothing open. Actions from new meetings show up here.")
        case (.deferred, false): localize("Nothing deferred.")
        case (.done, false): localize("Nothing done yet.")
        }
    }

    /// "Mail showed “Message sent” · Mon 5:48 PM" beside "Looks done?" on a row.
    static func completionHint(_ hint: ActionCompletionHint, calendar: Calendar = .current,
                               locale: Locale = .current, localize: (String) -> String = { $0 }) -> String {
        String(format: localize("%1$@ showed “%2$@”"), hint.app, hint.cue)
            + " · " + hintTime(hint, calendar: calendar, locale: locale)
    }

    /// The same evidence as a sentence, for the details pane.
    static func completionHintSentence(_ hint: ActionCompletionHint, calendar: Calendar = .current,
                                       locale: Locale = .current, localize: (String) -> String = { $0 }) -> String {
        String(format: localize("%1$@ showed “%2$@” on %3$@, after this was said."), hint.app, hint.cue,
               hintTime(hint, calendar: calendar, locale: locale))
    }

    private static func hintTime(_ hint: ActionCompletionHint, calendar: Calendar, locale: Locale) -> String {
        hint.capturedAt.formatted(style(calendar: calendar, locale: locale).weekday(.abbreviated).hour().minute())
    }

    private static func style(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}

/// The Actions list as it is drawn: filtered, ordered and grouped threads
/// with each row's wording already made, so rows do no work of their own.
struct ActionsListContent: Equatable, Sendable {
    struct DueLabel: Equatable, Sendable {
        enum Tone: Equatable, Sendable { case late, soon, calm }
        let text: String
        let tone: Tone
    }

    struct Row: Identifiable, Equatable, Sendable {
        let thread: ActionThread
        /// The meeting it came from, with a day where the group does not
        /// already give one. Empty under a meeting heading.
        let source: String
        let due: DueLabel?
        var id: String { thread.id }
    }

    struct Section: Identifiable, Equatable, Sendable {
        let id: String
        /// Nil for a list without headings.
        let title: String?
        var isLate = false
        let rows: [Row]
    }

    private(set) var sections: [Section] = []
    /// Row ids from top to bottom, for the arrow keys and range selection.
    private(set) var order: [String] = []
    /// The user's open actions, whatever the list is showing.
    private(set) var openCount = 0
    /// Open actions the stale review would list.
    private(set) var staleCount = 0
    /// Meeting titles the user's actions came from, newest first.
    private(set) var meetingTitles: [String] = []
    private var rowsByID: [String: Row] = [:]

    var isEmpty: Bool { order.isEmpty }
    func row(_ id: String) -> Row? { rowsByID[id] }

    static let maximumMeetingChoices = 40
    static let recentlyDoneDays = 7

    /// - Parameter kept: threads whose status the user just changed in this
    ///   view. They stay listed until the view or its filters change, so a
    ///   ticked row does not vanish under the pointer.
    static func build(
        threads: [ActionThread], filter: ActionsListFilter, links: ActionThreadLinks = .init(),
        kept: Set<String> = [], now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current, localize: (String) -> String = { $0 }
    ) -> ActionsListContent {
        var catalog: [String: String] = [:]
        func text(_ key: String) -> String {
            if let known = catalog[key] { return known }
            let value = localize(key)
            catalog[key] = value
            return value
        }
        func day(_ date: Date) -> String {
            ActionListWording.day(date, now: now, calendar: calendar, locale: locale, localize: text)
        }
        func row(_ thread: ActionThread, source: String) -> Row {
            Row(thread: thread, source: source,
                due: ActionListWording.dueLabel(for: thread, listing: filter.status, now: now, calendar: calendar,
                                                locale: locale, localize: text))
        }
        func named(_ thread: ActionThread) -> String { ActionListWording.source(of: thread, localize: text) }
        func namedWithDay(_ thread: ActionThread) -> String {
            named(thread) + " · " + day(thread.latestReference.meetingStartedAt)
        }
        func newestFirst(_ threads: [ActionThread]) -> [ActionThread] {
            threads.enumerated().sorted { lhs, rhs in
                let left = lhs.element.latestReference.meetingStartedAt
                let right = rhs.element.latestReference.meetingStartedAt
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        }
        func byAttention(_ threads: [ActionThread]) -> [ActionThread] {
            ActionAttentionOrder.sorted(newestFirst(threads), now: now, calendar: calendar)
        }

        var content = ActionsListContent()
        content.openCount = threads.filter { $0.status == .open }.count
        content.staleCount = threads.filter { $0.isStale(now: now, calendar: calendar) }.count
        content.meetingTitles = meetingTitles(in: threads)

        let listed = threads.filter { thread in
            kept.contains(thread.id)
                || matches(thread, filter: filter, links: links, now: now, calendar: calendar)
        }
        var sections: [Section] = []
        func add(_ id: String, _ title: String?, _ rows: [Row], isLate: Bool = false) {
            if !rows.isEmpty { sections.append(Section(id: id, title: title, isLate: isLate, rows: rows)) }
        }

        switch filter.status {
        case .open where filter.isStaleReview:
            add("stale", text("Still open?"), newestFirst(listed).map { thread in
                row(thread, source: named(thread) + " · " + String(
                    format: text("last mentioned %@"), day(thread.latestReference.meetingStartedAt)))
            })
        case .open:
            let ordered = byAttention(listed)
            switch filter.grouping {
            case .due:
                func rows(_ bucket: ActionAttentionOrder.Bucket, withDay: Bool) -> [Row] {
                    ordered.filter { ActionAttentionOrder.bucket(for: $0, now: now, calendar: calendar) == bucket }
                        .map { row($0, source: withDay ? namedWithDay($0) : named($0)) }
                }
                add("overdue", text("Overdue"), rows(.overdue, withDay: false), isLate: true)
                add("soon", text("Next 7 days"), rows(.soon, withDay: false))
                add("later", text("Later or no date"), rows(.later, withDay: true))
            case .meeting:
                var meetings: [UUID] = []
                var byMeeting: [UUID: [ActionThread]] = [:]
                for thread in newestFirst(listed) {
                    let id = thread.latestReference.meetingID
                    if byMeeting[id] == nil { meetings.append(id) }
                    byMeeting[id, default: []].append(thread)
                }
                for id in meetings {
                    guard let group = byMeeting[id], let first = group.first?.latestReference else { continue }
                    add("meeting-" + id.uuidString, first.meetingTitle + " · " + day(first.meetingStartedAt),
                        byAttention(group).map { row($0, source: ActionListWording.otherMeetings(of: $0, localize: text)) })
                }
            case .none:
                add("all", nil, ordered.map { row($0, source: namedWithDay($0)) })
            }
        case .done:
            let cutoff = calendar.date(byAdding: .day, value: -(recentlyDoneDays - 1),
                                       to: calendar.startOfDay(for: now)) ?? now
            var dated: [(thread: ActionThread, date: Date, offset: Int)] = []
            for (offset, thread) in listed.enumerated() {
                dated.append((thread, ActionListWording.completionDate(of: thread), offset))
            }
            // Threads done at the same moment keep their list order.
            dated.sort { $0.date == $1.date ? $0.offset < $1.offset : $0.date > $1.date }
            var recent: [Row] = []
            var earlier: [Row] = []
            for item in dated {
                let entry = row(item.thread, source: named(item.thread))
                if item.date >= cutoff { recent.append(entry) } else { earlier.append(entry) }
            }
            add("recent", text("Last 7 days"), recent)
            add("earlier", text("Earlier"), earlier)
        case .deferred:
            add("all", nil, newestFirst(listed).map { row($0, source: namedWithDay($0)) })
        }

        content.sections = sections
        content.order = sections.flatMap { $0.rows.map(\.id) }
        content.rowsByID = Dictionary(sections.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return content
    }

    /// Whether the filter lists this thread, before the rows the user just
    /// changed are added back.
    static func matches(_ thread: ActionThread, filter: ActionsListFilter, links: ActionThreadLinks = .init(),
                        now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard thread.status == filter.status else { return false }
        switch filter.due {
        case .any: break
        case .overdue:
            guard let due = thread.resolvedDueDate, due < calendar.startOfDay(for: now) else { return false }
        case .dated:
            if thread.resolvedDueDate == nil { return false }
        case .undated:
            if thread.resolvedDueDate != nil { return false }
        }
        if let personID = filter.personID, !links.thread(thread, isWith: personID) { return false }
        if let projectID = filter.projectID, !links.thread(thread, isIn: projectID) { return false }
        if let title = filter.meetingTitle,
           !thread.references.contains(where: { sameTitle($0.meetingTitle, title) }) { return false }
        if filter.isStaleReview, !thread.isStale(now: now, calendar: calendar) { return false }
        let needle = filter.trimmedQuery
        guard !needle.isEmpty else { return true }
        return thread.text.localizedCaseInsensitiveContains(needle)
            || thread.due?.localizedCaseInsensitiveContains(needle) == true
            || thread.references.contains { $0.meetingTitle.localizedCaseInsensitiveContains(needle) }
    }

    private static func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func meetingTitles(in threads: [ActionThread]) -> [String] {
        let references = threads.flatMap(\.references).sorted { $0.meetingStartedAt > $1.meetingStartedAt }
        var titles: [String] = []
        for reference in references where !titles.contains(where: { sameTitle($0, reference.meetingTitle) }) {
            titles.append(reference.meetingTitle)
            if titles.count == maximumMeetingChoices { break }
        }
        return titles
    }
}

/// Which rows the Actions list acts on. One row is always current, as in
/// Mail: the chosen rows that are still listed, or else the first row.
/// ⌘-click adds or removes a row and Shift-click takes a range.
struct ActionListSelection: Equatable, Sendable {
    var chosen: Set<String> = []
    /// Where a Shift range starts.
    var anchor: String?
    /// The row the arrow keys move from.
    var lead: String?

    func current(in order: [String]) -> [String] {
        let listed = order.filter(chosen.contains)
        return listed.isEmpty ? Array(order.prefix(1)) : listed
    }

    mutating func click(_ id: String, command: Bool = false, shift: Bool = false, order: [String]) {
        if shift, let start = rangeStart(in: order),
           let from = order.firstIndex(of: start), let to = order.firstIndex(of: id) {
            chosen = Set(order[min(from, to)...max(from, to)])
            anchor = start
        } else if command {
            var next = Set(current(in: order))
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            // The last row cannot be deselected: one row is always current.
            chosen = next.isEmpty ? [id] : next
            anchor = id
        } else {
            chosen = [id]
            anchor = id
        }
        lead = id
    }

    /// Moves up or down one row and returns the row to keep in view.
    @discardableResult
    mutating func move(by step: Int, extending: Bool = false, order: [String]) -> String? {
        let current = current(in: order)
        guard !current.isEmpty else { return nil }
        let start = lead.flatMap { current.contains($0) ? $0 : nil } ?? (step > 0 ? current.last : current.first)
        guard let start, let from = order.firstIndex(of: start) else { return nil }
        let to = min(max(from + step, 0), order.count - 1)
        if extending {
            let rangeStart = rangeStart(in: order) ?? start
            if let first = order.firstIndex(of: rangeStart) {
                chosen = Set(order[min(first, to)...max(first, to)])
                anchor = rangeStart
            }
        } else {
            chosen = [order[to]]
            anchor = order[to]
        }
        lead = order[to]
        return lead
    }

    mutating func selectAll(in order: [String]) {
        guard !order.isEmpty else { return }
        chosen = Set(order)
        anchor = order.first
        lead = order.last
    }

    /// Back to one row: the one the keyboard was on, or the first chosen.
    mutating func collapse(in order: [String]) {
        let current = current(in: order)
        guard let keep = lead.flatMap({ current.contains($0) ? $0 : nil }) ?? current.first else { return }
        chosen = [keep]
        anchor = keep
        lead = keep
    }

    private func rangeStart(in order: [String]) -> String? {
        anchor.flatMap { order.contains($0) ? $0 : nil } ?? current(in: order).first
    }
}

/// What the details pane says about one action, and the corrections it saves
/// through `OutcomeIndex.correctAction`.
enum ActionDetailsPresentation {
    /// The Due control: the resolved day, "Pick a date" for a phrase that
    /// names no day, or "No date".
    static func dueTitle(for thread: ActionThread, calendar: Calendar = .current, locale: Locale = .current,
                         localize: (String) -> String = { $0 }) -> String {
        if let date = thread.resolvedDueDate {
            return ActionListWording.weekdayDate(date, calendar: calendar, locale: locale)
        }
        return localize(thread.due == nil ? "No date" : "Pick a date")
    }

    /// Due phrases as they were said, newest meeting first, without the days
    /// someone typed in.
    static func saidDuePhrases(in thread: ActionThread) -> [String] {
        thread.references.compactMap { $0.action.due?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !ActionDuePresentation.isExplicitDate($0) }
            .reduce(into: [String]()) { phrases, phrase in
                if !phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                    phrases.append(phrase)
                }
            }
    }

    /// "You said “by Thursday”. Before that, “next week”."
    static func dueNote(for thread: ActionThread, localize: (String) -> String = { $0 }) -> String? {
        let phrases = saidDuePhrases(in: thread)
        guard let latest = phrases.first else { return nil }
        var note = String(format: localize("You said “%@”."), latest)
        if phrases.count > 1 {
            note += " " + String(format: localize("Before that, “%@”."), phrases[1])
        }
        return note
    }

    /// "Said in 2 meetings", or "What was said" for one meeting.
    static func mentionsHeading(for thread: ActionThread, localize: (String) -> String = { $0 }) -> String {
        thread.hasMultipleMeetings
            ? String(format: localize("Said in %lld meetings"), thread.meetingCount)
            : localize("What was said")
    }

    /// One call to `OutcomeIndex.correctAction`. Fields the change does not
    /// touch keep a saved correction and otherwise stay as extracted.
    struct Correction: Equatable, Sendable {
        let actionID: String
        let meetingID: UUID
        let text: String?
        let owner: String?
        let due: String?
    }

    /// A due day chosen in the details pane, or none. It is saved on the
    /// newest mention, whose correction a thread takes as its due date.
    static func dueCorrection(_ date: Date?, for thread: ActionThread, calendar: Calendar = .current) -> Correction {
        let reference = thread.latestReference
        return Correction(
            actionID: reference.action.id, meetingID: reference.meetingID,
            text: reference.textWasCorrected ? reference.text : nil,
            owner: reference.ownerWasCorrected ? (reference.owner ?? "") : nil,
            due: date.map { AskDayScope.key(for: $0, calendar: calendar) } ?? "")
    }

    /// "Not mine": every mention loses its owner, so the action leaves the
    /// user's list in each meeting it was said in.
    static func notMineCorrections(for thread: ActionThread) -> [Correction] {
        thread.references.filter(\.isForUser).map { reference in
            Correction(
                actionID: reference.action.id, meetingID: reference.meetingID,
                text: reference.textWasCorrected ? reference.text : nil,
                owner: "",
                due: reference.dueWasCorrected ? (reference.due ?? "") : nil)
        }
    }
}
