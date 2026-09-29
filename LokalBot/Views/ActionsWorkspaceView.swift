import SwiftUI

/// Full personal-action review under Today. It reads every projection, while
/// the Today preview stays deliberately small. Corrections never alter evidence.
struct ActionsWorkspaceView: View {
    @EnvironmentObject private var app: AppState
    @SceneStorage("actions.query") private var query = ""
    @SceneStorage("actions.status") private var status = "open"
    @SceneStorage("actions.due") private var dueFilter = "all"
    @SceneStorage("actions.sort") private var sort = "due"
    @SceneStorage("actions.reviewMode") private var reviewMode = "actions"
    @SceneStorage("actions.meetingID") private var storedMeetingID = ""
    @SceneStorage("actions.personID") private var personID = ""
    private var meetingID: UUID? { UUID(uuidString: storedMeetingID) }
    /// The user's open actions that name a person or came from a small
    /// meeting with them, using the same rules as the People workspace.
    private var personActionIDs: Set<String>? {
        guard !personID.isEmpty,
              let person = app.connections.people.first(where: { $0.id == personID }) else { return nil }
        return Set(person.myActions.flatMap(\.references).map(\.id))
    }
    private var selection: Set<String> {
        get { app.actionSelection }
        nonmutating set { app.actionSelection = newValue }
    }
    @State private var correction: OutcomeActionReference?
    @State private var failures: [String] = []
    /// Shows a checkbox per row so several actions can be chosen without ⌘-click.
    @State private var selecting = false

    private var all: [OutcomeActionReference] {
        app.outcomeIndex.all.flatMap(\.actionReferences).filter(\.isForUser)
    }
    private func visibleActions(in actions: [OutcomeActionReference]) -> [OutcomeActionReference] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let personActionIDs = personActionIDs
        return actions.filter { action in
            (status.isEmpty || action.status.rawValue == status)
                && (meetingID == nil || action.meetingID == meetingID)
                && (personActionIDs?.contains(action.id) ?? true)
                && (needle.isEmpty || [action.text, action.meetingTitle, action.due ?? ""].contains { $0.localizedCaseInsensitiveContains(needle) })
                && matchesDue(action)
        }.sorted { lhs, rhs in
            if sort != "recent" {
                return ActionDueSort(order: sort == "dueDescending" ? .reverse : .forward)
                    .compare(lhs, rhs) == .orderedAscending
            }
            if lhs.meetingStartedAt != rhs.meetingStartedAt { return lhs.meetingStartedAt > rhs.meetingStartedAt }
            return lhs.id < rhs.id
        }
    }
    private var tableSort: Binding<[ActionDueSort]> {
        Binding(get: {
            sort == "recent" ? [] : [ActionDueSort(order: sort == "dueDescending" ? .reverse : .forward)]
        }, set: { comparators in
            sort = comparators.first.map { $0.order == .forward ? "due" : "dueDescending" } ?? "recent"
        })
    }
    private func threads(matching visible: [OutcomeActionReference]) -> [ActionThread] {
        let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset) })
        return app.outcomeIndex.userActionThreads.compactMap { thread -> (ActionThread, Int)? in
            guard let position = thread.references.compactMap({ positions[$0.id] }).min() else { return nil }
            return (thread, position)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    private func listSelection(visibleIDs: Set<String>) -> Binding<Set<String>> {
        // AppKit reads selection repeatedly while building table accessibility.
        // Capture this render's IDs so those reads never rebuild/sort the library.
        Binding(get: { selection.intersection(visibleIDs) }, set: { updated in
            selection = selection.subtracting(visibleIDs).union(updated)
        })
    }

    var body: some View {
        // Share one projection across counts, selection, rows, and the inspector.
        let actions = all
        let visible = visibleActions(in: actions)
        let visibleIDs = Set(visible.map(\.id))
        let selected = visible.filter { selection.contains($0.id) }
        let visibleThreads = reviewMode == "threads" ? threads(matching: visible) : []
        VStack(spacing: 0) {
            header(total: actions.count, visible: visible.count, threads: visibleThreads.count, selected: selected)
            filters(hiddenSelectionCount: selection.count - selected.count)
            if !failures.isEmpty {
                Text("Could not update: " + failures.joined(separator: "; "))
                    .workspaceTextRole(.warning).padding(.horizontal, 20)
            }
            if reviewMode == "threads" {
                threadList(visibleThreads)
            } else {
                actionList(visible, visibleIDs: visibleIDs, inspected: selected.first)
            }
        }
        .navigationTitle("Actions")
        .task {
            app.refreshConnections()
            app.refreshActionCompletionHints()
        }
        .onChange(of: actions.map(\.id)) { _, ids in app.actionSelection.formIntersection(ids) }
        .sheet(item: $correction) { reference in
            ActionEditorSheet(reference: reference)
        }
    }

    private func threadList(_ visibleThreads: [ActionThread]) -> some View {
        VStack(spacing: 8) {
            Text("A thread groups the same action across meetings. Changing its status updates every linked meeting.")
                .workspaceTextRole(.supporting)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            List(visibleThreads) { thread in
                ActionThreadRow(thread: thread)
            }
            .accessibilityIdentifier("actions.threads")
            .accessibilityLabel("Action threads")
            .overlay {
                if visibleThreads.isEmpty {
                    ContentUnavailableView("No matching threads", systemImage: "checklist",
                                           description: Text("Choose All statuses to review completed and deferred actions."))
                }
            }
        }
    }

    private func actionList(
        _ visible: [OutcomeActionReference],
        visibleIDs: Set<String>,
        inspected: OutcomeActionReference?
    ) -> some View {
        HSplitView {
            Table(visible, selection: listSelection(visibleIDs: visibleIDs), sortOrder: tableSort) {
                TableColumn("") { reference in
                    HStack(spacing: 6) {
                        if selecting { selectionToggle(reference.id) }
                        Button { setStatus(reference.status == .done ? .open : .done, for: reference) } label: {
                            Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: LBTokens.Metric.actionToggleSize))
                                .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(reference.status == .done ? "Reopen action" : "Complete action")
                        .accessibilityValue(reference.text)
                        .accessibilityIdentifier("outcome.action.toggle.\(reference.id)")
                    }
                    .frame(minHeight: LBTokens.Metric.tableRowHeight)
                }.width(selecting ? 64 : 28)
                TableColumn("Action") { reference in
                    Text(reference.text).lineLimit(1)
                        .strikethrough(reference.status == .done)
                        .help(reference.text)
                        .accessibilityIdentifier("outcome.action.\(reference.id)")
                }.width(min: 150, ideal: 300)
                TableColumn("Owner") { reference in
                    Text(reference.owner.map { SpeakerDisplayName.label($0, identity: reference.isForUser ? .user : .unresolved) } ?? "Owner unclear")
                        .foregroundStyle(reference.owner == nil ? LBTokens.Palette.attentionText : .secondary)
                }.width(90)
                TableColumn("Due", sortUsing: ActionDueSort()) { reference in
                    Text(reference.due.map { ActionDuePresentation.label($0, spokenAt: reference.dueReferenceDate) } ?? "—")
                        .foregroundStyle(isOverdue(reference) ? LBTokens.Palette.recordingText : .secondary)
                }.width(110)
                TableColumn("Meeting") { reference in
                    Button(reference.meetingTitle) { app.openMeeting(reference.meetingID) }
                        .buttonStyle(.plain).lineLimit(1).help(reference.meetingTitle)
                }.width(160)
                TableColumn("Passage") { reference in
                    if let citation = reference.action.citations.first {
                        EvidencePill(citation: citation) { app.openMeeting(reference.meetingID, seek: citation.start) }
                    }
                }.width(100)
                TableColumn("") { reference in
                    Menu {
                        ForEach(OutcomeStatus.allCases, id: \.rawValue) { next in
                            Button(next.label) { setStatus(next, for: reference) }
                        }
                        Divider()
                        Button("Correct Action…") { correction = reference }
                        Button("Show Details") { selection = [reference.id] }
                        Button("Open Meeting") { app.openMeeting(reference.meetingID) }
                        Button("Open in Agent") {
                            app.openAgent(.init(title: reference.text,
                                prompt: "Help me complete this action from \(reference.meetingTitle): \(reference.text)",
                                meetingID: reference.meetingID, actionID: reference.action.id))
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel("Action options")
                    .accessibilityIdentifier("outcome.action.status.\(reference.id)")
                }.width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .tint(Brand.tealFill)
            .contextMenu(forSelectionType: String.self) { ids in
                if let reference = visible.first(where: { ids.contains($0.id) }) {
                    Button("Correct Action…") { correction = reference }
                    Button("Show Details") { selection = [reference.id] }
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
            .accessibilityIdentifier("actions.list")
            .accessibilityLabel("Actions")
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("No matching actions", systemImage: "checklist",
                                           description: Text("Choose All statuses to review completed and deferred actions."))
                }
            }
            .splitPaneAccessibilityLabel("Action list")
            if let inspected {
                inspector(inspected).frame(minWidth: 280, idealWidth: LBTokens.Metric.detailsPaneWidth, maxWidth: 380)
                    .splitPaneAccessibilityLabel("Action details", autosaveName: "LokalBot.actions", initialWidth: LBTokens.Metric.detailsPaneWidth)
            }
        }
    }

    private func header(total: Int, visible: Int, threads: Int, selected: [OutcomeActionReference]) -> some View {
        HStack(spacing: 12) {
            Button { app.showingActions = false } label: { Label("Today", systemImage: "chevron.left") }
            Text("Actions").font(.scaled(.title3).bold())
            Text(reviewMode == "threads" ? "\(threads) threads" : "\(visible) of \(total)")
                .foregroundStyle(.secondary)
            Spacer()
            if reviewMode == "actions" {
                if selected.isEmpty {
                    if selecting {
                        Text("Choose actions to change together")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("actions.batch.hint")
                    }
                } else {
                    Menu("Change \(CountLabel.format(selected.count, "selected action"))") {
                        ForEach(OutcomeStatus.allCases, id: \.rawValue) { next in
                            Button(next.label) {
                                failures = app.outcomeIndex.setStatus(next, for: selected)
                            }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("actions.batch")
                }
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    if !selecting { selection = [] }
                }
                .help(selecting ? "Stop selecting actions" : "Select several actions to change their status together")
                .accessibilityIdentifier("actions.selectMode")
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func filters(hiddenSelectionCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Review", selection: $reviewMode) {
                    Text("Actions").tag("actions")
                    Text("Threads").tag("threads")
                }.pickerStyle(.menu).frame(width: 170)
                    .accessibilityIdentifier("actions.reviewMode")
                TextField("Search actions and meetings", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("actions.search")
            }
            ViewThatFits(in: .horizontal) {
                HStack { statusPicker; duePicker; meetingPicker; personPicker; sortPicker }
                VStack {
                    HStack { statusPicker; duePicker; personPicker }
                    HStack { meetingPicker; sortPicker }
                }
            }
            if hiddenSelectionCount > 0 && reviewMode == "actions" {
                HStack {
                    Text("\(hiddenSelectionCount) selected outside these filters.")
                        .accessibilityIdentifier("actions.selection.hidden")
                    Button("Clear selection") { selection = [] }
                    Spacer()
                }.font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }
    private func selectionToggle(_ id: String) -> some View {
        let isSelected = selection.contains(id)
        return Button {
            if isSelected { selection.remove(id) } else { selection.insert(id) }
        } label: {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Brand.teal : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Deselect action" : "Select action")
        .accessibilityIdentifier("actions.select.\(id)")
    }

    private var statusPicker: some View {
        Picker("Status", selection: $status) {
            Text("All").tag("")
            ForEach(OutcomeStatus.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }.accessibilityIdentifier("actions.status")
    }
    private var duePicker: some View {
        Picker("Due", selection: $dueFilter) {
            Text("Any").tag("all")
            Text("Overdue").tag("overdue")
            Text("Known date").tag("dated")
            Text("Resolve date").tag("unresolved")
        }
    }
    private var meetingPicker: some View {
        Picker("Meeting", selection: Binding(get: { meetingID }, set: { storedMeetingID = $0?.uuidString ?? "" })) {
            Text("All meetings").tag(nil as UUID?)
            ForEach(app.outcomeIndex.all) { Text($0.meeting.displayTitle).tag(Optional($0.id)) }
        }
    }
    private var personPicker: some View {
        Picker("With", selection: $personID) {
            Text("Anyone").tag("")
            ForEach(app.connections.people.filter { !$0.myActions.isEmpty || $0.id == personID }) { person in
                Text(person.name).tag(person.id)
            }
        }
        .accessibilityIdentifier("actions.person")
        .help("Your commitments that name this person or came from a small meeting with them")
    }
    private var sortPicker: some View {
        Picker("Sort", selection: $sort) {
            Text("Due, then recent").tag("due")
            Text("Latest due first").tag("dueDescending")
            Text("Most recent").tag("recent")
        }
    }

    private func matchesDue(_ action: OutcomeActionReference) -> Bool {
        guard dueFilter != "all" else { return true }
        let date = action.resolvedDueDate
        switch dueFilter {
        case "overdue": return date.map { $0 < Calendar.current.startOfDay(for: Date()) } == true && action.status == .open
        case "dated": return date != nil
        case "unresolved": return action.due != nil && date == nil
        default: return true
        }
    }

    private func inspector(_ reference: OutcomeActionReference) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Action Details").font(.scaled(.title3).bold())
                Text(reference.text).font(.scaled(.body).weight(.semibold)).textSelection(.enabled)
                Button(reference.meetingTitle) { app.openMeeting(reference.meetingID) }
                    .buttonStyle(.workspaceLink)
                Picker("Status", selection: Binding(get: { reference.status }, set: { setStatus($0, for: reference) })) {
                    ForEach(OutcomeStatus.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                LabeledContent(
                    "Owner",
                    value: reference.owner.map {
                        SpeakerDisplayName.label(
                            $0,
                            identity: reference.isForUser ? .user : .unresolved)
                    } ?? "Not stated")
                if let due = reference.due { Text(ActionDuePresentation.label(due, spokenAt: reference.dueReferenceDate)) }
                Button("Correct Action or Resolve Date…") { correction = reference }
                Divider()
                Text("Original Wording").font(AppFont.scaled(.callout).weight(.semibold))
                Text(reference.action.displayText).textSelection(.enabled)
                if let originalDue = reference.action.due { Text("Original due phrase: \(originalDue)") }
                ActionEvidencePassages(reference: reference).id(reference.id)
                Text("Saved corrections stay separate from the original action and its supporting passage.")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
                if reference.action.citations.isEmpty { Text("No supporting passage was stored.").foregroundStyle(.secondary) }
            }.padding(20)
        }
        .background(.background.secondary)
    }

    private func isOverdue(_ reference: OutcomeActionReference) -> Bool {
        reference.status == .open && reference.resolvedDueDate.map {
            $0 < Calendar.current.startOfDay(for: Date())
        } == true
    }

    private func setStatus(_ status: OutcomeStatus, for reference: OutcomeActionReference) {
        if app.outcomeIndex.setStatus(status, actionID: reference.action.id, meetingID: reference.meetingID) {
            app.lastError = nil
        } else {
            app.lastError = "Could not update this action. " + (app.outcomeIndex.lastError ?? "The action is no longer available.")
        }
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
