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

    private var countSummary: String {
        let count = connections.people.count
        return "\(count) \(count == 1 ? "person" : "people") from your meetings"
    }

    private var grouped: (recent: [PersonProfile], earlier: [PersonProfile]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        let people = filtered
        return (people.filter { ($0.lastMetAt ?? .distantPast) >= cutoff },
                people.filter { ($0.lastMetAt ?? .distantPast) < cutoff })
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("People").font(.scaled(.title3).bold())
                    Text(connections.hasLoaded ? countSummary : "Loading…")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                TextField("Search people", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("people.search")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedPersonID) {
                let groups = grouped
                if !groups.recent.isEmpty {
                    Section("Last 2 Weeks") {
                        ForEach(groups.recent) { PersonRow(person: $0).tag($0.id) }
                    }
                }
                if !groups.earlier.isEmpty {
                    Section("Earlier") {
                        ForEach(groups.earlier) { PersonRow(person: $0).tag($0.id) }
                    }
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
        HStack(spacing: 10) {
            InitialsAvatar(name: person.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.scaled(.body).weight(.medium)).lineLimit(1)
                Text(meetingSummary)
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            OpenWorkBadge(youOwe: person.myActions.count, theyOwe: person.theirActions.count)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var meetingSummary: String {
        let count = person.meetings.count
        let label = "\(count) meeting\(count == 1 ? "" : "s")"
        guard let last = person.lastMetAt else { return label }
        return label + " · " + PersonDetailView.relativeDay(last)
    }
}

/// Open work between the user and one person, as a compact count.
private struct OpenWorkBadge: View {
    let youOwe: Int
    let theyOwe: Int

    var body: some View {
        if youOwe + theyOwe > 0 {
            Text("\(youOwe + theyOwe)")
                .font(.scaled(.caption).weight(.semibold).monospacedDigit())
                .foregroundStyle(youOwe > 0 ? LBTokens.Palette.attentionText : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill((youOwe > 0 ? LBTokens.Palette.attention : Color.secondary)
                    .opacity(LBTokens.Palette.statusFillOpacity * 1.5)))
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private var help: String {
        var parts: [String] = []
        if youOwe > 0 { parts.append("You owe \(youOwe)") }
        if theyOwe > 0 { parts.append("they owe you \(theyOwe)") }
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

struct PersonDetailView: View {
    @EnvironmentObject var app: AppState
    let person: PersonProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                openWork
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
                WorkspaceSection(title: "Meetings Together", icon: "waveform.circle") {
                    VStack(spacing: 0) {
                        ForEach(person.meetings.prefix(20)) { meeting in
                            Button {
                                app.openMeeting(meeting.id)
                            } label: {
                                HStack {
                                    Text(meeting.title).lineLimit(1)
                                    Spacer()
                                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 5)
                            if meeting.id != person.meetings.prefix(20).last?.id { Divider() }
                        }
                    }
                    if person.meetings.count > 20 {
                        Text("And \(person.meetings.count - 20) earlier meetings.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
                Text("Built on this Mac from calendar attendees, names you gave speakers, and action owners. Email addresses are never shown or shared.")
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(person.name)
        .accessibilityIdentifier("person.detail")

    }

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
        }
    }

    private var stats: String {
        let count = person.meetings.count
        var parts = ["\(count) meeting\(count == 1 ? "" : "s")"]
        if let first = person.meetings.last?.startedAt, count > 1 {
            parts[0] += " since " + first.formatted(.dateTime.month(.abbreviated).day())
        }
        if let last = person.lastMetAt { parts.append("last met " + Self.relativeDay(last)) }
        let open = person.myActions.count + person.theirActions.count
        if open > 0 { parts.append("\(open) open") }
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

    /// Both directions of open work; one quiet line when nothing is open.
    @ViewBuilder private var openWork: some View {
        if person.myActions.isEmpty && person.theirActions.isEmpty {
            WorkspaceSection(title: "Open Work", icon: "checklist") {
                EmptyWorkspaceRow(text: "Nothing open between you and \(person.firstName).")
            }
        } else {
            if !person.myActions.isEmpty {
                threadSection(title: "You Owe \(person.firstName)", icon: "arrow.up.right.circle",
                              threads: person.myActions)
            }
            if !person.theirActions.isEmpty {
                threadSection(title: "\(person.firstName) Owes You", icon: "arrow.down.left.circle",
                              threads: person.theirActions)
            }
        }
    }

    private var latestMeetingWithOutcomes: Meeting? {
        person.meetings.lazy
            .filter { app.outcomeIndex.projection(for: $0.id) != nil }
            .compactMap { ref in app.meetings.first { $0.id == ref.id } }
            .first
    }

    private func threadSection(title: String, icon: String, threads: [ActionThread]) -> some View {
        WorkspaceSection(title: title, icon: icon) {
            VStack(spacing: 0) {
                ForEach(threads) { thread in
                    ActionThreadRow(thread: thread)
                    if thread.id != threads.last?.id { Divider() }
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
