import SwiftUI
import AppKit

/// The status-bar item itself. When recording it shows a record dot plus a live
/// MM:SS timer so a glance at the menu bar confirms a meeting is being captured
/// — no window required. Idle, it's the app glyph: dimmed while day memory is
/// paused, with a dot when something needs attention.
struct MenuBarLabel: View {
    /// Not AppState: the status item redraws only when its glyph can change.
    @ObservedObject var scene: AppSceneState
    let recording: RecordingController
    @ObservedObject var dictation: DictationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        glyph
            // The status item is the one view guaranteed to exist at launch in
            // pure menu-bar mode, so register the window opener here — otherwise
            // a Finder/Dock reopen (or first-run onboarding) would queue a
            // request with nothing alive to service it.
            .onAppear { WindowAccess.shared.register { openWindow(id: $0) } }
    }

    @ViewBuilder private var glyph: some View {
        if scene.values.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(LBTokens.Palette.recording)
                MeetingRecordingTimerText(recording: recording)
            }
                .monospacedDigit()
        } else if dictation.state.isRecording {
            Text("\(Image(systemName: "mic.circle.fill")) \(dictation.menuBarLabel)")
                .monospacedDigit()
        } else if dictation.state.isWorking {
            Image(systemName: "mic.and.signal.meter.fill")
        } else {
            let variant = MenuBarIcon.Variant(
                dimmed: scene.values.dayMemoryPaused, attention: scene.values.needsAttention)
            Image(nsImage: MenuBarIcon.image(variant))
                // The image already carries the dot, in the menu bar's own
                // ink. Where the status item draws SwiftUI shapes, this lays
                // the attention colour over it.
                .overlay(alignment: .topTrailing) {
                    if variant.attention {
                        Circle()
                            .fill(LBTokens.Palette.attention)
                            .frame(width: MenuBarIcon.badgeDiameter, height: MenuBarIcon.badgeDiameter)
                            .accessibilityHidden(true)
                    }
                }
                // The dot is drawn on the right edge in every language.
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(accessibilityLabel(variant))
        }
    }

    private func accessibilityLabel(_ variant: MenuBarIcon.Variant) -> Text {
        var label = Text(verbatim: "LokalBot")
        if variant.attention { label = label + Text(verbatim: ", ") + Text("Needs attention") }
        if variant.dimmed { label = label + Text(verbatim: ", ") + Text("Day memory is paused") }
        return label
    }
}

/// The LokalBot brand mark for the status item: a minimal robot head whose
/// face is a three-bar waveform — "bot" and "listens locally" in one glyph.
/// Drawn in code as a template image so it stays crisp at any backing scale
/// and picks up the menu bar's light/dark/highlight tinting for free. Its
/// states stay template images too: dimming is the glyph's own alpha, and
/// the attention dot is cut into the corner.
enum MenuBarIcon {
    struct Variant: Hashable {
        /// Day memory is paused: the glyph is drawn faint.
        var dimmed = false
        /// Something needs attention: a dot sits on the top right corner.
        var attention = false
    }

    static let size = NSSize(width: 18, height: 18)
    static let badgeDiameter: CGFloat = 6
    /// How much of the glyph's ink is left while day memory is paused.
    static let dimmedOpacity: CGFloat = 0.38
    /// The clear ring that separates the dot from the glyph under it.
    private static let badgeGap: CGFloat = 1.5

    @MainActor private static var cache: [Variant: NSImage] = [:]

    @MainActor
    static func image(_ variant: Variant) -> NSImage {
        if let cached = cache[variant] { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(variant)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LokalBot"
        cache[variant] = image
        return image
    }

    /// The dot's box, in the image's bottom-left coordinates: the top right corner.
    static var badgeRect: NSRect {
        NSRect(x: size.width - badgeDiameter, y: size.height - badgeDiameter,
               width: badgeDiameter, height: badgeDiameter)
    }

    private static func draw(_ variant: Variant) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // One layer, so overlapping strokes do not darken where they cross.
        context.saveGState()
        context.setAlpha(variant.dimmed ? dimmedOpacity : 1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawGlyph()
        context.endTransparencyLayer()
        context.restoreGState()

        guard variant.attention else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: badgeRect.insetBy(dx: -badgeGap, dy: -badgeGap))
        context.restoreGState()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }

    private static func drawGlyph() {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Head
        let head = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 10.5),
            xRadius: 3, yRadius: 3
        )
        head.lineWidth = 1.5
        head.stroke()

        // Antenna — stem long enough that the knob clearly separates from the head
        let stem = NSBezierPath()
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 9, y: 12))
        stem.line(to: NSPoint(x: 9, y: 13.9))
        stem.stroke()
        NSBezierPath(ovalIn: NSRect(x: 9 - 1.2, y: 15.4 - 1.2, width: 2.4, height: 2.4)).fill()

        // Waveform face — bars pixel-aligned so 1x rasterization keeps the gaps
        func bar(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x, y: y0))
            path.line(to: NSPoint(x: x, y: y1))
            path.stroke()
        }
        bar(5.5, 5.2, 7.6)
        bar(9.0, 3.8, 9.3)
        bar(12.5, 5.2, 7.6)
    }
}

/// The dropdown shown when the menu bar item is clicked: one status block,
/// then rows, like a system status menu. The primary surface for running
/// LokalBot without ever opening the main window.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator

    var body: some View {
        MenuBarPanel(app: app, dictation: dictation, approvals: app.settingsApprovals)
    }
}

private struct MenuBarPanel: View {
    @ObservedObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    /// AppState does not republish these; the status block lists them.
    @ObservedObject var approvals: SettingsApprovals
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appTextScale) private var textScale
    @State private var appeared = false
    /// Whether the panel's window is on screen; nil until it has been seen
    /// there once, which shows the window reports it at all.
    @State private var windowVisible: Bool?
    @State private var now = Date()
    @State private var schedule: [CalendarMeetingCandidate] = []
    @State private var captureWarnings: [String] = []
    @State private var capturesBrowserProcess = false

    /// How often the open panel re-reads the time and the calendar.
    private static let refreshInterval: Duration = .seconds(15)

    /// The panel is on screen. The menu extra can stay mounted after it
    /// closes, so the clock, the calendar and the sound levels are read only
    /// while this holds: by the window's own visibility once it reports one,
    /// by appearing and disappearing until then.
    private var isOpen: Bool { windowVisible ?? appeared }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 0) {
            MenuBarStatusBlock(
                status: status,
                recording: app.recording,
                habit: .habit(detectedApp: app.detector.activeApp?.name, mode: app.settings.autoRecordMode),
                autoRecordMode: app.settings.autoRecordMode,
                captureWarnings: captureWarnings,
                capturesBrowserProcess: capturesBrowserProcess,
                isOpen: isOpen,
                now: now,
                recordWaits: app.recording.isStarting || dictationBusy,
                dictation: dictationPhase.map {
                    MenuBarDictationWords(
                        $0, timer: dictation.timerLabel,
                        shortcut: app.settings.dictationShortcut.displayLabel,
                        triggerMode: app.settings.dictationTriggerMode)
                })
                .padding(.horizontal, MenuBarMetric.rowInset)
                .padding(.bottom, 5)
            toolRows
            MenuBarSeparator()
            recentMeetings(status.recentMeetings)
            MenuBarSeparator()
            switchRows
            MenuBarSeparator()
            appRows
        }
        .padding(.vertical, MenuBarMetric.rowInset)
        .frame(width: (MenuBarMetric.panelWidth * textScale).rounded())
        .onAppear {
            // Register so non-View code (AppDelegate reopen, AppState first-run
            // onboarding) can open windows even when none are on screen.
            WindowAccess.shared.register { openWindow(id: $0) }
            permissions.startPolling()
            appeared = true
            // The clock before the first frame, so a recording saved long ago
            // is not named again. The calendar is read by the task below:
            // reading it can publish, which a view update must not do.
            now = Date()
        }
        .onDisappear {
            permissions.stopPolling()
            appeared = false
        }
        .background {
            WindowVisibilityReader { visible in
                if visible {
                    if windowVisible != true { windowVisible = true }
                    refresh()
                } else if windowVisible == true {
                    windowVisible = false
                }
            }
            .accessibilityHidden(true)
        }
        .task(id: isOpen) {
            guard isOpen else { return }
            while !Task.isCancelled {
                refresh()
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
        // A recording that starts or is saved moves the block at once.
        .onChange(of: app.isRecording) { _, _ in now = Date() }
        .onChange(of: app.meetings.first?.id) { _, _ in now = Date() }
        .onReceive(app.recording.$captureWarnings.removeDuplicates()) { captureWarnings = $0 }
        .onReceive(app.recording.$callObservationUnavailable.removeDuplicates()) { capturesBrowserProcess = $0 }
    }

    // MARK: State

    private var dictationBusy: Bool { dictationPhase != nil }

    private var dictationPhase: MenuBarStatus.Dictation? {
        if dictation.isStarting { return .starting }
        return switch dictation.state {
        case .idle: nil
        case .recording: .recording
        case .transcribing: .transcribing
        case .composing: .composing
        }
    }

    private var status: MenuBarStatus {
        let live = app.isRecording ? app.currentMeeting : nil
        let recorded = TodayAgenda.recordedEventIDs(in: (live.map { [$0] } ?? []) + app.meetings)
        return MenuBarStatus(
            liveMeeting: live,
            dictation: dictationPhase,
            attention: app.menuBarAttention(corePermissionsGranted: permissions.allGranted),
            nextMeeting: TodayAgenda.nextMeeting(
                in: schedule, now: now, recordedEventIDs: recorded, window: MenuBarStatus.soonWindow),
            dayMemoryPaused: app.settings.trackingEnabled && app.dayMemoryPaused,
            meetings: app.meetings,
            now: now)
    }

    /// The time, and today's meetings as Today reads them. With Calendar off
    /// in Settings or in macOS there are none, and no meeting leads the menu.
    private func refresh() {
        now = Date()
        var meetings: [CalendarMeetingCandidate] = []
        if case .meetings(let read) = UpcomingMeetingSchedule.read(app: app, now: now) { meetings = read }
        if meetings != schedule { schedule = meetings }
    }

    // MARK: Tools

    @ViewBuilder private var toolRows: some View {
        if app.isRecording, MeetingRadar.unavailableReason(app.settings) == nil {
            Button { app.liveRadarPanel.show() } label: {
                MenuBarRowLabel(title: Text("Live Radar"), icon: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(MenuBarRowStyle())
            .accessibilityIdentifier("menubar.liveRadar")
        }
        Button { app.openQuickRecall() } label: {
            MenuBarRowLabel(title: Text("Quick Recall…"), icon: "magnifyingglass") {
                if app.settings.quickRecallEnabled {
                    MenuBarShortcutText(label: app.settings.quickRecallShortcut.displayLabel)
                }
            }
        }
        .buttonStyle(MenuBarRowStyle())
        .accessibilityIdentifier("menubar.quickRecall")
        if app.settings.windowHandoffEnabled {
            Button { app.windowHandoff.invoke() } label: {
                MenuBarRowLabel(title: Text("Hand off this window"), icon: "arrow.up.forward.app") {
                    MenuBarShortcutText(label: app.settings.windowHandoffShortcut.displayLabel)
                }
            }
            .buttonStyle(MenuBarRowStyle())
            .accessibilityIdentifier("menubar.handoff")
        }
        dictationRow
        LastDictationMenuRow(
            entries: dictation.history.entries,
            localized: { app.settings.appLanguage.localized($0) },
            copy: { dictation.copyFromHistory($0) })
    }

    /// Starts dictation; while one runs, the same row stops or cancels it, as
    /// the status block does. A meeting recording holds the microphone, so
    /// the row waits for it.
    private var dictationRow: some View {
        let secureInput = dictationBusy || !app.settings.dictationEnabled ? nil : DictationSecureInput.holder()
        return Button { app.dictation.toggle(source: "menubar") } label: {
            MenuBarRowLabel(
                title: Text(LocalizedStringKey(dictationTitle)),
                icon: dictationIcon,
                detail: secureInput == nil ? nil : Text("Shortcut blocked by Secure Input"),
                detailTone: .attention
            ) {
                if dictation.state.isRecording {
                    Text(verbatim: dictation.timerLabel)
                } else if !dictationBusy, app.settings.dictationEnabled {
                    MenuBarShortcutText(label: app.settings.dictationShortcut.displayLabel)
                }
            }
        }
        .buttonStyle(MenuBarRowStyle())
        .disabled((app.isRecording || app.recording.isStarting) && !dictation.state.isWorking)
        .help(Text(verbatim: secureInput.map { holder in
            DictationSecureInput.message(appName: holder) { app.settings.appLanguage.localized($0) }
        } ?? ""))
        .accessibilityIdentifier("menubar.dictation")
    }

    private var dictationTitle: String {
        if dictation.isStarting { return "Cancel dictation" }
        return switch dictation.state {
        case .idle: "Start dictation"
        case .recording: "Stop dictation"
        case .transcribing, .composing: "Cancel dictation"
        }
    }

    private var dictationIcon: String {
        if dictation.isStarting { return "xmark.circle" }
        return switch dictation.state {
        case .idle: "mic"
        case .recording: "stop.circle"
        case .transcribing, .composing: "xmark.circle"
        }
    }

    // MARK: Recent meetings

    @ViewBuilder private func recentMeetings(_ recent: [MenuBarStatus.RecentMeeting]) -> some View {
        MenuBarGroupHeading(title: "Recent meetings")
        if recent.isEmpty {
            Text("No meetings yet")
                .font(AppFont.scaled(.body))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, MenuBarMetric.rowInset + MenuBarMetric.rowPadding)
                .frame(minHeight: MenuBarMetric.rowHeight)
        }
        ForEach(recent) { item in
            Button {
                app.openMeeting(item.meeting.id)
                WindowAccess.shared.open("main")
            } label: {
                MenuBarRowLabel(title: Text(verbatim: item.meeting.displayTitle), icon: "waveform") {
                    MenuBarPanelWhen.text(item.when)
                }
            }
            .buttonStyle(MenuBarRowStyle())
            .help(Text(verbatim: item.meeting.displayTitle))
            .accessibilityIdentifier("menubar.recentMeeting")
        }
    }

    // MARK: Switches

    @ViewBuilder private var switchRows: some View {
        MenuBarSwitchRow(
            title: "Autocomplete",
            icon: "character.cursor.ibeam",
            help: "Turn inline autocomplete on or off",
            isOn: $app.settings.cotypingEnabled)
            .accessibilityIdentifier("menubar.autocomplete")
        if app.settings.trackingEnabled {
            Button { app.sampler.isPaused.toggle() } label: {
                MenuBarRowLabel(
                    title: Text(app.dayMemoryPaused ? "Resume day memory" : "Pause day memory"),
                    icon: app.dayMemoryPaused ? "play.circle" : "pause.circle")
            }
            .buttonStyle(MenuBarRowStyle())
            .accessibilityIdentifier("menubar.dayMemory")
        }
    }

    // MARK: App

    /// ⌘, and ⌘Q are bound here as well as in the app menu: the panel is the
    /// key window while it is open, also when LokalBot has no other window.
    @ViewBuilder private var appRows: some View {
        Button { WindowAccess.shared.open("main") } label: {
            MenuBarRowLabel(title: Text("Open LokalBot"), icon: "macwindow")
        }
        .buttonStyle(MenuBarRowStyle())
        .accessibilityIdentifier("menubar.open")
        Button { app.openSettings() } label: {
            MenuBarRowLabel(title: Text("Settings…"), icon: "gearshape") {
                MenuBarShortcutText(label: "⌘,")
            }
        }
        .buttonStyle(MenuBarRowStyle())
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityIdentifier("menubar.settings")
        Button { NSApp.terminate(nil) } label: {
            MenuBarRowLabel(title: Text("Quit LokalBot"), icon: "power") {
                MenuBarShortcutText(label: "⌘Q")
            }
        }
        .buttonStyle(MenuBarRowStyle())
        .keyboardShortcut("q", modifiers: .command)
        .accessibilityIdentifier("menubar.quit")
    }
}

/// When a recent meeting was, at the far side of its row.
enum MenuBarPanelWhen {
    /// "Just now", today's start time, "Yesterday", or the day.
    static func text(_ when: MenuBarStatus.RecentMeeting.When) -> Text {
        switch when {
        case .justNow: Text("Just now")
        case .today(let date): Text(date, format: Date.FormatStyle(date: .omitted, time: .shortened))
        case .yesterday: Text("Yesterday")
        case .earlier(let date): Text(date, format: Date.FormatStyle().month(.abbreviated).day())
        }
    }
}

/// The recording clock is intentionally observed below AppState so its 1 Hz
/// tick updates only this tiny label instead of every app surface.
struct MeetingRecordingTimerText: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        HStack(spacing: 3) {
            if !recording.captureWarnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("Recording needs attention")
            }
            Text(recording.menuBarTimer).monospacedDigit()
        }
        .help(recording.captureWarnings.joined(separator: "\n"))
    }
}
