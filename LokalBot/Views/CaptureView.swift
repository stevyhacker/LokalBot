import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The Timeline section groups low-level capture blocks into human-scale Work
/// sessions and interleaves meetings as first-class events. The lossless raw
/// activity remains available behind Browse Raw Capture.
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
        selection = nil; selectedSessionID = nil
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

    func waitForOverview() async { await overviewTask?.value }

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
        let freshBlocks = app.activityStore.blocks(on: requestedDay)
        do {
            let result = try await app.dayDigest.generate(for: requestedDay)
            guard digestGeneration == generation,
                  Calendar.current.isDate(day, inSameDayAs: requestedDay) else { return }
            overviewGeneration &+= 1
            overviewTask?.cancel()
            overviewLoading = false
            blocks = freshBlocks
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

/// Reusable capture-volume stats used by Today and other compact summaries.
struct DayStatRow: View {
    let trackedSeconds: TimeInterval
    let appCount: Int
    let momentCount: Int
    let meetingCount: Int

    var body: some View {
        HStack(spacing: 8) {
            StatTile(icon: "clock", value: CaptureStyle.hm(trackedSeconds), label: "tracked")
            StatTile(icon: "square.grid.2x2", value: appCount.formatted(),
                     label: appCount == 1 ? "app" : "apps")
            StatTile(icon: "rectangle.and.text.magnifyingglass", value: momentCount.formatted(),
                     label: momentCount == 1 ? "moment" : "moments")
            if meetingCount > 0 {
                StatTile(icon: "waveform", value: meetingCount.formatted(),
                         label: meetingCount == 1 ? "meeting" : "meetings")
            }
            Spacer()
        }
    }
}

/// Timeline favors human-scale work summaries over capture-volume metrics.
private struct TimelineSessionStatRow: View {
    let activeSeconds: TimeInterval
    let sessionCount: Int
    let meetingCount: Int

    var body: some View {
        HStack(spacing: 8) {
            StatTile(icon: "clock", value: CaptureStyle.hm(activeSeconds), label: "tracked")
            StatTile(icon: "rectangle.stack", value: "\(sessionCount)",
                     label: sessionCount == 1 ? "session" : "sessions")
            if meetingCount > 0 {
                StatTile(icon: "waveform", value: "\(meetingCount)",
                         label: meetingCount == 1 ? "meeting" : "meetings")
            }
            Spacer()
        }
        .accessibilityIdentifier("timeline.sessionStats")
    }
}

// MARK: - Content column — the day track

struct TimelineContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: CaptureModel
    @State private var contextDrawerPresented = false

    /// Details open only for something selected; the day page is full width
    /// otherwise.
    private var hasContextSelection: Bool {
        model.selection != nil || model.selectedSessionID != nil || model.selectedSnapshotID != nil
            || model.showsRawCapture || !app.selectedMeetingIDs.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let usesDrawer = proxy.size.width < WorkspaceMetric.timelineDrawerBreakpoint
            VStack(spacing: 0) {
                TimelineWorkspaceHeader(
                    model: model,
                    showsContextToggle: usesDrawer && hasContextSelection,
                    usesCompactHeader: proxy.size.width < 1_000,
                    contextPresented: $contextDrawerPresented)
                Divider()

                if usesDrawer {
                    ZStack(alignment: .trailing) {
                        CaptureDayView(model: model) {
                            contextDrawerPresented = true
                        }

                        if contextDrawerPresented, hasContextSelection {
                            Color.black.opacity(0.16)
                                .contentShape(Rectangle())
                                .onTapGesture { contextDrawerPresented = false }
                                .transition(.opacity)

                            TimelineContextPanel(
                                model: model,
                                onDismiss: { contextDrawerPresented = false })
                                .frame(width: min(
                                    model.showsRawCapture ? 900 : WorkspaceMetric.timelineDrawerMaxWidth,
                                    max(320, proxy.size.width - 72)))
                                .background(.regularMaterial)
                                .shadow(color: .black.opacity(0.24), radius: 20, x: -8)
                                .transition(WorkspaceMotion.drawerTransition(
                                    reduceMotion: reduceMotion))
                        }
                    }
                } else {
                    HSplitView {
                        // Selection replaces the digest with its details until
                        // Back returns to the day; the sessions rail stays put.
                        Group {
                            if hasContextSelection {
                                TimelineContextPanel(model: model, onDismiss: nil)
                            } else {
                                CaptureDayView(model: model, includesSessions: false, onOpenContext: {})
                            }
                        }
                        .frame(minWidth: WorkspaceMetric.timelineDayMinWidth,
                               maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("timeline.evidencePane")
                        .splitPaneAccessibilityLabel("Timeline day")
                        ScrollView {
                            TimelineOverviewAndSessions(model: model, onOpenContext: {})
                                .padding(16)
                        }
                        .frame(minWidth: WorkspaceMetric.timelineRailMinWidth,
                               idealWidth: WorkspaceMetric.timelineRailIdealWidth,
                               maxWidth: WorkspaceMetric.timelineRailMaxWidth(in: proxy.size.width),
                               maxHeight: .infinity)
                        .background(.background.secondary)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("timeline.sessionRail")
                        .splitPaneAccessibilityLabel(
                            "Work sessions",
                            autosaveName: "LokalBot.timeline.sessions.v7",
                            initialWidth: WorkspaceMetric.timelineRailIdealWidth)
                    }
                    .detailSplitMinimumWidth([WorkspaceMetric.timelineDayMinWidth, WorkspaceMetric.timelineRailMinWidth])
                    .id("workspace.timeline")
                }
            }
            .animation(
                WorkspaceMotion.animation(.drawer, reduceMotion: reduceMotion),
                value: contextDrawerPresented)
            .onAppear {
                if usesDrawer, model.selection != nil || model.selectedSessionID != nil
                    || model.selectedSnapshotID != nil || !app.selectedMeetingIDs.isEmpty {
                    contextDrawerPresented = true
                }
            }
            .onChange(of: model.selection) { _, selection in
                if usesDrawer, selection != nil { contextDrawerPresented = true }
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                if usesDrawer, sessionID != nil { contextDrawerPresented = true }
            }
            .onChange(of: model.selectedSnapshotID) { _, snapshotID in
                if usesDrawer, snapshotID != nil { contextDrawerPresented = true }
            }
            .onChange(of: model.showsRawCapture) { _, showsRawCapture in
                if usesDrawer, showsRawCapture { contextDrawerPresented = true }
            }
            .onChange(of: app.selectedMeetingIDs) { _, meetingIDs in
                if usesDrawer, !meetingIDs.isEmpty { contextDrawerPresented = true }
            }
            .onChange(of: usesDrawer) { _, isDrawerLayout in
                if !isDrawerLayout { contextDrawerPresented = false }
            }
        }
        .navigationTitle("Timeline")
        .overlay(alignment: .topTrailing) {
            if model.overviewLoading { ProgressView().controlSize(.small).padding(12) }
        }
        .task {
            model.reload(app: app)
            clearMeetingSelectionOutsideSelectedDay()
        }
        .onAppear(perform: consumePendingScreenMoment)
        .onChange(of: app.navigationHandoff.revision) { consumePendingScreenMoment() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TrackingPauseButton(sampler: app.sampler, presentation: .toolbar)
                Button {
                    model.reload(app: app)
                    clearMeetingSelectionOutsideSelectedDay()
                } label: {
                    Label("Refresh timeline", systemImage: "arrow.clockwise")
                }
                .help("Reload the selected day's local activity")
            }
        }
    }

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

// MARK: - Persistent day header

private struct TimelineWorkspaceHeader: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let showsContextToggle: Bool
    let usesCompactHeader: Bool
    @Binding var contextPresented: Bool
    @State private var showingCalendar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesCompactHeader {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        dayControls.fixedSize()
                        Spacer(minLength: 8)
                        if showsContextToggle { contextToggle }
                    }
                    digestControls
                }
            } else {
                HStack(spacing: 8) {
                    dayControls.fixedSize()
                    Spacer(minLength: 12)
                    digestControls.fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var digestControls: some View {
        HStack(spacing: 8) {
            DayDigestControls(model: model, identifier: "timeline", regeneratesFromMenu: true)
        }
    }

    private var dayControls: some View {
        HStack(spacing: 7) {
            Button { changeDay(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            .accessibilityIdentifier("timeline.previousDay")
            Button {
                showingCalendar = true
            } label: {
                Label(model.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                      systemImage: "calendar")
                    .monospacedDigit()
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
            Button { changeDay(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .accessibilityIdentifier("timeline.nextDay")
            .disabled(Calendar.current.isDateInToday(model.day))
            // On today the jump back has nowhere to go, so it reads as a label.
            if Calendar.current.isDateInToday(model.day) {
                Text("Today")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            } else {
                Button("Today") { changeDay(to: Date()) }
                    .accessibilityIdentifier("timeline.today")
            }
        }
    }

    private var contextToggle: some View {
        Button {
            contextPresented.toggle()
        } label: {
            Label(contextLabel, systemImage: "sidebar.trailing")
        }
        .help(contextPresented ? "Hide day context" : "Show day context")
        .accessibilityIdentifier("timeline.context.toggle")
    }

    private var contextLabel: LocalizedStringKey {
        if model.selectedSnapshotID != nil { return "Moment" }
        if !app.selectedMeetingIDs.isEmpty { return "Meeting" }
        if model.selectedSessionID != nil { return "Session" }
        if model.selection != nil { return "Activity" }
        if model.showsRawCapture { return "Raw capture" }
        return "Details"
    }

    private var digestUpdatedHelp: String {
        guard let updatedAt = model.digestUpdatedAt else { return "Day digest actions" }
        return "Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
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
}

// MARK: - Day sessions

/// The day's digest with its open actions. Narrow layouts also place the
/// day's totals and the work sessions here; wide layouts keep them in the
/// trailing rail.
struct CaptureDayView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    var includesSessions = true
    let onOpenContext: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LBTokens.Metric.sectionSpacing) {
                TimelineDigestStatus(model: model, lifecycle: app.dayDigest)

                NeedsAttentionSection(threads: app.outcomeIndex.openUserActionThreads.filter { thread in
                    thread.references.contains { Calendar.current.isDate($0.meetingStartedAt, inSameDayAs: model.day) }
                }, limit: 3, style: .plain)

                if let digest = model.digest {
                    DayDigestView(digest, mode: .timeline)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("capture.dayDigest.text")
                    if let updated = model.digestUpdatedAt, !model.digestIsStale {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.tertiary)
                    }
                }

                if includesSessions {
                    Divider()
                    TimelineOverviewAndSessions(model: model, onOpenContext: onOpenContext)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// The digest's state above the day: an invitation before the first digest,
/// progress while one is written, and an Update button once activity has
/// arrived since the last one. A current digest needs no line at all.
private struct TimelineDigestStatus: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    @ObservedObject var lifecycle: DayDigestLifecycle

    var body: some View {
        let busy = model.generating || lifecycle.isGenerating(on: model.day)
        Group {
            if busy {
                strip {
                    ProgressView().controlSize(.small)
                    Text(model.digest == nil ? "Writing this day's digest…" : "Updating the digest with new activity…")
                }
            } else if model.digest == nil {
                Text("Your digest brings together this day's meetings and captured activity.")
                    .workspaceTextRole(.supporting)
            } else if model.digestIsStale {
                strip {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(LBTokens.Palette.accentText)
                        .accessibilityHidden(true)
                    staleMessage
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capture.dayDigest.stale")
                    Spacer(minLength: 8)
                    Button("Update Digest") { Task { await model.generateDigest(app: app) } }
                        .buttonStyle(.borderedProminent)
                        .tint(LBTokens.Palette.accentFill)
                        .accessibilityIdentifier("timeline.dayDigest.update")
                }
            }
            if let error = model.digestError {
                Label(error, systemImage: "exclamationmark.triangle").workspaceTextRole(.warning)
            }
        }
    }

    private var staleMessage: Text {
        if let updated = model.digestUpdatedAt {
            return Text("New activity since this digest was written at \(updated.formatted(date: .omitted, time: .shortened)).")
        }
        return Text("New activity since this digest was written.")
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(AppFont.scaled(.body))
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(Brand.teal.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
    }
}

/// The day's totals above the work sessions, so they lead the list.
struct TimelineOverviewAndSessions: View {
    @ObservedObject var model: CaptureModel
    let onOpenContext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LBTokens.Metric.sectionSpacing) {
            TimelineDayTotals(model: model)
            TimelineSessionsSection(model: model, onOpenContext: onOpenContext)
        }
    }
}

/// Tracked time as the one large number, the day's counts beneath it, and the
/// split by project, or by app on a day without coding-agent evidence.
/// Nothing shows for a day without activity: the sessions list explains that.
private struct TimelineDayTotals: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel

    /// One legend entry and bar segment.
    struct Row: Identifiable {
        enum Kind { case app, otherApps, project, otherProjects, otherActivity }
        let label: String
        let seconds: TimeInterval
        let kind: Kind
        var id: String { "\(kind)-\(label)" }
    }

    var body: some View {
        let perApp = DayActivityOverview.perApp(model.blocks)
        let split = model.projectSplit
        let meetingCount = model.meetings(in: app).count
        if !perApp.isEmpty || meetingCount > 0 {
            let rows = split.projects.isEmpty ? Self.appRows(perApp) : Self.projectRows(split)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(CaptureStyle.hm(perApp.reduce(0) { $0 + $1.seconds }))
                            .font(AppFont.scaledSystem(size: 24, weight: .semibold).monospacedDigit())
                        Text("tracked")
                            .font(AppFont.scaled(.body))
                            .foregroundStyle(.secondary)
                    }
                    countsLine(appCount: perApp.count, projectCount: split.projects.count,
                               meetingCount: meetingCount)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                }
                if !rows.isEmpty {
                    ProportionBar(segments: split.projects.isEmpty
                                  ? Self.appSegments(perApp) : Self.segments(rows), height: 8)
                    legend(rows)
                }
                if let outcomes = TimelineOutcomeText.text(model.dayOutcomes) {
                    Label {
                        outcomes
                    } icon: {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(LBTokens.Palette.accentText)
                    }
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                    .accessibilityIdentifier("timeline.dayOutcomes")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.dayOverview")
        }
    }

    static func appRows(_ perApp: [(label: String, seconds: TimeInterval)]) -> [Row] {
        AppTimePresentation.rows(perApp: perApp).map {
            Row(label: $0.label, seconds: $0.seconds, kind: $0.isOther ? .otherApps : .app)
        }
    }

    /// The four busiest projects, the rest folded together, then the time no
    /// project claims.
    static func projectRows(_ split: TimelineProjectAttribution.DaySplit, cap: Int = 4) -> [Row] {
        var rows: [Row] = []
        var otherSeconds: TimeInterval = 0
        for share in split.projects {
            if rows.count < cap, share.seconds >= 60 {
                rows.append(Row(label: share.project, seconds: share.seconds, kind: .project))
            } else {
                otherSeconds += share.seconds
            }
        }
        if otherSeconds >= 60 {
            rows.append(Row(label: "Other projects", seconds: otherSeconds, kind: .otherProjects))
        }
        if split.unattributedSeconds >= 60 {
            rows.append(Row(label: "Other activity", seconds: split.unattributedSeconds, kind: .otherActivity))
        }
        return rows
    }

    private static func appSegments(
        _ perApp: [(label: String, seconds: TimeInterval)]
    ) -> [(segment: ProportionBarMath.Segment, color: Color)] {
        ProportionBarMath.segments(perApp: perApp).map {
            ($0, $0.label == "Other" ? Color.gray : CaptureStyle.color(for: $0.label))
        }
    }

    private static func segments(_ rows: [Row]) -> [(segment: ProportionBarMath.Segment, color: Color)] {
        let total = rows.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        return rows.map { row in
            (ProportionBarMath.Segment(label: row.label, fraction: row.seconds / total), color(for: row))
        }
    }

    static func color(for row: Row) -> Color {
        switch row.kind {
        case .app, .project: CaptureStyle.color(for: row.label)
        case .otherProjects: Color.gray.opacity(0.55)
        case .otherApps, .otherActivity: Color.gray
        }
    }

    /// Each count is its own catalog entry, so every language words it.
    private func countsLine(appCount: Int, projectCount: Int, meetingCount: Int) -> Text {
        let sessionCount = model.workSessions.count
        var parts = [Text(sessionCount == 1 ? "\(sessionCount) work session" : "\(sessionCount) work sessions")]
        if meetingCount > 0 {
            parts.append(Text(meetingCount == 1 ? "\(meetingCount) meeting" : "\(meetingCount) meetings"))
        }
        if projectCount > 0 {
            parts.append(Text(projectCount == 1 ? "\(projectCount) project" : "\(projectCount) projects"))
        } else {
            parts.append(Text(appCount == 1 ? "\(appCount) app" : "\(appCount) apps"))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// Two columns, each entry's time flush right so the numbers line up.
    /// App and project names are shown as captured; the folded entries are
    /// interface copy.
    private func legend(_ rows: [Row]) -> some View {
        let pairs = stride(from: 0, to: rows.count, by: 2).map {
            Array(rows[$0..<min($0 + 2, rows.count)])
        }
        return Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            ForEach(pairs.indices, id: \.self) { index in
                GridRow {
                    ForEach(pairs[index]) { row in
                        HStack(spacing: 7) {
                            StatusDot(color: Self.color(for: row), size: 7)
                            label(row).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(CaptureStyle.hm(row.seconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(AppFont.scaled(.callout))
    }

    private func label(_ row: Row) -> Text {
        switch row.kind {
        case .app, .otherApps, .project: Text(verbatim: row.label)
        case .otherProjects: Text("Other projects")
        case .otherActivity: Text("Other activity")
        }
    }
}

/// "3 PRs opened · 1 merged", or the commits when no pull request moved.
/// Each count is its own catalog entry, so every language words it.
enum TimelineOutcomeText {
    static func text(_ outcomes: TimelineAgentOutcomes) -> Text? {
        var parts: [Text] = []
        let opened = outcomes.openedPullRequests.count
        if opened > 0 {
            parts.append(Text(opened == 1 ? "\(opened) PR opened" : "\(opened) PRs opened"))
        }
        let merged = outcomes.mergedPullRequests
        if merged > 0 { parts.append(Text("\(merged) merged")) }
        let commits = outcomes.commits
        if parts.isEmpty, commits > 0 {
            parts.append(Text(commits == 1 ? "\(commits) commit" : "\(commits) commits"))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }
}

/// Work sessions and meetings in order on one line, with long stretches of
/// no activity marked, followed by Browse Raw Capture.
struct TimelineSessionsSection: View {
    @EnvironmentObject var app: AppState
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var model: CaptureModel
    let onOpenContext: () -> Void

    var body: some View {
        let meetings = model.meetings(in: app)
        let sessions = model.workSessions
        VStack(alignment: .leading, spacing: 8) {
            if model.blocks.isEmpty && meetings.isEmpty && model.shots.isEmpty {
                ContentUnavailableView(
                    "No activity recorded",
                    systemImage: "clock",
                    description: Text(app.settings.trackingEnabled
                        ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                        : "Day tracking is off — enable it in Settings."))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Sessions")
                        .font(.scaled(.headline))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("timeline.workSessions")
                    Text(sessions.count + meetings.count, format: .number)
                        .font(AppFont.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if meetings.contains(where: { $0.endedAt == nil }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        sessionList(sessions: sessions, meetings: meetings, now: context.date)
                    }
                } else {
                    sessionList(sessions: sessions, meetings: meetings, now: Date())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sessionList(
        sessions: [TimelineWorkSession],
        meetings: [Meeting],
        now: Date
    ) -> some View {
        let rows = TimelineRailRow.rows(
            items: TimelineDayItem.items(sessions: sessions, meetings: meetings, now: now))
        let metrics = TimelineRailMetrics(textScale: textScale)
        // In narrow layouts the sessions follow the digest and Needs
        // Attention. A lazy stack would leave those rows out of the
        // accessibility tree until scrolled; the bounded list stays eager.
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No meaningful sessions",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Only system activity or raw context was captured. You can still inspect it below."))
                    .padding(.vertical, 28)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .item(.work(let session)):
                            TimelineWorkSessionRow(
                                session: session,
                                sceneCount: model.frames(in: session).count,
                                metrics: metrics,
                                isSelected: model.selectedSessionID == session.id,
                                onSelect: { selectSession(session) })
                        case .item(.meeting(let meeting, let end)):
                            TimelineSessionMeetingRow(
                                meeting: meeting,
                                end: end,
                                metrics: metrics,
                                isSelected: app.selectedMeetingIDs == [meeting.id],
                                onSelect: { selectMeeting(meeting.id) })
                        case .away(let start, let end):
                            TimelineAwayRow(start: start, end: end, metrics: metrics)
                        }
                    }
                }
                // One line runs through the dots, so the list reads as a day.
                .background(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1.5)
                        .padding(.vertical, 14)
                        .offset(x: metrics.dotCenterX - 0.75)
                        .accessibilityHidden(true)
                }
            }

            rawCaptureRow
                .padding(.top, 12)
        }
        .padding(.bottom, 8)
    }

    /// Opens raw activity and capture cleanup in the main column, where the
    /// hour track has room to be read.
    private var rawCaptureRow: some View {
        let isSelected = model.showsRawCapture
        return Button {
            let willSelect = !model.showsRawCapture
            model.selection = nil
            model.selectedSessionID = nil
            model.selectedSnapshotID = nil
            app.selectedMeetingIDs = []
            model.showsRawCapture = willSelect
            if willSelect { onOpenContext() }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Raw Capture")
                        .font(TimelineRailStyle.titleEmphasis)
                    rawCaptureCounts
                        .font(TimelineRailStyle.detail.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Brand.teal.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            .overlay(alignment: .top) {
                if !isSelected { Divider() }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse raw capture")
        .accessibilityValue(isSelected ? "Open" : "")
        .accessibilityIdentifier("timeline.rawCapture")
    }

    private var rawCaptureCounts: Text {
        let entries = model.blocks.count
        let moments = model.rewindFrames.count
        return Text(entries == 1 ? "\(entries) activity entry" : "\(entries) activity entries")
            + Text(verbatim: " · ")
            + Text(moments == 1 ? "\(moments) screen moment" : "\(moments) screen moments")
    }

    private func selectSession(_ session: TimelineWorkSession) {
        let willSelect = model.selectedSessionID != session.id
        model.selectedSessionID = willSelect ? session.id : nil
        model.showsRawCapture = false
        model.selection = nil
        model.selectedSnapshotID = nil
        app.selectedMeetingIDs = []
        if willSelect { onOpenContext() }
    }

    private func selectMeeting(_ id: Meeting.ID) {
        let willSelect = app.selectedMeetingIDs != [id]
        model.showsRawCapture = false
        model.selection = nil
        model.selectedSessionID = nil
        model.selectedSnapshotID = nil
        app.selectedMeetingIDs = willSelect ? [id] : []
        if willSelect { onOpenContext() }
    }

}

// MARK: - Raw capture

/// Individual activity blocks for exact evidence. Shown in the main column so
/// the hour track is readable without nested scrolling in the rail.
struct TimelineRawCaptureView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel

    var body: some View {
        let meetings = model.meetings(in: app)
        VStack(alignment: .leading, spacing: 14) {
            Text("Individual app activity and retained screen moments. Use this for exact evidence or cleanup.")
                .font(AppFont.scaled(.callout))
                .foregroundStyle(.secondary)
            if !model.blocks.isEmpty || !meetings.isEmpty {
                Label("App activity", systemImage: "calendar.day.timeline.left")
                    .font(AppFont.scaled(.headline))
                    .accessibilityIdentifier("timeline.track")
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

/// The work-session rail is a scannable index beside the digest, so its rows
/// use list-sized titles on a single line.
private enum TimelineRailStyle {
    static var title: AppFont { AppFont.scaledSystem(size: 13) }
    static var titleEmphasis: AppFont { AppFont.scaledSystem(size: 13, weight: .medium) }
    static var detail: AppFont { AppFont.scaledSystem(size: 12) }
    static var detailEmphasis: AppFont { AppFont.scaledSystem(size: 12, weight: .semibold) }
    static let rowPadding: CGFloat = 7

    static func rowBackground(selected: Bool, hovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: Brand.Radius.row)
            .fill(selected ? Brand.teal.opacity(0.11)
                  : hovering ? Color.primary.opacity(0.04) : .clear)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Brand.Radius.row)
                        .strokeBorder(Brand.teal.opacity(0.8), lineWidth: 1)
                }
            }
    }
}

/// Column widths of a rail row. The time column follows the text size and
/// the clock: "18:45" needs less room than "10:40 AM".
private struct TimelineRailMetrics {
    let timeWidth: CGFloat
    let dotColumn: CGFloat = 12
    let spacing: CGFloat = 8

    init(textScale: CGFloat) {
        timeWidth = ((Self.usesDayPeriod ? 58 : 38) * max(1, textScale)).rounded()
    }

    var dotCenterX: CGFloat { timeWidth + spacing + dotColumn / 2 }

    private static let usesDayPeriod: Bool =
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
}

private struct TimelineRailTime: View {
    let date: Date
    let metrics: TimelineRailMetrics
    var emphasis: Color?

    var body: some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font((emphasis == nil ? TimelineRailStyle.detail : TimelineRailStyle.detailEmphasis).monospacedDigit())
            .foregroundStyle(emphasis.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(width: metrics.timeWidth, alignment: .trailing)
    }
}

private struct TimelineRailDot: View {
    let color: Color
    let metrics: TimelineRailMetrics

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(2)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .frame(width: metrics.dotColumn)
            .accessibilityHidden(true)
    }
}

private struct TimelineWorkSessionRow: View {
    let session: TimelineWorkSession
    let sceneCount: Int
    let metrics: TimelineRailMetrics
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let outcomes = TimelineOutcomeText.text(session.outcomes)
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing) {
                TimelineRailTime(date: session.start, metrics: metrics)
                // A project session takes its project's color, so the rail
                // and the day's split read together.
                TimelineRailDot(color: CaptureStyle.color(for: session.project ?? session.primaryApp),
                                metrics: metrics)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    // A title that only lists apps stays quieter than one that
                    // names what was open.
                    Text(session.title)
                        .font(session.titleNamesApps && !session.titleNamesProject
                              ? TimelineRailStyle.title : TimelineRailStyle.titleEmphasis)
                        .foregroundStyle(session.titleNamesApps && !session.titleNamesProject
                            ? AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting))
                            : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let outcomes {
                        outcomes
                            .font(TimelineRailStyle.detail.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(CaptureStyle.hm(session.activeDuration))
                    .font(TimelineRailStyle.detailEmphasis.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.vertical, TimelineRailStyle.rowPadding)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(TimelineRailStyle.rowBackground(selected: isSelected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(outcomes.map { Text("Work session, \(session.title)") + Text(verbatim: ", ") + $0 }
            ?? Text("Work session, \(session.title)"))
        .accessibilityValue("\(session.start.formatted(date: .omitted, time: .shortened)) to \(session.end.formatted(date: .omitted, time: .shortened)), \(CaptureStyle.hm(session.activeDuration)), \(session.appCount) apps, \(sceneCount) context scenes\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this work session in the context panel")
        .accessibilityIdentifier("timeline.session.\(session.id)")
    }

    private var helpText: String {
        let range = "\(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened))"
        return "\(session.title)\n\(range) · \(session.apps.joined(separator: ", "))"
    }
}

private struct TimelineSessionMeetingRow: View {
    let meeting: Meeting
    let end: Date
    let metrics: TimelineRailMetrics
    let isSelected: Bool
    let onSelect: () -> Void

    private var isLive: Bool { meeting.endedAt == nil }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: metrics.spacing) {
                TimelineRailTime(date: meeting.startedAt, metrics: metrics,
                                 emphasis: isLive ? Brand.recording : LBTokens.Palette.accentText)
                TimelineRailDot(color: isLive ? Brand.recording : Brand.teal, metrics: metrics)
                // The one tinted row: meetings are first-class events in the day.
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .font(TimelineRailStyle.detail)
                        .foregroundStyle(LBTokens.Palette.accentText)
                        .accessibilityHidden(true)
                    Text(meeting.displayTitle)
                        .font(TimelineRailStyle.titleEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(meeting.displayTitle)
                    Text(isLive ? "Recording" : "Meeting")
                        .font(TimelineRailStyle.detail)
                        .foregroundStyle(isLive ? Brand.recording : LBTokens.Palette.accentText)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(CaptureStyle.hm(end.timeIntervalSince(meeting.startedAt)))
                        .font(TimelineRailStyle.detailEmphasis.monospacedDigit())
                        .foregroundStyle(LBTokens.Palette.accentText)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Brand.teal.opacity(isSelected ? 0.16 : 0.07),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.row))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.row)
                        .strokeBorder(Brand.teal.opacity(isSelected ? 0.85 : 0.22), lineWidth: 1)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Meeting, \(meeting.displayTitle)")
        .accessibilityValue("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)), \(CaptureStyle.hm(end.timeIntervalSince(meeting.startedAt)))\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this meeting in the context panel")
        .accessibilityIdentifier("capture.meeting.\(meeting.id.uuidString)")
    }
}

/// A stretch with nothing recorded between two rows.
private struct TimelineAwayRow: View {
    let start: Date
    let end: Date
    let metrics: TimelineRailMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            Color.clear.frame(width: metrics.timeWidth + metrics.spacing + metrics.dotColumn, height: 1)
            Text("Away \(CaptureStyle.hm(end.timeIntervalSince(start)))")
                .font(TimelineRailStyle.detail)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No activity from \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day chronology")
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
