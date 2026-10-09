import AppKit
import Combine
import SwiftUI

/// Shows the dictation HUD in a floating panel near the bottom of the screen.
///
/// The SwiftUI canvas has one fixed size and stays put on screen; the panel
/// is a window onto the canvas's bottom-center. A capsule that grows makes
/// the panel grow first, and a capsule that shrinks shrinks inside the panel
/// before the panel follows, so resizing never shifts or clips what is drawn.
@MainActor
final class DictationOverlayController {
    private let settingsStore: SettingsStore
    private let model = DictationOverlayModel()
    private var panel: NSPanel?
    private var canvasView: NSView?
    private weak var dictation: DictationCoordinator?
    private var changeObserver: AnyCancellable?
    private var allowsDisplay = false
    private var syncScheduled = false
    private var revealScheduled = false
    /// The capsule's bottom-center while the HUD is up. Fixed until it hides,
    /// so a focus change cannot move it to another screen mid-dictation.
    private var anchor: CGPoint?
    private var panelContentSize: CGSize = .zero
    private var shrinkTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    /// Long enough for the capsule's resize to settle before the panel shrinks.
    private static let shrinkDelay: Duration = .milliseconds(450)
    /// Long enough for the exit transition before the panel leaves the screen.
    private static let orderOutDelay: Duration = .milliseconds(220)

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func update(for dictation: DictationCoordinator, visible: Bool) {
        observe(dictation)
        allowsDisplay = visible
        sync()
    }

    /// Some changes reshape the HUD without a call to `update`, such as a
    /// model check that ends. Follow every published change, once per turn.
    private func observe(_ dictation: DictationCoordinator) {
        guard self.dictation !== dictation else { return }
        self.dictation = dictation
        changeObserver = dictation.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.sync()
        }
    }

    private func sync() {
        if allowsDisplay, let dictation, let content = DictationOverlayContent(dictation) {
            show(content, for: dictation)
        } else {
            hide()
        }
    }

    private func show(_ content: DictationOverlayContent, for dictation: DictationCoordinator) {
        let panel = panel ?? makePanel(for: dictation)
        orderOutTask?.cancel()
        orderOutTask = nil
        let target = content.layout.size
        if let anchor, panel.isVisible {
            if model.content != content { model.content = content }
            let size = CGSize(
                width: max(panelContentSize.width, target.width),
                height: max(panelContentSize.height, target.height))
            if size != panelContentSize { place(panel, contentSize: size, anchor: anchor) }
            if size != target {
                scheduleShrink(to: target)
            } else {
                shrinkTask?.cancel()
                shrinkTask = nil
            }
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let anchor = DictationOverlayGeometry.anchor(
                in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            self.anchor = anchor
            model.content = content
            place(panel, contentSize: target, anchor: anchor)
            panel.orderFrontRegardless()
        }
        guard !model.isShown, !revealScheduled else { return }
        // Insert the capsule on the next turn, once the empty canvas has
        // drawn, so its entrance transition runs.
        revealScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.revealScheduled = false
            guard self.orderOutTask == nil, self.anchor != nil, self.panel?.isVisible == true else { return }
            self.model.isShown = true
        }
    }

    private func hide() {
        shrinkTask?.cancel()
        shrinkTask = nil
        guard let panel, panel.isVisible, orderOutTask == nil else { return }
        model.isShown = false
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.orderOutDelay)
            guard let self, !Task.isCancelled else { return }
            self.orderOutTask = nil
            self.panel?.orderOut(nil)
            self.anchor = nil
            self.model.content = nil
        }
    }

    private func scheduleShrink(to size: CGSize) {
        shrinkTask?.cancel()
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard let self, !Task.isCancelled, let panel = self.panel, let anchor = self.anchor,
                  self.model.content?.layout.size == size else { return }
            self.shrinkTask = nil
            self.place(panel, contentSize: size, anchor: anchor)
        }
    }

    private func place(_ panel: NSPanel, contentSize: CGSize, anchor: CGPoint) {
        let frame = DictationOverlayGeometry.panelFrame(contentSize: contentSize, anchor: anchor)
        canvasView?.setFrameOrigin(DictationOverlayGeometry.canvasOrigin(inPanelOfSize: frame.size))
        panel.setFrame(frame, display: true, animate: false)
        panelContentSize = contentSize
    }

    private func makePanel(for dictation: DictationCoordinator) -> NSPanel {
        let canvasSize = DictationOverlayGeometry.canvasSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let container = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        container.autoresizesSubviews = false
        let hosting = NSHostingView(rootView: DictationOverlayRoot(
            model: model,
            meter: dictation.audioLevelMeter,
            actions: DictationOverlayActions(dictation))
            .appLanguageRoot(settingsStore))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: canvasSize)
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        self.canvasView = hosting
        return panel
    }
}

/// What the HUD shows, and whether its capsule is on screen.
@MainActor
final class DictationOverlayModel: ObservableObject {
    @Published var content: DictationOverlayContent?
    @Published var isShown = false
}

struct DictationOverlayActions {
    var cancel: () -> Void = {}
    var copyNotice: () -> Void = {}
    var dismissNotice: () -> Void = {}
    var retryPreparation: () -> Void = {}
}

extension DictationOverlayActions {
    @MainActor
    init(_ dictation: DictationCoordinator) {
        self.init(
            cancel: { [weak dictation] in dictation?.cancel() },
            copyNotice: { [weak dictation] in dictation?.copyDeliveryNoticeText() },
            dismissNotice: { [weak dictation] in dictation?.dismissDeliveryNotice() },
            retryPreparation: { [weak dictation] in dictation?.retryModelPreparation() })
    }
}

/// The fixed-size canvas: the capsule sits at its bottom-center and enters
/// with a short rise, the HUD being summoned many times a day.
struct DictationOverlayRoot: View {
    @ObservedObject var model: DictationOverlayModel
    let meter: AudioLevelMeter
    let actions: DictationOverlayActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let margins = DictationOverlayGeometry.margins
        let canvas = DictationOverlayGeometry.canvasSize
        ZStack(alignment: .bottom) {
            if model.isShown, let content = model.content {
                DictationOverlayView(content: content, meter: meter, actions: actions)
                    .transition(transition)
            }
        }
        .padding(EdgeInsets(
            top: margins.top, leading: margins.left, bottom: margins.bottom, trailing: margins.right))
        .frame(width: canvas.width, height: canvas.height, alignment: .bottom)
        .brandTinted()
        // On the canvas rather than the capsule, so the capsule's position
        // springs together with its size and its bottom edge stays put.
        .animation(reduceMotion ? nil : Self.resize, value: model.content?.layout)
        .animation(model.isShown ? Self.entrance : Self.exit, value: model.isShown)
    }

    private static let resize: Animation = .spring(duration: 0.32, bounce: 0.12)
    private static let entrance: Animation = .spring(duration: 0.26, bounce: 0.14)
    private static let exit: Animation = .easeOut(duration: 0.14)

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.9, anchor: .bottom))
                .combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
    }
}

/// The capsule. Each kind of content is laid out at its own final size and
/// cross-fades, while the surface springs between sizes and clips whatever
/// does not fit yet.
struct DictationOverlayView: View {
    let content: DictationOverlayContent
    let meter: AudioLevelMeter
    let actions: DictationOverlayActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = content.layout.size
        ZStack {
            face
                .frame(width: size.width, height: size.height)
                .id(content.face)
                .transition(.opacity.animation(.easeOut(duration: 0.16)))
        }
        .frame(width: size.width, height: size.height)
        .dictationHUDSurface()
    }

    @ViewBuilder
    private var face: some View {
        switch content.kind {
        case .pill(let activity):
            pill(activity)
        case .transcript(let activity):
            transcriptPanel(activity)
        case let .preparation(presentation, canRetry):
            preparationPanel(presentation, canRetry: canRetry)
        case .notice(let notice):
            noticeRow(notice)
        }
    }

    // MARK: Pill

    /// The bars move only while audio arrives, and a microphone problem
    /// replaces them with words: the HUD once animated a fixed wave while the
    /// microphone reconnected, so recording looked fine when it was not.
    private func pill(_ activity: DictationOverlayContent.Activity) -> some View {
        HStack(spacing: 0) {
            leadingIndicator(activity)
                .frame(width: Self.slot, height: Self.slot)
            Spacer(minLength: 4)
            Group {
                if activity == .listening {
                    if content.captureStatus.isEmpty {
                        AudioLevelBars(meter: meter, live: content.microphoneLive)
                    } else {
                        statusText(content.captureStatus)
                    }
                } else {
                    Text(activity == .composing ? "Composing" : "Transcribing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .transition(.opacity)
            Spacer(minLength: 4)
            HUDCloseButton(help: "Cancel dictation", action: actions.cancel)
                .frame(width: Self.slot, height: Self.slot)
        }
        .padding(.horizontal, Self.inset)
    }

    @ViewBuilder
    private func leadingIndicator(_ activity: DictationOverlayContent.Activity) -> some View {
        if activity == .listening {
            DictationRecordingDot(live: content.microphoneLive)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        }
    }

    private func statusText(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LBTokens.Palette.attentionText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: Live transcript

    private func transcriptPanel(_ activity: DictationOverlayContent.Activity) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingIndicator(activity)
                    .frame(width: Self.slot, height: Self.slot)
                    .animation(.easeOut(duration: 0.16), value: activity)
                transcriptTitle(activity)
                if activity == .listening, !content.timer.isEmpty {
                    Text(content.timer)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 8)
                if activity == .listening, content.captureStatus.isEmpty {
                    AudioLevelBars(meter: meter, live: content.microphoneLive, barCount: 9, maxHeight: 16)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
                HUDCloseButton(help: "Cancel dictation", action: actions.cancel)
                    .frame(width: Self.slot, height: Self.slot)
            }
            .padding(.horizontal, Self.inset)
            .frame(height: 44)

            Divider()
                .padding(.horizontal, 14)

            transcriptBody(activity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func transcriptTitle(_ activity: DictationOverlayContent.Activity) -> some View {
        switch activity {
        case .listening:
            if content.captureStatus.isEmpty {
                Text("Dictating").hudTitle()
            } else {
                statusText(content.captureStatus)
            }
        case .transcribing:
            Text("Finalizing").hudTitle()
        case .composing:
            Text("Composing").hudTitle()
        }
    }

    @ViewBuilder
    private func transcriptBody(_ activity: DictationOverlayContent.Activity) -> some View {
        if content.transcript.isEmpty {
            Text(placeholder(activity))
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        transcriptText
                            .font(.system(size: 16))
                            .lineSpacing(3.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.transcriptEndID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                .mask {
                    // Earlier lines fade out under the header as text scrolls.
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14)],
                        startPoint: .top,
                        endPoint: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(Self.transcriptEndID, anchor: .bottom)
                }
                .onChange(of: content.transcript) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        proxy.scrollTo(Self.transcriptEndID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let transcriptEndID = "dictation-live-transcript-end"

    private func placeholder(_ activity: DictationOverlayContent.Activity) -> LocalizedStringKey {
        switch activity {
        case .listening: content.microphoneLive ? "Listening…" : "Starting the microphone…"
        case .transcribing: "Transcribing…"
        case .composing: "Composing…"
        }
    }

    private var transcriptText: Text {
        let committed = content.transcript.committed
        let tentative = content.transcript.tentative
        let committedText = Text(committed).foregroundColor(.primary)
        let tentativeText = Text(tentative).foregroundColor(.secondary)
        if committed.isEmpty { return tentativeText }
        if tentative.isEmpty { return committedText }
        return committedText + Text(" ") + tentativeText
    }

    // MARK: Model preparation

    private func preparationPanel(_ presentation: ModelPreparationPresentation, canRetry: Bool) -> some View {
        HStack(spacing: 10) {
            ModelPreparationView(
                presentation: presentation,
                style: .hud,
                action: canRetry ? actions.retryPreparation : nil)
            HUDCloseButton(help: "Cancel dictation", action: actions.cancel)
                .frame(width: Self.slot, height: Self.slot)
        }
        .padding(.leading, 16)
        .padding(.trailing, Self.inset)
    }

    // MARK: Delivery notice

    /// Pasted text the field did not show: offer it again instead of losing it.
    private func noticeRow(_ notice: DictationDeliveryNotice) -> some View {
        HStack(spacing: 0) {
            Image(systemName: notice.copied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.copied ? LBTokens.Palette.success : LBTokens.Palette.attention)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.slot, height: Self.slot)
            Text(notice.copied ? "Copied to the clipboard" : "The text may not have been inserted")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if !notice.copied {
                Button("Copy", action: actions.copyNotice)
                    .buttonStyle(HUDCapsuleButtonStyle())
                    .accessibilityIdentifier("dictation.notice.copy")
                    .padding(.trailing, 2)
            }
            HUDCloseButton(help: "Dismiss", action: actions.dismissNotice)
                .frame(width: Self.slot, height: Self.slot)
        }
        .padding(.horizontal, Self.inset)
        .animation(.easeOut(duration: 0.16), value: notice.copied)
    }

    /// Square cell for the leading indicator and the close button, the same
    /// in every shape so they stay put when the capsule changes.
    private static let slot: CGFloat = 30
    private static let inset: CGFloat = 4
}

private extension Text {
    func hudTitle() -> some View {
        font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}

extension DictationOverlayContent {
    /// What cross-fades. The transcript panel keeps one face across its
    /// activities, so its text does not blink when recording ends.
    enum Face: Hashable {
        case pill(Activity)
        case transcript
        case preparation
        case notice
    }

    var face: Face {
        switch kind {
        case .pill(let activity): .pill(activity)
        case .transcript: .transcript
        case .preparation: .preparation
        case .notice: .notice
        }
    }
}

// MARK: - Surface and controls

private extension View {
    /// The app's floating surface (glass on macOS 26, material before it, an
    /// opaque fill under Reduce Transparency), clipped to the capsule, with a
    /// soft shadow so it lifts off the app underneath.
    func dictationHUDSurface() -> some View {
        clipShape(RoundedRectangle(
            cornerRadius: DictationOverlayContent.Layout.cornerRadius, style: .continuous))
            .lbFloatingComposer()
            .background { HUDShadow(cornerRadius: DictationOverlayContent.Layout.cornerRadius) }
    }
}

/// A shadow drawn only outside the capsule: glass and material sample what
/// lies behind them, and a shadow shape underneath would darken the surface.
private struct HUDShadow: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14))
            .blur(radius: 9)
            .offset(y: 4)
            .mask { OutsideOfShape(cornerRadius: cornerRadius).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct OutsideOfShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -40, dy: -40))
        path.addRoundedRect(
            in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
        return path
    }
}

private struct HUDCloseButton: View {
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(isHovering ? 0.14 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(HUDPressStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct HUDCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(LBTokens.Palette.accentFill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HUDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Grey and still until the microphone delivers audio (a Bluetooth headset
/// can take a second to switch), then the pulsing recording dot.
private struct DictationRecordingDot: View {
    var live: Bool

    var body: some View {
        StatusDot(color: live ? Brand.recording : Color.secondary.opacity(0.6), size: 9, pulses: live)
            .animation(.easeOut(duration: 0.2), value: live)
            .accessibilityLabel(Text(live ? "Recording" : "Starting the microphone"))
    }
}

// MARK: - Level bars

/// Bars drawn from the microphone's measured loudness: the newest reading in
/// the middle, older ones rippling outward. Flat and dim while nothing
/// arrives, so a silent or reconnecting microphone is visible instead of
/// hidden behind a decorative animation. Drawn in a Canvas, so the 30 fps
/// redraw causes no layout.
struct AudioLevelBars: View {
    let meter: AudioLevelMeter
    var live = true
    var barCount = 11
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var maxHeight: CGFloat = 20
    @State private var follower = AudioLevelFollower()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { timeline in
            Canvas { context, size in
                let targets = live
                    ? Self.mirrored(meter.recent(barCount / 2 + 1))
                    : Array(repeating: Float(0), count: barCount)
                let levels = reduceMotion ? targets : follower.follow(targets, at: timeline.date)
                let color = live ? Brand.teal : Color.secondary.opacity(0.45)
                for (index, level) in levels.enumerated() {
                    let height = Self.height(
                        for: level * Self.envelope(index: index, count: levels.count),
                        maxHeight: maxHeight)
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + spacing),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing, height: maxHeight)
        .accessibilityHidden(true)
    }

    static func height(for level: Float, maxHeight: CGFloat, minHeight: CGFloat = 3) -> CGFloat {
        minHeight + CGFloat(min(max(level, 0), 1)) * (maxHeight - minHeight)
    }

    /// Recent levels, oldest first, laid out newest-in-the-middle.
    static func mirrored(_ recent: [Float]) -> [Float] {
        recent + recent.reversed().dropFirst()
    }

    /// Outer bars stand a little shorter, so the shape reads as a voice.
    static func envelope(index: Int, count: Int) -> Float {
        guard count > 1 else { return 1 }
        let center = Float(count - 1) / 2
        let distance = abs(Float(index) - center) / center
        return 1 - 0.45 * distance * distance
    }
}

/// Eases the bars toward the measured levels, quick to rise and slower to
/// fall like a level meter, so a dozen readings a second move smoothly.
final class AudioLevelFollower {
    private var levels: [Float] = []
    private var lastTime: Date?

    func follow(_ targets: [Float], at time: Date) -> [Float] {
        defer { lastTime = time }
        guard levels.count == targets.count, let lastTime else {
            levels = targets
            return levels
        }
        let elapsed = Float(min(max(time.timeIntervalSince(lastTime), 0), 0.1))
        for index in levels.indices {
            let timeConstant: Float = targets[index] > levels[index] ? 0.045 : 0.12
            levels[index] += (targets[index] - levels[index]) * (1 - exp(-elapsed / timeConstant))
        }
        return levels
    }
}
