import SwiftUI

/// Everyone the user meets, joined across calendar attendees, names applied
/// to speakers, and action owners. The list is grouped by time only: people
/// in calendar meetings in the next week, the last two weeks, and earlier.
/// The page beside it leads with the next meeting, then what is open between
/// you, what the last meeting said and what you decided together. Names,
/// merges, and hidden entries the person chose live in `PeopleStore`.
struct PeopleWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @ObservedObject var store: PeopleStore
    @SceneStorage("people.query") private var query = ""
    @State private var renaming: PersonProfile?
    @State private var merging: PersonProfile?
    /// Each person's next calendar meeting in the coming week, by person id.
    /// Empty without Calendar access.
    @State private var upcoming: [String: PersonUpcomingMeeting] = [:]
    @State private var listCache = PeopleListCache()
    @State private var compactToolbar = false

    /// How often the coming week's calendar is read again while People is open.
    private static let upcomingRefreshSeconds = 60

    var body: some View {
        let language = app.settings.appLanguage
        let content = listCache.content(
            people: connections.people, upcoming: upcoming, query: query, now: Date(), language: language)
        let selected = selectedPerson(content)
        return HSplitView {
            PeopleListColumn(content: content, people: connections.people, hasLoaded: connections.hasLoaded,
                             store: store, query: $query,
                             onRename: { renaming = $0 }, onMerge: { merging = $0 })
                .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                       idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("People", autosaveName: "LokalBot.people",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail(selected)
                .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Person details")
        }
        .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
        // The selected person is the window's title; the toolbar draws it
        // with their avatar and how long you have been meeting.
        .navigationTitle(selected.map { Text(verbatim: $0.name) } ?? Text("People"))
        .toolbar(removing: .title)
        .toolbar { toolbar(selected) }
        .onGeometryChange(for: Bool.self) { $0.size.width < 720 } action: { compactToolbar = $0 }
        .task {
            app.refreshConnections()
            // The coming week changes slowly; a meeting that has started or
            // ended still has to leave "Coming up" without a visit elsewhere.
            while !Task.isCancelled {
                refreshUpcoming()
                try? await Task.sleep(for: .seconds(Self.upcomingRefreshSeconds))
            }
        }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.meetings.count) { app.refreshConnections() }
        .onChange(of: store.curation) { app.refreshConnections() }
        .onChange(of: connections.people) { refreshUpcoming() }
        .onChange(of: app.settings.calendarDetectionEnabled) { refreshUpcoming() }
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

    /// Reads the calendar only while Calendar use is on and access is
    /// granted, and matches its events to people by the directory's keys.
    private func refreshUpcoming() {
        let now = Date()
        let matched = PeopleUpcomingMeetings.match(
            events: UpcomingMeetingSchedule.readAhead(app: app, now: now),
            people: connections.people,
            recordedEventIDs: TodayAgenda.recordedEventIDs(
                in: (app.currentMeeting.map { [$0] } ?? []) + app.meetings),
            now: now)
        if matched != upcoming { upcoming = matched }
    }

    /// A merge keeps the selection: an id folded into someone else finds
    /// the person it joined. With nothing chosen, the first row's person.
    private func selectedPerson(_ content: PeopleListContent) -> PersonProfile? {
        guard let id = app.selectedPersonID else {
            return content.personIDs.first.flatMap { first in connections.people.first { $0.id == first } }
        }
        return connections.people.first { $0.id == id || $0.memberIDs.contains(id) }
    }

    // MARK: - Page

    @ViewBuilder private func detail(_ person: PersonProfile?) -> some View {
        if let person {
            PersonDetailView(person: person, nextMeeting: upcoming[person.id])
                .id(person.id)
        } else {
            Text(connections.hasLoaded ? "Select a person." : "Loading people…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func toolbar(_ person: PersonProfile?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let person {
                let language = app.settings.appLanguage
                HStack(spacing: 8) {
                    InitialsAvatar(name: person.name, size: 26)
                    Text(verbatim: person.name)
                        .font(LBTokens.Typography.columnTitle)
                        .lineLimit(1)
                    if !compactToolbar {
                        Text(verbatim: PeopleWording.subtitle(
                            for: person, locale: PeopleWording.formattingLocale(language.locale), localize: language.catalog))
                            .font(AppFont.scaled(.callout).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("person.title")
            } else {
                Text("People").font(LBTokens.Typography.columnTitle)
            }
        }
        if let person {
            ToolbarItemGroup(placement: .primaryAction) {
                // Words and the icon while the toolbar has room, the icon alone
                // when it does not.
                if compactToolbar {
                    askButton(person).labelStyle(.iconOnly)
                } else {
                    askButton(person).labelStyle(.titleAndIcon)
                }
                WorkspaceMenu(title: app.settings.appLanguage.localized("More"), symbol: "ellipsis",
                              identifier: "person.menu", items: menuItems(person))
            }
        }
    }

    private func askButton(_ person: PersonProfile) -> some View {
        Button {
            app.openAsk(query: "What has \(person.name) been working on lately, and what is open between us?",
                        meetingIDs: person.meetingIDs)
        } label: {
            Label("Ask about \(person.firstName)", systemImage: "magnifyingglass")
        }
        .disabled(person.meetings.isEmpty)
        .help("Ask about \(person.firstName)")
        .accessibilityIdentifier("person.ask")
    }

    /// Prepare and follow-up first, then the corrections: rename, merge,
    /// separate what was merged, and hide.
    private func menuItems(_ person: PersonProfile) -> [WorkspaceMenu.Item] {
        let language = app.settings.appLanguage
        var items: [WorkspaceMenu.Item] = [
            .init(title: language.localized("Prepare in Agent…"), identifier: "person.menu.prepare",
                  action: { app.openAgent(PersonPreparation.launchContext(for: person)) }),
        ]
        if let meeting = followUpMeeting(person) {
            items.append(.init(
                title: String(format: language.localized("Draft follow-up for %@…"), meeting.displayTitle),
                identifier: "person.menu.followUp", action: { app.draftFollowUp(for: meeting) }))
        }
        items += [
            .separator,
            .init(title: language.localized("Rename…"), identifier: "person.menu.rename",
                  action: { renaming = person }),
            .init(title: language.localized("Merge into…"), identifier: "person.menu.merge",
                  action: { merging = person }),
        ]
        let merges = store.merges(into: person)
        if !merges.isEmpty {
            items.append(.init(
                title: language.localized("Separate"), identifier: "person.menu.separate",
                children: merges.map { merge in
                    .init(title: merge.sourceName, action: { store.separate(merge) })
                }))
        }
        items += [
            .separator,
            .init(title: language.localized("Not a person"), identifier: "person.menu.notAPerson", action: {
                store.hide(person)
                if app.selectedPersonID == person.id { app.selectedPersonID = nil }
            }),
        ]
        return items
    }

    /// The newest meeting with outcomes that was small enough to be with
    /// this person, rather than a team call they happened to attend.
    private func followUpMeeting(_ person: PersonProfile) -> Meeting? {
        person.occasions.lazy
            .map(\.primary)
            .filter { $0.participantCount <= PeopleDirectory.decisionMeetingSize }
            .filter { app.outcomeIndex.projection(for: $0.id) != nil }
            .compactMap { ref in app.meetings.first { $0.id == ref.id } }
            .first
    }
}

/// The list column: a search field as its header, then people under Coming
/// up, Last 2 weeks and Earlier. Hidden entries are restored from its foot.
struct PeopleListColumn: View {
    @EnvironmentObject var app: AppState
    let content: PeopleListContent
    let people: [PersonProfile]
    let hasLoaded: Bool
    @ObservedObject var store: PeopleStore
    @Binding var query: String
    let onRename: (PersonProfile) -> Void
    let onMerge: (PersonProfile) -> Void
    @State private var showingProvenance = false

    static let provenance = "Built on this Mac from calendar attendees, names you gave speakers, action owners, and meeting notes. Email addresses are used only to tell people apart and are never shown or shared."

    var body: some View {
        let language = app.settings.appLanguage
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ListColumnSearchField(prompt: "Search people", text: $query, identifier: "people.search")
                Button {
                    showingProvenance.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Where People comes from")
                .accessibilityLabel("Where People comes from")
                .accessibilityIdentifier("people.provenance")
                .popover(isPresented: $showingProvenance, arrowEdge: .bottom) {
                    Text(Self.provenance)
                        .font(.scaled(.callout))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300, alignment: .leading)
                        .padding(14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                List(selection: $app.selectedPersonID) {
                    ForEach(content.sections) { section in
                        // A heading row, as in the Meetings list: it scrolls
                        // with its people and arrow keys pass over it.
                        Group {
                            SectionHeader(text: LocalizedStringKey(section.group.title))
                                .padding(.top, 6)
                                .selectionDisabled(true)
                                .listRowSeparator(.hidden)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("people.group.\(section.group.rawValue)")
                            ForEach(section.rows) { row in
                                PersonRow(row: row, isSelected: row.id == app.selectedPersonID,
                                          localize: language.catalog)
                                    .tag(row.id)
                                    .listRowSeparator(.hidden)
                                    .contextMenu {
                                        if let person = peopleByID[row.id] {
                                            PersonMenuItems(person: person, store: store,
                                                            onRename: { onRename(person) },
                                                            onMerge: { onMerge(person) })
                                        }
                                    }
                            }
                        }
                    }
                    if !store.curation.hidden.isEmpty {
                        Button {
                            store.restoreHidden()
                        } label: {
                            Text(verbatim: PeopleWording.restoreHidden(
                                store.curation.hidden.count, localize: language.catalog))
                        }
                        .buttonStyle(.workspaceLink)
                        .font(.scaled(.callout))
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                        .help(store.curation.hidden.map(\.name).sorted().joined(separator: ", "))
                        .accessibilityIdentifier("people.restoreHidden")
                    }
                }
                .listStyle(.inset)
                .tint(Brand.tealFill)
                .accessibilityIdentifier("people.list")
                // A person opened from Actions, Projects, a meeting or Ask
                // may sit far down the list.
                .onChange(of: app.selectedPersonID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onAppear {
                    guard let id = app.selectedPersonID else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if !hasLoaded {
                    LoadingStateLabel(language.localized("Loading…"), font: AppFont.scaled(.body))
                } else if people.isEmpty {
                    Text("People appear after meetings with calendar attendees, named speakers, or named action owners.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else if content.isEmpty {
                    Text("No matches")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                        .padding(24)
                }
            }
        }
    }
}

/// Remembers the list for the inputs it was built from: the page redraws far
/// more often than its people, their calendar or the search change.
final class PeopleListCache {
    private struct Key: Equatable {
        let people: [PersonProfile]
        let upcoming: [String: PersonUpcomingMeeting]
        let query: String
        let day: Date
        let language: AppLanguage
    }

    private var key: Key?
    private var cached = PeopleListContent()

    func content(people: [PersonProfile], upcoming: [String: PersonUpcomingMeeting], query: String,
                 now: Date, language: AppLanguage, calendar: Calendar = .current) -> PeopleListContent {
        let next = Key(people: people, upcoming: upcoming, query: query,
                       day: calendar.startOfDay(for: now), language: language)
        if next != key {
            key = next
            cached = PeopleListContent.build(
                people: people, upcoming: upcoming, query: query, now: now, calendar: calendar,
                locale: PeopleWording.formattingLocale(language.locale), localize: language.catalog)
        }
        return cached
    }
}

/// One person in the list: avatar, name and when, then the latest or next
/// meeting and which way open work runs.
private struct PersonRow: View {
    let row: PeopleListContent.Row
    /// From the list's selection, like the meeting rows: the supporting grey
    /// does not read on the teal highlight.
    var isSelected = false
    let localize: (String) -> String

    private var supporting: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting))
    }

    var body: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: row.name, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.name).font(.scaled(.body).weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: row.when)
                        .font(AppFont.scaled(.subheadline).monospacedDigit())
                        .foregroundStyle(supporting)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 8) {
                    Text(verbatim: row.detail)
                        .font(.scaled(.callout))
                        .foregroundStyle(supporting)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge = row.badge {
                        LabelChip(text: badge.text(localize: localize), attention: badge.needsAttention,
                                  size: .small, onSelection: isSelected)
                            .layoutPriority(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("people.row.\(row.id)")
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

/// Rename, merge, separate, and hide, on a row's context menu. The page's
/// own menu in the toolbar lists the same corrections after Prepare.
private struct PersonMenuItems: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile
    @ObservedObject var store: PeopleStore
    let onRename: () -> Void
    let onMerge: () -> Void

    var body: some View {
        Button("Rename…", action: onRename)
        Button("Merge into…", action: onMerge)
        let merges = store.merges(into: person)
        if !merges.isEmpty {
            Menu("Separate") {
                ForEach(merges, id: \.sourceID) { merge in
                    Button(merge.sourceName) { store.separate(merge) }
                }
            }
        }
        Divider()
        Button("Not a person") {
            store.hide(person)
            if app.selectedPersonID == person.id { app.selectedPersonID = nil }
        }
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
