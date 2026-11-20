import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var scene: AppSceneState
    let recording: RecordingController
    @ObservedObject var dictation: DictationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        glyph
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
                .overlay(alignment: .topTrailing) {
                    if variant.attention {
                        Circle()
                            .fill(LBTokens.Palette.attention)
                            .frame(width: MenuBarIcon.badgeDiameter, height: MenuBarIcon.badgeDiameter)
                            .accessibilityHidden(true)
                    }
                }
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

enum MenuBarIcon {
    struct Variant: Hashable {
        var dimmed = false
        var attention = false
    }

    static let size = NSSize(width: 18, height: 18)
    static let badgeDiameter: CGFloat = 6
    static let dimmedOpacity: CGFloat = 0.38
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

    static var badgeRect: NSRect {
        NSRect(x: size.width - badgeDiameter, y: size.height - badgeDiameter,
               width: badgeDiameter, height: badgeDiameter)
    }

    private static func draw(_ variant: Variant) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
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

        let head = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 10.5),
            xRadius: 3, yRadius: 3
        )
        head.lineWidth = 1.5
        head.stroke()

        let stem = NSBezierPath()
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 9, y: 12))
        stem.line(to: NSPoint(x: 9, y: 13.9))
        stem.stroke()
        NSBezierPath(ovalIn: NSRect(x: 9 - 1.2, y: 15.4 - 1.2, width: 2.4, height: 2.4)).fill()

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
    @ObservedObject var approvals: SettingsApprovals
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appTextScale) private var textScale
    @State private var appeared = false
    @State private var windowVisible: Bool?
    @State private var now = Date()
    @State private var schedule: [CalendarMeetingCandidate] = []
    @State private var captureWarnings: [String] = []
    @State private var capturesBrowserProcess = false

    private static let refreshInterval: Duration = .seconds(15)

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
            WindowAccess.shared.register { openWindow(id: $0) }
            permissions.startPolling()
            appeared = true
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
        .onChange(of: app.isRecording) { _, _ in now = Date() }
        .onChange(of: app.meetings.first?.id) { _, _ in now = Date() }
        .onReceive(app.recording.$captureWarnings.removeDuplicates()) { captureWarnings = $0 }
        .onReceive(app.recording.$callObservationUnavailable.removeDuplicates()) { capturesBrowserProcess = $0 }
    }

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

    private func refresh() {
        now = Date()
        var meetings: [CalendarMeetingCandidate] = []
        if case .meetings(let read) = UpcomingMeetingSchedule.read(app: app, now: now) { meetings = read }
        if meetings != schedule { schedule = meetings }
    }

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

enum MenuBarPanelWhen {
    static func text(_ when: MenuBarStatus.RecentMeeting.When) -> Text {
        switch when {
        case .justNow: Text("Just now")
        case .today(let date): Text(date, format: Date.FormatStyle(date: .omitted, time: .shortened))
        case .yesterday: Text("Yesterday")
        case .earlier(let date): Text(date, format: Date.FormatStyle().month(.abbreviated).day())
        }
    }
}

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
