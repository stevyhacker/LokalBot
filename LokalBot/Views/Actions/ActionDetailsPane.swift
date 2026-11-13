import SwiftUI

/// The pane beside the Actions list. One selected action shows what the app
/// knows about it; several show the changes that apply to all of them.
struct ActionDetailsPane: View {
    let rows: [ActionsListContent.Row]
    let links: ActionThreadLinks
    /// The status the list is showing, which decides what a batch offers.
    let listing: OutcomeStatus
    let listedCount: Int
    let onStatus: (OutcomeStatus, [ActionThread]) -> Void
    let onSelectAll: () -> Void

    var body: some View {
        Group {
            if rows.count > 1 {
                ActionBatchDetails(rows: rows, listing: listing, listedCount: listedCount,
                                   onStatus: onStatus, onSelectAll: onSelectAll)
            } else if let row = rows.first {
                ActionThreadDetails(thread: row.thread, links: links) { onStatus($0, [row.thread]) }
            } else {
                Text("No action selected")
                    .font(.scaled(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("actions.details.empty")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }
}

private struct ActionThreadDetails: View {
    @EnvironmentObject private var app: AppState
    let thread: ActionThread
    let links: ActionThreadLinks
    let onStatus: (OutcomeStatus) -> Void
    @State private var choosingDue = false
    @State private var dueDraft = Date()

    private var language: AppLanguage { app.settings.appLanguage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(thread.text)
                    .font(.scaled(.title3).weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("actions.details.title")
                if let hint = app.actionCompletionHints[thread.id] {
                    completionHint(hint)
                }
                properties
                mentions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func completionHint(_ hint: ActionCompletionHint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Brand.teal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                (Text("Looks done?").bold() + Text(verbatim: " " + ActionListWording.completionHintSentence(
                    hint, locale: language.locale, localize: language.catalog)))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Mark Done") { onStatus(.done) }
                    Button("Show the screen") { app.openScreenSnapshot(hint.snapshotID) }
                    Button("Not Yet") { app.dismissActionCompletionHint(hint) }
                }
                .buttonStyle(.workspaceLink)
            }
        }
        .font(AppFont.scaled(.callout))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(Brand.teal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actions.details.completionHint")
    }

    private var properties: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                label("Status")
                HStack(spacing: 8) {
                    Picker("Status", selection: Binding(get: { thread.status }, set: { onStatus($0) })) {
                        ForEach([OutcomeStatus.open, .deferred, .done], id: \.self) { status in
                            Text(LocalizedStringKey(status.stateKey)).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("actions.details.status")
                    if thread.hasMixedStatus {
                        Text("Mixed status")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                label("Due")
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        dueDraft = thread.resolvedDueDate ?? Date()
                        choosingDue = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: ActionDetailsPresentation.dueTitle(
                                for: thread, locale: language.locale, localize: language.catalog))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("actions.details.due")
                    .popover(isPresented: $choosingDue, arrowEdge: .bottom) { duePicker }
                    dueNote
                }
            }
            let people = links.people(for: thread)
            if !people.isEmpty {
                GridRow {
                    label("With")
                    linkColumn(people, identifier: "actions.details.person") { app.openPerson($0) }
                }
            }
            let projects = links.projects(for: thread)
            if !projects.isEmpty {
                GridRow {
                    label("Project")
                    linkColumn(projects, identifier: "actions.details.project") { app.openProject($0) }
                }
            }
        }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(AppFont.scaled(.callout))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    /// What was said about the date, led by "Overdue." while it is.
    @ViewBuilder private var dueNote: some View {
        if let note = dueNoteText {
            note
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var dueNoteText: Text? {
        let said = ActionDetailsPresentation.dueNote(for: thread, localize: language.catalog)
        let late = thread.isOverdue()
            ? Text("Overdue.").bold().foregroundStyle(LBTokens.Palette.recordingText) : nil
        switch (late, said) {
        case let (late?, said?): return late + Text(verbatim: " " + said)
        case let (late?, nil): return late
        case let (nil, said?): return Text(verbatim: said)
        case (nil, nil): return nil
        }
    }

    private func linkColumn(_ items: [ActionThreadLinks.Link], identifier: String,
                            open: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.prefix(Self.maximumLinks)) { item in
                Button {
                    open(item.id)
                } label: {
                    Text(verbatim: item.name).lineLimit(1)
                }
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("\(identifier).\(item.id)")
            }
        }
    }

    private static let maximumLinks = 4

    private var duePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Due", selection: $dueDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack(spacing: 8) {
                Button("No date") { saveDue(nil) }
                    .disabled(thread.due == nil)
                Spacer(minLength: 16)
                Button("Cancel") { choosingDue = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDue(dueDraft) }
                    .primaryActionButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func saveDue(_ date: Date?) {
        let change = ActionDetailsPresentation.dueCorrection(date, for: thread)
        if app.outcomeIndex.correctAction(actionID: change.actionID, meetingID: change.meetingID,
                                          text: change.text, owner: change.owner, due: change.due) {
            choosingDue = false
            app.lastError = nil
        } else {
            app.lastError = app.outcomeIndex.lastError ?? "The correction could not be saved."
        }
    }

    private var mentions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: ActionDetailsPresentation.mentionsHeading(for: thread, localize: language.catalog))
                .font(AppFont.scaled(.headline))
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(thread.references) { reference in
                Divider()
                ActionEvidencePassages(reference: reference)
                    .id(reference.id)
                    .padding(.vertical, 10)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button("Draft next steps…") { app.followThrough(thread.latestReference) }
                    .help("Follow Through")
                    .accessibilityIdentifier("actions.details.followThrough")
                Menu("Hand off") {
                    Section("Hand off to") {
                        ActionThreadRow.handOffItems(for: thread, app: app)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("actions.details.handOff")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.background.secondary)
    }
}

private struct ActionBatchDetails: View {
    @EnvironmentObject private var app: AppState
    let rows: [ActionsListContent.Row]
    let listing: OutcomeStatus
    let listedCount: Int
    let onStatus: (OutcomeStatus, [ActionThread]) -> Void
    let onSelectAll: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(rows.count) actions selected")
                    .font(.scaled(.title3).weight(.semibold))
                    .accessibilityIdentifier("actions.batch")
                HStack(spacing: 8) {
                    Button(listing == .done ? "Mark open" : "Mark Done") {
                        onStatus(listing == .done ? .open : .done, rows.map(\.thread))
                    }
                    .accessibilityIdentifier("actions.batch.done")
                    Button(listing == .deferred ? "Move back to open" : "Defer") {
                        onStatus(listing == .deferred ? .open : .deferred, rows.map(\.thread))
                    }
                    .accessibilityIdentifier("actions.batch.defer")
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Divider()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.thread.text)
                                .font(.scaled(.body))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.source.isEmpty
                                 ? ActionListWording.source(of: row.thread, localize: app.settings.appLanguage.catalog)
                                 : row.source)
                                .font(AppFont.scaled(.callout))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("⌘-click rows to add or remove them.")
                        .foregroundStyle(.secondary)
                    if rows.count < listedCount {
                        Button("Select all \(listedCount)", action: onSelectAll)
                            .buttonStyle(.workspaceLink)
                            .accessibilityIdentifier("actions.batch.selectAll")
                    }
                }
                .font(AppFont.scaled(.callout))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
