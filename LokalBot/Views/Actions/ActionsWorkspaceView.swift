import SwiftUI

/// The user's own actions from meetings, each said once however many
/// meetings it came up in. The list shows one status at a time in attention
/// order; the pane beside it shows the selected action and the evidence
/// behind it. Status changes and corrections go through `OutcomeIndex` and
/// never alter what was extracted.
struct ActionsWorkspaceView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ActionsWorkspace(connections: app.connections)
    }
}

/// People and Projects publish on their own object, so the page observes it
/// to show an action's people and project as soon as they are known.
private struct ActionsWorkspace: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var connections: WorkMemoryConnections
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("actions.query") private var query = ""
    @SceneStorage("actions.status") private var status = OutcomeStatus.open.rawValue
    @SceneStorage("actions.due") private var due = ActionsListFilter.Due.any.rawValue
    @SceneStorage("actions.personID") private var personID = ""
    @SceneStorage("actions.projectID") private var projectID = ""
    @SceneStorage("actions.meeting") private var meetingTitle = ""
    @SceneStorage("actions.stale") private var staleOnly = false
    @SceneStorage("actions.group") private var grouping = ActionsListFilter.Grouping.due.rawValue
    @SceneStorage("actions.detailsHidden") private var detailsHidden = false
    @State private var cache = ActionsListCache()
    /// Threads whose status just changed here; they stay listed until the
    /// view or its filters change.
    @State private var kept: Set<String> = []
    @State private var anchor: String?
    @State private var lead: String?
    @State private var correction: OutcomeActionReference?
    @State private var pendingStatus: PendingStatusChange?

    /// A status change that reaches into several meetings waits for a yes.
    private struct PendingStatusChange {
        let status: OutcomeStatus
        let threads: [ActionThread]

        var meetingTitles: [String] {
            var seen = Set<UUID>()
            return threads.filter(\.hasMultipleMeetings).flatMap(\.references)
                .filter { seen.insert($0.meetingID).inserted }
                .map(\.meetingTitle)
        }
    }

    private static let listMinWidth: CGFloat = 400
    private static let detailsMinWidth: CGFloat = 280
    private static let detailsMaxWidth: CGFloat = 440

    private var filter: ActionsListFilter {
        get {
            ActionsListFilter(
                status: OutcomeStatus(rawValue: status) ?? .open, query: query,
                due: .init(rawValue: due) ?? .any,
                personID: personID.isEmpty ? nil : personID,
                projectID: projectID.isEmpty ? nil : projectID,
                meetingTitle: meetingTitle.isEmpty ? nil : meetingTitle,
                staleOnly: staleOnly,
                grouping: .init(rawValue: grouping) ?? .due)
        }
        nonmutating set {
            status = newValue.status.rawValue
            query = newValue.query
            due = newValue.due.rawValue
            personID = newValue.personID ?? ""
            projectID = newValue.projectID ?? ""
            meetingTitle = newValue.meetingTitle ?? ""
            staleOnly = newValue.staleOnly
            grouping = newValue.grouping.rawValue
        }
    }

    private var selection: ActionListSelection {
        get { ActionListSelection(chosen: app.actionSelection, anchor: anchor, lead: lead) }
        nonmutating set {
            if app.actionSelection != newValue.chosen { app.actionSelection = newValue.chosen }
            anchor = newValue.anchor
            lead = newValue.lead
        }
    }

    var body: some View {
        // One list serves the rows, the selection and the details pane, and
        // is rebuilt only when what it is made of changes.
        let filter = filter
        let language = app.settings.appLanguage
        let links = cache.links(people: connections.people, projects: connections.projects)
        let content = cache.content(threads: app.outcomeIndex.userActionThreads, filter: filter, links: links,
                                    kept: kept, language: language)
        let current = selection.current(in: content.order)
        HSplitView {
            VStack(spacing: 0) {
                ActionsFilterBar(
                    filter: Binding(get: { self.filter }, set: { self.filter = $0 }),
                    chips: filter.chips(links: links, localize: language.catalog),
                    links: links, meetingTitles: content.meetingTitles)
                Divider()
                ActionsList(
                    content: content, current: Set(current),
                    emptyText: ActionListWording.emptyText(for: filter, localize: language.catalog),
                    offersClearFilters: filter.narrowsList,
                    onClick: { id, command, shift in
                        selection.click(id, command: command, shift: shift, order: content.order)
                    },
                    onMove: { step, extending in
                        selection.move(by: step, extending: extending, order: content.order)
                    },
                    onSelectAll: { selection.selectAll(in: content.order) },
                    onCollapse: { selection.collapse(in: content.order) },
                    onStatus: { requestStatus($0, for: [$1]) },
                    onEdit: { correction = $0.latestReference },
                    onNotMine: markNotMine,
                    onClearFilters: { self.filter.clearFilters() })
                if filter.status == .open, !filter.staleOnly, content.staleCount > 0 {
                    Divider()
                    ActionsStaleBar(summary: ActionListWording.staleSummary(
                        count: content.staleCount, localize: language.catalog)) {
                        self.filter.staleOnly = true
                    }
                }
            }
            .frame(minWidth: Self.listMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .splitPaneAccessibilityLabel("Action list")
            if !detailsHidden {
                ActionDetailsPane(
                    rows: current.compactMap(content.row), links: links, listing: filter.status,
                    listedCount: content.order.count, onStatus: requestStatus,
                    onSelectAll: { selection.selectAll(in: content.order) })
                    .frame(minWidth: Self.detailsMinWidth, idealWidth: LBTokens.Metric.detailsPaneWidth,
                           maxWidth: Self.detailsMaxWidth)
                    .splitPaneAccessibilityLabel("Action details", autosaveName: "LokalBot.actions",
                                                 initialWidth: LBTokens.Metric.detailsPaneWidth)
            }
        }
        .detailSplitMinimumWidth(detailsHidden ? [Self.listMinWidth] : [Self.listMinWidth, Self.detailsMinWidth])
        .navigationTitle("Actions")
        .navigationSubtitle(Text("\(content.openCount) open"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Planning the open actions with Agent moved here from Today.
                if content.openCount > 0 {
                    Button(action: planInAgent) {
                        Label("Plan in Agent…", systemImage: "wand.and.sparkles")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Open a new Agent task with these action threads")
                    .accessibilityIdentifier("outcomes.planInAgent")
                }
                Toggle(isOn: Binding(get: { !detailsHidden }, set: { detailsHidden = !$0 })) {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Details")
                .accessibilityIdentifier("actions.detailsToggle")
            }
        }
        .task {
            app.refreshConnections()
            app.refreshActionCompletionHints()
        }
        .onChange(of: filter) { kept = [] }
        .sheet(item: $correction) { reference in
            ActionEditorSheet(reference: reference)
        }
        .confirmationDialog(
            "Update actions in \(pendingStatus?.meetingTitles.count ?? 0) meetings?",
            isPresented: Binding(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
            titleVisibility: .visible,
            presenting: pendingStatus
        ) { change in
            Button(Self.confirmationTitle(for: change.status)) { applyStatus(change.status, to: change.threads) }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text(verbatim: change.meetingTitles.joined(separator: "\n"))
        }
    }

    private static func confirmationTitle(for status: OutcomeStatus) -> LocalizedStringKey {
        switch status {
        case .done: "Mark all done"
        case .deferred: "Mark all deferred"
        case .open: "Mark all open"
        }
    }

    /// One action said in several meetings changes in each of them, so that
    /// change is confirmed first, for one row or for a batch.
    private func requestStatus(_ status: OutcomeStatus, for threads: [ActionThread]) {
        let changing = threads.filter { $0.status != status || $0.hasMixedStatus }
        guard !changing.isEmpty else { return }
        if changing.contains(where: \.hasMultipleMeetings) {
            pendingStatus = PendingStatusChange(status: status, threads: changing)
        } else {
            applyStatus(status, to: changing)
        }
    }

    private func applyStatus(_ status: OutcomeStatus, to threads: [ActionThread]) {
        var failed: [String] = []
        var reason: String?
        // Changed rows stay where they are; the list closes up when the view changes.
        kept.formUnion(threads.map(\.id))
        withAnimation(WorkspaceMotion.animation(.selection, reduceMotion: reduceMotion)) {
            for thread in threads where !app.outcomeIndex.setStatus(status, thread: thread) {
                failed.append(thread.text)
                reason = reason ?? app.outcomeIndex.lastError
            }
        }
        if failed.isEmpty {
            app.lastError = nil
        } else if threads.count == 1 {
            app.lastError = "Could not update this action thread. " + (reason ?? "The action is no longer available.")
        } else {
            app.lastError = "Could not update: " + failed.joined(separator: "; ")
        }
    }

    /// "Not mine" clears the owner of every mention through the same
    /// correction path as the editor, so the action leaves this list.
    private func markNotMine(_ thread: ActionThread) {
        for change in ActionDetailsPresentation.notMineCorrections(for: thread)
        where !app.outcomeIndex.correctAction(actionID: change.actionID, meetingID: change.meetingID,
                                             text: change.text, owner: change.owner, due: change.due) {
            app.lastError = app.outcomeIndex.lastError ?? "The correction could not be saved."
            return
        }
        app.lastError = nil
    }

    private func planInAgent() {
        guard let plan = ActionThreadPlan.launchContext(
            for: ActionAttentionOrder.sorted(app.outcomeIndex.openUserActionThreads)) else { return }
        app.openAgent(plan)
    }
}

/// Keeps the built list between renders. The page redraws for every change
/// to the app's state; filtering, ordering and wording run again only when
/// the threads, the filter, the people and projects, the day or the
/// interface language change.
@MainActor
private final class ActionsListCache {
    private struct Key: Equatable {
        let threads: [ActionThread]
        let filter: ActionsListFilter
        /// Which build of the links, so two dictionaries are never compared.
        let linksRevision: Int
        let kept: Set<String>
        let day: Date
        let language: AppLanguage
    }

    private var people: [PersonProfile] = []
    private var projects: [ProjectProfile] = []
    private var builtLinks: ActionThreadLinks?
    private var linksRevision = 0
    private var key: Key?
    private var built = ActionsListContent()

    func links(people: [PersonProfile], projects: [ProjectProfile]) -> ActionThreadLinks {
        if let builtLinks, self.people == people, self.projects == projects { return builtLinks }
        let links = ActionThreadLinks(people: people, projects: projects)
        self.people = people
        self.projects = projects
        builtLinks = links
        linksRevision &+= 1
        return links
    }

    func content(threads: [ActionThread], filter: ActionsListFilter, links: ActionThreadLinks,
                 kept: Set<String>, language: AppLanguage, now: Date = Date()) -> ActionsListContent {
        let key = Key(threads: threads, filter: filter, linksRevision: linksRevision, kept: kept,
                      day: Calendar.current.startOfDay(for: now), language: language)
        if key == self.key { return built }
        built = ActionsListContent.build(
            threads: threads, filter: filter, links: links, kept: kept, now: now,
            locale: language.locale, localize: language.catalog)
        self.key = key
        return built
    }
}

private struct ActionEditorSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let reference: OutcomeActionReference
    @State private var text: String
    @State private var owner: String
    @State private var due: String
    @State private var ownerWasEdited = false
    @State private var dueWasEdited = false
    @State private var resolvedDate = Date()
    @State private var error: String?

    init(reference: OutcomeActionReference) {
        self.reference = reference
        _text = State(initialValue: reference.text)
        _owner = State(initialValue: reference.owner ?? "")
        _due = State(initialValue: reference.due ?? "")
        _resolvedDate = State(initialValue: reference.resolvedDueDate ?? Date())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action").font(AppFont.scaled(.largeTitle).bold())
            Text("Action").font(AppFont.scaled(.callout).weight(.semibold))
            TextEditor(text: $text).frame(height: 100).padding(8).workspaceControl()
            LabeledContent("Owner") {
                TextField("Me or named participant", text: Binding(
                    get: { owner },
                    set: { owner = $0; ownerWasEdited = true }))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Due phrase") {
                TextField("Original wording or YYYY-MM-DD", text: Binding(
                    get: { due },
                    set: { due = $0; dueWasEdited = true }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                DatePicker("Resolve date", selection: $resolvedDate, displayedComponents: .date)
                Button("Use date") {
                    due = AskDayScope.key(for: resolvedDate)
                    dueWasEdited = true
                }
            }
            Text("The original action, due phrase and citations stay available.").workspaceTextRole(.supporting)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save correction") {
                    let ownerIntent = ActionCorrectionFieldIntent.persistedValue(
                        owner,
                        wasCorrected: reference.ownerWasCorrected,
                        wasEdited: ownerWasEdited)
                    let dueIntent = ActionCorrectionFieldIntent.persistedValue(
                        due,
                        wasCorrected: reference.dueWasCorrected,
                        wasEdited: dueWasEdited)
                    if app.outcomeIndex.correctAction(
                        actionID: reference.action.id,
                        meetingID: reference.meetingID,
                        text: text,
                        owner: ownerIntent,
                        due: dueIntent
                    ) {
                        dismiss()
                    } else {
                        error = app.outcomeIndex.lastError ?? "The correction could not be saved."
                    }
                }.primaryActionButton().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 530)
    }
}
