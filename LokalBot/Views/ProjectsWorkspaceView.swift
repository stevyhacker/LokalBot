import SwiftUI

/// Projects the person tracks, plus suggestions: names that recur across
/// meetings and overnight review projects nobody tracks yet. Each project is
/// joined to the meetings, actions, decisions, review notes, people, and
/// window time that name it; tracked projects also get a "Where it stands"
/// note written by the Think model.
struct ProjectsWorkspaceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @ObservedObject var store: ProjectStore
    @State private var addingProject = false

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                       idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                .splitPaneAccessibilityLabel("Projects", autosaveName: "LokalBot.projects",
                                             initialWidth: LBTokens.Metric.contentColumnWidth)
            detail
                .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .splitPaneAccessibilityLabel("Project details")
        }
        .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
        .task {
            // Review notes come from Dream memory, which other sections load lazily.
            app.refreshDreamMemory()
            app.refreshConnections()
        }
        .onReceive(app.outcomeIndex.$projections.dropFirst()) { _ in app.refreshConnections() }
        .onChange(of: app.dreamMemory) { app.refreshConnections() }
        .onChange(of: store.curation) { app.refreshConnections() }
        .sheet(isPresented: $addingProject) {
            ProjectNameSheet(title: "Track a Project", actionTitle: "Track", name: "", otherNames: []) { name, others in
                if let id = store.track(name: name, otherNames: others) {
                    app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(id)
                }
            }
        }
    }

    static func trackedSelectionID(_ id: UUID) -> String { "tracked:" + id.uuidString }

    private var tracked: [ProjectProfile] { connections.projects.filter(\.isTracked) }
    private var suggestions: [ProjectProfile] { connections.projects.filter { !$0.isTracked } }

    private var countSummary: String {
        var parts: [String] = []
        if !store.curation.tracked.isEmpty { parts.append("\(store.curation.tracked.count) tracked") }
        if !suggestions.isEmpty { parts.append("\(suggestions.count) suggested") }
        return parts.isEmpty ? "None yet" : parts.joined(separator: " · ")
    }

    private var hiddenLabel: String {
        let count = store.curation.hiddenNames.count
        return "Show \(count) hidden suggestion\(count == 1 ? "" : "s") again"
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects").font(.scaled(.title3).bold())
                    Text(connections.hasLoaded ? countSummary : "Loading…")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addingProject = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Track a project")
                .accessibilityLabel("Track a project")
                .accessibilityIdentifier("projects.add")
            }
            .padding(WorkspaceMetric.cardPadding)
            List(selection: $app.selectedProjectID) {
                Section("Tracked") {
                    if tracked.isEmpty {
                        Text(store.curation.tracked.isEmpty
                             ? "Track a suggestion below, or add a project with +."
                             : "Loading…")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                            .selectionDisabled(true)
                    }
                    ForEach(tracked) { project in
                        ProjectRow(project: project).tag(project.id)
                            .contextMenu { ProjectMenuItems(project: project, store: store) }
                    }
                }
                if !suggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestions) { project in
                            ProjectRow(project: project).tag(project.id)
                                .contextMenu { ProjectMenuItems(project: project, store: store) }
                        }
                    }
                }
                if !store.curation.hiddenNames.isEmpty {
                    Button(hiddenLabel) { store.restoreHiddenSuggestions() }
                        .buttonStyle(.workspaceLink)
                        .font(.scaled(.callout))
                        .selectionDisabled(true)
                }
            }
            .listStyle(.inset)
            .tint(Brand.tealFill)
            .accessibilityIdentifier("projects.list")
            .overlay {
                if connections.hasLoaded && connections.projects.isEmpty && store.curation.tracked.isEmpty {
                    VStack(spacing: 10) {
                        Text("Add the projects you work on, and LokalBot gathers their meetings, actions, and decisions. It also suggests names that come up in \(ProjectTopicDetector.minimumMeetings) or more meetings.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Track a Project") { addingProject = true }
                    }
                    .padding(24)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let project = selectedProject {
            ProjectDetailView(project: project, store: store).id(project.id)
        } else {
            Text(detailPlaceholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedProject: ProjectProfile? {
        guard let id = app.selectedProjectID else { return tracked.first ?? connections.projects.first }
        return connections.projects.first { $0.id == id }
    }

    private var detailPlaceholder: String {
        guard connections.hasLoaded else { return "Loading projects…" }
        // A project tracked a moment ago appears after the next refresh.
        if let id = app.selectedProjectID, id.hasPrefix("tracked:") { return "Loading…" }
        return "Select a project."
    }
}

private struct ProjectRow: View {
    let project: ProjectProfile

    var body: some View {
        HStack(spacing: 10) {
            ProjectMonogram(name: project.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.scaled(.body).weight(.medium)).lineLimit(1)
                Text(ProjectDetailView.summary(project))
                    .font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The project's first letter on a tint chosen from its name.
private struct ProjectMonogram: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        let color = InitialsAvatar.color(for: name)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Track, rename, merge, and hide commands shared by a row's context menu
/// and the detail page's menu.
private struct ProjectMenuItems: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore
    var onRename: (() -> Void)?

    private var otherTracked: [ProjectCuration.TrackedProject] {
        store.curation.tracked.filter { $0.id != project.trackedID }
    }

    var body: some View {
        if let id = project.trackedID {
            if let onRename { Button("Rename…", action: onRename) }
            if !otherTracked.isEmpty {
                Menu("Merge Into") {
                    ForEach(otherTracked) { target in
                        Button(target.name) {
                            store.merge(id, into: target.id)
                            app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(target.id)
                        }
                    }
                }
            }
            Divider()
            Button("Stop Tracking") {
                store.stopTracking(id)
                app.selectedProjectID = nil
            }
        } else {
            Button("Track \(project.name)") {
                if let id = store.track(name: project.name) {
                    app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(id)
                }
            }
            if !store.curation.tracked.isEmpty {
                Menu("Add as a Name Of") {
                    ForEach(store.curation.tracked) { target in
                        Button(target.name) {
                            store.addName(project.name, to: target.id)
                            app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(target.id)
                        }
                    }
                }
            }
            Divider()
            Button("Not a Project") {
                store.hideSuggestion(named: project.name)
                app.selectedProjectID = nil
            }
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore
    @State private var renaming = false
    @State private var showingOlderActions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                if project.isTracked {
                    WhereItStandsSection(project: project, store: store)
                } else {
                    suggestionBanner
                }
                actionSections
                decisionsSection
                reviewNotesSection
                timeSection
                peopleSection
                meetingsSection
                Text(provenance)
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(project.name)
        .accessibilityIdentifier("project.detail")
        .onAppear { app.writeProjectSummary(for: project, automatic: true) }
        .onChange(of: project) { _, updated in app.writeProjectSummary(for: updated, automatic: true) }
        .sheet(isPresented: $renaming) {
            ProjectNameSheet(title: "Rename Project", actionTitle: "Save", name: project.name,
                             otherNames: project.otherNames) { name, others in
                if let id = project.trackedID { store.update(id, name: name, otherNames: others) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ProjectMonogram(name: project.name, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(project.name).font(.scaled(.largeTitle).bold())
                        if !project.isTracked { SuggestedBadge() }
                    }
                    Text(Self.summary(project, long: true))
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    if !project.otherNames.isEmpty {
                        Text("Also: " + project.otherNames.joined(separator: ", "))
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    app.openAsk(query: "What is the latest on \(project.name)?",
                                meetingIDs: project.meetings.isEmpty ? nil : project.meetingIDs)
                } label: {
                    Label("Ask About \(project.name)", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                if project.isTracked {
                    Menu {
                        ProjectMenuItems(project: project, store: store, onRename: { renaming = true })
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("project.menu")
                }
            }
        }
    }

    private var suggestionBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestionReason)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    if let id = store.track(name: project.name) {
                        app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(id)
                    }
                } label: {
                    Label("Track \(project.name)", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.tealFill)
                .accessibilityIdentifier("project.track")
                Button("Not a Project") {
                    store.hideSuggestion(named: project.name)
                    app.selectedProjectID = nil
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("project.hide")
                if !store.curation.tracked.isEmpty {
                    Menu("Add as a Name Of") {
                        ForEach(store.curation.tracked) { target in
                            Button(target.name) {
                                store.addName(project.name, to: target.id)
                                app.selectedProjectID = ProjectsWorkspaceView.trackedSelectionID(target.id)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(WorkspaceMetric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LBTokens.Palette.groupFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(LBTokens.Palette.groupStroke, lineWidth: 0.5))
    }

    private var suggestionReason: String {
        if project.kind == .suggestedReview {
            return "The overnight review saw work on this. Track it to keep its meetings, actions, and a note on where it stands together."
        }
        let count = project.meetings.count
        return "\(project.name) came up in \(count) meeting\(count == 1 ? "" : "s"). Track it to keep a note on where it stands, or hide it if it is not a project."
    }

    @ViewBuilder private var actionSections: some View {
        if !project.myActions.isEmpty {
            WorkspaceSection(title: "Your Actions", icon: "checklist") {
                threadList(project.myActions, showsOwner: false)
            }
        }
        if !project.othersActions.isEmpty || !project.olderOthersActions.isEmpty {
            WorkspaceSection(title: "Waiting on Others", icon: "person.2.badge.gearshape") {
                if project.othersActions.isEmpty {
                    EmptyWorkspaceRow(text: "Nothing from others in the last \(ProjectLinks.recentOthersActionDays) days.")
                } else {
                    threadList(project.othersActions, showsOwner: true)
                }
                if !project.olderOthersActions.isEmpty {
                    if showingOlderActions {
                        Divider()
                        threadList(project.olderOthersActions, showsOwner: true)
                    }
                    Button(showingOlderActions ? "Hide older" : olderActionsLabel) {
                        showingOlderActions.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(.scaled(.callout))
                }
            }
        }
    }

    private var olderActionsLabel: String {
        let count = project.olderOthersActions.count
        return "Show \(count) older action\(count == 1 ? "" : "s") last mentioned over \(ProjectLinks.recentOthersActionDays) days ago"
    }

    private func threadList(_ threads: [ActionThread], showsOwner: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(threads) { thread in
                ActionThreadRow(thread: thread, showsOwner: showsOwner)
                if thread.id != threads.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private var decisionsSection: some View {
        if !project.decisions.isEmpty {
            WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                ForEach(project.decisions) { decision in
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
    }

    @ViewBuilder private var reviewNotesSection: some View {
        if !project.reviewNotes.isEmpty {
            WorkspaceSection(title: "From Overnight Review", icon: "moon.stars") {
                ForEach(project.reviewNotes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        if note.name != project.name {
                            Text(note.name).font(.scaled(.body).weight(.medium))
                        }
                        Text(note.status).textSelection(.enabled)
                        Text(Self.dayLabel(note.lastActiveDay))
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private var timeSection: some View {
        if project.trackedSeconds >= 60 {
            WorkspaceSection(title: "Time This Week", icon: "clock") {
                LabeledContent("Total", value: Self.duration(project.trackedSeconds))
                ForEach(project.days) { day in
                    LabeledContent(Self.dayLabel(day.dayKey), value: Self.duration(day.seconds))
                        .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(project.windows) { window in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(window.title).lineLimit(1)
                            Text(window.app).font(.scaled(.callout)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.duration(window.seconds)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var peopleSection: some View {
        if !project.people.isEmpty {
            WorkspaceSection(title: "People", icon: "person.2") {
                FlowingNames(names: project.people) { name in
                    if let person = app.connections.people.first(where: { $0.name == name }) {
                        app.openPerson(person.id)
                    }
                }
            }
        }
    }

    private var meetingsSection: some View {
        WorkspaceSection(title: "Meetings", icon: "waveform.circle") {
            if project.meetings.isEmpty {
                EmptyWorkspaceRow(text: "No meeting in the last \(WorkMemoryConnections.projectMeetingLookbackDays) days names this project.")
            } else {
                let shown: [ProjectProfile.MeetingRef] = Array(project.meetings.prefix(20))
                VStack(spacing: 0) {
                    ForEach(shown) { meeting in
                        ProjectMeetingRow(meeting: meeting) { seek in app.openMeeting(meeting.id, seek: seek) }
                        if meeting.id != shown.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var provenance: String {
        switch project.kind {
        case .tracked:
            "Linked on this Mac wherever one of the project's names appears in meeting titles, summaries, transcripts, actions, decisions, overnight review projects, and window titles."
        case .suggestedTopic:
            "Suggested because the name recurs in meeting titles, summaries, actions, and decisions. People, apps, and generic terms are left out."
        case .suggestedReview:
            "Suggested because the overnight review named this work and no tracked project covers it."
        }
    }

    /// "19 meetings · 1 yours · last 12 Oct" for tracked projects, and why a
    /// suggestion is offered otherwise.
    static func summary(_ project: ProjectProfile, long: Bool = false) -> String {
        var parts: [String] = []
        let meetings = project.meetings.count
        let meetingsLabel = "\(meetings) meeting\(meetings == 1 ? "" : "s")"
        switch project.kind {
        case .tracked:
            if meetings > 0 { parts.append(meetingsLabel) }
        case .suggestedTopic:
            parts.append("Came up in " + meetingsLabel)
        case .suggestedReview:
            parts.append("Overnight review")
            if meetings > 0 { parts.append(meetingsLabel) }
        }
        if !project.myActions.isEmpty { parts.append("\(project.myActions.count) yours") }
        if long, !project.othersActions.isEmpty { parts.append("\(project.othersActions.count) waiting on others") }
        if long, !project.decisions.isEmpty {
            parts.append("\(project.decisions.count) decision\(project.decisions.count == 1 ? "" : "s")")
        }
        if project.trackedSeconds >= 60 { parts.append(duration(project.trackedSeconds) + " this week") }
        if let last = project.lastActive { parts.append("last " + PersonDetailView.relativeDay(last)) }
        return parts.isEmpty ? "Nothing linked yet" : parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m"
    }

    static func dayLabel(_ key: String) -> String {
        AskDayScope.date(for: key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? key
    }
}

/// The tracked project's "Where it stands" note: overview, cited points,
/// open questions, and when and where it was written.
private struct WhereItStandsSection: View {
    @EnvironmentObject var app: AppState
    let project: ProjectProfile
    @ObservedObject var store: ProjectStore

    private var trackedID: UUID? { project.trackedID }
    private var summary: ProjectStatusSummary? { trackedID.flatMap { store.summaries[$0] } }
    private var isWriting: Bool { trackedID.map { store.writing.contains($0) } ?? false }
    private var error: String? { trackedID.flatMap { store.errors[$0] } }
    private var hasEvidence: Bool { !ProjectStatusGenerator.evidence(for: project).isEmpty }

    var body: some View {
        WorkspaceSection(title: "Where It Stands", icon: "text.alignleft") {
            if let summary {
                note(summary)
            } else if isWriting {
                EmptyWorkspaceRow(text: "Writing a note from the latest meetings and review notes…")
            } else if hasEvidence {
                EmptyWorkspaceRow(text: "No note yet. LokalBot can write one from the meetings and review notes below.")
            } else {
                EmptyWorkspaceRow(text: "Nothing names this project yet. A note can be written once meetings or overnight reviews mention it.")
            }
            if let error {
                Text(error)
                    .font(.scaled(.callout))
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .accessibilityIdentifier("project.summary")
    }

    private func note(_ summary: ProjectStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.overview)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.points) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let meetingID = point.meetingID, let title = point.meetingTitle {
                            Button(Self.citation(title: title, date: point.meetingDate)) {
                                app.openMeeting(meetingID)
                            }
                            .buttonStyle(.workspaceLink)
                            .font(.scaled(.callout))
                        }
                    }
                }
            }
            if !summary.openQuestions.isEmpty {
                Text("Open questions").font(.scaled(.callout).weight(.semibold)).padding(.top, 2)
                ForEach(summary.openQuestions, id: \.self) { question in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("?").foregroundStyle(.secondary)
                        Text(question)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let summary {
                let outdated: Bool = store.summaryState(for: project) == .outdated
                Text(Self.provenance(summary, outdated: outdated))
                    .font(.scaled(.caption))
                    .foregroundStyle(outdated ? AnyShapeStyle(LBTokens.Palette.attentionText) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isWriting {
                ProgressView().controlSize(.small)
            } else if hasEvidence {
                Button(summary == nil ? "Write Note" : "Update") {
                    app.writeProjectSummary(for: project, automatic: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("project.summary.write")
            }
        }
    }

    static func citation(title: String, date: Date?) -> String {
        guard let date else { return title }
        return title + " · " + date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func provenance(_ summary: ProjectStatusSummary, outdated: Bool) -> String {
        let when: String = Date().timeIntervalSince(summary.generatedAt) < 60
            ? "just now" : summary.generatedAt.formatted(.relative(presentation: .named))
        let written: String = "Written \(when) by \(summary.engineName) on \(summary.location). Check the meetings before relying on it."
        return outdated ? "Newer evidence since this was written. " + written : written
    }
}

/// Marks a project LokalBot offered but nobody tracks yet.
private struct SuggestedBadge: View {
    var body: some View {
        Label("Suggested", systemImage: "sparkles")
            .font(.scaled(.caption).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(LBTokens.Palette.groupFill))
            .overlay(Capsule().strokeBorder(LBTokens.Palette.groupStroke, lineWidth: 0.5))
    }
}

/// A meeting that names the project, with the line that does. Transcript
/// lines open the meeting at that moment.
private struct ProjectMeetingRow: View {
    let meeting: ProjectProfile.MeetingRef
    let open: (TimeInterval?) -> Void

    var body: some View {
        Button {
            open(meeting.mention?.seek)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(meeting.title).lineLimit(1)
                    Spacer()
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let mention = meeting.mention {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if mention.seek != nil {
                            Image(systemName: "quote.bubble")
                                .font(.scaled(.caption))
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("Said in the call")
                        }
                        Text(mention.text)
                            .font(.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}

/// Names a tracked project: its main name and other names for the same work.
private struct ProjectNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    @State private var name: String
    @State private var otherNamesText: String
    let onSave: (String, [String]) -> Void

    init(title: String, actionTitle: String, name: String, otherNames: [String],
         onSave: @escaping (String, [String]) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        _name = State(initialValue: name)
        _otherNamesText = State(initialValue: otherNames.joined(separator: ", "))
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.scaled(.title3).bold())
            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("project.name")
                TextField("Other names", text: $otherNamesText,
                          prompt: Text("Codenames or clients, separated by commas"))
                    .accessibilityIdentifier("project.otherNames")
            }
            .formStyle(.columns)
            Text("Meetings, actions, and window titles that use any of these names are linked to the project.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    let others: [String] = otherNamesText.split(separator: ",").map { String($0) }
                    onSave(trimmedName, others)
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

/// Names as quiet link buttons that wrap to the available width.
private struct FlowingNames: View {
    let names: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(names, id: \.self) { name in
            Button(name) { onSelect(name) }
                .buttonStyle(.workspaceLink)
        }
    }
}
