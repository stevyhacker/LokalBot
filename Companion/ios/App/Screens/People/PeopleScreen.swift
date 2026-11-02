import LokalBotCompanionKit
import SwiftUI

struct PeopleSplit: View {
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: PersonRoute?

    var body: some View {
        NavigationSplitView {
            PeopleList(selection: $selection)
        } detail: {
            NavigationStack {
                if let selection {
                    PersonDetailScreen(personID: selection.id).companionDestinations()
                } else {
                    ContentUnavailableView("Choose a person", systemImage: "person.2",
                                           description: Text("Open work, decisions and meetings you share."))
                }
            }
            .id(selection)
        }
        .onAppear(perform: consumeSelection)
        .onChange(of: navigator.personSelection) { consumeSelection() }
    }

    private func consumeSelection() {
        guard let id = navigator.personSelection else { return }
        selection = PersonRoute(id: id)
        navigator.personSelection = nil
    }
}

/// People, most recently met first. In a split view the list selects; in a
/// stack (More on iPhone) rows push.
struct PeopleList: View {
    @Environment(CompanionSession.self) private var session
    let selection: Binding<PersonRoute?>?
    @State private var model = PeopleModel()

    var body: some View {
        Group {
            if let selection {
                List(selection: selection) { rows }
            } else {
                List { rows }
            }
        }
        .listStyle(.plain)
        .tint(Brand.tealFill)
        .overlay {
            if model.loaded && model.people.isEmpty {
                ContentUnavailableView("No people yet", systemImage: "person.2",
                                       description: Text("People from your meetings appear here after a sync."))
            }
        }
        .navigationTitle("People")
        .refreshable { await session.syncNow() }
        .task(id: session.revision) { await model.load(session) }
    }

    private var rows: some View {
        ForEach(model.people) { person in
            NavigationLink(value: PersonRoute(id: person.id)) {
                PersonRow(person: person, today: session.today)
            }
        }
    }
}

struct PersonRow: View {
    let person: Person
    let today: DayKey

    var body: some View {
        let yours = person.openWork.filter { !$0.theirs }.count
        let theirs = person.openWork.filter(\.theirs).count
        HStack(spacing: 12) {
            InitialsAvatar(name: person.displayName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName).font(LBTokens.Typography.body.weight(.medium)).lineLimit(1)
                Text(summary(yours: yours, theirs: theirs))
                    .font(LBTokens.Typography.secondary)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func summary(yours: Int, theirs: Int) -> String {
        var parts: [String] = []
        if let met = person.lastMetAt {
            parts.append("Met \(LBFormat.current.dayTitle(DayKey(met), today: today).lowercasedFirstWordIfRelative)")
        }
        if yours > 0 { parts.append("\(yours) waiting on you") }
        if theirs > 0 { parts.append("\(theirs) waiting on \(person.firstName)") }
        return parts.joined(separator: " · ")
    }
}

extension String {
    /// "Met today", "Met yesterday", but "Met Tuesday".
    var lowercasedFirstWordIfRelative: String {
        ["Today", "Yesterday"].contains(self) ? lowercased() : self
    }
}

struct PersonDetailScreen: View {
    let personID: String
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @State private var model: PersonDetailModel

    init(personID: String) {
        self.personID = personID
        _model = State(initialValue: PersonDetailModel(personID: personID))
    }

    private let format = LBFormat.current

    var body: some View {
        ScrollView {
            if let person = model.person {
                VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
                    header(person)
                    openWork(person, theirs: false)
                    openWork(person, theirs: true)
                    if !person.decisionsTogether.isEmpty {
                        WorkspaceSection("Decisions Together", icon: "checkmark.seal") {
                            ForEach(Array(person.decisionsTogether.enumerated()), id: \.offset) { _, decision in
                                LinkedTextRow(text: decision.text, meeting: model.meetings[decision.meetingId],
                                              meetingID: decision.meetingId)
                            }
                        }
                    }
                    WorkspaceSection("Meetings Together", icon: "waveform.circle") {
                        if model.meetingsTogether.isEmpty {
                            EmptyWorkspaceRow("\(person.firstName) appears only as an action owner.")
                        } else {
                            MeetingLinkList(meetings: model.meetingsTogether)
                        }
                    }
                }
                .pageColumn(maxWidth: 760)
            } else if model.loaded {
                ContentUnavailableView("Not on this device", systemImage: "person.2")
                    .padding(.top, 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let person = model.person {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.ask(about: nil, draft: "What's open between me and \(person.firstName)?")
                    } label: {
                        Label("Ask About \(person.firstName)", systemImage: "sparkle.magnifyingglass")
                    }
                }
            }
        }
        .refreshable { await session.syncNow() }
        .task(id: session.revision) { await model.load(session) }
    }

    private func header(_ person: Person) -> some View {
        HStack(spacing: 14) {
            InitialsAvatar(name: person.displayName, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName).font(LBTokens.Typography.pageTitle).lineLimit(2)
                if let met = person.lastMetAt {
                    Text("Last met \(format.dayTitle(DayKey(met), today: session.today).lowercasedFirstWordIfRelative)")
                        .font(LBTokens.Typography.secondary)
                        .workspaceSupportingForeground()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func openWork(_ person: Person, theirs: Bool) -> some View {
        let items = person.openWork.filter { $0.theirs == theirs }
        if !items.isEmpty {
            WorkspaceSection(theirs ? "Waiting on \(person.firstName)" : "Waiting on You",
                             icon: theirs ? "arrow.down.left.circle" : "arrow.up.right.circle") {
                OpenWorkList(items: items.map {
                    OpenWorkItem(meetingID: $0.meetingId, actionID: $0.actionId, text: $0.text, dueDate: $0.dueDate,
                                 owner: theirs ? person.displayName : nil, status: .open)
                }, meetings: model.meetings)
            }
        }
    }
}

/// An open action summarized on a person or project page.
struct OpenWorkItem: Hashable {
    let meetingID: String
    let actionID: String
    let text: String
    let dueDate: String?
    let owner: String?
    let status: ActionStatus
}

/// Open actions with toggles, due dates and their meeting.
struct OpenWorkList: View {
    @Environment(CompanionSession.self) private var session
    let items: [OpenWorkItem]
    let meetings: [String: Meeting]
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 2) {
                    ActionCheck(isDone: item.status == .done) { toggle(item) }
                        .padding(.top, -10)
                        .padding(.leading, -10)
                    NavigationLink(value: ActionRoute(meetingID: item.meetingID, actionID: item.actionID)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .font(LBTokens.Typography.body)
                                .strikethrough(item.status == .done)
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                            FlowLayout(spacing: 8, lineSpacing: 4) {
                                if let owner = item.owner { Text(owner) }
                                if let due = LBFormat.current.due(item.dueDate, status: item.status, today: session.today) {
                                    Text(due.text).foregroundStyle(due.isOverdue ? LBTokens.Palette.recordingText : LBTokens.Palette.supporting)
                                }
                                if let meeting = meetings[item.meetingID] {
                                    Text(meeting.title).lineLimit(1)
                                }
                            }
                            .font(LBTokens.Typography.secondary)
                            .foregroundStyle(LBTokens.Palette.supporting)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                if item != items.last { Divider() }
            }
            if let error { Text(error).workspaceTextRole(.warning).padding(.vertical, 6) }
        }
    }

    private func toggle(_ item: OpenWorkItem) {
        Task {
            do {
                try await session.setActionStatus(item.status == .done ? .open : .done,
                                                   meetingID: item.meetingID, actionID: item.actionID)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A decision or other text with the meeting it came from.
struct LinkedTextRow: View {
    let text: String
    let meeting: Meeting?
    let meetingID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(LBTokens.Typography.body).fixedSize(horizontal: false, vertical: true)
            if let meeting {
                NavigationLink(value: MeetingRoute(id: meetingID)) {
                    Text("\(meeting.title) · \(LBFormat.current.shortDate(DayKey(meeting.day) ?? DayKey(meeting.startedAt)))")
                        .lineLimit(1)
                }
                .buttonStyle(.workspaceLink)
                .font(LBTokens.Typography.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Meetings as links, newest first.
struct MeetingLinkList: View {
    let meetings: [Meeting]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(meetings) { meeting in
                NavigationLink(value: MeetingRoute(id: meeting.id)) {
                    HStack {
                        MeetingRowView(meeting: meeting, showsDay: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lbHoverEffect()
                if meeting.id != meetings.last?.id { Divider() }
            }
        }
    }
}
