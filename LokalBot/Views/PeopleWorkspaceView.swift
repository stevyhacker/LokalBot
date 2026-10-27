import SwiftUI

/// Everyone the user meets, joined across calendar attendees, names applied
/// to speakers, and action owners: what each side is waiting on, what the
/// newest notes say about them, the projects named around them, decisions
/// made together, and the meetings behind them. Names, merges, and hidden
/// entries the person chose live in `PeopleStore`.
struct PeopleWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @ObservedObject var store: PeopleStore
    @SceneStorage("people.query") private var query = ""
    @State private var showingProvenance = false
    @State private var renaming: PersonProfile?
    @State private var merging: PersonProfile?

    static let provenance = "Built on this Mac from calendar attendees, names you gave speakers, action owners, and meeting notes. Email addresses are used only to tell people apart and are never shown or shared."

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                       idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("People", autosaveName: "LokalBot.people",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail
                .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Person details")
        }
        .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
        // The toolbar title sits over the list column, so it names the
        // section; the selected person's name heads the detail page.
        .navigationTitle("People")
        .task { app.refreshConnections() }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.meetings.count) { app.refreshConnections() }
        .onChange(of: store.curation) { app.refreshConnections() }
        .sheet(item: $renaming) { person in
            PersonNameSheet(person: person, chosenName: store.chosenName(for: person)) { name in
                store.rename(person, to: name)
            }
        }
        .sheet(item: $merging) { person in
            PersonMergeSheet(person: person, candidates: connections.people.filter { $0.id != person.id }) { target in
                store.merge(person, into: target)
                app.selectedPersonID = target.id
            }
        }
    }

    private var filtered: [PersonProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return connections.people }
        return connections.people.filter { person in
            ([person.name] + person.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var countSummary: String {
        let count = connections.people.count
        return "\(count) \(count == 1 ? "person" : "people") from your meetings"
    }

    private var hiddenLabel: String {
        let count = store.curation.hidden.count
        return "Show \(count) hidden \(count == 1 ? "entry" : "entries") again"
    }

    /// People with open work first (anyone waiting on the user before
    /// anyone the user waits on), then the last two weeks by how often you
    /// met in the last 30 days, then everyone else by when you last met.
    private var grouped: (open: [PersonProfile], recent: [PersonProfile], earlier: [PersonProfile]) {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? .distantPast
        let frequencyStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let people = filtered
        let open = people.filter { $0.openCount > 0 }.sorted { left, right in
            if left.myActions.isEmpty != right.myActions.isEmpty { return !left.myActions.isEmpty }
            if left.openCount != right.openCount { return left.openCount > right.openCount }
            return (left.lastMetAt ?? .distantPast) > (right.lastMetAt ?? .distantPast)
        }
        let rest = people.filter { $0.openCount == 0 }
        var frequency: [String: Int] = [:]
        for person in rest { frequency[person.id] = person.occasions(since: frequencyStart) }
        let recent = rest.filter { ($0.lastMetAt ?? .distantPast) >= cutoff }.sorted { left, right in
            let leftCount = frequency[left.id] ?? 0, rightCount = frequency[right.id] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let leftDate = left.lastMetAt ?? .distantPast, rightDate = right.lastMetAt ?? .distantPast
            return leftDate == rightDate ? left.name < right.name : leftDate > rightDate
        }
        let earlier = rest.filter { ($0.lastMetAt ?? .distantPast) < cutoff }
        return (open, recent, earlier)
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(connections.hasLoaded ? countSummary : "Loading…")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    Button {
                        showingProvenance.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Where People comes from")
                    .accessibilityLabel("Where People comes from")
                    .popover(isPresented: $showingProvenance, arrowEdge: .bottom) {
                        Text(Self.provenance)
                            .font(.scaled(.callout))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                            .padding(14)
                    }
                }
                TextField("Search people", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("people.search")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedPersonID) {
                let groups = grouped
                section("Open Work", groups.open)
                section("Last 2 Weeks", groups.recent)
                section("Earlier", groups.earlier)
                if !store.curation.hidden.isEmpty {
                    Button(hiddenLabel) { store.restoreHidden() }
                        .buttonStyle(.workspaceLink)
                        .font(.scaled(.callout))
                        .selectionDisabled(true)
                        .help(store.curation.hidden.map(\.name).sorted().joined(separator: ", "))
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("people.list")
            .overlay {
                if connections.hasLoaded && connections.people.isEmpty {
                    Text("People appear after meetings with calendar attendees, named speakers, or named action owners.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ people: [PersonProfile]) -> some View {
        if !people.isEmpty {
            Section(title) {
                ForEach(people) { person in
                    PersonRow(person: person).tag(person.id)
                        .contextMenu {
                            PersonMenuItems(person: person, store: store,
                                            onRename: { renaming = person }, onMerge: { merging = person })
                        }
                }
            }
        }
    }

    /// A merge keeps the selection: an id folded into someone else finds
    /// the person it joined.
    private var selectedPerson: PersonProfile? {
        guard let id = app.selectedPersonID else { return filtered.first }
        return connections.people.first { $0.id == id || $0.memberIDs.contains(id) }
    }

    @ViewBuilder private var detail: some View {
        if let person = selectedPerson {
            PersonDetailView(person: person, store: store,
                             onRename: { renaming = person }, onMerge: { merging = person })
                .id(person.id)
        } else {
            Text(connections.hasLoaded ? "Select a person." : "Loading people…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PersonRow: View {
    let person: PersonProfile

    var body: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: person.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(person.name).font(.scaled(.body).weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let last = person.lastMetAt {
                        Text(PersonDetailView.relativeDay(last))
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(context)
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    OpenWorkBadge(youOwe: person.myActions.count, theyOwe: person.theirActions.count,
                                  firstName: person.firstName)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// What sets this person apart: the projects named around them, else
    /// the meetings you share most.
    private var context: String {
        let projects = person.projects.prefix(2).map(\.name)
        if !projects.isEmpty { return projects.joined(separator: " · ") }
        let series = person.series.sorted { $0.occasions.count > $1.occasions.count }.prefix(2).map(\.title)
        if !series.isEmpty { return series.joined(separator: ", ") }
        let count = person.meetingCount
        return count == 0 ? "Named in actions" : "\(count) meeting\(count == 1 ? "" : "s")"
    }
}

/// Open work between the user and one person: what is waiting on the user
/// (↗) and what is waiting on them (↙), matching the detail page's sections.
private struct OpenWorkBadge: View {
    let youOwe: Int
    let theyOwe: Int
    let firstName: String

    var body: some View {
        if youOwe + theyOwe > 0 {
            HStack(spacing: 4) {
                if youOwe > 0 { pill(youOwe, symbol: "arrow.up.right", attention: true) }
                if theyOwe > 0 { pill(theyOwe, symbol: "arrow.down.left", attention: false) }
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
        }
    }

    private func pill(_ count: Int, symbol: String, attention: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("\(count)").font(.scaled(.caption).weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(attention ? LBTokens.Palette.attentionText : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill((attention ? LBTokens.Palette.attention : Color.secondary)
            .opacity(LBTokens.Palette.statusFillOpacity * 1.5)))
    }

    private var help: String {
        var parts: [String] = []
        if youOwe > 0 { parts.append("\(youOwe) waiting on you") }
        if theyOwe > 0 { parts.append("\(theyOwe) waiting on \(firstName)") }
        return parts.joined(separator: ", ")
    }
}

/// A person's initials on a tint chosen from their name, matching the
/// speaker colors used in transcripts.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        let color = Self.color(for: name)
        Circle()
            .fill(color.opacity(0.16))
            .overlay(Circle().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Text(Self.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count >= 2 ? [words.first, words.last] : [words.first]
        return letters.compactMap { $0?.first.map { String($0).uppercased() } }.joined()
    }

    static func color(for name: String) -> Color {
        let palette = LBTokens.Palette.speakers
        let hash = PeopleDirectory.normalized(name).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

/// Rename, merge, separate, and hide, shared by a row's context menu and
/// the detail page's More menu.
private struct PersonMenuItems: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile
    @ObservedObject var store: PeopleStore
    let onRename: () -> Void
    let onMerge: () -> Void

    var body: some View {
        Button("Rename…", action: onRename)
        Button("Merge Into…", action: onMerge)
        let merges = store.merges(into: person)
        if !merges.isEmpty {
            Menu("Separate") {
                ForEach(merges, id: \.sourceID) { merge in
                    Button(merge.sourceName) { store.separate(merge) }
                }
            }
        }
        Divider()
        Button("Not a Person") {
            store.hide(person)
            if app.selectedPersonID == person.id { app.selectedPersonID = nil }
        }
    }
}

struct PersonDetailView: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile
    @ObservedObject var store: PeopleStore
    var onRename: () -> Void = {}
    var onMerge: () -> Void = {}

    /// Series shown before the rest are summed up in one line.
    static let visibleSeries = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                openWork
                recentNotes
                projects
                if !person.decisions.isEmpty {
                    WorkspaceSection(title: "Decisions Together", icon: "checkmark.seal") {
                        ForEach(person.decisions) { decision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(decision.text).textSelection(.enabled)
                                Button("\(decision.meetingTitle) · \(decision.meetingDate.formatted(date: .abbreviated, time: .omitted))") {
                                    app.openMeeting(decision.meetingID)
                                }
                                .buttonStyle(.workspaceLink)
                                .font(.scaled(.callout))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                meetingsTogether
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("person.detail")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                InitialsAvatar(name: person.name, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(.scaled(.largeTitle).bold())
                    Text(stats).font(.scaled(.callout)).foregroundStyle(.secondary)
                    if !person.otherNames.isEmpty {
                        Text("Also appears as " + person.otherNames.joined(separator: ", "))
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    app.openAsk(query: "What has \(person.name) been working on lately, and what is open between us?",
                                meetingIDs: person.meetingIDs)
                } label: {
                    Label("Ask About \(person.firstName)", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(person.meetings.isEmpty)
                .accessibilityIdentifier("person.ask")
                Menu {
                    Button("Prepare in Agent…") { prepareInAgent() }
                    if let meeting = followUpMeeting {
                        Button("Draft Follow-up for \(meeting.displayTitle)…") { app.draftFollowUp(for: meeting) }
                    }
                    Divider()
                    PersonMenuItems(person: person, store: store, onRename: onRename, onMerge: onMerge)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("person.menu")
            }
        }
    }

    private var stats: String {
        let occasions = person.occasions
        let count = occasions.count
        var parts = ["\(count) meeting\(count == 1 ? "" : "s")"]
        if let first = occasions.last?.startedAt, count > 1 {
            parts[0] += " since " + first.formatted(.dateTime.month(.abbreviated).day())
        }
        if let last = person.lastMetAt { parts.append("last met " + Self.relativeDay(last)) }
        if person.openCount > 0 { parts.append("\(person.openCount) open") }
        return parts.joined(separator: " · ")
    }

    /// "today", "yesterday", "3 days ago", then a date.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    // MARK: - Open work

    /// Both directions of open work; one quiet line when nothing is open.
    @ViewBuilder private var openWork: some View {
        if person.myActions.isEmpty && person.theirActions.isEmpty {
            WorkspaceSection(title: "Open Work", icon: "checklist") {
                EmptyWorkspaceRow(text: "Nothing open between you and \(person.firstName).")
            }
        } else {
            if !person.myActions.isEmpty {
                threadSection(title: "Waiting on You", icon: "arrow.up.right.circle", threads: person.myActions)
            }
            if !person.theirActions.isEmpty {
                threadSection(title: "Waiting on \(person.firstName)", icon: "arrow.down.left.circle",
                              threads: person.theirActions)
            }
        }
    }

    private func threadSection(title: String, icon: String, threads: [ActionThread]) -> some View {
        WorkspaceSection(title: title, icon: icon) {
            VStack(spacing: 0) {
                ForEach(threads) { thread in
                    ActionThreadRow(thread: thread, showsStaleness: true)
                    if thread.id != threads.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Notes and projects

    @ViewBuilder private var recentNotes: some View {
        if let notes = person.recentNotes {
            WorkspaceSection(title: notes.isLatestMeeting ? "Last Time" : "Last Mentioned", icon: "text.quote") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("\(notes.meetingTitle) · \(notes.meetingDate.formatted(date: .abbreviated, time: .omitted))") {
                        app.openMeeting(notes.meetingID)
                    }
                    .buttonStyle(.workspaceLink)
                    .font(.scaled(.callout))
                    ForEach(notes.points) { point in
                        NotePointRow(point: point) { seek in app.openMeeting(point.meetingID, seek: seek) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var projects: some View {
        if !person.projects.isEmpty {
            WorkspaceSection(title: "Projects", icon: "folder") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { projectLinks }
                    VStack(alignment: .leading, spacing: 6) { projectLinks }
                }
            }
        }
    }

    @ViewBuilder private var projectLinks: some View {
        ForEach(person.projects) { project in
            Button {
                app.openProject(project.id)
            } label: {
                Text(project.isTracked ? project.name : "\(project.name) (suggested)")
            }
            .buttonStyle(.workspaceLink)
            .help("Named \(project.mentions) time\(project.mentions == 1 ? "" : "s") around \(person.firstName)")
        }
    }

    // MARK: - Meetings

    private var meetingsTogether: some View {
        let series = person.series
        return WorkspaceSection(title: "Meetings Together", icon: "waveform.circle") {
            if series.isEmpty {
                EmptyWorkspaceRow(text: "\(person.firstName) appears only as an action owner.")
            } else {
                let shown = Array(series.prefix(Self.visibleSeries))
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        MeetingSeriesRow(series: item) { app.openMeeting($0) }
                        if item.id != shown.last?.id { Divider() }
                    }
                }
                if series.count > Self.visibleSeries {
                    let rest = series.dropFirst(Self.visibleSeries)
                    let count = rest.reduce(0) { $0 + $1.occasions.count }
                    Text("And \(count) more meeting\(count == 1 ? "" : "s") under \(rest.count) other title\(rest.count == 1 ? "" : "s").")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    /// The newest meeting with outcomes that was small enough to be with
    /// this person, rather than a team call they happened to attend.
    private var followUpMeeting: Meeting? {
        person.occasions.lazy
            .map(\.primary)
            .filter { $0.participantCount <= PeopleDirectory.decisionMeetingSize }
            .filter { app.outcomeIndex.projection(for: $0.id) != nil }
            .compactMap { ref in app.meetings.first { $0.id == ref.id } }
            .first
    }

    private func prepareInAgent() {
        app.openAgent(.init(
            title: "Prepare for \(person.name)",
            prompt: preparationPrompt,
            meetingID: person.meetings.first?.id,
            actionID: nil))
    }

    private var preparationPrompt: String {
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

/// One line from meeting notes, with who said it when that is not the
/// person, and the moment in the call.
private struct NotePointRow: View {
    let point: PersonProfile.NotePoint
    let open: (TimeInterval?) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let speaker = point.speaker {
                    Text("\(Text(speaker).fontWeight(.semibold)): \(point.text)")
                } else {
                    Text(point.text)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let seek = point.seek {
                Button {
                    open(seek)
                } label: {
                    Label(Transcript.stamp(seek), systemImage: "quote.bubble")
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .foregroundStyle(Brand.teal)
                }
                .buttonStyle(.plain)
                .help("Open the meeting at this moment")
            }
        }
    }
}

/// A meeting series: one row for a one-off meeting, or a row that opens to
/// list each date of a recurring one. A call recorded in parts is one
/// meeting that opens its longest recording.
private struct MeetingSeriesRow: View {
    let series: PersonProfile.Series
    let open: (UUID) -> Void
    @State private var expanded = false

    var body: some View {
        if series.occasions.count == 1 {
            MeetingLinkRow(title: series.title, detail: recordingsNote(series.latest),
                           date: series.latest.startedAt) { open(series.latest.primary.id) }
        } else {
            VStack(spacing: 0) {
                MeetingLinkRow(title: series.title, detail: "\(series.occasions.count) meetings",
                               date: series.latest.startedAt,
                               disclosure: expanded ? .expanded : .collapsed) {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .accessibilityHint(expanded ? "Hides the dates" : "Shows each date")
                if expanded {
                    ForEach(series.occasions) { occasion in
                        MeetingLinkRow(title: occasion.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                                       detail: recordingsNote(occasion), date: nil, indented: true) {
                            open(occasion.primary.id)
                        }
                    }
                }
            }
        }
    }

    private func recordingsNote(_ occasion: PersonProfile.Occasion) -> String? {
        occasion.recordings.count > 1 ? "\(occasion.recordings.count) recordings" : nil
    }
}

private struct MeetingLinkRow: View {
    enum Disclosure { case none, collapsed, expanded }

    let title: String
    let detail: String?
    let date: Date?
    var disclosure: Disclosure = .none
    var indented = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if disclosure != .none {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosure == .expanded ? 90 : 0))
                        .frame(width: 12)
                }
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail).font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if disclosure == .none {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.5)
                }
            }
            .padding(.leading, indented ? 20 : 0)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
    }
}

/// Chooses the name People shows for someone. The names meetings used stay
/// as other names, and the chosen one is recognized in notes and owners.
private struct PersonNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: PersonProfile
    let chosenName: String?
    let onSave: (String) -> Void
    @State private var name: String

    init(person: PersonProfile, chosenName: String?, onSave: @escaping (String) -> Void) {
        self.person = person
        self.chosenName = chosenName
        self.onSave = onSave
        _name = State(initialValue: person.name)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(person.name)").font(.scaled(.title3).bold())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("person.name")
            Text("People shows this name, and LokalBot also recognizes it in meeting notes and action owners. Names from your meetings stay listed as other names.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if chosenName != nil {
                    Button("Use Name from Meetings") {
                        onSave("")
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Folds one person into another: for a name heard wrong, a nickname, or
/// someone who joined from two addresses.
private struct PersonMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: PersonProfile
    let candidates: [PersonProfile]
    let onMerge: (PersonProfile) -> Void
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [PersonProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = candidates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { ([$0.name] + $0.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(person.name) Into…").font(.scaled(.title3).bold())
            Text("Choose who \(person.name) really is. Their meetings, open work, and decisions move to that person, and \(person.name) becomes another name. Separate them again from that person's More menu.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search people", text: $query)
                .textFieldStyle(.roundedBorder)
            List(filtered, selection: $selection) { candidate in
                HStack(spacing: 8) {
                    InitialsAvatar(name: candidate.name, size: 22)
                    Text(candidate.name)
                    Spacer()
                    Text("\(candidate.meetingCount) meeting\(candidate.meetingCount == 1 ? "" : "s")")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                .tag(candidate.id)
            }
            .listStyle(.bordered)
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let target = candidates.first(where: { $0.id == selection }) { onMerge(target) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
