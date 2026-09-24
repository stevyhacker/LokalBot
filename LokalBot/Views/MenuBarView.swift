import SwiftUI
import AppKit

/// The status-bar item itself. When recording it shows a record dot plus a live
/// MM:SS timer so a glance at the menu bar confirms a meeting is being captured
/// — no window required. Idle, it's just the app glyph.
struct MenuBarLabel: View {
    @ObservedObject var app: AppState
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
        if app.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                MeetingRecordingTimerText(recording: app.recording)
            }
                .monospacedDigit()
        } else if app.dictation.state.isRecording {
            Text("\(Image(systemName: "mic.circle.fill")) \(app.dictation.menuBarLabel)")
                .monospacedDigit()
        } else if app.dictation.state.isWorking {
            Image(systemName: "mic.and.signal.meter.fill")
        } else {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// The LokalBot brand mark for the status item: a minimal robot head whose
/// face is a three-bar waveform — "bot" and "listens locally" in one glyph.
/// Drawn in code as a template image so it stays crisp at any backing scale
/// and picks up the menu bar's light/dark/highlight tinting for free.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LokalBot"
        return image
    }()

    private static func draw() {
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

/// A narrowly-observed control for pausing day tracking. `AppState` owns the
/// sampler but does not rebroadcast its frequent sample updates, so views that
/// display `isPaused` must observe the sampler directly to refresh immediately.
struct TrackingPauseButton: View {
    enum Presentation {
        case overflowMenu
        case toolbar
    }

    @ObservedObject var sampler: ActivitySampler
    let presentation: Presentation

    var body: some View {
        switch presentation {
        case .overflowMenu:
            Button(action: toggle) {
                Label(actionTitle,
                      systemImage: sampler.isPaused ? "play.fill" : "pause.fill")
            }

        case .toolbar:
            Button(action: toggle) {
                Label(actionTitle,
                      systemImage: sampler.isPaused ? "play.fill" : "pause.fill")
            }
            .help(actionTitle)
        }
    }

    private var actionTitle: String {
        sampler.isPaused ? "Resume day memory" : "Pause day memory"
    }

    private func toggle() {
        sampler.isPaused.toggle()
    }
}

/// The dropdown shown when the menu bar item is clicked. The primary surface for
/// running LokalBot without ever opening the main window: live recording state,
/// the record/stop control, recent meetings, and app actions (Settings, Quit).
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            if app.isRecording { RecordingHealthStrip(recording: app.recording) }

            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.error).lineLimit(2)
            }

            if app.micRecoveryNeeded {
                Button {
                    PermissionManager.shared.openSettings(for: .microphone)
                    app.micRecoveryNeeded = false
                } label: {
                    Label("Turn on microphone access in System Settings",
                          systemImage: "mic.slash.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Brand.error)
            }

            if !permissions.allGranted {
                Button { WindowAccess.shared.open("onboarding") } label: {
                    Label("Grant permissions to record", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Brand.error)
            }

            recentSection
            toolsSection
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            // Register so non-View code (AppDelegate reopen, AppState first-run
            // onboarding) can open windows even when none are on screen.
            WindowAccess.shared.register { openWindow(id: $0) }
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
    }

    // MARK: Recording status

    private var statusCard: some View {
        HeroPanel(radius: Brand.Radius.panel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(statusSubtitle)
                            .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer()
                    if app.isRecording || app.dictation.state.isRecording {
                        // MenuBarExtra keeps this view mounted after its popover
                        // closes, so never leave a display-linked animation here.
                        LiveWaveform(barCount: 7, barWidth: 3, maxHeight: 14,
                                     animated: false)
                    }
                }

                if app.isRecording || app.dictation.state.isWorking {
                    primaryTimer
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Label(audioSourceLabel, systemImage: "waveform")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }

                Button {
                    if app.isRecording {
                        app.stopRecording()
                    } else if app.dictation.isStarting || app.dictation.state.isWorking {
                        app.dictation.toggle(source: "menubar")
                    } else {
                        app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "menubar")
                    }
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint((app.isRecording || app.dictation.state.isRecording) ? .red : Brand.tealFill)

                if app.isRecording {
                    Button {
                        app.showLiveMeeting()
                    } label: {
                        Label("Live transcript & notes", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.panel)
                .strokeBorder(app.isRecording ? Brand.recording.opacity(0.5) : Color.clear))
    }

    /// Keep the always-mounted menu extra static while recording. Repeating
    /// SwiftUI animations continue after the popover closes and otherwise
    /// consume the main thread for the duration of a meeting.
    private var statusDot: some View {
        let live = app.isRecording || app.dictation.state.isRecording
        return StatusDot(color: live ? Brand.recording : Color.secondary.opacity(0.4),
                         size: 11)
    }

    private var statusTitle: String {
        if app.isRecording { return "Recording" }
        if app.dictation.isStarting { return "Starting dictation" }
        switch app.dictation.state {
        case .idle: return "Not recording"
        case .recording: return "Dictating"
        case .transcribing: return "Transcribing"
        case .composing: return "Composing"
        }
    }

    private var statusSubtitle: String {
        if app.dictation.isStarting { return "Connecting to the microphone" }
        switch app.dictation.state {
        case .recording:
            return "Release \(DictationShortcut.label) to compose"
        case .transcribing:
            return "Turning speech into a writing request"
        case .composing:
            return "Writing for the focused app"
        case .idle:
            break
        }
        if app.isRecording {
            return app.currentMeeting?.title ?? "In progress"
        }
        if let detected = app.detector.activeApp {
            return "\(detected.name) detected — ready"
        }
        switch app.settings.autoRecordMode {
        case .automatic: return "Auto-records detected meetings"
        case .ask: return "Asks before recording meetings"
        case .manual: return "Manual recording only"
        }
    }

    @ViewBuilder private var primaryTimer: some View {
        if app.isRecording {
            MeetingRecordingTimerText(recording: app.recording)
        } else {
            switch app.dictation.state {
            case .idle: Text("00:00")
            case .recording: Text(app.dictation.timerLabel)
            case .transcribing, .composing: Text("...")
            }
        }
    }

    private var primaryActionTitle: String {
        if app.isRecording { return "Stop recording" }
        if app.dictation.isStarting { return "Cancel dictation" }
        switch app.dictation.state {
        case .idle: return "Record now"
        case .recording: return "Stop dictation"
        case .transcribing, .composing: return "Cancel dictation"
        }
    }

    private var primaryActionIcon: String {
        if app.isRecording { return "stop.fill" }
        if app.dictation.isStarting { return "xmark.circle" }
        switch app.dictation.state {
        case .idle: return "record.circle"
        case .recording: return "stop.fill"
        case .transcribing, .composing: return "xmark.circle"
        }
    }

    private var audioSourceLabel: String {
        if app.dictation.state.isWorking {
            return "Microphone dictation"
        }
        return (app.currentMeeting?.hasSystemTrack ?? false)
            ? "Microphone + system audio"
            : "Microphone only"
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(text: "Recent")
                Spacer()
                if !app.meetings.isEmpty {
                    Button("View all") {
                        app.navSection = .meetings
                        WindowAccess.shared.open("main")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if app.meetings.isEmpty {
                Text("No meetings yet").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(app.meetings.prefix(2)) { meeting in
                        Button {
                            app.openMeeting(meeting.id)
                            WindowAccess.shared.open("main")
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(shortMenuTitle(meeting.title))
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(meeting.appName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(meeting.durationLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Quick tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(text: "Tools")
            VStack(spacing: 0) {
                dictationRow
                Divider().padding(.leading, 28)
                cotypingRow
            }
            .padding(.horizontal, 10)
            .background(
                .quaternary.opacity(0.32),
                in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                WindowAccess.shared.open("quick-recall")
            } label: {
                Label("Ask", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                WindowAccess.shared.open("main")
            } label: {
                Label("Open App", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Menu {
                Button {
                    app.openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                if app.settings.trackingEnabled {
                    TrackingPauseButton(
                        sampler: app.sampler,
                        presentation: .overflowMenu
                    )
                }

                Divider()
                Button("Quit LokalBot", role: .destructive) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .font(.callout)
        .controlSize(.regular)
    }

    private var cotypingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Autocomplete").font(.callout.weight(.medium))
                Text("Suggests text as you type")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Autocomplete", isOn: $app.settings.cotypingEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Turn inline autocomplete on or off")
        }
        .padding(.vertical, 8)
    }

    private var dictationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dictation").font(.callout.weight(.medium))
                Text("Shortcut · \(DictationShortcut.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Dictation shortcut", isOn: $app.settings.dictationEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Enable the \(DictationShortcut.label) dictation shortcut")
            Button {
                app.dictation.toggle(source: "menubar")
            } label: {
                Image(systemName: dictationButtonIcon)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(app.dictation.state.isRecording || app.dictation.isStarting ? .red : nil)
            .disabled(
                (app.isRecording || app.recording.isStarting)
                    && !app.dictation.state.isWorking
            )
            .help("\(dictationButtonTitle) dictation")
            .accessibilityLabel("\(dictationButtonTitle) dictation")
        }
        .padding(.vertical, 8)
    }

    private var dictationButtonTitle: String {
        if app.dictation.isStarting { return "Cancel" }
        return switch app.dictation.state {
        case .idle: "Start"
        case .recording: "Stop"
        case .transcribing, .composing: "Cancel"
        }
    }

    private var dictationButtonIcon: String {
        if app.dictation.isStarting { return "xmark" }
        return switch app.dictation.state {
        case .idle: "mic.fill"
        case .recording: "stop.fill"
        case .transcribing, .composing: "xmark"
        }
    }

    private func shortMenuTitle(_ title: String) -> String {
        let limit = 30
        guard title.count > limit else { return title }
        let end = title.index(title.startIndex, offsetBy: limit - 3)
        return String(title[..<end]) + "..."
    }
}

/// The recording clock is intentionally observed below AppState so its 1 Hz
/// tick updates only this tiny label instead of every app surface.
struct MeetingRecordingTimerText: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        Text(recording.menuBarTimer).monospacedDigit()
    }
}
