import AppKit
import Combine
import SwiftUI

/// A small always-on-top window with Live Radar, for checking it from the
/// meeting app: it floats over other apps and full-screen calls and never
/// takes focus from them. It opens when a recording starts (if Meta Muse is
/// set up, with Start Radar in it) and when the radar starts, remembers where
/// it was dragged, and collapses to its header. By default it is left out of
/// screen sharing and screen recordings.
@MainActor
final class LiveRadarPanelController {
    static let width: CGFloat = 360
    static let expandedHeight: CGFloat = 560
    static let collapsedHeight: CGFloat = 92
    private static let originKey = "liveRadarPanelOrigin"

    let model = LiveRadarPanelModel()
    private weak var app: AppState?
    private var panel: NSPanel?
    private var observers: [AnyCancellable] = []

    init(app: AppState) {
        self.app = app
        model.$collapsed.dropFirst().removeDuplicates()
            .sink { [weak self] collapsed in self?.resize(collapsed: collapsed) }
            .store(in: &observers)
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        guard let app else { return }
        let panel = panel ?? makePanel(app: app)
        panel.sharingType = Self.sharingType(app.settings)
        guard !panel.isVisible else { return }
        panel.setFrameOrigin(Self.origin(for: panel.frame.size))
        panel.orderFrontRegardless()
        model.isShown = true
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        saveOrigin(of: panel)
        panel.orderOut(nil)
        model.isShown = false
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Shown to others when sharing the screen only if the person turned the
    /// hiding off, for example to record a demo. Films need it visible.
    private static func sharingType(_ settings: AppSettings) -> NSWindow.SharingType {
#if LOKALBOT_UI_TEST_HOST
        return .readOnly
#else
        return settings.liveRadarPanelHiddenFromCapture ? .none : .readOnly
#endif
    }

    private func makePanel(app: AppState) -> NSPanel {
        let size = NSSize(width: Self.width, height: model.collapsed ? Self.collapsedHeight : Self.expandedHeight)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = String(localized: "Live Radar")
        // A floating window to VoiceOver (and to UI tests), not a dialog
        // waiting for an answer.
        panel.setAccessibilitySubrole(.floatingWindow)
        let root = LiveRadarPanelView(
            radar: app.meetingRadar, transcriber: app.liveTranscriber, recording: app.recording, model: model,
            close: { [weak self] in self?.hide() })
            .environmentObject(app)
            .appLanguageRoot(app.settingsStore)
            .brandTinted()
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self, weak panel] _ in if let panel { self?.saveOrigin(of: panel) } }
            .store(in: &observers)
        self.panel = panel
        return panel
    }

    /// Keeps the top edge where it is, so collapsing pulls the bottom up.
    private func resize(collapsed: Bool) {
        guard let panel else { return }
        let height = collapsed ? Self.collapsedHeight : Self.expandedHeight
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
    }

    private func saveOrigin(of panel: NSPanel) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.originKey)
    }

    /// Where it was left, if that is still on a screen; else the top-right
    /// corner of the screen in front.
    private static func origin(for size: NSSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let topLeft = NSPointFromString(saved)
            let origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: origin, size: size)) }) {
                return origin
            }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
    }
}

@MainActor
final class LiveRadarPanelModel: ObservableObject {
    @Published var collapsed = false
    @Published var showsTranscript = true
    @Published var isShown = false
    /// An item the person clicked, shown in the spotlight until a newer one
    /// arrives.
    @Published var pinnedID: String?
}

/// The panel's content: a header with the recording time and counts, the
/// newest item as a large card, the earlier ones as rows, and the last few
/// transcript lines.
struct LiveRadarPanelView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var radar: MeetingRadar
    @ObservedObject var transcriber: LiveMeetingTranscriber
    @ObservedObject var recording: RecordingController
    @ObservedObject var model: LiveRadarPanelModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meeting: Meeting? {
        radar.meetingID.flatMap { id in app.meetings.first { $0.id == id } } ?? app.currentMeeting
    }

    private var spotlight: RadarItem? {
        let pinned = model.pinnedID.flatMap { id in radar.items.first { $0.id == id } }
        return pinned ?? radar.spotlightID.flatMap { id in radar.items.first { $0.id == id } } ?? radar.items.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.collapsed {
                collapsedLine
            } else {
                Divider()
                content
                if model.showsTranscript {
                    Divider()
                    transcript
                }
            }
        }
        .frame(width: LiveRadarPanelController.width,
               height: model.collapsed ? LiveRadarPanelController.collapsedHeight : LiveRadarPanelController.expandedHeight,
               alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: radar.spotlightID) { model.pinnedID = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveRadarPanel")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: radar.state == .running ? Brand.recording : .secondary, size: 7,
                      pulses: radar.state == .running)
            Text("Live Radar").font(.scaled(.headline)).lineLimit(1)
            if recording.isRecording {
                MeetingRecordingTimerText(recording: recording)
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            iconButton(model.showsTranscript ? "text.bubble.fill" : "text.bubble", label: "Live Transcript") {
                model.showsTranscript.toggle()
            }
            .disabled(model.collapsed)
            iconButton("macwindow", label: "Open LokalBot") { app.showLiveMeeting() }
                .accessibilityIdentifier("liveRadarPanel.open")
            iconButton(model.collapsed ? "chevron.down" : "chevron.up", label: model.collapsed ? "Expand" : "Collapse") {
                model.collapsed.toggle()
            }
            .accessibilityIdentifier("liveRadarPanel.collapse")
            iconButton("xmark", label: "Close", action: close)
                .accessibilityIdentifier("liveRadarPanel.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var collapsedLine: some View {
        Group {
            if let item = spotlight {
                row(item)
            } else {
                status
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if radar.meetingID == nil || (radar.meetingID != app.currentMeeting?.id && !radar.isActive && radar.items.isEmpty) {
            startPrompt
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 4)
                    RadarCounts(items: radar.items).fixedSize()
                }
                if let spotlight {
                    RadarCard(item: spotlight, folder: meeting.map { $0.folderURL(in: app.storage) }, prominent: true,
                              idPrefix: "panel", allowsEnlarge: false, step: radar.answerSteps[spotlight.id])
                        .id(spotlight.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    let others = radar.items.filter { $0.id != spotlight.id }.sorted { $0.time > $1.time }
                    if !others.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(others) { item in
                                    Button { model.pinnedID = item.id } label: { row(item) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                    }
                } else {
                    Text(radar.totals.passes == 0 ? "Waiting for the first transcript lines…" : "Nothing caught yet.")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: spotlight?.id)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var status: some View {
        if let message = radar.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.scaled(.caption)).foregroundStyle(Brand.error)
                .lineLimit(2)
        } else if radar.isAnalyzing {
            LoadingStateLabel("Reading the newest lines…", font: .scaled(.caption))
        } else if radar.state == .running {
            Text("Listening with \(MetaModelAPI.displayName(for: radar.model)).")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
        } else if !recording.isRecording {
            Text("Not recording").font(.scaled(.caption)).foregroundStyle(.secondary)
        }
    }

    /// Start Radar without leaving the meeting app.
    private var startPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = MeetingRadar.unavailableReason(app.settings) {
                Text(verbatim: reason).font(.scaled(.callout)).foregroundStyle(.secondary)
                Button("Set Up…") { app.openSettings(tab: .recording) }
            } else {
                Text("Catches commitments, decisions, open questions, and conflicts with earlier meetings as they are said. Sends \(MetaModelAPI.displayName(for: app.settings.museRadarModel)) new live transcript lines, the meeting title, invited names, and related passages from your earlier meetings at api.meta.ai. Starts the live preview if it is off.")
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start Radar") {
                    if let meeting = app.currentMeeting { app.startLiveRadar(for: meeting) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.currentMeeting == nil || radar.state == .finishing)
                .accessibilityIdentifier("liveRadarPanel.start")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// An earlier item in one or two lines.
    private func row(_ item: RadarItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(item.kind.tintText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.scaled(.callout))
                    .lineLimit(2)
                    .strikethrough(item.answered)
                if let answer = item.answer {
                    Text(verbatim: answer.text)
                        .font(.scaled(.callout).weight(.semibold))
                        .foregroundStyle(LBTokens.Palette.successText)
                        .lineLimit(2)
                } else if let step = radar.answerSteps[item.id] {
                    Text(verbatim: step)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let answer = item.screenAnswer {
                    Text(verbatim: answer.text)
                        .font(.scaled(.callout).weight(.semibold))
                        .foregroundStyle(LBTokens.Palette.successText)
                        .lineLimit(1)
                } else if let earlier = item.earlier, !earlier.isCurrentMeeting {
                    Text("Earlier: \(earlier.meetingTitle) · \(earlier.meetingDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.scaled(.caption))
                        .foregroundStyle(LBTokens.Palette.attentionText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(verbatim: MeetingRadarAnalyzer.timestamp(item.time))
                .font(.scaled(.caption).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("panel.row.\(item.kind.rawValue).\(item.id)")
    }

    // MARK: - Transcript

    /// The last few lines, and the turn still being spoken.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 3) {
            let shown = Array(transcriber.lines.suffix(3))
            if shown.isEmpty && transcriber.partials.isEmpty {
                Text(transcriber.state == .off ? "Not recording" : "Waiting for the first transcript lines…")
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
            ForEach(shown) { line in transcriptLine(line, partial: false) }
            ForEach(transcriber.partials) { line in transcriptLine(line, partial: true) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    }

    private func transcriptLine(_ line: LiveMeetingTranscriber.Line, partial: Bool) -> some View {
        let isMe = line.speaker == "local" || line.speaker == "me"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The microphone track is the person; the call track is everyone else.
            Image(systemName: isMe ? "person.fill" : "person.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(isMe ? LBTokens.Palette.accentText : .secondary)
                .frame(width: 16)
                .accessibilityLabel(isMe ? Text("You") : Text("Meeting audio"))
            Text(verbatim: line.text)
                .font(.scaled(.caption))
                .foregroundStyle(partial ? .secondary : .primary)
                .lineLimit(2)
        }
    }
}
