import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The Timeline section groups low-level capture blocks into human-scale Work
/// sessions and interleaves meetings as first-class events. The lossless raw
/// activity and moment rail remain available behind a secondary disclosure.
@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var day = Date()
    @Published var blocks: [ActivityBlock] = [] {
        didSet { workSessions = DayActivityProjection(blocks: blocks, day: day).sessions }
    }
    @Published var shots: [ActivityStore.Screenshot] = []
    @Published private(set) var rewindFrames: [ScreenRewindFrame] = []
    @Published var selection: ActivityBlock.ID?
    @Published var selectedSessionID: TimelineWorkSession.ID?
    @Published var selectedSnapshotID: Int64?
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
        blocks = []; shots = []; rewindFrames = []
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
                return (store.blocks(on: requestedDay), shots, loadDigest(store))
            }
            guard !Task.isCancelled, generation == overviewGeneration else { return }
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
        guard !generating else { return }
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
            StatTile(icon: "square.grid.2x2", value: "\(appCount)",
                     label: appCount == 1 ? "app" : "apps")
            StatTile(icon: "rectangle.and.text.magnifyingglass", value: "\(momentCount)",
                     label: "moments")
            if meetingCount > 0 {
                StatTile(icon: "waveform", value: "\(meetingCount)",
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
            StatTile(icon: "clock", value: CaptureStyle.hm(activeSeconds), label: "active")
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

    var body: some View {
        GeometryReader { proxy in
            let usesDrawer = proxy.size.width < WorkspaceMetric.timelineDrawerBreakpoint
            VStack(spacing: 0) {
                TimelineWorkspaceHeader(
                    model: model,
                    showsContextToggle: usesDrawer,
                    contextPresented: $contextDrawerPresented)
                Divider()

                if usesDrawer {
                    ZStack(alignment: .trailing) {
                        CaptureDayView(model: model) {
                            contextDrawerPresented = true
                        }

                        if contextDrawerPresented {
                            Color.black.opacity(0.16)
                                .contentShape(Rectangle())
                                .onTapGesture { contextDrawerPresented = false }
                                .transition(.opacity)

                            TimelineContextPanel(
                                model: model,
                                onDismiss: { contextDrawerPresented = false })
                                .frame(width: min(
                                    WorkspaceMetric.timelineDrawerMaxWidth,
                                    max(320, proxy.size.width - 72)))
                                .background(.regularMaterial)
                                .shadow(color: .black.opacity(0.24), radius: 20, x: -8)
                                .transition(WorkspaceMotion.drawerTransition(
                                    reduceMotion: reduceMotion))
                        }
                    }
                } else {
                    HSplitView {
                        TimelineContextPanel(model: model, onDismiss: nil)
                            .frame(minWidth: 340, idealWidth: 520, maxWidth: WorkspaceMetric.readingMaxWidth)
                            .splitPaneAccessibilityLabel("Timeline evidence")
                        CaptureDayView(model: model, onOpenContext: {})
                            .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity)
                            .splitPaneAccessibilityLabel("Day timeline")
                    }
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
    @Binding var contextPresented: Bool

    var body: some View {
        let meetings = model.meetings(in: app)
        let sessions = model.workSessions
        let active = sessions.reduce(0) { $0 + $1.activeDuration }
        VStack(alignment: .leading, spacing: 10) {
            if showsContextToggle {
                HStack(spacing: 8) {
                    dayControls
                    Spacer(minLength: 8)
                    contextToggle
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    askButton
                    regenerateButton
                    digestActions
                }
            } else {
                HStack(spacing: 8) {
                    dayControls
                    Spacer(minLength: 12)
                    askButton
                    regenerateButton
                    digestActions
                }
            }

            TimelineSessionStatRow(
                activeSeconds: active,
                sessionCount: sessions.count,
                meetingCount: meetings.count)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var dayControls: some View {
        HStack(spacing: 7) {
            Button { changeDay(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            .accessibilityIdentifier("timeline.previousDay")
            DatePicker("", selection: daySelection, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("timeline.dayPicker")
            Button("Today") { changeDay(to: Date()) }
                .disabled(Calendar.current.isDateInToday(model.day))
                .accessibilityIdentifier("timeline.today")
            Button { changeDay(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .accessibilityIdentifier("timeline.nextDay")
            .disabled(Calendar.current.isDateInToday(model.day))
        }
    }

    private var regenerateButton: some View {
        Button {
            Task { await model.generateDigest(app: app) }
        } label: {
            if model.generating {
                LoadingStateLabel("Updating digest…")
            } else {
                Label(model.digest == nil ? "Write day digest" : "Rewrite day digest",
                      systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.generating)
        .help("Rewrite the day digest using the latest activity and meetings")
        .accessibilityIdentifier("timeline.dayDigest.generate")
    }

    private var askButton: some View {
        Button {
            app.openAsk(dayScope: model.day)
        } label: {
            Label("Ask about day", systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("capture.askDay")
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

    @ViewBuilder private var digestActions: some View {
        if let digest = model.digest {
            Menu {
                Button { model.copyDigest(digest) } label: {
                    Label("Copy digest", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("capture.dayDigest.copyAll")
                Button { model.exportDigest(digest) } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("Digest actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(digestUpdatedHelp)
            .accessibilityLabel("Day digest actions")
            .accessibilityIdentifier("timeline.dayDigest.actions")
        }
    }

    private var contextLabel: String {
        if model.selectedSnapshotID != nil { return "Moment" }
        if !app.selectedMeetingIDs.isEmpty { return "Meeting" }
        if model.selectedSessionID != nil { return "Session" }
        if model.selection != nil { return "Activity" }
        return "Day digest"
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
        guard !Calendar.current.isDate(day, inSameDayAs: model.day) else { return }
        app.selectedMeetingIDs = []
        model.selectDay(day, app: app)
    }
}

// MARK: - Day sessions

struct CaptureDayView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    let onOpenContext: () -> Void
    @State private var rawCaptureExpanded = false

    var body: some View {
        let meetings = model.meetings(in: app)
        let sessions = model.workSessions
        VStack(alignment: .leading, spacing: 10) {
            if model.blocks.isEmpty && meetings.isEmpty && model.shots.isEmpty {
                ContentUnavailableView(
                    "No activity recorded",
                    systemImage: "clock",
                    description: Text(app.settings.trackingEnabled
                        ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                        : "Day tracking is off — enable it in Settings."))
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    Label("Work sessions", systemImage: "rectangle.stack")
                        .font(WorkspaceTypography.sectionTitle)
                        .accessibilityIdentifier("timeline.workSessions")
                    Spacer()
                    Text("Select a session to inspect its evidence")
                        .font(WorkspaceTypography.metadata)
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionList(
        sessions: [TimelineWorkSession],
        meetings: [Meeting],
        now: Date
    ) -> some View {
        let items = TimelineDayItem.items(sessions: sessions, meetings: meetings, now: now)
        return ScrollView {
            LazyVStack(spacing: 8) {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No meaningful sessions",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text("Only system activity or raw context was captured. You can still inspect it below."))
                        .padding(.vertical, 28)
                } else {
                    ForEach(items) { item in
                        switch item {
                        case .work(let session):
                            TimelineWorkSessionRow(
                                session: session,
                                sceneCount: model.frames(in: session).count,
                                isSelected: model.selectedSessionID == session.id,
                                onSelect: { selectSession(session) })
                        case .meeting(let meeting, let end):
                            TimelineSessionMeetingRow(
                                meeting: meeting,
                                end: end,
                                isSelected: app.selectedMeetingIDs == [meeting.id],
                                onSelect: { selectMeeting(meeting.id) })
                        }
                    }
                }

                rawCapture(meetings: meetings, now: now)
                    .padding(.top, 4)
            }
            .padding(.bottom, 8)
        }
    }

    private func rawCapture(meetings: [Meeting], now: Date) -> some View {
        WorkspaceDisclosure(
            isExpanded: $rawCaptureExpanded,
            identifier: "timeline.rawCapture") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Individual app blocks and every retained context scene. Use this for exact evidence or cleanup.")
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(.secondary)

                    if !model.rewindFrames.isEmpty {
                        ScreenRewindView(
                            frames: model.rewindFrames,
                            selectedSnapshotID: screenSelection,
                            onReload: { model.reload(app: app) },
                            presentation: .compact)
                    }

                    if !model.blocks.isEmpty || !meetings.isEmpty {
                        Divider()
                        Label("Raw activity blocks", systemImage: "calendar.day.timeline.left")
                            .font(WorkspaceTypography.sectionTitle)
                            .accessibilityIdentifier("timeline.track")
                        rawTrack(meetings: meetings, now: now)
                            .frame(height: 360)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Browse raw capture", systemImage: "waveform.path.ecg.rectangle")
                        .font(WorkspaceTypography.bodyEmphasis)
                    Text("\(model.blocks.count) blocks · \(model.rewindFrames.count) scenes")
                        .font(WorkspaceTypography.metadata.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func rawTrack(meetings: [Meeting], now: Date) -> some View {
        CaptureTrackView(
            items: CaptureTrackItem.items(blocks: model.blocks,
                                          meetings: meetings,
                                          now: now),
            blockSelection: model.selection,
            selectedMeetingIDs: app.selectedMeetingIDs,
            onSelectBlock: { id in
                model.selection = id
                model.selectedSessionID = nil
                if id != nil {
                    model.selectedSnapshotID = nil
                    app.selectedMeetingIDs = []
                    onOpenContext()
                }
            },
            onSelectMeeting: { id in
                let willSelect = app.selectedMeetingIDs != [id]
                model.selection = nil
                model.selectedSessionID = nil
                model.selectedSnapshotID = nil
                app.selectedMeetingIDs = willSelect ? [id] : []
                if willSelect { onOpenContext() }
            })
    }

    private func selectSession(_ session: TimelineWorkSession) {
        let willSelect = model.selectedSessionID != session.id
        model.selectedSessionID = willSelect ? session.id : nil
        model.selection = nil
        model.selectedSnapshotID = nil
        app.selectedMeetingIDs = []
        if willSelect { onOpenContext() }
    }

    private func selectMeeting(_ id: Meeting.ID) {
        let willSelect = app.selectedMeetingIDs != [id]
        model.selection = nil
        model.selectedSessionID = nil
        model.selectedSnapshotID = nil
        app.selectedMeetingIDs = willSelect ? [id] : []
        if willSelect { onOpenContext() }
    }

    private var screenSelection: Binding<Int64?> {
        Binding(get: { model.selectedSnapshotID }, set: { snapshotID in
            model.selectedSnapshotID = snapshotID
            if snapshotID != nil {
                model.selection = nil
                model.selectedSessionID = nil
                app.selectedMeetingIDs = []
                onOpenContext()
            }
        })
    }
}

private struct TimelineWorkSessionRow: View {
    let session: TimelineWorkSession
    let sceneCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                timeRange(start: session.start, end: session.end)
                IconTile(systemImage: "briefcase", tint: CaptureStyle.color(for: session.primaryApp),
                         size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(WorkspaceTypography.bodyEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(appSummary)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let context = secondaryContext {
                        Text(context)
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(CaptureStyle.hm(session.activeDuration))
                        .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                    if sceneCount > 0 {
                        Label("\(sceneCount)", systemImage: "rectangle.and.text.magnifyingglass")
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Brand.teal.opacity(0.11) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                    .strokeBorder(isSelected ? Brand.teal.opacity(0.8)
                                             : Color.primary.opacity(0.10),
                                  lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Work session, \(session.title)")
        .accessibilityValue("\(session.start.formatted(date: .omitted, time: .shortened)) to \(session.end.formatted(date: .omitted, time: .shortened)), \(CaptureStyle.hm(session.activeDuration)), \(session.appCount) apps, \(sceneCount) context scenes\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this work session in the context panel")
        .accessibilityIdentifier("timeline.session.\(session.id)")
    }

    private var appSummary: String {
        let visible = session.apps.prefix(3).joined(separator: " · ")
        let remaining = session.apps.count - min(3, session.apps.count)
        return remaining > 0 ? "\(visible) · +\(remaining)" : visible
    }

    private var secondaryContext: String? {
        let otherTitles = session.notableTitles.filter { $0 != session.title }.prefix(2)
        guard !otherTitles.isEmpty else {
            return session.contextSwitchCount > 0
                ? "\(session.contextSwitchCount) context switch\(session.contextSwitchCount == 1 ? "" : "es")"
                : nil
        }
        return otherTitles.joined(separator: " · ")
    }

    private func timeRange(start: Date, end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(start.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.primary)
            Text(end.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.tertiary)
        }
        .font(WorkspaceTypography.metadata.monospacedDigit())
        .frame(width: 60, alignment: .trailing)
    }
}

private struct TimelineSessionMeetingRow: View {
    let meeting: Meeting
    let end: Date
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.primary)
                    Text(end.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                }
                .font(WorkspaceTypography.metadata.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
                IconTile(systemImage: "waveform", tint: Brand.teal, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.displayTitle)
                        .font(WorkspaceTypography.bodyEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(meeting.endedAt == nil ? "Meeting · Recording in progress" : "Meeting")
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(meeting.endedAt == nil ? Brand.recording : .secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(CaptureStyle.hm(end.timeIntervalSince(meeting.startedAt)))
                        .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Brand.teal.opacity(0.13) : Brand.teal.opacity(0.045),
                in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                    .strokeBorder(isSelected ? Brand.teal.opacity(0.85)
                                             : Brand.teal.opacity(0.20),
                                  lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Meeting, \(meeting.displayTitle)")
        .accessibilityValue("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)), \(CaptureStyle.hm(end.timeIntervalSince(meeting.startedAt)))\(isSelected ? ", selected" : "")")
        .accessibilityHint("Show this meeting in the context panel")
        .accessibilityIdentifier("capture.meeting.\(meeting.id.uuidString)")
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
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
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
                            Text(block.app).font(.caption.weight(.medium)).lineLimit(1)
                            if !block.title.isEmpty && h >= 38 {
                                Text(block.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                .fill(Brand.teal.opacity(isSelected ? 1 : 0.85))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform").font(.caption2)
                            Text(meeting.title).font(.caption.weight(.medium)).lineLimit(1)
                        }
                        if h >= 38 {
                            Text(meeting.durationLabel).font(.caption2).opacity(0.8)
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
        .help("\(meeting.title)\n\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(meeting.durationLabel)")
        .accessibilityLabel("Meeting, \(meeting.displayTitle)")
        .accessibilityValue("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)), \(meeting.durationLabel)\(isSelected ? ", selected" : "")")
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
