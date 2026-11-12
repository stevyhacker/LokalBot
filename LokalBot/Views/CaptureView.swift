import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The Timeline section groups low-level capture blocks into human-scale Work
/// sessions and interleaves meetings as first-class events. The lossless raw
/// activity remains available under All captured activity.
@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var day = Date()
    @Published var blocks: [ActivityBlock] = [] {
        didSet { refreshProjection() }
    }
    /// The day's settled coding-agent bursts. Set before `blocks`, whose
    /// change recomputes the sessions from both.
    @Published private(set) var agentBursts: [CodingAgentBurst] = []
    /// Tracked time by project; empty without coding-agent evidence.
    @Published private(set) var projectSplit = TimelineProjectAttribution.DaySplit()
    @Published var shots: [ActivityStore.Screenshot] = []
    @Published private(set) var rewindFrames: [ScreenRewindFrame] = []
    @Published var selection: ActivityBlock.ID?
    @Published var selectedSessionID: TimelineWorkSession.ID?
    @Published var selectedSnapshotID: Int64?
    /// Raw activity and screen moments shown full width in the main pane.
    @Published var showsRawCapture = false
    @Published var digest: String?
    @Published private(set) var digestUpdatedAt: Date?
    @Published private(set) var latestDigestEvidenceAt: Date?
    @Published var generating = false
    @Published var digestError: String?
    private var digestGeneration = 0
    private var overviewGeneration = 0
    private var overviewTask: Task<Void, Never>?
    private var retentionObserver: AnyCancellable?
    @Published private(set) var overviewLoading = false
    private var digestEvidenceMatches = true

    var selectedBlock: ActivityBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.id == selection }
    }

    @Published private(set) var workSessions: [TimelineWorkSession] = []

    private func refreshProjection() {
        let projection = DayActivityProjection(blocks: blocks, day: day, agentBursts: agentBursts)
        workSessions = projection.sessions
        projectSplit = projection.attribution.split(of: blocks)
    }

    /// What the day's agents recorded, scheduled runs left out like in the
    /// sessions.
    var dayOutcomes: TimelineAgentOutcomes {
        TimelineAgentOutcomes(agentBursts.filter { !$0.isScheduledRun })
    }

    var selectedSession: TimelineWorkSession? {
        guard let selectedSessionID else { return nil }
        return workSessions.first { $0.id == selectedSessionID }
    }

    func frames(in session: TimelineWorkSession) -> [ScreenRewindFrame] {
        rewindFrames.filter {
            $0.screenshot.ts >= session.start && $0.screenshot.ts <= session.end
        }
    }

    func representativeFrames(
        in session: TimelineWorkSession,
        limit: Int = 3
    ) -> [ScreenRewindFrame] {
        let scoped = frames(in: session)
        guard limit > 0, scoped.count > limit else { return scoped }
        guard limit > 1 else { return [scoped[scoped.count / 2]] }
        let indices = (0..<limit).map { index in
            Int((Double(index) * Double(scoped.count - 1) / Double(limit - 1)).rounded())
        }
        return indices.map { scoped[$0] }
    }

    var digestIsStale: Bool {
        DayDigestLifecycle.Snapshot(
            text: digest,
            modifiedAt: digestUpdatedAt,
            latestEvidenceAt: latestDigestEvidenceAt,
            evidenceMatches: digestEvidenceMatches).isStale
    }

    /// Clear the previous day immediately, then publish only the latest load.
    func selectDay(_ value: Date, app: AppState) {
        digestGeneration &+= 1
        generating = false
        selectedSnapshotID = nil
        day = value
        agentBursts = []; blocks = []; shots = []; rewindFrames = []
        digest = nil; digestUpdatedAt = nil; latestDigestEvidenceAt = nil
        // A new day opens on its digest.
        selection = nil; selectedSessionID = nil; showsRawCapture = false
        reload(app: app)
    }

    func moveDay(by value: Int, app: AppState) {
        let target = Calendar.current.date(byAdding: .day, value: value, to: day)
            ?? day.addingTimeInterval(TimeInterval(value) * 86_400)
        selectDay(target, app: app)
    }

    func reload(app: AppState) {
        refreshOverview(app: app)
        digestError = nil
    }

    /// Updates a mounted overview without resetting its generation state or
    /// hiding an error from the last explicit generation attempt.
    func refreshOverview(app: AppState) {
        if retentionObserver == nil {
            retentionObserver = NotificationCenter.default.publisher(for: .retainedScreenTextChanged)
                .merge(with: NotificationCenter.default.publisher(for: .codingAgentEvidenceChanged))
                .sink { [weak self, weak app] _ in
                    guard let self, let app else { return }
                    self.refreshOverview(app: app)
                }
        }
        overviewTask?.cancel()
        overviewGeneration &+= 1
        let generation = overviewGeneration, requestedDay = day
        let url = app.activityStore.databaseURL
        let loadDigest = app.dayDigest.backgroundSnapshotLoader(for: requestedDay)
        overviewLoading = true
        overviewTask = Task { @MainActor in
            let snapshot = await ActivityStore.readInBackground(at: url) { store in
                let shots = store.screenshots(on: requestedDay, includingTextOnly: true)
                return (store.blocks(on: requestedDay), shots, loadDigest(store),
                        store.codingAgentBursts(on: requestedDay))
            }
            guard !Task.isCancelled, generation == overviewGeneration else { return }
            agentBursts = snapshot.3
            blocks = snapshot.0
            shots = snapshot.1
            rewindFrames = ScreenRewindSequence.frames(from: snapshot.1)
            digest = snapshot.2.text
            digestUpdatedAt = snapshot.2.modifiedAt
            latestDigestEvidenceAt = snapshot.2.latestEvidenceAt
            digestEvidenceMatches = snapshot.2.evidenceMatches
            selection = blocks.contains { $0.id == selection } ? selection : nil
            selectedSessionID = workSessions.contains { $0.id == selectedSessionID } ? selectedSessionID : nil
            selectedSnapshotID = shots.contains { $0.id == selectedSnapshotID } ? selectedSnapshotID : nil
            overviewLoading = false
        }
    }

    /// The selected day's meetings, live recording included, for the track
    /// and the overview stats.
    func meetings(in app: AppState) -> [Meeting] {
        app.dayDigest.meetings(for: day)
    }

    func generateDigest(app: AppState) async {
        guard !generating, !app.dayDigest.isGenerating(on: day) else { return }
        digestGeneration &+= 1
        let generation = digestGeneration
        let requestedDay = day
        generating = true
        defer {
            if digestGeneration == generation { generating = false }
        }
        do {
            let result = try await app.dayDigest.generate(for: requestedDay)
            guard digestGeneration == generation,
                  Calendar.current.isDate(day, inSameDayAs: requestedDay) else { return }
            overviewGeneration &+= 1
            overviewTask?.cancel()
            overviewLoading = false
            // Read now, not before the model ran: generation can take a
            // minute, and blocks from before it replaced newer ones.
            blocks = app.activityStore.blocks(on: requestedDay)
            digest = result.text
            let snapshot = app.dayDigest.snapshot(for: requestedDay)
            digestUpdatedAt = snapshot.modifiedAt
            latestDigestEvidenceAt = snapshot.latestEvidenceAt
            digestEvidenceMatches = snapshot.evidenceMatches
            digestError = nil
        } catch {
            guard digestGeneration == generation else { return }
            digestError = error.localizedDescription
        }
    }

    /// Copy the raw digest Markdown to the clipboard. The rendered document
    /// supports partial selection too; this one-click action remains the fast
    /// path when the user wants the whole source document.
    func copyDigest(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export the digest to a user-chosen `.md` file via the standard save
    /// panel. The digest is already auto-saved to `journal/<date>.md`; this
    /// drops a shareable copy wherever the user picks.
    func exportDigest(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Export Day Digest"
        panel.nameFieldStringValue = "\(DreamDay.key(for: day)).md"
        panel.canCreateDirectories = true
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            digestError = "Export failed — \(error.localizedDescription)"
        }
    }
}

/// Shared Capture styling helpers (block colors, duration labels).
enum CaptureStyle {
    /// Stable per-app color from the name hash.
    static func color(for app: String) -> Color {
        var hash: UInt64 = 5381
        for byte in app.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.78)
    }

    static func hm(_ seconds: TimeInterval) -> String {
        if seconds > 0, seconds < 60 { return "<1m" }
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - The day: its page beside a rail

/// Timeline is one day: the day's page on the leading side, and on the
/// trailing side a rail with the tracked time, the hour strip and the day's
/// sessions and meetings. Choosing one in the rail shows its page in the
/// main area; the rail stays. The date is the window's title.
struct TimelineContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var model: CaptureModel
    @State private var showingCalendar = false
    @State private var digestCache = TimelineDigestCache()

    private var isToday: Bool { Calendar.current.isDateInToday(model.day) }

    var body: some View {
        let meetings = model.meetings(in: app)
        Group {
            if meetings.contains(where: { $0.endedAt == nil }) {
                // A recording grows; its row and bar follow it.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    dayBody(meetings: meetings, now: context.date)
                }
            } else {
                dayBody(meetings: meetings, now: Date())
            }
        }
        .navigationTitle(dayTitle)
        // The date in the toolbar is the title, and it opens the calendar.
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .task {
            model.reload(app: app)
            clearMeetingSelectionOutsideSelectedDay()
        }
        .onAppear(perform: consumePendingScreenMoment)
        .onChange(of: app.navigationHandoff.revision) { consumePendingScreenMoment() }
    }

    private func dayBody(meetings: [Meeting], now: Date) -> some View {
        let localize = app.settings.appLanguage.catalog
        let list = TimelineDayList(
            sessions: model.workSessions, meetings: meetings, now: now,
            usesProjectColors: !model.projectSplit.projects.isEmpty,
            localize: localize)
        let presentation = digestCache.presentation(for: model.digest)
        // A day whose captures have expired can still have its digest.
        let hasDay = !model.blocks.isEmpty || !meetings.isEmpty || !model.shots.isEmpty || model.digest != nil
        let selection = TimelineSelection.current(model: model, app: app, list: list)
        let select: (TimelineListSelection) -> Void = {
            TimelineSelection.select($0, model: model, app: app, list: list)
        }
        let tracked = TimelineTrackedSummary(
            perApp: DayActivityOverview.perApp(model.blocks), split: model.projectSplit, list: list,
            meetingCount: meetings.count, outcomes: model.dayOutcomes, day: model.day, localize: localize)
        // One row, not a split: the rail's width follows the window and the
        // text size, and the row mirrors for a right-to-left language.
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                Group {
                    if selection == .digest {
                        if hasDay {
                            TimelineDigestPage(
                                model: model, lifecycle: app.dayDigest, list: list,
                                presentation: presentation,
                                onSelectRow: { select(.row($0)) })
                        } else {
                            TimelineEmptyDay()
                        }
                    } else {
                        TimelineContextPanel(model: model, list: list) { select(.digest) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if model.overviewLoading { ProgressView().controlSize(.small).padding(12) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("timeline.evidencePane")
                Divider()
                TimelineRail(
                    tracked: hasDay ? tracked : nil, list: list, hasDay: hasDay,
                    captureCounts: TimelineCaptureCounts.text(
                        entries: model.blocks.count, moments: model.rewindFrames.count),
                    selection: selection,
                    sceneCount: { sceneCount(of: $0) },
                    onSelect: select
                ) {
                    TimelinePausedLine(sampler: app.sampler)
                }
                .frame(width: TimelineRailMetric.width(available: proxy.size.width, textScale: textScale))
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: TimelineRailMetric.bodyMinimumWidth)
        .id("workspace.timeline")
    }

    private func sceneCount(of row: TimelineDayList.Row) -> Int {
        guard case .work = row.kind else { return 0 }
        return model.rewindFrames.filter { $0.screenshot.ts >= row.start && $0.screenshot.ts <= row.end }.count
    }

    // MARK: Toolbar

    /// "Tuesday, November 10", with the year for a day outside this one.
    private var dayTitle: Text {
        let style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        let sameYear = Calendar.current.isDate(model.day, equalTo: Date(), toGranularity: .year)
        return Text(model.day, format: sameYear ? style : style.year())
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Arriving from a search result or an answer's source offers the way back.
        if app.evidenceReturnSection != nil {
            ToolbarItem(placement: .navigation) {
                Button(action: app.returnFromEvidence) {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Return to the source search or conversation")
            }
        }
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Button {
                    showingCalendar = true
                } label: {
                    HStack(spacing: 5) {
                        dayTitle
                            .font(LBTokens.Typography.columnTitle)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.scaled(.caption2).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                    DatePicker("Day", selection: daySelection, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                }
                .help("Choose a day")
                .accessibilityLabel("Choose day")
                .accessibilityValue(model.day.formatted(date: .complete, time: .omitted))
                .accessibilityIdentifier("timeline.dayPicker")
                if let relative = relativeDay {
                    Text(relative)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        // Without the system title nothing pushes the actions to the
        // trailing edge, so they sat against the date.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .primaryAction) { Spacer() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !isToday {
                Button("Today") { changeDay(to: Date()) }
                    .accessibilityIdentifier("timeline.today")
            }
            Button { changeDay(by: -1) } label: {
                Label("Previous day", systemImage: "chevron.left")
            }
            .help("Previous day")
            .accessibilityIdentifier("timeline.previousDay")
            Button { changeDay(by: 1) } label: {
                Label("Next day", systemImage: "chevron.right")
            }
            .help("Next day")
            .disabled(isToday)
            .accessibilityIdentifier("timeline.nextDay")
            Button { app.openAsk(dayScope: model.day) } label: {
                Label("Ask about this day", systemImage: "magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("capture.askDay")
            TimelineDayMenu(model: model, sampler: app.sampler, lifecycle: app.dayDigest) {
                model.reload(app: app)
                clearMeetingSelectionOutsideSelectedDay()
            }
        }
    }

    private var relativeDay: LocalizedStringKey? {
        if isToday { return "Today" }
        return Calendar.current.isDateInYesterday(model.day) ? "Yesterday" : nil
    }

    private var daySelection: Binding<Date> {
        Binding(get: { model.day }, set: { changeDay(to: $0) })
    }

    private func changeDay(by offset: Int) {
        app.selectedMeetingIDs = []
        model.moveDay(by: offset, app: app)
    }

    private func changeDay(to day: Date) {
        showingCalendar = false
        guard !Calendar.current.isDate(day, inSameDayAs: model.day) else { return }
        app.selectedMeetingIDs = []
        model.selectDay(day, app: app)
    }

    // MARK: Arriving from another page

    private func consumePendingScreenMoment() {
        if let day = app.navigationHandoff.consumeTimelineDay() {
            model.selectDay(day, app: app)
        }
        guard let snapshotID = app.navigationHandoff.consumeScreenSnapshot() else { return }
        guard let screenshot = app.activityStore.screenshot(id: snapshotID) else {
            app.lastError = "That captured screen is no longer available."
            return
        }
        model.selectDay(screenshot.ts, app: app)
        model.selectedSnapshotID = snapshotID
        model.selection = nil
        model.selectedSessionID = nil
        app.selectedMeetingIDs = []
    }

    private func clearMeetingSelectionOutsideSelectedDay() {
        let dayMeetingIDs = Set(model.meetings(in: app).map(\.id))
        if !app.selectedMeetingIDs.isSubset(of: dayMeetingIDs) {
            app.selectedMeetingIDs = []
        }
    }
}

/// Parses the digest once per text.
@MainActor
final class TimelineDigestCache {
    private var markdown: String?
    private var parsed: DayDigestPresentation?

    func presentation(for digest: String?) -> DayDigestPresentation? {
        if digest != markdown {
            markdown = digest
            parsed = digest.map(DayDigestPresentation.init(markdown:))
        }
        return parsed
    }
}

/// Reads and changes what the rail has selected. The selection lives in the
/// shared `CaptureModel` and the app's meeting selection, so it survives a
/// visit to another page.
@MainActor
enum TimelineSelection {
    static func current(model: CaptureModel, app: AppState, list: TimelineDayList) -> TimelineListSelection {
        if app.selectedMeetingIDs.count == 1, let id = app.selectedMeetingIDs.first,
           let meeting = app.selectedMeeting, Calendar.current.isDate(meeting.startedAt, inSameDayAs: model.day) {
            return .row(TimelineDayList.Row.id(meeting: id))
        }
        if let session = model.selectedSessionID {
            return .row(list.rowID(showing: session) ?? TimelineDayList.Row.id(session: session))
        }
        if model.showsRawCapture { return .raw }
        if model.selection != nil || model.selectedSnapshotID != nil || app.selectedMeetingIDs.count > 1 {
            return .none
        }
        return .digest
    }

    /// Selecting the selected row again returns to the day's page.
    static func select(_ target: TimelineListSelection, model: CaptureModel, app: AppState, list: TimelineDayList) {
        let current = current(model: model, app: app, list: list)
        model.selection = nil
        model.selectedSnapshotID = nil
        model.selectedSessionID = nil
        model.showsRawCapture = false
        app.selectedMeetingIDs = []
        guard target != current else { return }
        switch target {
        case .digest, .none:
            break
        case .raw:
            model.showsRawCapture = true
        case .row(let id):
            switch list.row(id: id)?.kind {
            case .work(let session): model.selectedSessionID = session
            case .meeting(let meeting, _): app.selectedMeetingIDs = [meeting]
            case nil: break
            }
        }
    }
}

/// The … menu: write, update or rewrite the digest, copy or export it, pause
/// or resume day memory, and reload the day. It observes the sampler itself,
/// which publishes too often for the whole page to follow.
private struct TimelineDayMenu: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    @ObservedObject var sampler: ActivitySampler
    @ObservedObject var lifecycle: DayDigestLifecycle
    let onReload: () -> Void

    var body: some View {
        let language = app.settings.appLanguage
        let busy = model.generating || lifecycle.isGenerating(on: model.day)
        let digest = model.digest
        let items: [WorkspaceMenu.Item] = [
            .init(title: language.localized(TimelineDigestPreview.menuTitle(
                    isWriting: busy, hasDigest: digest != nil, isStale: model.digestIsStale)),
                  identifier: "timeline.dayDigest.regenerate", enabled: !busy,
                  action: { Task { await model.generateDigest(app: app) } }),
            .init(title: language.localized("Copy digest"), identifier: "capture.dayDigest.copyAll",
                  enabled: digest != nil, action: { if let digest { model.copyDigest(digest) } }),
            .init(title: language.localized("Export as Markdown…"), identifier: "timeline.dayDigest.export",
                  enabled: digest != nil, action: { if let digest { model.exportDigest(digest) } }),
            .separator,
            .init(title: language.localized(sampler.isPaused ? "Resume day memory" : "Pause day memory"),
                  identifier: "timeline.dayMemory.pause", action: { sampler.isPaused.toggle() }),
            .init(title: language.localized("Reload"), identifier: "timeline.reload", action: onReload),
        ]
        WorkspaceMenu(title: language.localized("Digest and day memory"), symbol: "ellipsis",
                      identifier: "timeline.dayDigest.actions", items: items)
    }

}

/// A day with nothing recorded and no digest.
private struct TimelineEmptyDay: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ContentUnavailableView(
            "Nothing recorded on this day",
            systemImage: "clock",
            description: Text(app.settings.trackingEnabled
                ? "LokalBot keeps only what happens on this Mac while day memory is on."
                : "Day tracking is off — enable it in Settings."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.emptyDay")
    }
}

// MARK: - All captured activity

/// Individual activity blocks for exact evidence, hour by hour.
struct TimelineRawCaptureView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel

    var body: some View {
        let meetings = model.meetings(in: app)
        Group {
            if !model.blocks.isEmpty || !meetings.isEmpty {
                CaptureTrackView(
                    items: CaptureTrackItem.items(blocks: model.blocks, meetings: meetings, now: Date()),
                    blockSelection: model.selection,
                    selectedMeetingIDs: app.selectedMeetingIDs,
                    onSelectBlock: { id in
                        model.selection = id
                        if id != nil { model.selectedSnapshotID = nil }
                    },
                    onSelectMeeting: { id in
                        model.selection = nil
                        model.selectedSnapshotID = nil
                        model.showsRawCapture = false
                        app.selectedMeetingIDs = [id]
                    })
                    .frame(maxHeight: .infinity)
            } else if model.rewindFrames.isEmpty {
                ContentUnavailableView(
                    "No raw capture",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("No activity or screen moments were retained for this day."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Raw vertical, hour-indexed track. Meetings get a
/// dedicated teal lane on the left edge of the block area so they never
/// occlude the activity blocks they overlap (a meeting and its app's
/// activity cover the same minutes); activity blocks keep the remaining lane
/// width. With no meetings, activity blocks span the full lane as before.
private struct CaptureTrackView: View {
    let items: [CaptureTrackItem]
    let blockSelection: ActivityBlock.ID?
    let selectedMeetingIDs: Set<Meeting.ID>
    let onSelectBlock: (ActivityBlock.ID?) -> Void
    let onSelectMeeting: (Meeting.ID) -> Void

    private let pointsPerHour: CGFloat = 108
    private let gutter: CGFloat = 56

    private var hasMeetings: Bool {
        items.contains { if case .meeting = $0 { return true }; return false }
    }

    var body: some View {
        let start = trackStart
        let hours = hourCount(from: start)
        let height = CGFloat(hours) * pointsPerHour
        ScrollView {
            GeometryReader { geo in
                let laneWidth = max(40, geo.size.width - gutter)
                let meetingLane = hasMeetings ? max(96, laneWidth * 0.28) : 0
                let activityX = gutter + (meetingLane > 0 ? meetingLane + 6 : 0)
                let activityWidth = max(40, laneWidth - (meetingLane > 0 ? meetingLane + 6 : 0))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(0..<hours), id: \.self) { i in
                        let y = CGFloat(i) * pointsPerHour
                        Rectangle().fill(.quaternary.opacity(0.4))
                            .frame(width: laneWidth, height: 1)
                            .offset(x: gutter, y: y)
                        Text(hourLabel(start, i))
                            .font(.scaled(.caption2).monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: y - 6)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .activity(let block):
                            activityView(block, start: start, x: activityX, width: activityWidth)
                        case .meeting(let meeting, let end):
                            meetingView(meeting, end: end, start: start,
                                        x: gutter, width: max(96, meetingLane))
                        }
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
            // Room for the first hour's label, which sits on its line.
            .padding(.top, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day chronology")
        .accessibilityIdentifier("timeline.track")
    }

    @ViewBuilder
    private func activityView(_ block: ActivityBlock, start: Date,
                              x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(block.start.timeIntervalSince(start) / 3600) * pointsPerHour
        let h = max(8, CGFloat(block.duration / 3600) * pointsPerHour)
        let isSelected = blockSelection == block.id
        Button {
            onSelectBlock(isSelected ? nil : block.id)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(CaptureStyle.color(for: block.app).opacity(isSelected ? 1 : 0.85))
                .overlay(alignment: .topLeading) {
                    if h >= 20 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.app).font(.scaled(.caption).weight(.medium)).lineLimit(1)
                            if !block.title.isEmpty && h >= 38 {
                                Text(block.title).font(.scaled(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 6).padding(.top, 3)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Brand.teal : .clear, lineWidth: 2))
                .frame(width: width, height: h, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .help("\(block.app)\(block.title.isEmpty ? "" : " — \(block.title)")\n\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))")
        .accessibilityLabel(block.title.isEmpty ? block.app : "\(block.app), \(block.title)")
        .accessibilityValue("\(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened)), \(CaptureStyle.hm(block.duration))\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this activity in the context panel")
        .accessibilityIdentifier("capture.activity.\(block.id)")
    }

    @ViewBuilder
    private func meetingView(_ meeting: Meeting, end: Date, start: Date,
                             x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(meeting.startedAt.timeIntervalSince(start) / 3600) * pointsPerHour
        let duration = end.timeIntervalSince(meeting.startedAt)
        let h = max(24, CGFloat(duration / 3600) * pointsPerHour)
        let isSelected = selectedMeetingIDs == [meeting.id]
        Button {
            onSelectMeeting(meeting.id)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Brand.tealFill.opacity(isSelected ? 1 : 0.85))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform").font(.scaled(.caption2))
                            Text(meeting.title).font(.scaled(.caption).weight(.medium)).lineLimit(1)
                        }
                        if h >= 38 {
                            Text(meeting.displayDuration).font(.scaled(.caption2)).opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.top, 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 2))
                .frame(width: width, height: h, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .help("\(meeting.title)\n\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(meeting.displayDuration)")
        .accessibilityLabel("Meeting, \(meeting.displayTitle)")
        .accessibilityValue("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)), \(meeting.displayDuration)\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this meeting in the context panel")
        .accessibilityIdentifier("capture.meeting.\(meeting.id.uuidString)")
    }

    private var trackStart: Date {
        let first = items.first?.start ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateInterval(of: .hour, for: first)?.start ?? first
    }

    private func hourCount(from start: Date) -> Int {
        let last = items.map(\.end).max() ?? start.addingTimeInterval(3600)
        return max(1, Int(ceil(last.timeIntervalSince(start) / 3600)))
    }

    private func hourLabel(_ start: Date, _ i: Int) -> String {
        start.addingTimeInterval(Double(i) * 3600).formatted(date: .omitted, time: .shortened)
    }
}
