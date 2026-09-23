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
    private var meetingID: UUID? { UUID(uuidString: storedMeetingID) }
    private var selection: Set<String> {
        get { app.actionSelection }
        nonmutating set { app.actionSelection = newValue }
    }
    @State private var correction: OutcomeActionReference?
    @State private var failures: [String] = []

    private var all: [OutcomeActionReference] {
        app.outcomeIndex.all.flatMap(\.actionReferences).filter(\.isForUser)
    }
    private var visible: [OutcomeActionReference] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { action in
            (status.isEmpty || action.status.rawValue == status)
                && (meetingID == nil || action.meetingID == meetingID)
                && (needle.isEmpty || [action.text, action.meetingTitle, action.due ?? ""].contains { $0.localizedCaseInsensitiveContains(needle) })
                && matchesDue(action)
        }.sorted { lhs, rhs in
            if sort == "due" {
                let left = ActionDuePresentation.date(lhs.due) ?? .distantFuture
                let right = ActionDuePresentation.date(rhs.due) ?? .distantFuture
                if left != right { return left < right }
            }
            if lhs.meetingStartedAt != rhs.meetingStartedAt { return lhs.meetingStartedAt > rhs.meetingStartedAt }
            return lhs.id < rhs.id
        }
    }
    private var inspected: OutcomeActionReference? {
        visible.first { selection.contains($0.id) }
    }
    private var visibleThreads: [ActionThread] {
        let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset) })
        return app.outcomeIndex.userActionThreads.compactMap { thread -> (ActionThread, Int)? in
            guard let position = thread.references.compactMap({ positions[$0.id] }).min() else { return nil }
            return (thread, position)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    private var visibleSelection: [OutcomeActionReference] { visible.filter { selection.contains($0.id) } }
    private var hiddenSelectionCount: Int { selection.count - visibleSelection.count }
    private var listSelection: Binding<Set<String>> {
        Binding(get: { Set(visibleSelection.map(\.id)) }, set: { updated in
            selection = selection.subtracting(visible.map(\.id)).union(updated)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            if !failures.isEmpty {
                Text("Could not update: " + failures.joined(separator: "; "))
                    .workspaceTextRole(.warning).padding(.horizontal, 20)
            }
            if reviewMode == "threads" {
                threadList
            } else {
                actionList
            }
        }
        .navigationTitle("Actions")
        .onChange(of: all.map(\.id)) { app.actionSelection.formIntersection(all.map(\.id)) }
        .sheet(item: $correction) { reference in
            ActionEditorSheet(reference: reference)
        }
    }

    private var threadList: some View {
        VStack(spacing: 8) {
            Text("Matching threads retain all linked sources. Review their source meetings before applying a status to the whole thread.")
                .workspaceTextRole(.supporting).padding(.horizontal, 20)
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

    private var actionList: some View {
        HSplitView {
            List(selection: listSelection) {
                ForEach(visible) { reference in
                    OutcomeOverviewActionRow(reference: reference).tag(reference.id)
                        .contextMenu {
                            Button("Correct action…") { correction = reference }
                            Button("Show details") { selection = [reference.id] }
                        }
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
                inspector(inspected).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                    .splitPaneAccessibilityLabel("Action details")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { app.showingActions = false } label: { Label("Today", systemImage: "chevron.left") }
            Text("Actions").font(WorkspaceTypography.pageTitle)
            Text(reviewMode == "threads" ? "\(visibleThreads.count) threads" : "\(visible.count) of \(all.count)")
                .foregroundStyle(.secondary)
            Spacer()
            if reviewMode == "actions" {
                if visibleSelection.isEmpty {
                    Text("Select actions to change several at once (⌘-click)")
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("actions.batch.hint")
                } else {
                    Menu("Change \(CountLabel.format(visibleSelection.count, "selected action"))") {
                        ForEach(OutcomeStatus.allCases, id: \.rawValue) { next in
                            Button(next.label) {
                                failures = app.outcomeIndex.setStatus(next, for: visibleSelection)
                            }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("actions.batch")
                }
            }
        }.padding(20)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Review", selection: $reviewMode) {
                    Text("Actions").tag("actions")
                    Text("Threads").tag("threads")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    .accessibilityIdentifier("actions.reviewMode")
                TextField("Search actions and meetings", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("actions.search")
            }
            ViewThatFits(in: .horizontal) {
                HStack { statusPicker; duePicker; meetingPicker; sortPicker }
                VStack { HStack { statusPicker; duePicker }; HStack { meetingPicker; sortPicker } }
            }
            if hiddenSelectionCount > 0 && reviewMode == "actions" {
                HStack {
                    Text("\(hiddenSelectionCount) selected outside these filters.")
                        .accessibilityIdentifier("actions.selection.hidden")
                    Button("Clear selection") { selection = [] }
                    Spacer()
                }.font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
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
    private var sortPicker: some View {
        Picker("Sort", selection: $sort) {
            Text("Due, then recent").tag("due")
            Text("Most recent").tag("recent")
        }
    }

    private func matchesDue(_ action: OutcomeActionReference) -> Bool {
        let date = ActionDuePresentation.date(action.due)
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
                Text(reference.text).font(WorkspaceTypography.sectionTitle).textSelection(.enabled)
                Text(reference.meetingTitle).foregroundStyle(.secondary)
                LabeledContent("Owner", value: reference.owner.map(SpeakerDisplayName.label) ?? "Not stated")
                if let due = reference.due { Text(ActionDuePresentation.label(due, spokenAt: reference.meetingStartedAt)) }
                Button("Correct action or resolve date…") { correction = reference }
                Divider()
                Text("Original wording").font(WorkspaceTypography.metadataEmphasis)
                Text(reference.action.displayText).textSelection(.enabled)
                if let originalDue = reference.action.due { Text("Original due phrase: \(originalDue)") }
                ForEach(reference.action.citations) { citation in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(citation.excerpt).textSelection(.enabled)
                        Button("Show passage · \(Transcript.stamp(citation.start))") {
                            app.openMeeting(reference.meetingID, seek: citation.start)
                        }
                    }
                }
                if reference.action.citations.isEmpty { Text("No supporting passage was stored.").foregroundStyle(.secondary) }
            }.padding(20)
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
    @State private var resolvedDate = Date()
    @State private var error: String?

    init(reference: OutcomeActionReference) {
        self.reference = reference
        _text = State(initialValue: reference.text)
        _owner = State(initialValue: reference.owner ?? "")
        _due = State(initialValue: reference.due ?? "")
        _resolvedDate = State(initialValue: ActionDuePresentation.date(reference.due) ?? Date())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action").font(WorkspaceTypography.pageTitle)
            Text("Action").font(WorkspaceTypography.metadataEmphasis)
            TextEditor(text: $text).frame(height: 100).padding(8).workspaceControl()
            LabeledContent("Owner") { TextField("Me or named participant", text: $owner).textFieldStyle(.roundedBorder) }
            LabeledContent("Due phrase") { TextField("Original wording or YYYY-MM-DD", text: $due).textFieldStyle(.roundedBorder) }
            HStack {
                DatePicker("Resolve date", selection: $resolvedDate, displayedComponents: .date)
                Button("Use date") { due = AskDayScope.key(for: resolvedDate) }
            }
            Text("The original action, due phrase and citations stay available.").workspaceTextRole(.supporting)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save correction") {
                    if app.outcomeIndex.correctAction(actionID: reference.action.id, meetingID: reference.meetingID,
                                                     text: text, owner: owner, due: due) { dismiss() } else { error = app.outcomeIndex.lastError ?? "The correction could not be saved." }
                }.primaryActionButton().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 530)
    }
}
