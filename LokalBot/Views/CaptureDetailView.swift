import SwiftUI

/// The page beside Timeline's list when something other than the digest is
/// selected: a work session, a meeting's short preview, all captured
/// activity, or one activity block or screen moment opened from those.
struct TimelineContextPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let list: TimelineDayList
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
                    TimelineMeetingPreview(meeting: meeting)
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
        TimelinePage {
            TimelinePageHeader(title: Text("Details"), subtitle: "") {
                Image(systemName: "rectangle.and.text.magnifyingglass")
            }
            Text("Select a work session, meeting, or captured moment to review its details.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - All captured activity

    private var rawCapturePage: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            CaptureRangeDeletionView(frames: model.rewindFrames, isExpanded: $deletingRange) {
                model.selectedSnapshotID = nil
                model.reload(app: app)
            }
            TimelineRawCaptureView(model: model)
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        return TimelinePage {
            TimelinePageHeader(
                title: Text(verbatim: text.title),
                subtitle: TimelineSessionWording.subtitle(for: session, localize: language.catalog),
                identifier: "timeline.sessionPreview") {
                StatusDot(color: TimelineRowColor.color(for: colorKey), size: 12)
                    .padding(.top, 7)
            }

            if !tasks.isEmpty {
                TimelinePageSection(title: "Coding agent") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tasks) { task in
                            TimelineAgentTaskCard(task: task,
                                                  showsTitle: tasks.count > 1 || task.title != text.title)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.session.agentWork")
                }
            }

            TimelinePageSection(title: "Screen moments", count: momentCount) {
                if momentCount > representative.count {
                    Button(showsAllMoments ? "Show fewer" : "Show all \(momentCount)") {
                        showsAllMoments.toggle()
                    }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .accessibilityIdentifier("timeline.session.browseMoments")
                }
            } content: {
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

            if !session.titleEvidence.isEmpty {
                TimelinePageSection(title: "What was open") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(session.titleEvidence) { evidence in
                            titleRow(evidence)
                            if evidence.id != session.titleEvidence.last?.id { Divider() }
                        }
                    }
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
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 7)
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
                    .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 10) {
                TimelineBackLink(label: model.selectedSession != nil ? "Back to work session"
                                 : model.showsRawCapture ? "Back to all captured activity" : "Back to day") {
                    model.selection = nil
                    if !hasParent { model.selectedSnapshotID = nil }
                }
                TimelinePageHeader(
                    title: Text(verbatim: block.app),
                    subtitle: "\(Self.timeRange(block.start, block.end)) · \(CaptureStyle.hm(block.duration))",
                    identifier: "timeline.activityPreview") {
                    StatusDot(color: CaptureStyle.color(for: block.app), size: 12)
                        .padding(.top, 7)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
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

            TimelinePageSection(title: "Related moments", count: scoped.count) {
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
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.activityMoment.\(screenshot.id)")
    }

    private func multiSelection(_ count: Int) -> some View {
        TimelinePage {
            TimelinePageHeader(
                title: Text(verbatim: "\(count) meetings selected"),
                subtitle: "Timeline previews one meeting at a time.") {
                Image(systemName: "checklist")
            }
            Button("Day digest") {
                app.selectedMeetingIDs = []
            }
            .buttonStyle(.bordered)
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

/// The reading column every Timeline page shares with the digest.
private struct TimelinePage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 48)
            .frame(maxWidth: TimelineDigestPage.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// A page's heading: its mark (a colour dot or an icon), the title, and one
/// quiet line under it.
private struct TimelinePageHeader<Mark: View>: View {
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A headed part of a page, with an optional count and a trailing link.
private struct TimelinePageSection<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    var count: Int?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, count: Int? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(AppFont.scaled(.headline))
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text(count, format: .number)
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TimelinePageSection where Accessory == EmptyView {
    init(title: LocalizedStringKey, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, accessory: { EmptyView() }, content: content)
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
        TimelinePage {
            TimelinePageHeader(
                title: Text(verbatim: meeting.displayTitle),
                subtitle: facts.filter { !$0.isEmpty }.joined(separator: " · "),
                identifier: "timeline.meetingPreview") {
                Image(systemName: "waveform")
            }

            if meeting.endedAt == nil {
                Label("Recording in progress", systemImage: "record.circle.fill")
                    .font(AppFont.scaled(.body).weight(.semibold))
                    .foregroundStyle(LBTokens.Palette.recordingText)
            }

            // The recap only: decisions and actions follow as their own
            // sections, so the full summary would repeat them.
            if let recap = summary.flatMap(SummaryPresentation.recap) {
                SelectableDigestText(recap, font: AppFont.scaledSystem(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 660, alignment: .leading)
            }

            if !actions.isEmpty {
                TimelinePageSection(title: "Your actions") {
                    VStack(spacing: 0) {
                        ForEach(actions.prefix(6)) { thread in
                            ActionThreadRow(thread: thread, hidesSingleMeetingLink: true)
                            if thread.id != actions.prefix(6).last?.id { Divider() }
                        }
                    }
                }
            }

            if !decisions.isEmpty {
                TimelinePageSection(title: "Decisions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(decisions.prefix(6)) { decision in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(AppFont.scaled(.callout).weight(.semibold))
                                    .foregroundStyle(LBTokens.Palette.accentText)
                                    .accessibilityHidden(true)
                                Text(decision.displayText)
                                    .font(AppFont.scaled(.body))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            if summary?.isEmpty != false,
               projection?.actionReferences.isEmpty != false,
               decisions.isEmpty,
               meeting.endedAt != nil {
                Text("No outcome summary has been extracted for this meeting yet.")
                    .workspaceTextRole(.supporting)
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

/// One agent task in a work session: the request that started it, when it
/// ran, and the pull requests and commits it recorded. Recorded actions come
/// from the commands the agent ran; its own report is left out because it is
/// only a claim.
private struct TimelineAgentTaskCard: View {
    @EnvironmentObject private var app: AppState
    let task: TimelineAgentTask
    /// One task named like its session needs no second title.
    let showsTitle: Bool

    private struct PullRequestLink: Hashable {
        let label: String
        let url: URL
    }

    var body: some View {
        let outcomes = TimelineAgentOutcomes(task.bursts)
        VStack(alignment: .leading, spacing: 5) {
            if showsTitle || task.request == nil {
                Text(verbatim: task.title)
                    .font(AppFont.scaled(.body).weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let request = task.request {
                Text(verbatim: "“\(request)”")
                    .font(AppFont.scaled(.body))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Text(verbatim: metadata)
                .workspaceTextRole(.metadata)
                .padding(.bottom, 2)
            ForEach(Array(outcomes.openedPullRequests.enumerated()), id: \.offset) { _, title in
                outcome("arrow.triangle.pull", Text("Opened pull request “\(title)”"))
            }
            ForEach(Array(mergedNumbers.enumerated()), id: \.offset) { _, number in
                outcome("arrow.triangle.merge",
                        number.map { Text("Merged #\($0)") } ?? Text("Merged a pull request"))
            }
            if outcomes.commits > 0 {
                outcome("smallcircle.filled.circle",
                        Text(outcomes.commits == 1 ? "\(outcomes.commits) commit" : "\(outcomes.commits) commits"))
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbGroupedSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.agentTask.\(task.id)")
    }

    private func outcome(_ symbol: String, _ text: Text) -> some View {
        Label {
            text.lineLimit(2)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(LBTokens.Palette.accentText)
        }
        .font(AppFont.scaled(.callout))
    }

    /// "Claude Code · Asked at 9:12 AM · worked until 9:58 AM", or the time
    /// range alone when the request was not kept.
    private var metadata: String {
        let language = app.settings.appLanguage
        var parts: [String] = [task.agent.displayName]
        if task.request != nil {
            parts.append(String(format: language.localized("Asked at %@"),
                                task.start.formatted(date: .omitted, time: .shortened)))
            parts.append(String(format: language.localized("worked until %@"),
                                task.end.formatted(date: .omitted, time: .shortened)))
        } else {
            parts.append(TimelineContextPanel.timeRange(task.start, task.end))
        }
        return parts.joined(separator: " · ")
    }

    private var mergedNumbers: [Int?] {
        task.actions.compactMap { action in
            if case .mergedPullRequest(let number) = action { return .some(number) }
            return nil
        }
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
