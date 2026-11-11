import SwiftUI

/// Shared outcome-first building blocks used by Today, Timeline, People and
/// Projects. They read the same `OutcomeIndex` as Meetings, so status changes
/// are immediately reflected everywhere without modifying extracted source
/// files.
///
/// Today's open actions: rows on the page itself, with the link to Actions
/// beside the heading.
struct NeedsAttentionSection: View {
    @EnvironmentObject var app: AppState
    let threads: [ActionThread]
    var title = "Needs Attention"
    var limit = 4
    /// The heading link says how many more wait in Actions.
    var linksRemainder = false
    var headingFont = AppFont.scaled(.headline)
    /// Space added above and below each row.
    var rowSpacing: CGFloat = 8

    /// Open threads the section leaves to the Actions page.
    static func remainder(total: Int, limit: Int) -> Int {
        max(0, total - max(0, limit))
    }

    /// Nothing to act on means no section at all: an empty "Needs attention"
    /// is dead weight on a glanceable page.
    var body: some View {
        if !threads.isEmpty { rows }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // No header trait, matching the panel style's heading: a
                // header becomes a different accessibility element, which
                // static-text queries no longer find.
                Text(LocalizedStringKey(title))
                    .font(headingFont)
                Text(threads.count, format: .number)
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    app.openActions()
                } label: {
                    actionsLinkLabel
                }
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .accessibilityIdentifier("outcomes.review")
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(threads.prefix(limit))) { thread in
                    ActionThreadRow(thread: thread)
                        .padding(.vertical, rowSpacing)
                    if thread.id != threads.prefix(limit).last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsLinkLabel: Text {
        guard linksRemainder else { return Text("Review Actions…") }
        let more = Self.remainder(total: threads.count, limit: limit)
        return more > 0 ? Text("\(more) more in Actions") : Text("All actions")
    }
}

/// How the Actions page shows the shared row: its own source and due wording,
/// a selection it owns, and status changes it confirms and keeps in view.
/// The links a row has elsewhere live in that page's details pane.
struct ActionListRowStyle {
    let source: String
    let due: ActionsListContent.DueLabel?
    var isSelected = false
    /// Several rows are selected: a row's menu shows only under the pointer.
    var isBatch = false
    let onStatus: (OutcomeStatus) -> Void
    let onEdit: () -> Void
    let onNotMine: () -> Void
}

struct ActionThreadRow: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let thread: ActionThread
    /// Projects show whose work it is when it is someone else's.
    var showsOwner = false
    /// People show deferred work as deferred and ask about open work nobody
    /// has mentioned for weeks.
    var showsStaleness = false
    /// Timeline's meeting preview lists that meeting's actions, so a row from
    /// one meeting does not name it again.
    var hidesSingleMeetingLink = false
    /// People show the moment as a ▶ time that opens the meeting playing
    /// from there, like the notes beside it.
    var playsEvidence = false
    /// Set by the Actions page; every other page shows the row with its links.
    var list: ActionListRowStyle?
    @State private var showingSources = false
    @State private var showingStatusConfirmation = false
    @State private var pendingStatus: OutcomeStatus = .done
    @State private var hovered = false

    var body: some View {
        if let list {
            listBody(list)
        } else {
            standardBody
        }
    }

    private func toggle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: thread.hasMixedStatus ? "minus.circle" : thread.status == .done
                  ? "checkmark.circle.fill" : "circle")
                .font(.system(size: LBTokens.Metric.actionToggleSize))
                .foregroundStyle(thread.status == .done ? Brand.teal : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(thread.status == .done ? "Reopen action thread" : "Mark action thread done")
        .accessibilityValue(thread.text)
        .accessibilityIdentifier("outcome.thread.toggle.\(thread.id)")
    }

    // MARK: Actions page

    private func listBody(_ list: ActionListRowStyle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            toggle { list.onStatus(thread.status == .done ? .open : .done) }
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.text)
                    .font(.scaled(.body))
                    .strikethrough(thread.status == .done)
                    .foregroundStyle(thread.status == .done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !list.source.isEmpty || list.due != nil || thread.hasMixedStatus {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !list.source.isEmpty {
                            Text(verbatim: list.source)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let due = list.due {
                            Text(verbatim: due.text)
                                .foregroundStyle(Self.color(for: due.tone))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        if thread.hasMixedStatus {
                            Text("Mixed status")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(AppFont.scaled(.callout))
                }
                if let hint = app.actionCompletionHints[thread.id] {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Looks done?")
                            .font(AppFont.scaled(.callout).weight(.semibold))
                            .foregroundStyle(Brand.teal)
                        Text(verbatim: ActionListWording.completionHint(
                            hint, locale: app.settings.appLanguage.locale,
                            localize: app.settings.appLanguage.catalog))
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("outcome.thread.completionHint")
                }
            }
            // The menu shows on the selected row and under the pointer. It
            // stays in the view tree either way, so it cannot go away while
            // it is open and the pointer has moved onto its items.
            let showsMenu = hovered || (list.isSelected && !list.isBatch)
            Menu {
                listMenuItems(list)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showsMenu ? 1 : 0)
            .allowsHitTesting(showsMenu)
            .accessibilityHidden(!showsMenu)
            .accessibilityLabel("Action thread options")
            .accessibilityIdentifier("outcome.thread.status.\(thread.id)")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            list.isSelected ? Brand.teal.opacity(0.12) : hovered ? Color.primary.opacity(0.04) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if list.isSelected, contrast == .increased {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.teal)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { listMenuItems(list) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outcome.thread.\(thread.id)")
        .accessibilityAddTraits(list.isSelected ? .isSelected : [])
    }

    @ViewBuilder private func listMenuItems(_ list: ActionListRowStyle) -> some View {
        Button(thread.status == .done ? "Mark open" : "Mark Done") {
            list.onStatus(thread.status == .done ? .open : .done)
        }
        Button(thread.status == .deferred ? "Move back to open" : "Defer") {
            list.onStatus(thread.status == .deferred ? .open : .deferred)
        }
        Divider()
        Button("Edit…", action: list.onEdit)
        Button("Not mine", action: list.onNotMine)
        Button("Open meeting") { app.openMeeting(thread.latestReference.meetingID) }
        if thread.hasMultipleMeetings {
            Menu("Keep as separate action") {
                ForEach(thread.references) { reference in
                    Button {
                        setThreadExcluded(true, for: reference)
                    } label: {
                        Text(verbatim: reference.meetingTitle + " · "
                             + reference.meetingStartedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
        } else {
            let reference = thread.latestReference
            Button(reference.isThreadExcluded ? "Allow matching across meetings" : "Keep as separate action") {
                setThreadExcluded(!reference.isThreadExcluded, for: reference)
            }
        }
        Divider()
        Button("Draft next steps…") { app.followThrough(thread.latestReference) }
        Menu("Hand off") { Self.handOffItems(for: thread, app: app) }
    }

    /// Agent, then the external agents installed on this Mac.
    @ViewBuilder static func handOffItems(for thread: ActionThread, app: AppState) -> some View {
        Button("Agent") { app.openAgent(agentContext(for: thread)) }
        ForEach(ActionAgentAvailability.installed) { target in
            Button {
                app.handOff(thread, to: target)
            } label: {
                Text(verbatim: target.rawValue)
            }
        }
    }

    static func agentContext(for thread: ActionThread) -> AgentLaunchContext {
        let sourceNote = thread.meetingCount == 1
            ? thread.latestReference.meetingTitle
            : "\(thread.meetingCount) source meetings"
        return AgentLaunchContext(
            title: thread.text,
            prompt: "Help me complete this action thread from \(sourceNote): " + thread.text,
            meetingID: thread.latestReference.meetingID,
            actionID: thread.latestReference.action.id)
    }

    static func color(for tone: ActionsListContent.DueLabel.Tone) -> Color {
        switch tone {
        case .late: LBTokens.Palette.recordingText
        case .soon: LBTokens.Palette.attentionText
        case .calm: Color(nsColor: WorkspaceTextColor.supporting)
        }
    }

    private func setThreadExcluded(_ excluded: Bool, for reference: OutcomeActionReference) {
        if !app.outcomeIndex.setThreadExcluded(
            excluded, actionID: reference.action.id, meetingID: reference.meetingID) {
            app.lastError = app.outcomeIndex.lastError
        }
    }

    // MARK: Today, Timeline, People and Projects

    private var standardBody: some View {
        HStack(alignment: .top, spacing: 10) {
            toggle { set(thread.status == .done ? .open : .done) }

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.text)
                    .font(.scaled(.body))
                    .strikethrough(thread.status == .done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if showsOwner {
                        Text(thread.owner.map { SpeakerDisplayName.label($0) } ?? "Owner unclear")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                    }
                    if thread.hasMixedStatus {
                        Text("Mixed status")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                    } else if showsStaleness && thread.status == .deferred {
                        Text("Deferred")
                            .font(AppFont.scaled(.callout))
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
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Brand.teal)
                        .accessibilityIdentifier("outcome.thread.sources.\(thread.id)")
                        .popover(isPresented: $showingSources) {
                            ActionThreadSourcesView(
                                thread: thread,
                                showingSources: $showingSources)
                                .environmentObject(app)
                        }
                    } else if !hidesSingleMeetingLink {
                        Button(thread.latestReference.meetingTitle) {
                            app.openMeeting(thread.latestReference.meetingID)
                        }
                        .buttonStyle(.plain)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Brand.teal)
                    }
                    if let due = thread.due, let spokenAt = thread.dueReferenceDate {
                        Text(ActionDuePresentation.label(due, spokenAt: spokenAt))
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(dueColor)
                            .accessibilityLabel(thread.isOverdue()
                                ? "Overdue. " + ActionDuePresentation.label(due, spokenAt: spokenAt)
                                : ActionDuePresentation.label(due, spokenAt: spokenAt))
                    }
                    if thread.dueHistory.count > 1 {
                        Text("Deadline updated")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                    }
                    if !thread.hasMultipleMeetings,
                       let citation = thread.latestReference.action.citations.first {
                        if playsEvidence {
                            MeetingPlayTimeButton(time: citation.start, excerpt: citation.excerpt) {
                                app.openMeeting(
                                    thread.latestReference.meetingID,
                                    seek: citation.start, intent: .play)
                            }
                        } else {
                            EvidencePill(citation: citation) {
                                app.openMeeting(
                                    thread.latestReference.meetingID,
                                    seek: citation.start)
                            }
                        }
                    }
                }
                if let hint = app.actionCompletionHints[thread.id] {
                    ActionCompletionHintLine(
                        hint: hint,
                        onDone: { set(.done) },
                        onView: { app.openScreenSnapshot(hint.snapshotID) },
                        onDismiss: { app.dismissActionCompletionHint(hint) })
                } else if showsStaleness && thread.isStale() {
                    StillOpenLine(
                        lastMentioned: thread.latestReference.meetingStartedAt,
                        onDone: { set(.done) },
                        onDefer: { set(.deferred) })
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
                        setThreadExcluded(!reference.isThreadExcluded, for: reference)
                    }
                }
                Button("Open in Agent") { app.openAgent(Self.agentContext(for: thread)) }
                ForEach(ActionAgentAvailability.installed) { target in
                    Button("Open in \(target.rawValue)") { app.handOff(thread, to: target) }
                }
                Button("Follow Through…") { app.followThrough(thread.latestReference) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
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

    /// Overdue reads red, due within the week amber, anything later quiet.
    private var dueColor: Color {
        if thread.isOverdue() { return LBTokens.Palette.recordingText }
        return thread.isDueSoon() ? LBTokens.Palette.attentionText : .secondary
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
        // A completed thread leaves open-only lists; animate the change so
        // the rows below close the gap.
        let updated = withAnimation(WorkspaceMotion.animation(.selection, reduceMotion: reduceMotion)) {
            app.outcomeIndex.setStatus(status, thread: thread)
        }
        if updated {
            app.lastError = nil
        } else {
            app.lastError = "Could not update this action thread. "
                + (app.outcomeIndex.lastError ?? "The action is no longer available.")
        }
    }
}

/// "Looks done?" evidence from a later screen capture. It never changes
/// status by itself; Mark Done goes through the normal status path.
private struct ActionCompletionHintLine: View {
    let hint: ActionCompletionHint
    let onDone: () -> Void
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Looks done?", systemImage: "checkmark.circle.badge.questionmark")
                .font(AppFont.scaled(.callout).weight(.semibold))
                .foregroundStyle(Brand.teal)
            Text(evidence)
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Mark Done", action: onDone).buttonStyle(.workspaceLink)
            Button("View", action: onView).buttonStyle(.workspaceLink)
            Button("Not Yet", action: onDismiss).buttonStyle(.workspaceLink)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looks done? \(evidence)")
        .accessibilityIdentifier("outcome.thread.completionHint")
        .help("A later screen capture shows “\(hint.cue)” with this action's words. Nothing changes until you choose Mark Done.")
    }

    private var evidence: String {
        let time = hint.capturedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let title = hint.title.isEmpty ? "" : " · \(hint.title)"
        return "“\(hint.cue)” in \(hint.app) · \(time)\(title)"
    }
}

/// Asks about open work nobody has mentioned for weeks. Either answer goes
/// through the normal status path; deferred work stops asking.
private struct StillOpenLine: View {
    let lastMentioned: Date
    let onDone: () -> Void
    let onDefer: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Still open?", systemImage: "clock.badge.questionmark")
                .font(AppFont.scaled(.callout).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            Text(age)
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Mark Done", action: onDone).buttonStyle(.workspaceLink)
            Button("Defer", action: onDefer).buttonStyle(.workspaceLink)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Still open? \(age)")
        .accessibilityIdentifier("outcome.thread.stillOpen")
        .help("Nobody has mentioned this in a meeting for a while. Mark it done, or defer it to stop this question.")
    }

    private var age: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last mentioned " + formatter.localizedString(for: lastMentioned, relativeTo: Date())
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
                    .font(AppFont.scaled(.headline))
                Text("Every source remains attached to its original meeting.")
                    .font(AppFont.scaled(.callout))
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
                                        .font(AppFont.scaled(.body).weight(.semibold))
                                    Spacer()
                                    Text(reference.meetingStartedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened))
                                        .font(AppFont.scaled(.callout))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Text(reference.action.displayText)
                                .font(AppFont.scaled(.body))
                                .foregroundStyle(.secondary)
                            if reference.textWasCorrected {
                                Label("Corrected to: \(reference.text)", systemImage: "pencil")
                                    .font(AppFont.scaled(.callout))
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                if let owner = reference.owner {
                                    let displayOwner = SpeakerDisplayName.label(
                                        owner,
                                        identity: reference.isForUser ? .user : .unresolved)
                                    Text("Owner: " + displayOwner)
                                }
                                if let due = reference.due {
                                    Text("Due: \(due)")
                                }
                                Text(reference.status.label)
                            }
                            .font(AppFont.scaled(.callout))
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
                            .font(AppFont.scaled(.callout))
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
                                    .font(AppFont.scaled(.callout))
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
