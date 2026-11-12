import AppKit
import SwiftUI

/// The top of the menu bar panel: what LokalBot is doing, in one line and one
/// colour, with its buttons always in the same place under it.
/// `MenuBarStatus` picks the state; this draws it.
struct MenuBarStatusBlock: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openURL) private var openURL
    let status: MenuBarStatus
    /// The timer and the sound levels read the recorder itself, not AppState.
    let recording: RecordingController
    /// What makes a recording start, for the line under "Not recording".
    let habit: MenuBarRecordingHabit
    let autoRecordMode: AppSettings.AutoRecordMode
    /// The recording's capture warnings, shown in the block while it leads.
    let captureWarnings: [String]
    /// The call is a browser tab captured by process (`callObservationUnavailable`).
    let capturesBrowserProcess: Bool
    /// The panel is on screen, so the sound levels may tick.
    let isOpen: Bool
    let now: Date
    /// A recording is starting or dictation holds the microphone: Record waits.
    let recordWaits: Bool
    /// The running dictation in words; nil when there is none.
    var dictation: MenuBarDictationWords?

    private var tone: MenuBarStatus.Tone { status.tone(hasCaptureWarnings: !captureWarnings.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
            }
            ForEach(status.moreAttention) { item in
                Divider().overlay(LBTokens.Palette.attention.opacity(0.28))
                MenuBarAttentionStrip(item: item) { resolve(item) }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MenuBarStatusSurface(tone: tone))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.status")
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        switch status.block {
        case .recording(let meeting):
            heading(Text(captureWarnings.isEmpty ? "Recording" : "Recording needs attention")) {
                MeetingRecordingTimerText(recording: recording)
            }
            line(Text(verbatim: meeting.displayTitle))
            MenuBarRecordingLevels(recording: recording, ticks: isOpen)
                .padding(.top, 2)
            ForEach(captureWarnings, id: \.self) { warning in
                Text(verbatim: warning)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if capturesBrowserProcess {
                Text("Browser audio is captured by process and may include other tabs in that process.")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            buttons {
                Button {
                    app.stopRecording()
                } label: {
                    Label {
                        Text("Stop")
                    } icon: {
                        Image(systemName: "stop.fill").foregroundStyle(LBTokens.Palette.recording)
                    }
                }
                .accessibilityLabel("Stop Recording")
                .accessibilityIdentifier("menubar.stop")
                Button("Open live notes") { app.showLiveMeeting() }
                    .accessibilityIdentifier("menubar.liveNotes")
            }
        case .dictating:
            if let dictation {
                heading(Text(dictation.title)) {
                    if let timer = dictation.timer { Text(verbatim: timer) }
                }
                if let progress = dictation.progress { line(progress, lines: 2) }
                buttons {
                    Button {
                        app.dictation.toggle(source: "menubar")
                    } label: {
                        Label(dictation.action, systemImage: dictation.actionIcon)
                    }
                    .accessibilityIdentifier("menubar.dictation.stop")
                }
            }
        case .attention(let item):
            let words = MenuBarAttentionWords(item)
            heading(words.title, lines: 2)
            if let detail = words.detail {
                line(detail, lines: 4)
            }
            buttons {
                Button(words.action) { resolve(item) }
                    .primaryActionButton()
                    .accessibilityIdentifier(words.identifier)
            }
        case .meetingSoon(let event):
            heading(Text(verbatim: event.title)) {
                TodayMeetingStatusText.text(TodayAgenda.status(of: event, now: now))
            }
            line(Text(verbatim: Self.schedule(event)))
            if autoRecordMode == .automatic {
                line(Text("Recording starts when the call does"), lines: 2, quiet: true)
            }
            buttons {
                let isCall = UpcomingMeetingSelector.kind(of: event) == .meeting
                if isCall, let meetingURL = event.meetingURL {
                    Button("Join") { openURL(meetingURL) }
                        .primaryActionButton()
                        .accessibilityIdentifier("menubar.join")
                }
                // A solo event without a link may not be a call: it is recorded
                // like any other manual start, without the event's context.
                recordButton("Record", event: isCall ? event : nil)
            }
        case .paused:
            heading(Text("Day memory is paused"))
            line(Self.habitText(.habit(detectedApp: nil, mode: autoRecordMode), paused: true), lines: 2)
            buttons {
                Button("Resume") { app.sampler.isPaused = false }
                    .primaryActionButton()
                    .accessibilityIdentifier("menubar.resume")
                recordButton("Record now")
            }
        case .justStopped(let meeting):
            heading(Text("Not recording"))
            line(Text("\(meeting.displayTitle) saved · \(meeting.durationLabel)"), lines: 2)
            buttons {
                recordButton("Record now")
                Button("Open notes") { open(meeting) }
                    .accessibilityIdentifier("menubar.openNotes")
            }
        case .idle:
            heading(Text("Not recording"))
            line(Self.habitText(habit, paused: false), lines: 2)
            buttons { recordButton("Record now") }
        }
    }

    // MARK: Pieces

    private func heading(_ title: Text, lines: Int = 1) -> some View {
        heading(title, lines: lines) { EmptyView() }
    }

    private func heading(_ title: Text, lines: Int = 1, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
                .font(AppFont.scaled(.body).weight(.semibold))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: lines > 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            trailing()
                .font(AppFont.scaled(.body).weight(.semibold).monospacedDigit())
                .foregroundStyle(trailingStyle)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func line(_ text: Text, lines: Int = 1, quiet: Bool = false) -> some View {
        text
            .font(AppFont.scaled(.callout))
            .foregroundStyle(quiet ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: lines > 1)
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .buttonStyle(.bordered)
            .padding(.top, 9)
    }

    /// Records the calendar event when one is given, otherwise whatever call
    /// the detector sees, as Record now always has.
    private func recordButton(_ title: LocalizedStringKey, event: CalendarMeetingCandidate? = nil) -> some View {
        Button {
            let context = event.map { app.recordingContext(for: $0) }
                ?? app.recordingContext(for: app.detector.activeApp)
            app.startRecording(context: context, source: "menubar")
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(LBTokens.Palette.recording)
            }
        }
        .disabled(recordWaits)
        .accessibilityIdentifier("menubar.record")
    }

    private var trailingStyle: Color {
        switch tone {
        case .recording: LBTokens.Palette.recordingText
        case .attention: LBTokens.Palette.attentionText
        case .upcoming, .neutral: LBTokens.Palette.accentText
        }
    }

    private var tile: some View {
        let (symbol, fill, ink): (String, Color, Color) = switch status.block {
        case .recording:
            ("circle.fill", tone == .attention ? LBTokens.Palette.attention : LBTokens.Palette.recording, .white)
        case .dictating(let phase):
            ("mic.fill", phase == .recording ? LBTokens.Palette.recording : Color(nsColor: .systemGray), .white)
        case .attention: ("exclamationmark", LBTokens.Palette.attention, .white)
        case .meetingSoon: ("calendar", LBTokens.Palette.accentFill, .white)
        case .paused: ("pause.fill", Color(nsColor: .systemGray), .white)
        case .justStopped, .idle: ("record.circle", Color.primary.opacity(0.08), .secondary)
        }
        return Image(systemName: symbol)
            .font(.system(size: status.block.usesSmallSymbol ? 10 : 14, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 30, height: 30)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }

    // MARK: Words

    /// "6:00 – 6:30 PM · Maya Chen +2": the panel is narrow, so one name
    /// and a count stand for the people Today lists.
    static func schedule(_ event: CalendarMeetingCandidate) -> String {
        var people: String?
        if let first = event.participantNames.first {
            let others = event.participantNames.count - 1
            people = others > 0 ? "\(first) +\(others)" : first
        }
        return [UpcomingMeetingPresentation.interval(event), people]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// What makes a recording start. While day memory is paused the line
    /// says meetings are not: pausing never touches recording.
    static func habitText(_ habit: MenuBarRecordingHabit, paused: Bool) -> Text {
        switch habit {
        case .appDetected(let name):
            return Text("\(name) detected — ready")
        case .recordsAutomatically:
            if paused { return Text("Meetings still record when they start") }
            return Text("Records meetings when they start")
        case .asksFirst:
            return Text("Asks before recording meetings")
        case .manualOnly:
            return Text("Manual recording only")
        }
    }

    // MARK: Actions

    private func open(_ meeting: Meeting) {
        app.openMeeting(meeting.id)
        WindowAccess.shared.open("main")
    }

    /// The fix each attention item offers. They are the ones the menu had.
    private func resolve(_ item: MenuBarAttention) {
        switch item {
        case .microphoneRefused:
            PermissionManager.shared.openSettings(for: .microphone)
            app.micRecoveryNeeded = false
        case .microphoneNotGranted:
            WindowAccess.shared.open("onboarding")
        case .error:
            app.lastError = nil
        case .settingsApproval:
            WindowAccess.shared.open("settings-approval")
        }
    }
}

private extension MenuBarStatus.Block {
    /// The recording dot is drawn smaller than the other tiles' symbols.
    var usesSmallSymbol: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// A running dictation as the status block says it: what it is doing, how
/// to finish it, and the one button that stops or cancels it.
struct MenuBarDictationWords {
    let title: LocalizedStringKey
    let progress: Text?
    /// The elapsed time, while the dictation is being spoken.
    let timer: String?
    let action: LocalizedStringKey
    let actionIcon: String

    init(_ phase: MenuBarStatus.Dictation, timer: String, shortcut: String,
         triggerMode: DictationTriggerMode) {
        switch phase {
        case .starting:
            title = "Starting dictation"
            progress = Text("Connecting to the microphone")
            self.timer = nil
            action = "Cancel dictation"
            actionIcon = "xmark.circle"
        case .recording:
            title = "Dictating"
            switch triggerMode {
            case .toggle: progress = Text("Press \(shortcut) again to compose")
            case .pushToTalk: progress = Text("Release \(shortcut) to compose")
            case .tapOrHold: progress = Text("Release or tap \(shortcut) to compose")
            }
            self.timer = timer
            action = "Stop dictation"
            actionIcon = "stop.fill"
        case .transcribing:
            title = "Transcribing"
            progress = Text("Turning speech into a writing request")
            self.timer = nil
            action = "Cancel dictation"
            actionIcon = "xmark.circle"
        case .composing:
            title = "Composing"
            progress = Text("Writing for the focused app")
            self.timer = nil
            action = "Cancel dictation"
            actionIcon = "xmark.circle"
        }
    }
}

/// The words for one attention item: as the block's heading, and as a line
/// under another block.
struct MenuBarAttentionWords {
    let title: Text
    let detail: Text?
    /// The one line under another block: an error is its own message.
    let strip: Text
    let action: LocalizedStringKey
    let icon: String
    let identifier: String

    init(_ item: MenuBarAttention) {
        switch item {
        case .microphoneRefused, .microphoneNotGranted:
            title = Text("Microphone access is off")
            detail = Text("Meetings and dictation can’t record until you turn it on.")
            strip = title
            action = item == .microphoneRefused ? "Open System Settings" : "Grant Access"
            icon = "mic.slash"
            identifier = "menubar.microphone"
        case .error(let message):
            title = Text("Needs attention")
            detail = Text(verbatim: message)
            strip = Text(verbatim: message)
            action = "Dismiss"
            icon = "exclamationmark.triangle"
            identifier = "menubar.error"
        case .settingsApproval(let count):
            title = count == 1
                ? Text("A settings change is waiting for your approval")
                : Text("\(count) settings changes are waiting for your approval")
            detail = nil
            strip = title
            action = "Review"
            icon = "checkmark.shield"
            // The name the row had before the status block took it in.
            identifier = "menuBar.settingsApproval"
        }
    }
}

/// An attention item that is not the block's heading: its words and its fix
/// on one line.
private struct MenuBarAttentionStrip: View {
    let item: MenuBarAttention
    let resolve: () -> Void

    var body: some View {
        let words = MenuBarAttentionWords(item)
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: words.icon)
                .font(AppFont.scaled(.callout))
                .foregroundStyle(LBTokens.Palette.attentionText)
                .frame(width: 16)
                .accessibilityHidden(true)
            words.strip
                .font(AppFont.scaled(.callout))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(words.action, action: resolve)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(words.identifier)
        }
    }
}

/// The block's fill and edge in its one colour.
private struct MenuBarStatusSurface: ViewModifier {
    let tone: MenuBarStatus.Tone

    @ViewBuilder func body(content: Content) -> some View {
        switch tone {
        case .neutral: content.lbGroupedSurface()
        case .recording: content.lbStatusSurface(LBTokens.Palette.recording)
        case .upcoming: content.lbStatusSurface(LBTokens.Palette.accentFill)
        case .attention: content.lbStatusSurface(LBTokens.Palette.attention)
        }
    }
}

/// Whether the microphone and the call are producing sound right now, from
/// the health snapshot the recording strip reads, on one line. It ticks only
/// while the panel is on screen: the menu extra stays mounted after it closes.
private struct MenuBarRecordingLevels: View {
    let recording: RecordingController
    let ticks: Bool

    var body: some View {
        if ticks {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                MenuBarAudioLineRow(line: MenuBarAudioLine(recording.memoryHealthSnapshot(at: context.date)))
            }
        } else {
            MenuBarAudioLineRow(line: MenuBarAudioLine(recording.memoryHealthSnapshot()))
        }
    }
}

/// One snapshot of the recording's sources: a dot and a name each, and the
/// call's level when it was just measured.
struct MenuBarAudioLineRow: View {
    let line: MenuBarAudioLine

    private static let meterBars = 10

    var body: some View {
        MeetingWrappingRow(spacing: 10, lineSpacing: 2) {
            if let call = line.callAudio {
                source(line.microphone, name: Text("Microphone"), detailed: Text("Mic · \(line.microphone.status)"))
                HStack(spacing: 6) {
                    source(call, name: Text("Call audio"), detailed: Text("Call audio · \(call.status)"))
                    if let level = line.callAudioLevel { meter(level) }
                }
            } else {
                source(line.microphone, name: Text("Microphone only"),
                       detailed: Text("Mic · \(line.microphone.status)"))
            }
        }
        .font(AppFont.scaled(.callout))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.recording.health")
    }

    /// A source with sound arriving is its name and a green dot; any other
    /// state adds the recorder's own words for it.
    private func source(_ source: MenuBarAudioLine.Source, name: Text, detailed: Text) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor(source.tone))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            (source.isReceiving ? name : detailed).lineLimit(1)
        }
        .help(Text(verbatim: source.status))
    }

    private func dotColor(_ tone: MemoryHealthTone) -> Color {
        switch tone {
        case .good: LBTokens.Palette.success
        case .attention: LBTokens.Palette.attention
        case .idle, .neutral: Color.secondary.opacity(0.5)
        }
    }

    private func meter(_ level: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.meterBars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(index) / Double(Self.meterBars) < level
                          ? LBTokens.Palette.accentFill : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System audio input level")
        .accessibilityValue(Text(Int(level * 100), format: .percent))
    }
}
