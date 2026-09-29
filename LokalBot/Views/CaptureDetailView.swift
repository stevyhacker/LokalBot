import SwiftUI

/// The bounded context panel inside Timeline's one-day workspace. Selection
/// replaces only this panel; the date, stats, and chronology remain stable so
/// inspecting evidence never turns Timeline into another Meetings or Today
/// screen.
struct TimelineContextPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let onDismiss: (() -> Void)?
    @State private var expandedTitles: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            selectedContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.contextPanel")
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let snapshotID = model.selectedSnapshotID,
           let screenshot = model.shots.first(where: { $0.id == snapshotID }) {
            ScreenMomentDetailView(
                screenshot: screenshot,
                onReload: { model.reload(app: app) },
                onClear: {
                    model.selectedSnapshotID = nil
                    if model.selection == nil, model.selectedSessionID == nil, !model.showsRawCapture {
                        onDismiss?()
                    }
                },
                backLabel: model.selection != nil ? "Back to activity"
                    : model.selectedSessionID != nil ? "Back to work session"
                    : model.showsRawCapture ? "Back to raw capture" : "Back to day",
                onDismiss: onDismiss)
                .id(snapshotID)
        } else if app.selectedMeetingIDs.isEmpty, model.selection == nil, let session = model.selectedSession {
            sessionPreview(session)
        } else if model.showsRawCapture, app.selectedMeetingIDs.isEmpty, model.selection == nil {
            rawCapturePanel
        } else {
            switch inspectorState {
            case .meeting:
                if let meeting = selectedMeetingForDay {
                    TimelineMeetingPreview(
                        meeting: meeting,
                        onBack: clearSelection,
                        onDismiss: onDismiss)
                        .id(meeting.id)
                } else {
                    dayBrief
                }
            case .multiSelection(let count):
                multiSelection(count)
            case .block:
                if let block = model.selectedBlock {
                    activityPreview(block)
                } else {
                    dayBrief
                }
            case .overview:
                dayBrief
            }
        }
    }

    private var rawCapturePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelinePanelHeader(
                title: "Raw capture",
                subtitle: "\(CountLabel.format(model.blocks.count, "activity entry", plural: "activity entries")) · \(CountLabel.format(model.rewindFrames.count, "screen moment"))",
                icon: "waveform.path.ecg.rectangle",
                onBack: clearSelection,
                onDismiss: onDismiss)
                .accessibilityIdentifier("timeline.rawCapturePanel")
            CaptureRangeDeletionView(frames: model.rewindFrames) {
                model.selectedSnapshotID = nil
                model.reload(app: app)
            }
            TimelineRawCaptureView(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var dayBrief: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelinePanelHeader(title: "Details", subtitle: "", icon: "rectangle.and.text.magnifyingglass",
                                onBack: nil, onDismiss: onDismiss)
            Text("Select a work session, meeting, or captured moment to review its details.")
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func sessionPreview(_ session: TimelineWorkSession) -> some View {
        let frames = model.frames(in: session)
        let representative = model.representativeFrames(in: session)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelinePanelHeader(
                    title: session.title,
                    subtitle: "\(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(session.activeDuration)) active",
                    icon: "briefcase",
                    onBack: clearSelection,
                    onDismiss: onDismiss)
                    .accessibilityIdentifier("timeline.sessionPreview")

                TimelineContextSection(
                    title: "Representative evidence",
                    icon: "rectangle.and.text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 9) {
                            if representative.isEmpty {
                                Text("No context moments were captured during this session.")
                                    .font(AppFont.scaled(.body))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(representative) { frame in
                                    relatedMomentRow(frame.screenshot)
                                }
                                if frames.count > representative.count {
                                    Text("Showing \(representative.count) representative scenes from \(frames.count). Browse raw capture for every scene.")
                                        .font(AppFont.scaled(.callout))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                DisclosureGroup(frames.count == 1 ? "Browse the retained moment" : "Browse all \(CountLabel.format(frames.count, "retained moment"))") {
                    SessionMomentBrowser(model: model, session: session)
                }
                .accessibilityIdentifier("timeline.session.browseMoments")

                if !session.notableTitles.isEmpty {
                    TimelineContextSection(title: "Documents and windows", icon: "text.page") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("These are captured window titles. Expand a title to inspect the activity behind it.")
                                .workspaceTextRole(.supporting)
                            ForEach(session.titleEvidence) { evidence in
                                WorkspaceDisclosure(isExpanded: Binding(
                                    get: { expandedTitles.contains(evidence.id) },
                                    set: { if $0 { expandedTitles.insert(evidence.id) } else { expandedTitles.remove(evidence.id) } }),
                                    identifier: "timeline.titleDisclosure.\(evidence.id)", style: .compact) {
                                    Text(evidence.title).textSelection(.enabled)
                                    ForEach(evidence.blocks) { block in
                                        Button {
                                            model.selection = block.id
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(block.title).lineLimit(2)
                                                Text("\(block.app) · \(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))")
                                                    .workspaceTextRole(.supporting)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Inspect \(block.title), \(block.app), \(block.start.formatted(date: .omitted, time: .shortened))")
                                        .accessibilityIdentifier("timeline.titleSource.\(block.id)")
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(evidence.title).font(AppFont.scaled(.body).weight(.semibold))
                                            .lineLimit(2).help(evidence.title)
                                        Text("\(CaptureStyle.hm(evidence.duration)) observed · \(evidence.blocks.count) activity \(evidence.blocks.count == 1 ? "block" : "blocks")")
                                            .workspaceTextRole(.supporting)
                                    }
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Documents and windows")
                        .accessibilityIdentifier("timeline.session.titleEvidence")
                    }
                }

                DisclosureGroup("Session details") {
                    VStack(alignment: .leading, spacing: 10) {
                        sessionMetrics(session)
                        Text(session.apps.prefix(5).joined(separator: " · "))
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CaptureStyle.color(for: session.primaryApp).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                }
                .accessibilityIdentifier("timeline.session.details")

                HStack {
                    Spacer()
                    Button {
                        app.openAsk(
                            query: "What matters from my work session on \(session.title)?",
                            dayScope: model.day,
                            screenSnapshotIDs: model.shots.filter { $0.ts >= session.start && $0.ts <= session.end }.map(\.id))
                    } label: {
                        Label("Ask about this session", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func sessionMetrics(_ session: TimelineWorkSession) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                activeMetric(session)
                appMetric(session)
                if session.contextSwitchCount > 0 { switchMetric(session) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    activeMetric(session)
                    appMetric(session)
                }
                if session.contextSwitchCount > 0 { switchMetric(session) }
            }
        }
    }

    private func activeMetric(_ session: TimelineWorkSession) -> some View {
        StatTile(icon: "clock", value: CaptureStyle.hm(session.activeDuration), label: "active")
    }

    private func appMetric(_ session: TimelineWorkSession) -> some View {
        StatTile(icon: "square.grid.2x2", value: "\(session.appCount)",
                 label: session.appCount == 1 ? "app" : "apps")
    }

    private func switchMetric(_ session: TimelineWorkSession) -> some View {
        StatTile(icon: "arrow.left.arrow.right",
                 value: "\(session.contextSwitchCount)", label: "switches")
    }

    private func activityPreview(_ block: ActivityBlock) -> some View {
        let scoped = model.shots
            .filter { $0.ts >= block.start && $0.ts <= block.end }
            .sorted { $0.ts < $1.ts }
        let sameApp = model.blocks.filter { $0.app == block.app }
        let appTotal = sameApp.reduce(0) { $0 + $1.duration }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelinePanelHeader(
                    title: block.app,
                    subtitle: "\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))",
                    icon: "rectangle.stack",
                    onBack: {
                        if model.selectedSession != nil || model.showsRawCapture {
                            model.selection = nil
                        } else {
                            clearSelection()
                        }
                    },
                    onDismiss: onDismiss,
                    backLabel: model.selectedSession != nil ? "Back to work session"
                        : model.showsRawCapture ? "Back to raw capture" : "Back to day")
                    .accessibilityIdentifier("timeline.activityPreview")

                VStack(alignment: .leading, spacing: 8) {
                    if !block.title.isEmpty {
                        Text(block.title)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(CaptureStyle.color(for: block.app).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.control))

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Related moments", systemImage: "rectangle.and.text.magnifyingglass")
                            .font(AppFont.scaled(.headline))
                        Spacer()
                        Text("\(scoped.count)")
                            .font(AppFont.scaled(.callout).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if scoped.isEmpty {
                        Text("No context moments were captured during this activity.")
                            .font(AppFont.scaled(.body))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(scoped.prefix(6)) { screenshot in
                                relatedMomentRow(screenshot)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        app.openAsk(
                            query: "What matters from my \(block.app) activity, \(block.title)?",
                            dayScope: model.day)
                    } label: {
                        Label("Ask about this activity", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                    Text(screenshot.windowTitle.isEmpty ? screenshot.app : screenshot.windowTitle)
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
        VStack(alignment: .leading, spacing: 16) {
            TimelinePanelHeader(
                title: "\(count) meetings selected",
                subtitle: "Timeline previews one meeting at a time.",
                icon: "checklist",
                onBack: clearSelection,
                onDismiss: onDismiss)
            Text("Return to the day or select one meeting in Work sessions.")
                .font(AppFont.scaled(.body))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private func clearSelection() {
        model.selectedSnapshotID = nil
        model.selection = nil
        model.selectedSessionID = nil
        model.showsRawCapture = false
        app.selectedMeetingIDs = []
        onDismiss?()
    }
}

private struct TimelineMeetingPreview: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    let onBack: () -> Void
    let onDismiss: (() -> Void)?

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var projection: MeetingOutcomeProjection? {
        app.outcomeIndex.projection(for: meeting.id)
    }
    private var summary: String? {
        try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelinePanelHeader(
                    title: meeting.displayTitle,
                    subtitle: "\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.displayDuration)",
                    icon: "waveform",
                    onBack: onBack,
                    onDismiss: onDismiss)
                    .accessibilityIdentifier("timeline.meetingPreview")

                if meeting.endedAt == nil {
                    Label("Recording in progress", systemImage: "record.circle.fill")
                        .font(AppFont.scaled(.body).weight(.semibold))
                        .foregroundStyle(Brand.recording)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.24),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                }

                // The recap only: decisions and actions render below as their
                // own sections, so the full summary would repeat them.
                if let recap = summary.flatMap(SummaryPresentation.recap) {
                    TimelineContextSection(title: "Recap", icon: "text.alignleft") {
                        MarkdownText(recap)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                if let actions = projection?.actionReferences.filter(\.isForUser), !actions.isEmpty {
                    TimelineContextSection(title: "My actions", icon: "checklist") {
                        VStack(spacing: 0) {
                            ForEach(actions.prefix(4)) { reference in
                                TimelineMeetingActionRow(reference: reference)
                                if reference.id != actions.prefix(4).last?.id { Divider() }
                            }
                        }
                    }
                }

                if let decisions = projection?.outcomes.decisionRecords, !decisions.isEmpty {
                    TimelineContextSection(title: "Decisions", icon: "checkmark.seal") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(decisions.prefix(4)) { decision in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Brand.teal)
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
                   projection?.outcomes.decisionRecords.isEmpty != false,
                   meeting.endedAt != nil {
                    Text("No outcome summary has been extracted for this meeting yet.")
                        .font(AppFont.scaled(.body))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        app.openAsk(query: "What matters from \(meeting.displayTitle)?",
                                    screenSnapshotIDs: [], meetingIDs: [meeting.id])
                    } label: {
                        Label("Ask about this meeting", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        app.openMeeting(meeting.id)
                    } label: {
                        Label("Open meeting", systemImage: "arrow.up.right.square")
                    }
                    .primaryActionButton()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct TimelineMeetingActionRow: View {
    @EnvironmentObject private var app: AppState
    let reference: OutcomeActionReference

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                _ = app.outcomeIndex.setStatus(
                    reference.status == .done ? .open : .done,
                    actionID: reference.action.id,
                    meetingID: reference.meetingID)
            } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            Text(reference.text)
                .font(AppFont.scaled(.body))
                .strikethrough(reference.status == .done)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

private struct TimelinePanelHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let onBack: (() -> Void)?
    let onDismiss: (() -> Void)?
    var backLabel = "Back to day"

    /// "Back to day" → "Day" for the visible button text.
    private var backTitle: String {
        let destination = backLabel.hasPrefix("Back to ") ? String(backLabel.dropFirst(8)) : backLabel
        return destination.prefix(1).uppercased() + destination.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if onBack != nil || onDismiss != nil {
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Label(backTitle, systemImage: "chevron.left")
                                .font(AppFont.scaled(.body))
                        }
                        .buttonStyle(.workspaceLink)
                        .help(backLabel)
                        .accessibilityLabel(backLabel)
                    }
                    Spacer(minLength: 4)
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("Close context panel")
                        .accessibilityLabel("Close context panel")
                    }
                }
            }
            titleRow
        }
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.scaled(.title3)).foregroundStyle(LBTokens.Palette.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(2)
                    .help(title)
                    .font(AppFont.scaled(.title2).weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
    }
}

private struct TimelineContextSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(AppFont.scaled(.headline))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbGroupedSurface()
    }
}
