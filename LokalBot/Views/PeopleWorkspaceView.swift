import SwiftUI

/// Everyone the user meets, joined across calendar attendees, names applied
/// to speakers, and action owners: what each side owes the other, decisions
/// made together, and the shared meetings behind them.
struct PeopleWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @SceneStorage("people.query") private var query = ""

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("People", autosaveName: "LokalBot.people",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Person details")
        }
        .task { app.refreshConnections() }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.meetings.count) { app.refreshConnections() }
    }

    private var filtered: [PersonProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return connections.people }
        return connections.people.filter { person in
            ([person.name] + person.otherNames).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("People").font(.title3.bold())
                    Text(connections.hasLoaded ? "\(connections.people.count) people" : "Loading…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                TextField("Search people", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("people.search")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedPersonID) {
                ForEach(filtered) { person in
                    PersonRow(person: person).tag(person.id)
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("people.list")
            .overlay {
                if connections.hasLoaded && connections.people.isEmpty {
                    Text("People appear after meetings with calendar attendees, named speakers, or named action owners.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let person = connections.people.first(where: { $0.id == app.selectedPersonID })
            ?? (app.selectedPersonID == nil ? filtered.first : nil) {
            PersonDetailView(person: person)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(person.name).font(.body.weight(.medium))
            Text(meetingSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !person.myActions.isEmpty || !person.theirActions.isEmpty {
                HStack(spacing: 8) {
                    if !person.myActions.isEmpty {
                        Text("You owe \(person.myActions.count)")
                            .foregroundStyle(LBTokens.Palette.attentionText)
                    }
                    if !person.theirActions.isEmpty {
                        Text("Owes you \(person.theirActions.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var meetingSummary: String {
        let count = person.meetings.count
        let label = "\(count) meeting\(count == 1 ? "" : "s")"
        guard let last = person.lastMetAt else { return label }
        return label + " · last " + last.formatted(date: .abbreviated, time: .omitted)
    }
}

struct PersonDetailView: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                threadSection(
                    title: "You Owe \(person.firstName)",
                    icon: "arrow.up.right.circle",
                    threads: person.myActions,
                    empty: "No open commitments of yours name \(person.firstName) or came from a small meeting together.")
                threadSection(
                    title: "\(person.firstName) Owes You",
                    icon: "arrow.down.left.circle",
                    threads: person.theirActions,
                    empty: "No open actions are assigned to \(person.firstName).")
                if !person.decisions.isEmpty {
                    WorkspaceSection(title: "Decisions Together", icon: "checkmark.seal") {
                        ForEach(person.decisions) { decision in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(decision.text).textSelection(.enabled)
                                Button("\(decision.meetingTitle) · \(decision.meetingDate.formatted(date: .abbreviated, time: .omitted))") {
                                    app.openMeeting(decision.meetingID)
                                }
                                .buttonStyle(.workspaceLink)
                                .font(.callout)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                WorkspaceSection(title: "Meetings", icon: "waveform.circle") {
                    ForEach(person.meetings.prefix(20)) { meeting in
                        Button {
                            app.openMeeting(meeting.id)
                        } label: {
                            HStack {
                                Text(meeting.title).lineLimit(1)
                                Spacer()
                                Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                    if person.meetings.count > 20 {
                        Text("And \(person.meetings.count - 20) earlier meetings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(person.name)
        .accessibilityIdentifier("person.detail")

    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(person.name).font(.largeTitle.bold())
            if !person.otherNames.isEmpty {
                Text("Also appears as " + person.otherNames.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    app.openAsk(query: "What is open between me and \(person.name)?",
                                meetingIDs: person.meetingIDs)
                } label: {
                    Label("Ask About \(person.firstName)", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(person.meetings.isEmpty)
                Button {
                    if let meeting = latestMeetingWithOutcomes { app.draftFollowUp(for: meeting) }
                } label: {
                    Label("Draft Follow-up…", systemImage: "arrowshape.turn.up.right")
                }
                .buttonStyle(.bordered)
                .disabled(latestMeetingWithOutcomes == nil)
                .help("Draft a follow-up from your latest meeting with \(person.firstName) that has outcomes")
                Button {
                    app.openAgent(.init(
                        title: "Prepare for \(person.name)",
                        prompt: preparationPrompt,
                        meetingID: person.meetings.first?.id,
                        actionID: nil))
                } label: {
                    Label("Prepare in Agent…", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.bordered)
            }
            Text("Built on this Mac from calendar attendee names, names you applied to speakers, and action owners. Email addresses are not shown or shared.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var latestMeetingWithOutcomes: Meeting? {
        person.meetings.lazy
            .filter { app.outcomeIndex.projection(for: $0.id) != nil }
            .compactMap { ref in app.meetings.first { $0.id == ref.id } }
            .first
    }

    private func threadSection(title: String, icon: String, threads: [ActionThread],
                               empty: String) -> some View {
        WorkspaceSection(title: title, icon: icon) {
            if threads.isEmpty {
                EmptyWorkspaceRow(text: empty)
            } else {
                VStack(spacing: 0) {
                    ForEach(threads) { thread in
                        ActionThreadRow(thread: thread)
                        if thread.id != threads.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var preparationPrompt: String {
        var lines = ["Help me prepare for my next conversation with \(person.name)."]
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
