import SwiftUI

/// Shared outcome-first building blocks used by Today and Timeline. They read
/// the same `OutcomeIndex` as Meetings, so status changes are immediately
/// reflected everywhere without modifying extracted source files.
struct NeedsAttentionSection: View {
    @EnvironmentObject var app: AppState
    let threads: [ActionThread]
    var title = "Needs attention"
    var limit = 4

    /// Nothing to act on means no card at all — an empty "Needs attention"
    /// section is dead weight on a glanceable page (the Timeline test pins the
    /// same rule for its day view).
    var body: some View {
        if !threads.isEmpty {
            WorkspaceSection(title: title, icon: "exclamationmark.circle") {
                VStack(spacing: 0) {
                    ForEach(Array(threads.prefix(limit))) { thread in
                        ActionThreadRow(thread: thread)
                        if thread.id != threads.prefix(limit).last?.id { Divider() }
                    }
                }
                Button("Review all actions") {
                    app.openActions()
                }
                .primaryActionButton()
                .accessibilityIdentifier("outcomes.review")
            }
        }
    }
}

struct ActionThreadRow: View {
    @EnvironmentObject var app: AppState
    let thread: ActionThread
    @State private var showingSources = false
    @State private var showingStatusConfirmation = false
    @State private var pendingStatus: OutcomeStatus = .done

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                set(thread.status == .done ? .open : .done)
            } label: {
                Image(systemName: thread.hasMixedStatus ? "minus.circle" : thread.status == .done
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(thread.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(thread.status == .done ? "Reopen action thread" : "Mark action thread done")
            .accessibilityValue(thread.text)
            .accessibilityIdentifier("outcome.thread.toggle.\(thread.id)")

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.text)
                    .font(WorkspaceTypography.bodyEmphasis)
                    .strikethrough(thread.status == .done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if thread.hasMixedStatus {
                        Text("Mixed status")
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if thread.hasMultipleMeetings {
                        Button {
                            showingSources = true
                        } label: {
                            Label(
                                "Mentioned in \(thread.meetingCount) meetings",
                                systemImage: "link")
                        }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(Brand.teal)
                        .accessibilityIdentifier("outcome.thread.sources.\(thread.id)")
                        .popover(isPresented: $showingSources) {
                            ActionThreadSourcesView(
                                thread: thread,
                                showingSources: $showingSources)
                                .environmentObject(app)
                        }
                    } else {
                        Button(thread.latestReference.meetingTitle) {
                            app.openMeeting(thread.latestReference.meetingID)
                        }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(Brand.teal)
                    }
                    if let due = thread.due, let spokenAt = thread.dueSourceMeetingDate {
                        Text(ActionDuePresentation.label(due, spokenAt: spokenAt))
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if thread.dueHistory.count > 1 {
                        Text("Deadline updated")
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if !thread.hasMultipleMeetings,
                       let citation = thread.latestReference.action.citations.first {
                        EvidencePill(citation: citation) {
                            app.openMeeting(
                                thread.latestReference.meetingID,
                                seek: citation.start)
                        }
                    }
                }
            }

            Menu {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { status in
                    Button(status.label) { set(status) }
                }
                Divider()
                Button("Open latest meeting") {
                    app.openMeeting(thread.latestReference.meetingID)
                }
                if thread.hasMultipleMeetings {
                    Button("Review source meetings") { showingSources = true }
                } else {
                    let reference = thread.latestReference
                    Button(reference.isThreadExcluded ? "Allow matching across meetings" : "Keep as separate action") {
                        if !app.outcomeIndex.setThreadExcluded(
                            !reference.isThreadExcluded, actionID: reference.action.id, meetingID: reference.meetingID) {
                            app.lastError = app.outcomeIndex.lastError
                        }
                    }
                }
                Button("Open in Agent") {
                    let sourceNote = thread.meetingCount == 1
                        ? thread.latestReference.meetingTitle
                        : "\(thread.meetingCount) source meetings"
                    app.openAgent(.init(
                        title: thread.text,
                        prompt: "Help me complete this action thread from \(sourceNote): "
                            + thread.text,
                        meetingID: thread.latestReference.meetingID,
                        actionID: thread.latestReference.action.id))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Action thread options")
            .accessibilityIdentifier("outcome.thread.status.\(thread.id)")
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outcome.thread.\(thread.id)")
        .confirmationDialog(
            "Update actions in \(thread.meetingCount) meetings?",
            isPresented: $showingStatusConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark all \(pendingStatus.label.lowercased())") { apply(pendingStatus) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(thread.references.map(\.meetingTitle).joined(separator: "\n"))
        }
    }

    private func set(_ status: OutcomeStatus) {
        if thread.hasMultipleMeetings {
            pendingStatus = status
            showingStatusConfirmation = true
        } else {
            apply(status)
        }
    }

    private func apply(_ status: OutcomeStatus) {
        if app.outcomeIndex.setStatus(status, thread: thread) {
            app.lastError = nil
        } else {
            app.lastError = "Could not update this action thread. "
                + (app.outcomeIndex.lastError ?? "The action is no longer available.")
        }
    }
}

private struct ActionThreadSourcesView: View {
    @EnvironmentObject var app: AppState
    let thread: ActionThread
    @Binding var showingSources: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Action thread")
                    .font(WorkspaceTypography.sectionTitle)
                Text("Every source remains attached to its original meeting.")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(thread.references) { reference in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                open(reference, seek: nil)
                            } label: {
                                HStack {
                                    Text(reference.meetingTitle)
                                        .font(WorkspaceTypography.bodyEmphasis)
                                    Spacer()
                                    Text(reference.meetingStartedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened))
                                        .font(WorkspaceTypography.metadata)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Text(reference.action.displayText)
                                .font(WorkspaceTypography.body)
                                .foregroundStyle(.secondary)
                            if reference.textWasCorrected {
                                Label("Corrected to: \(reference.text)", systemImage: "pencil")
                                    .font(WorkspaceTypography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                if let owner = reference.owner {
                                    Text("Owner: \(SpeakerDisplayName.label(owner))")
                                }
                                if let due = reference.due {
                                    Text("Due: \(due)")
                                }
                                Text(reference.status.label)
                            }
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.tertiary)
                            Button("Keep as separate action") {
                                if app.outcomeIndex.setThreadExcluded(
                                    true, actionID: reference.action.id, meetingID: reference.meetingID) {
                                    showingSources = false
                                } else {
                                    app.lastError = app.outcomeIndex.lastError
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(WorkspaceTypography.metadata)
                            .accessibilityIdentifier("outcome.thread.separate.\(reference.id)")
                            ForEach(reference.action.citations) { citation in
                                Button {
                                    open(reference, seek: citation.start)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: "quote.bubble")
                                        Text(citation.excerpt)
                                            .lineLimit(2)
                                    }
                                    .font(WorkspaceTypography.metadata)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Brand.teal)
                            }
                        }
                        if reference.id != thread.references.last?.id { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .frame(maxHeight: 420)
    }

    private func open(_ reference: OutcomeActionReference, seek: TimeInterval?) {
        showingSources = false
        app.openMeeting(reference.meetingID, seek: seek)
    }
}

struct OutcomeOverviewActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                set(reference.status == .done ? .open : .done)
            } label: {
                Image(systemName: reference.status == .done
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("outcome.action.toggle.\(reference.id)")
            .accessibilityLabel(reference.status == .done ? "Reopen action" : "Complete action")
            VStack(alignment: .leading, spacing: 4) {
                Text(reference.text)
                    .font(WorkspaceTypography.bodyEmphasis)
                    .strikethrough(reference.status == .done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button(reference.meetingTitle) { app.openMeeting(reference.meetingID) }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(Brand.teal)
                    if let due = reference.due {
                        Text(ActionDuePresentation.label(due, spokenAt: reference.meetingStartedAt))
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(citation: citation) {
                            app.openMeeting(reference.meetingID, seek: citation.start)
                        }
                    }
                }
            }
            Menu {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { status in
                    Button(status.label) { set(status) }
                }
                Divider()
                Button("Open meeting") { app.openMeeting(reference.meetingID) }
                Button("Open in Agent") {
                    app.openAgent(.init(
                        title: reference.text,
                        prompt: "Help me complete this action from \(reference.meetingTitle): \(reference.text)",
                        meetingID: reference.meetingID,
                        actionID: reference.action.id))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("outcome.action.status.\(reference.id)")
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outcome.action.\(reference.id)")
    }

    private func set(_ status: OutcomeStatus) {
        if app.outcomeIndex.setStatus(
            status,
            actionID: reference.action.id,
            meetingID: reference.meetingID) {
            app.lastError = nil
        } else {
            app.lastError = "Could not update this action. "
                + (app.outcomeIndex.lastError ?? "The action is no longer available.")
        }
    }
}
