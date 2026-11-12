import SwiftUI

/// Timeline's main area when something other than the day is chosen in the
/// rail: a work session, a meeting's short preview, all captured activity, or
/// one activity block or screen moment opened from those. Each is a title
/// panel, then one panel per section it has; "Day digest" above goes back.
struct TimelineContextPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let list: TimelineDayList
    /// Returns to the day's page.
    let onShowDigest: () -> Void
    @State private var expandedTitles: Set<String> = []
    @State private var showsAllMoments = false
    @State private var deletingRange = false

    var body: some View {
        VStack(spacing: 0) {
            selectedContent
        }
        // No identifier here: this wrapper and the pane around it reach
        // assistive tools as one element, which keeps the pane's. Each page's
        // title carries the page's identifier instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.selectedSessionID) {
            showsAllMoments = false
            expandedTitles = []
        }
        .onChange(of: model.day) { deletingRange = false }
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let snapshotID = model.selectedSnapshotID,
           let screenshot = model.shots.first(where: { $0.id == snapshotID }) {
            ScreenMomentDetailView(
                screenshot: screenshot,
                onReload: { model.reload(app: app) },
                onClear: { model.selectedSnapshotID = nil },
                backLabel: model.selection != nil ? "Back to activity"
                    : model.selectedSessionID != nil ? "Back to work session"
                    : model.showsRawCapture ? "Back to all captured activity" : "Back to day",
                onDismiss: nil)
                .id(snapshotID)
        } else if app.selectedMeetingIDs.isEmpty, model.selection == nil, let session = model.selectedSession {
            sessionPage(session)
        } else if model.showsRawCapture, app.selectedMeetingIDs.isEmpty, model.selection == nil {
            rawCapturePage
        } else {
            switch inspectorState {
            case .meeting:
                if let meeting = selectedMeetingForDay {
                    TimelineMeetingPreview(meeting: meeting, onShowDigest: onShowDigest)
                        .id(meeting.id)
                } else {
                    nothingSelected
                }
            case .multiSelection(let count):
                multiSelection(count)
            case .block:
                if let block = model.selectedBlock {
                    activityPreview(block)
                } else {
                    nothingSelected
                }
            case .overview:
                nothingSelected
            }
        }
    }

    private var inspectorState: CaptureInspectorState {
        CaptureInspectorState.resolve(
            meetingIDs: app.selectedMeetingIDs,
            blockSelection: model.selection,
            allowsBlockSelection: true)
    }

    private var selectedMeetingForDay: Meeting? {
        guard let meeting = app.selectedMeeting,
              Calendar.current.isDate(meeting.startedAt, inSameDayAs: model.day) else {
            return nil
        }
        return meeting
    }

    /// A selection that is still loading, or one the day no longer has.
    private var nothingSelected: some View {
        TimelinePage(onShowDigest: onShowDigest) {
            SectionPanelLead {
                VStack(alignment: .leading, spacing: 10) {
                    TimelinePageHeader(title: Text("Details"), subtitle: "") {
                        Image(systemName: "rectangle.and.text.magnifyingglass")
                    }
                    Text("Select a work session, meeting, or captured moment to review its details.")
                        .workspaceTextRole(.supporting)
                }
            }
        }
    }

    // MARK: - All captured activity

    /// One panel that fills the main area: its title and the way to delete
    /// screen moments on top, the hour track scrolling under them.
    private var rawCapturePage: some View {
        VStack(alignment: .leading, spacing: TimelinePageMetric.panelGap) {
            TimelineDigestLink(action: onShowDigest)
            SectionPanelLead {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        TimelinePageHeader(
                            title: Text("All captured activity"),
                            subtitle: "",
                            subtitleText: TimelineCaptureCounts.text(
                                entries: model.blocks.count, moments: model.rewindFrames.count),
                            identifier: "timeline.rawCapturePanel") {
                            Image(systemName: "waveform.path.ecg.rectangle")
                        }
                        if !model.rewindFrames.isEmpty {
                            // A toggle, so it keeps its name while the range controls
                            // are open and reads as on; a second "Cancel" beside the
                            // review sheet's own would say nothing about what it cancels.
                            Toggle("Delete screen moments…", isOn: $deletingRange)
                                .toggleStyle(.button)
                                .accessibilityIdentifier("timeline.deleteRange.toggle")
                        }
                    }
                    Text("Every app and window LokalBot saw, hour by hour. Use it to check exact times.")
                        .workspaceTextRole(.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                    CaptureRangeDeletionView(frames: model.rewindFrames, isExpanded: $deletingRange) {
                        model.selectedSnapshotID = nil
                        model.reload(app: app)
                    }
                }
            } below: {
                TimelineRawCaptureView(model: model)
                    .padding(.horizontal, SectionPanelMetric.inset)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: TimelinePageMetric.maximumWidth, alignment: .leading)
        .padding(.horizontal, TimelinePageMetric.gutter)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - A work session

    private func sessionPage(_ session: TimelineWorkSession) -> some View {
        let language = app.settings.appLanguage
        let text = TimelineDayList.workText(for: session, localize: language.catalog)
        let row = list.row(id: TimelineDayList.Row.id(session: session.id))
        let representative = model.representativeFrames(in: session)
        let momentCount = model.shots.filter { $0.ts >= session.start && $0.ts <= session.end }.count
        let tasks = TimelineAgentTask.tasks(from: session.agentBursts)
        // The dot the session has in the list and the day strip.
        let colorKey: String? = row.map(\.colorKey) ?? (session.project ?? session.primaryApp)
        return TimelinePage(onShowDigest: onShowDigest) {
            SectionPanelLead {
                TimelinePageHeader(
                    title: Text(verbatim: text.title),
                    subtitle: TimelineSessionWording.subtitle(for: session, localize: language.catalog),
                    identifier: "timeline.sessionPreview") {
                    StatusDot(color: TimelineRowColor.color(for: colorKey), size: 12)
                        .padding(.top, 7)
                }
            }

            if !tasks.isEmpty {
                TimelineAgentPanel(tasks: tasks, sessionTitle: text.title, localize: language.catalog)
            }

            SectionPanel(
                title: Text("Screen moments"),
                systemImage: "photo",
                count: momentCount,
                identifier: "timeline.session.moments"
            ) {
                if momentCount > representative.count {
                    Button(showsAllMoments ? "Show fewer" : "Show all \(momentCount)") {
                        showsAllMoments.toggle()
                    }
                    .accessibilityIdentifier("timeline.session.browseMoments")
                }
            } content: {
                Group {
                    if representative.isEmpty, momentCount == 0 {
                        Text("None were kept for this session.")
                            .workspaceTextRole(.supporting)
                    } else if showsAllMoments {
                        SessionMomentBrowser(model: model, session: session)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14, alignment: .top)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(representative) { frame in
                                momentThumbnail(frame.screenshot)
                            }
                        }
                    }
                }
                .padding(.horizontal, SectionPanelMetric.inset)
                .padding(.vertical, 14)
            }

            if !session.titleEvidence.isEmpty {
                SectionPanel(
                    title: Text("What was open"),
                    systemImage: "macwindow",
                    identifier: "timeline.session.open"
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(session.titleEvidence) { evidence in
                            titleRow(evidence)
                            if evidence.id != session.titleEvidence.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, SectionPanelMetric.inset)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("What was open")
                    .accessibilityIdentifier("timeline.session.titleEvidence")
                }
            }

            Button {
                app.openAsk(
                    query: "What matters from my work session on \(session.title)?",
                    dayScope: model.day,
                    screenSnapshotIDs: model.shots.filter { $0.ts >= session.start && $0.ts <= session.end }.map(\.id))
            } label: {
                Label("Ask about this session", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
        }
    }

    /// A window or document the session had open, with its time. Opening the
    /// row lists the activity behind the title, which stays inspectable.
    private func titleRow(_ evidence: TimelineWorkSession.TitleEvidence) -> some View {
        let isExpanded = Binding(
            get: { expandedTitles.contains(evidence.id) },
            set: { if $0 { expandedTitles.insert(evidence.id) } else { expandedTitles.remove(evidence.id) } })
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 12) {
                    Text(verbatim: evidence.title)
                        .lineLimit(isExpanded.wrappedValue ? nil : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(evidence.title)
                    Text(verbatim: CaptureStyle.hm(evidence.duration))
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .workspaceSupportingForeground()
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption).weight(.semibold))
                        .workspaceSupportingForeground()
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("timeline.titleDisclosure.\(evidence.id)")
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(evidence.blocks) { block in
                        Button {
                            model.selection = block.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: block.title).lineLimit(2)
                                Text(verbatim: "\(block.app) · \(Self.timeRange(block.start, block.end))")
                                    .workspaceTextRole(.supporting)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Inspect \(block.title), \(block.app), \(block.start.formatted(date: .omitted, time: .shortened))")
                        .accessibilityIdentifier("timeline.titleSource.\(block.id)")
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 9)
            }
        }
    }

    private func momentThumbnail(_ screenshot: ActivityStore.Screenshot) -> some View {
        Button {
            model.selectedSnapshotID = screenshot.id
            app.selectedMeetingIDs = []
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                ScreenThumbnailView(screenshot: screenshot, height: 108, cornerRadius: 8)
                    .padding(.bottom, 4)
                Text(verbatim: screenshot.windowTitle.isEmpty ? screenshot.app : screenshot.windowTitle)
                    .font(AppFont.scaled(.callout))
                    .lineLimit(1)
                Text(screenshot.ts.formatted(date: .omitted, time: .shortened))
                    .font(AppFont.scaled(.subheadline).monospacedDigit())
                    .workspaceSupportingForeground()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.sessionMoment.\(screenshot.id)")
    }

    // MARK: - One activity block

    private func activityPreview(_ block: ActivityBlock) -> some View {
        let scoped = model.shots
            .filter { $0.ts >= block.start && $0.ts <= block.end }
            .sorted { $0.ts < $1.ts }
        let sameApp = model.blocks.filter { $0.app == block.app }
        let appTotal = sameApp.reduce(0) { $0 + $1.duration }
        let hasParent = model.selectedSession != nil || model.showsRawCapture

        return TimelinePage {
            TimelineBackLink(label: model.selectedSession != nil ? "Back to work session"
                             : model.showsRawCapture ? "Back to all captured activity" : "Back to day") {
                model.selection = nil
                if !hasParent { model.selectedSnapshotID = nil }
            }
            .padding(.top, -4)
            .padding(.bottom, -6)
            SectionPanelLead {
                VStack(alignment: .leading, spacing: 12) {
                    TimelinePageHeader(
                        title: Text(verbatim: block.app),
                        subtitle: "\(Self.timeRange(block.start, block.end)) · \(CaptureStyle.hm(block.duration))",
                        identifier: "timeline.activityPreview") {
                        StatusDot(color: CaptureStyle.color(for: block.app), size: 12)
                            .padding(.top, 7)
                    }
                    if !block.title.isEmpty {
                        Text(verbatim: block.title)
                            .font(AppFont.scaled(.body).weight(.semibold))
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        StatTile(icon: "clock", value: CaptureStyle.hm(appTotal),
                                 label: "today")
                        StatTile(icon: "rectangle.stack", value: "\(sameApp.count)",
                                 label: sameApp.count == 1 ? "block" : "blocks")
                    }
                }
            }

            SectionPanel(
                title: Text("Related moments"),
                systemImage: "photo",
                count: scoped.count,
                identifier: "timeline.activity.moments"
            ) {
                Group {
                    if scoped.isEmpty {
                        Text("No context moments were captured during this activity.")
                            .workspaceTextRole(.supporting)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(scoped.prefix(6)) { screenshot in
                                relatedMomentRow(screenshot)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SectionPanelMetric.inset)
                .padding(.vertical, 12)
            }

            Button {
                app.openAsk(
                    query: "What matters from my \(block.app) activity, \(block.title)?",
                    dayScope: model.day)
            } label: {
                Label("Ask about this activity", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
        }
    }

    private func relatedMomentRow(_ screenshot: ActivityStore.Screenshot) -> some View {
        Button {
            model.selectedSnapshotID = screenshot.id
            app.selectedMeetingIDs = []
        } label: {
            HStack(spacing: 10) {
                ScreenThumbnailView(screenshot: screenshot, height: 54)
                    .frame(width: 86)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: screenshot.windowTitle.isEmpty ? screenshot.app : screenshot.windowTitle)
                        .font(AppFont.scaled(.body).weight(.semibold))
                        .lineLimit(2)
                    Text(screenshot.ts.formatted(date: .omitted, time: .shortened))
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .workspaceSupportingForeground()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption))
                    .workspaceSupportingForeground()
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.activityMoment.\(screenshot.id)")
    }

    /// "Day digest" above the page clears the selection.
    private func multiSelection(_ count: Int) -> some View {
        TimelinePage(onShowDigest: onShowDigest) {
            SectionPanelLead {
                TimelinePageHeader(
                    title: Text(verbatim: "\(count) meetings selected"),
                    subtitle: "Timeline previews one meeting at a time.") {
                    Image(systemName: "checklist")
                }
            }
        }
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        (start..<max(start, end)).formatted(date: .omitted, time: .shortened)
    }
}

/// A session's line under its title: "Atlas · 9:10 – 10:15 AM · 1h 5m
/// active · Xcode, Terminal, Safari".
enum TimelineSessionWording {
    static func subtitle(for session: TimelineWorkSession, localize: (String) -> String = { $0 }) -> String {
        var parts: [String] = []
        if session.titleNamesProject, session.taskTitle != nil, let project = session.projectLabel {
            parts.append(project)
        }
        parts.append(TimelineContextPanel.timeRange(session.start, session.end))
        parts.append(String(format: localize("%@ active"), CaptureStyle.hm(session.activeDuration)))
        let apps = session.usedApps.prefix(4).joined(separator: ", ")
        if !apps.isEmpty { parts.append(apps) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Page pieces

/// The column every page in Timeline's main area shares: panels that fill
/// the width inside their gutters, up to the widest line.
struct TimelinePageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: TimelinePageMetric.panelGap) {
            content
        }
        .frame(maxWidth: TimelinePageMetric.maximumWidth, alignment: .leading)
        .padding(.horizontal, TimelinePageMetric.gutter)
        .padding(.top, 20)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A scrolling page of panels for something chosen in the rail.
struct TimelinePage<Content: View>: View {
    /// Shows "Day digest" above the page. Nil for a page opened inside
    /// another, which has its own way back.
    var onShowDigest: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            TimelinePageColumn {
                if let onShowDigest {
                    TimelineDigestLink(action: onShowDigest)
                }
                content
            }
        }
    }
}

/// "‹ Day digest": the way from a session, a meeting or all captured activity
/// back to the day's page. Choosing the selected row again does the same.
struct TimelineDigestLink: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Day digest", systemImage: "chevron.backward")
                .font(AppFont.scaled(.body))
        }
        .buttonStyle(.workspaceLink)
        // Sits a little nearer the panel it leads to than panels sit to each other.
        .padding(.top, -4)
        .padding(.bottom, -6)
        .accessibilityIdentifier("timeline.backToDigest")
    }
}

/// A page's heading: its mark (a colour dot or an icon), the title, and one
/// quiet line under it.
struct TimelinePageHeader<Mark: View>: View {
    let title: Text
    let subtitle: String
    var subtitleText: Text?
    /// Names the page for UI tests. It goes on the title alone: on the whole
    /// header it would be copied onto every text inside.
    var identifier = ""
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
                .font(.scaled(.title2))
                .foregroundStyle(LBTokens.Palette.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // A heading stays plain text: selectable text with the
                // header trait reaches assistive tools without its words.
                title
                    .font(AppFont.scaledSystem(size: 20, weight: .bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
                (subtitleText ?? Text(verbatim: subtitle))
                    .font(AppFont.scaled(.callout))
                    .workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The way back from a page opened inside another: an activity block to its
/// session, a moment to its activity.
private struct TimelineBackLink: View {
    /// "Back to work session": the full phrase is the tooltip and the
    /// VoiceOver label, and the destination alone is the visible text.
    let label: String
    let action: () -> Void

    private var title: String {
        let destination = label.hasPrefix("Back to ") ? String(label.dropFirst(8)) : label
        return destination.prefix(1).uppercased() + destination.dropFirst()
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(AppFont.scaled(.body))
        }
        .buttonStyle(.workspaceLink)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - A meeting

/// A meeting on Timeline is a short preview: the recap, the user's actions,
/// the decisions, and the way to the meeting itself.
private struct TimelineMeetingPreview: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    let onShowDigest: () -> Void

    /// The preview stays short; the meeting has the rest.
    private static let rowLimit = 6

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var projection: MeetingOutcomeProjection? {
        app.outcomeIndex.projection(for: meeting.id)
    }
    private var savedSummary: String? {
        try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
    }

    var body: some View {
        // One read per render: the recap and the empty state both need it.
        let summary = savedSummary
        let end = CaptureTrackItem.meetingEnd(meeting, now: Date())
        let actions = app.outcomeIndex.userActionThreads.filter { thread in
            thread.references.contains { $0.meetingID == meeting.id }
        }
        let decisions = projection?.outcomes.decisionRecords ?? []
        let facts: [String] = [TimelineContextPanel.timeRange(meeting.startedAt, end),
                               CaptureStyle.hm(end.timeIntervalSince(meeting.startedAt)),
                               meeting.appName]
        let hasNoOutcomes = summary?.isEmpty != false
            && projection?.actionReferences.isEmpty != false
            && decisions.isEmpty
            && meeting.endedAt != nil
        TimelinePage(onShowDigest: onShowDigest) {
            TimelineMeetingLead(
                title: meeting.displayTitle,
                facts: facts.filter { !$0.isEmpty }.joined(separator: " · "),
                isLive: meeting.endedAt == nil,
                // The recap only: decisions and actions follow as their own
                // panels, so the full summary would repeat them.
                recap: summary.flatMap(SummaryPresentation.recap),
                hasNoOutcomes: hasNoOutcomes)

            if !actions.isEmpty {
                let shown = Array(actions.prefix(Self.rowLimit))
                SectionPanel(
                    title: Text("Your actions"),
                    systemImage: AppState.NavSection.actions.symbol,
                    count: actions.count,
                    identifier: "timeline.meeting.actions"
                ) {
                    VStack(spacing: 0) {
                        ForEach(shown) { thread in
                            ActionThreadRow(thread: thread, hidesSingleMeetingLink: true)
                            if thread.id != shown.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, SectionPanelMetric.inset)
                }
            }

            if !decisions.isEmpty {
                TimelineDecisionsPanel(
                    decisions: decisions.prefix(Self.rowLimit).map(\.displayText),
                    count: decisions.count,
                    identifier: "timeline.meeting.decisions")
            }

            HStack(spacing: 8) {
                Button("Open meeting") { app.openMeeting(meeting.id) }
                    .primaryActionButton()
                Button("Ask about this meeting") {
                    app.openAsk(query: "What matters from \(meeting.displayTitle)?",
                                screenSnapshotIDs: [], meetingIDs: [meeting.id])
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// The meeting's title panel: its name, when it ran and where, and the recap
/// under a hairline.
struct TimelineMeetingLead: View {
    let title: String
    /// "11:00 – 11:25 AM · 25m · Zoom".
    let facts: String
    let isLive: Bool
    let recap: String?
    /// The meeting ended and nothing was extracted from it yet.
    let hasNoOutcomes: Bool

    var body: some View {
        SectionPanelLead {
            VStack(alignment: .leading, spacing: 12) {
                TimelinePageHeader(
                    title: Text(verbatim: title),
                    subtitle: facts,
                    identifier: "timeline.meetingPreview") {
                    Image(systemName: "waveform")
                }
                if isLive {
                    Label("Recording in progress", systemImage: "record.circle.fill")
                        .font(AppFont.scaled(.body).weight(.semibold))
                        .foregroundStyle(LBTokens.Palette.recordingText)
                }
                if let recap {
                    Divider()
                    SelectableDigestText(recap, font: AppFont.scaledSystem(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: WorkspaceMetric.readingMaxWidth, alignment: .leading)
                } else if hasNoOutcomes {
                    Divider()
                    Text("No outcome summary has been extracted for this meeting yet.")
                        .workspaceTextRole(.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Decisions as a panel: one per row under a check.
struct TimelineDecisionsPanel: View {
    let decisions: [String]
    /// The meeting's decisions in all; the preview lists the first few.
    let count: Int
    let identifier: String

    var body: some View {
        SectionPanel(
            title: Text("Decisions"),
            systemImage: "flag",
            count: count,
            identifier: identifier
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(decisions.enumerated()), id: \.offset) { index, decision in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(AppFont.scaled(.callout).weight(.semibold))
                            .foregroundStyle(LBTokens.Palette.accentText)
                            .accessibilityHidden(true)
                        Text(verbatim: decision)
                            .font(AppFont.scaled(.body))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    if index < decisions.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, SectionPanelMetric.inset)
        }
    }
}

// MARK: - Coding agent

/// What the agents did in a work session, one task after another: the
/// request that started it and the pull requests and commits it recorded,
/// with when it ran in the panel's footer. Recorded actions come from the
/// commands the agent ran; its own report is left out because it is only a
/// claim.
struct TimelineAgentPanel: View {
    let tasks: [TimelineAgentTask]
    /// One task named like its session needs no second title.
    let sessionTitle: String
    /// Looks a catalog key up in the interface language.
    let localize: (String) -> String

    var body: some View {
        let last = tasks.last
        SectionPanel(
            title: Text("Coding agent"),
            systemImage: AppState.NavSection.agent.symbol,
            identifier: "timeline.session.agent",
            showsFooter: last != nil
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { task in
                    let isLast = task.id == last?.id
                    TimelineAgentTaskBlock(
                        task: task,
                        showsTitle: tasks.count > 1 || task.title != sessionTitle,
                        // The last task's line is the panel's footer.
                        metadata: isLast ? nil : TimelineAgentTaskWording.metadata(task, localize: localize))
                    if !isLast { Divider() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.session.agentWork")
        } footer: {
            if let last {
                Text(verbatim: TimelineAgentTaskWording.metadata(last, localize: localize))
                    .sectionPanelFooterText()
            }
        }
    }
}

enum TimelineAgentTaskWording {
    /// "Claude Code · Asked at 9:12 AM · worked until 9:58 AM", or the time
    /// range alone when the request was not kept.
    static func metadata(_ task: TimelineAgentTask, localize: (String) -> String = { $0 }) -> String {
        var parts: [String] = [task.agent.displayName]
        if task.request != nil {
            parts.append(String(format: localize("Asked at %@"),
                                task.start.formatted(date: .omitted, time: .shortened)))
            parts.append(String(format: localize("worked until %@"),
                                task.end.formatted(date: .omitted, time: .shortened)))
        } else {
            parts.append(TimelineContextPanel.timeRange(task.start, task.end))
        }
        return parts.joined(separator: " · ")
    }
}

/// One agent task: its title or request, then a row for each thing it
/// recorded.
private struct TimelineAgentTaskBlock: View {
    let task: TimelineAgentTask
    let showsTitle: Bool
    /// When the task ran, for every task but the panel's last.
    let metadata: String?

    private struct PullRequestLink: Hashable {
        let label: String
        let url: URL
    }

    private struct Outcome: Identifiable {
        let id: Int
        let symbol: String
        let text: Text
    }

    var body: some View {
        let outcomes = outcomes
        let links = links
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                if showsTitle || task.request == nil {
                    Text(verbatim: task.title)
                        .font(AppFont.scaled(.body).weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let request = task.request {
                    Text(verbatim: "“\(request)”")
                        .font(AppFont.scaledSystem(size: 13.5))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let metadata {
                    Text(verbatim: metadata)
                        .workspaceTextRole(.metadata)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SectionPanelMetric.inset)
            .padding(.vertical, 14)
            if !outcomes.isEmpty || !links.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(outcomes) { outcome in
                        Label {
                            outcome.text.lineLimit(2)
                        } icon: {
                            Image(systemName: outcome.symbol)
                                .foregroundStyle(LBTokens.Palette.accentText)
                        }
                        .font(AppFont.scaled(.callout))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        if outcome.id != outcomes.last?.id || !links.isEmpty { Divider() }
                    }
                    if !links.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(links, id: \.url) { link in
                                Link(destination: link.url) {
                                    Text(verbatim: link.label)
                                }
                                .font(AppFont.scaled(.callout))
                            }
                        }
                        .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, SectionPanelMetric.inset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.agentTask.\(task.id)")
    }

    /// Opened pull requests, merged ones, then the commits.
    private var outcomes: [Outcome] {
        let recorded = TimelineAgentOutcomes(task.bursts)
        var rows: [(String, Text)] = recorded.openedPullRequests.map {
            ("arrow.triangle.pull", Text("Opened pull request “\($0)”"))
        }
        for action in task.actions {
            guard case .mergedPullRequest(let number) = action else { continue }
            rows.append(("arrow.triangle.merge",
                         number.map { Text("Merged #\($0)") } ?? Text("Merged a pull request")))
        }
        if recorded.commits > 0 {
            rows.append(("smallcircle.filled.circle",
                         Text(recorded.commits == 1 ? "\(recorded.commits) commit" : "\(recorded.commits) commits")))
        }
        return rows.enumerated().map { Outcome(id: $0.offset, symbol: $0.element.0, text: $0.element.1) }
    }

    /// The pull requests the agent session linked, at most three, as
    /// "repository #number".
    private var links: [PullRequestLink] {
        var result: [PullRequestLink] = []
        for raw in task.pullRequests {
            guard result.count < 3, let reference = CodingAgentPullRequest(url: raw),
                  let url = URL(string: raw), url.scheme == "https",
                  !result.contains(where: { $0.url == url }) else { continue }
            result.append(PullRequestLink(label: "\(reference.repository) #\(reference.number)", url: url))
        }
        return result
    }
}
