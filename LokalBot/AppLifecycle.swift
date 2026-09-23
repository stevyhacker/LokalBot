import SwiftUI
import LaunchAtLogin

/// Opt-in diagnostics for the dedicated hosted UI-test process. Production
/// targets compile this to a no-op, and the UI-test host emits nothing unless
/// the launch explicitly sets `LOKALBOT_UI_TEST_DIAGNOSTICS=1`.
func uiTestDiagnosticLog(_ message: @autoclosure () -> String) {
#if LOKALBOT_UI_TEST_HOST
    guard ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_DIAGNOSTICS"] == "1" else {
        return
    }
    print("[LokalBot UI diagnostics] \(message())")
#endif
}

/// Whether this launch should come up menu-bar-only (accessory: no Dock icon,
/// no window). Computed identically in the pre-launch entry point (to disable
/// window restoration before AppKit reads the flag) and in the app delegate (to
/// set the activation policy). "Established" = has seen onboarding OR already
/// granted every permission, so upgrades that predate the onboarding flag still
/// go menu-bar-only; only a genuinely-new user (and UI tests) stays windowed.
func lokalbotLaunchesMenuBarOnly() -> Bool {
    guard !AppState.isUITesting else { return false }
    let onboarded = UserDefaults.standard.bool(forKey: AppState.onboardingShownKey)
        || AppPermission.coreCases.allSatisfy { $0.isGranted }
    return AppSettings.load().menuBarOnly && onboarded
}

// MARK: - Menu-bar-only plumbing

/// Bridges AppKit launch + window lifecycle into the menu-bar-only experience.
/// SwiftUI alone can't suppress the launch window on macOS 14, so the Dock /
/// activation policy is driven from here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var appState: AppState?

    private var uiTestWindow: NSWindow?
    private var terminationCleanupStarted = false
    private var terminationCleanupFinished = false

    /// Hides the Dock icon for a menu-bar-only start. Setting `.accessory` this
    /// early also stops SwiftUI from auto-opening the launch window; restoration
    /// was already disabled in `LokalBotMain`. UI tests and not-yet-onboarded
    /// users stay windowed — see `lokalbotLaunchesMenuBarOnly()`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppState.isUITesting {
            NSApp.setActivationPolicy(.regular)
            return
        }
        if lokalbotLaunchesMenuBarOnly() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Keep the Dock icon in sync with what's on screen: a real (titled) window
    /// → show the Dock icon + app menu for full window UX; nothing open → fall
    /// back to a pure menu-bar accessory.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppState.isUITesting {
            uiTestDiagnosticLog(
                "didFinishLaunching application=\(NSStringFromClass(type(of: NSApp!))) "
                    + "principal=\(Bundle.main.principalClass.map(NSStringFromClass) ?? "nil")")
            NSApp.setActivationPolicy(.regular)
            let app = Self.appState ?? AppState()
            Self.appState = app
#if LOKALBOT_UI_TEST_HOST
            applyCaptureEnvironment(to: app)
#endif
            openUITestWindow(app: app)
            forceActivateForUITests()
            return
        }
        // Menu-bar-only *start* is gated on HOW we launched. Only a login
        // auto-start (the "Launch at login" item firing) should come up silent
        // in the menu bar; a manual open (Finder/Launchpad/Dock/`open`) must
        // show the main window. `willFinishLaunching` already set `.accessory`
        // to avoid a window-flash, so for a manual open we explicitly bring the
        // window back up as a regular, Dock-visible app. `wasLaunchedAtLogin`
        // is only reliable here in `applicationDidFinishLaunching`.
        if lokalbotLaunchesMenuBarOnly() {
            if LaunchAtLogin.wasLaunchedAtLogin {
                DispatchQueue.main.async { DockPolicy.beginLaunchSuppression() }
            } else {
                DispatchQueue.main.async { WindowAccess.shared.open("main") }
            }
        }
        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // `willClose` fires while the window still reports visible —
                // re-evaluate on the next tick once it's actually gone.
                DispatchQueue.main.async { DockPolicy.sync() }
            }
        }
    }

    /// Reopening the app (Finder/Launchpad relaunch, Dock click) brings the main
    /// window back: nothing on screen → open it; visible but buried behind other
    /// apps' windows → raise it. Returning true keeps AppKit's default
    /// un-miniaturize behavior.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowAccess.shared.open("main")
        } else if let main = WindowAccess.visibleMainWindow(in: sender) {
            main.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Give the in-process llama runtime a real shutdown window before AppKit
    /// calls exit(). Letting C++ static destructors run while Metal buffers are
    /// still resident trips ggml-metal's residency-set assertion on quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupFinished { return .terminateNow }
        guard !terminationCleanupStarted else { return .terminateLater }
        terminationCleanupStarted = true
        Task { @MainActor [weak self, weak sender] in
            if let app = Self.appState {
                await app.prepareForTermination()
            } else {
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                await LlamaServer.cotyping.stop()
                await GraniteSpeechEngine.shared.shutdown()
            }
            self?.terminationCleanupFinished = true
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private func openUITestWindow(app: AppState, kind: String? = nil) {
        let windowKind = kind ?? ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_WINDOW"] ?? "main"
        if let uiTestWindow, uiTestWindow.identifier?.rawValue == "\(windowKind).window" {
            uiTestWindow.makeKeyAndOrderFront(nil)
            uiTestWindow.orderFrontRegardless()
            return
        }

        let showsOnboarding = windowKind == "onboarding"
        let showsQuickRecall = windowKind == "quick-recall"
        let contentSize: NSSize
        if showsOnboarding {
            contentSize = NSSize(width: 640, height: 720)
        } else if showsQuickRecall {
            contentSize = NSSize(width: 660, height: 480)
        } else {
            // GitHub's hosted macOS desktop is narrower than the production
            // default. Keep the synthetic host inside the visible frame so
            // right-edge controls remain genuinely hittable by XCUITest.
            let visible = NSScreen.main?.visibleFrame.size
                ?? NSSize(width: 1180, height: 740)
            contentSize = NSSize(
                width: min(1180, max(900, visible.width - 40)),
                height: min(740, max(620, visible.height - 40)))
        }
        let window = MeetingFindWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.meetingFindAction = { [weak app] in
            guard let app, app.canSearchSelectedMeeting else { return false }
            // AppKit invokes key-equivalent handling inside its event dispatch.
            // Let that dispatch unwind before publishing the SwiftUI request;
            // otherwise the host can consume Command-F without invalidating the
            // meeting detail's state on macOS 15.
            let revision = app.meetingPageSearchRequestRevision
            uiTestDiagnosticLog("meetingFindAction schedule revision=\(revision)")
            DispatchQueue.main.async { [weak app] in
                guard let app else { return }
                app.requestSelectedMeetingSearch()
                uiTestDiagnosticLog(
                    "meetingFindAction publish revision="
                        + "\(app.meetingPageSearchRequestRevision)")
            }
            return true
        }
        window.title = showsOnboarding ? "Welcome to LokalBot" : (showsQuickRecall ? "Ask" : "LokalBot")
        if showsQuickRecall {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.identifier = NSUserInterfaceItemIdentifier("\(windowKind).window")
        let hostingView = NSHostingView(rootView: uiTestRootView(app: app, windowKind: windowKind))
        hostingView.identifier = NSUserInterfaceItemIdentifier("\(windowKind).window.host")
        hostingView.setAccessibilityLabel(showsOnboarding ? "LokalBot setup" : (showsQuickRecall ? "Quick Recall" : "LokalBot workspace"))
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        uiTestWindow = window
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.orderFrontRegardless()
        if showsQuickRecall {
            // The compact host has no menu-bar scene to register the normal
            // window opener. Its explicit handoff must still create a main
            // host before the compact window dismisses.
            WindowAccess.shared.register { [weak self, weak app] id in
                guard id == "main", let app else { return }
                self?.openUITestWindow(app: app, kind: "main")
            }
        }
    }

    @MainActor
    private func uiTestRootView(app: AppState, windowKind: String) -> some View {
        Group {
            if windowKind == "onboarding" {
                OnboardingView()
                    .environmentObject(app)
                    .brandTinted()
            } else if windowKind == "quick-recall" {
                QuickRecallView()
                    .environmentObject(app)
                    .brandTinted()
            } else {
                MainWindowView()
                    .environmentObject(app)
                    .brandTinted()
            }
        }
    }

#if LOKALBOT_UI_TEST_HOST
    /// Screenshot/scripting hook for the UI-test host: a few env vars let an
    /// external capture script land the window on a specific section with a
    /// meeting preselected, without synthetic input (no Accessibility needed).
    /// A no-op unless the vars are set, so the XCUITest suite is unaffected, and
    /// compiled out of every non-host build.
    @MainActor
    private func applyCaptureEnvironment(to app: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let style = env["LOKALBOT_CAPTURE_APPEARANCE"] {
            // Marketing captures must not depend on the host machine's
            // appearance: the committed README set is dark, and the scripted
            // sidebar colors resolve per scheme. Pin the app-level appearance
            // before the capture window exists so exports are reproducible.
            NSApp.appearance = NSAppearance(
                named: style == "contrast-dark" ? .accessibilityHighContrastDarkAqua : (style == "dark" ? .darkAqua : .aqua))
        }
        if let raw = env["LOKALBOT_INITIAL_SECTION"],
           let section = AppState.NavSection(captureName: raw) {
            app.navSection = section
            if let tab = AppState.TypeTab(captureName: raw) { app.openType(tab) }
            if ["write", "type"].contains(raw.lowercased()) { app.settingsTab = .writing }
            if let tab = AppState.SettingsTab(captureName: raw) { app.settingsTab = tab }
        }
        applyCaptureMeetingSelection(to: app, environment: env)
        applyRedesignCaptureState(to: app, environment: env)
        if env["LOKALBOT_CAPTURE_READY_FILE"] == nil,
           env["LOKALBOT_SELECT_FIRST"] == "1" || env["LOKALBOT_SELECT_INDEX"] != nil {
            // Storage discovery and NavigationSplitView restoration can both
            // update the selection after AppState is created. Reapply once the
            // synthetic library and list have settled so marketing captures
            // always show the requested meeting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak app] in
                guard let self, let app else { return }
                self.applyCaptureMeetingSelection(to: app, environment: env)
                self.applyRedesignCaptureState(to: app, environment: env)
            }
        }
        if env["LOKALBOT_DISMISS_ONBOARDING"] == "1" {
            UserDefaults.standard.set(true, forKey: "lokalbotv3.gettingStartedDismissed")
        }
        if let name = env["LOKALBOT_INITIAL_SETTINGS_CATEGORY"], let category = AppState.SettingsTab(captureName: name) {
            app.settingsTab = category
        }
        if env["LOKALBOT_INITIAL_ACTIONS"] == "1" { app.openActions() }
        if env["LOKALBOT_INITIAL_ASK_MODE"] == "search" { app.askMode = .keyword }
        #if LOKALBOT_UI_TEST_HOST
        if let key = env["LOKALBOT_INITIAL_ASK_DATE"] { app.askDateScope = AskDateScope(storageKey: key) }
        if let raw = env["LOKALBOT_INITIAL_ASK_FACET"], let facet = AskFacet(rawValue: raw) { app.recallState.facet = facet }
        app.recallState.screenApp = env["LOKALBOT_INITIAL_ASK_SCREEN_APP"]
        #endif
        if env["LOKALBOT_SHOW_GETTING_STARTED"] == "1" {
            UserDefaults.standard.set(false, forKey: "lokalbotv3.gettingStartedDismissed")
        }
        if let readyPath = env["LOKALBOT_CAPTURE_READY_FILE"], let path = env["LOKALBOT_CAPTURE_FILE"] {
            awaitCaptureReadiness(app: app, environment: env, readyPath: readyPath,
                                  capturePath: path, deadline: Date().addingTimeInterval(20))
            return
        }
        if env["LOKALBOT_CAPTURE_SIZE"] != nil {
            // Window creation happens immediately after this method. Resize on
            // the next settled turn, before the scripted rasterization delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let raw = env["LOKALBOT_CAPTURE_SIZE"] {
                    // These are outer-window dimensions, matching the frame
                    // view exported below (including its native titlebar).
                    let parts = raw.split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2, let window = self?.uiTestWindow {
                        window.setFrame(NSRect(origin: window.frame.origin,
                                               size: NSSize(width: parts[0], height: parts[1])), display: true)
                        window.center()
                    }
                }
            }
        }
        if let path = env["LOKALBOT_CAPTURE_FILE"] {
            // Self-capture: render the window to a PNG in-process and quit.
            // Needs no Screen Recording grant, and renders at a fixed 2x so
            // README assets are Retina-crisp regardless of the display.
            let delay = Double(env["LOKALBOT_CAPTURE_DELAY"] ?? "") ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.uiTestWindow else {
                    NSApp.terminate(nil)
                    return
                }
                // Repeated background launches can lose key status even after
                // the normal UI-test activation retries. Re-key immediately
                // before rasterization so active selections and titlebar
                // controls match what a person sees while using the app.
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                // Sidebar vibrancy redraws asynchronously after key-state
                // changes. A full second prevents the active material from
                // being captured between its mask and compositing passes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Self.writeWindowCapture(window, to: path)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The harness acknowledges populated route content after the window reaches
    /// its requested geometry. Keep the existing material settle after activation.
    @MainActor
    private func awaitCaptureReadiness(app: AppState, environment env: [String: String],
                                       readyPath: String, capturePath: String, deadline: Date) {
        guard Date() < deadline else {
            try? Data("Capture readiness timed out".utf8).write(
                to: URL(fileURLWithPath: capturePath + ".error"), options: .atomic)
            NSApp.terminate(nil)
            return
        }
        if let window = uiTestWindow, !app.meetings.isEmpty {
            applyCaptureMeetingSelection(to: app, environment: env)
            let parts = (env["LOKALBOT_CAPTURE_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                let size = NSSize(width: parts[0], height: parts[1])
                if window.frame.size != size {
                    window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
                    window.center()
                }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            if FileManager.default.fileExists(atPath: readyPath) {
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Self.writeWindowCapture(window, to: capturePath)
                    NSApp.terminate(nil)
                }
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak app] in
            guard let self, let app else { return }
            self.awaitCaptureReadiness(app: app, environment: env, readyPath: readyPath,
                                       capturePath: capturePath, deadline: deadline)
        }
    }

    @MainActor
    private func applyCaptureMeetingSelection(to app: AppState,
                                              environment env: [String: String]) {
        if env["LOKALBOT_SELECT_FIRST"] == "1", let first = app.meetings.first {
            if app.selectedMeetingIDs != [first.id] { app.selectedMeetingIDs = [first.id] }
        }
        if let raw = env["LOKALBOT_SELECT_INDEX"], let idx = Int(raw) {
            let ordered = app.meetings.sorted { $0.startedAt > $1.startedAt }
            if ordered.indices.contains(idx), app.selectedMeetingIDs != [ordered[idx].id] {
                app.selectedMeetingIDs = [ordered[idx].id]
            }
        }
    }

    @MainActor
    private func applyRedesignCaptureState(to app: AppState,
                                           environment env: [String: String]) {
        if env["LOKALBOT_AGENT_DEMO"] == "1" {
            let meeting = app.meetings.first
            app.openAgent(.init(
                title: "Draft the eviction-policy document",
                prompt: "Draft a concise follow-up for \(meeting?.displayTitle ?? "my latest meeting"). Do not send it.",
                meetingID: meeting?.id,
                actionID: nil))
        }
    }

    /// Render the window's frame view (titlebar + content) into a configurable
    /// high-density PNG via `cacheDisplay`, independent of the display's
    /// backing scale. README captures default to 2x; video experiments can ask
    /// for up to 4x through LOKALBOT_CAPTURE_SCALE.
    @MainActor
    private static func writeWindowCapture(_ window: NSWindow?, to path: String) {
        guard let window, let content = window.contentView else { return }
        let view: NSView = content.superview ?? content
        let bounds = view.bounds
        let requestedScale = Double(
            ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_SCALE"] ?? ""
        ) ?? 2
        let scale = CGFloat(min(max(requestedScale, 1), 4))
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        // cacheDisplay renders through the current display profile. Convert the
        // samples before tagging the web asset so P3 captures are not mislabeled.
        guard let export = rep.converting(to: .sRGB,
                                          renderingIntent: .relativeColorimetric) else { return }
        export.size = bounds.size
        if let png = export.representation(using: .png, properties: [:]) {
            // Readers treat the destination's appearance as completion.
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
#endif

    private func forceActivateForUITests() {
        for delay: Double in [0, 0.15, 0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                NSApp.setActivationPolicy(.regular)
                NSApp.unhide(nil)
                if let window = self?.uiTestWindow {
                    window.makeKeyAndOrderFront(nil)
                    window.makeMain()
                    window.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// The UI-test host owns an explicit AppKit window rather than a SwiftUI
/// `Window` scene, so scene commands are intentionally absent there. Handle
/// the meeting-local key equivalent at the same window boundary AppKit uses
/// for synthesized and physical keyboard events. Production keeps its visible
/// Edit-menu command in `LokalBotApp`.
final class MeetingFindWindow: NSWindow {
    var meetingFindAction: (() -> Bool)?

#if LOKALBOT_UI_TEST_HOST
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Self-captures rasterize the native frame view, including portions
        // beyond the hosted desktop. Preserve the requested layout instead of
        // silently clipping every large-window fixture to the runner's screen.
        // Interactive UI tests retain ordinary on-screen window constraints.
        if ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_FILE"] != nil {
            return frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
    }
#endif

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           event.modifierFlags.contains(.command) {
            uiTestDiagnosticLog(
                "window.sendEvent window=\(NSStringFromClass(type(of: self))) "
                    + "canHandle=\(Self.isMeetingFindKeyEquivalent(event))")
        }
        // `XCUIApplication.typeKey` and physical keyboard input arrive here as
        // key-down events. `performKeyEquivalent` is still needed for AppKit's
        // menu/responder traversal, but NSWindow does not route every key-down
        // through that method before dispatching it to the first responder.
        if event.type == .keyDown,
           Self.isMeetingFindKeyEquivalent(event),
           meetingFindAction?() == true {
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "f",
           event.modifierFlags.contains(.command) {
            uiTestDiagnosticLog(
                "window.performKeyEquivalent window=\(NSStringFromClass(type(of: self))) "
                    + "canHandle=\(Self.isMeetingFindKeyEquivalent(event))")
        }
        if Self.isMeetingFindKeyEquivalent(event),
           meetingFindAction?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isMeetingFindKeyEquivalent(_ event: NSEvent) -> Bool {
        !event.isARepeat
            && event.charactersIgnoringModifiers?.lowercased() == "f"
            && event.modifierFlags.intersection(
                [.command, .option, .control, .shift]) == .command
    }
}

/// Drives the Dock/menu-bar activation policy from the current setting and the
/// windows on screen: accessory (menu-bar-only) unless the user opted into a
/// Dock icon or a real window is open. Also the launch-time backstop that evicts
/// windows macOS restores behind a menu-bar-only start.
@MainActor
enum DockPolicy {
    /// True from a menu-bar-only launch until the first explicit user-initiated
    /// open. While set, any titled window on screen was restored or auto-opened
    /// by macOS (the user hasn't asked for one yet) and is evicted — `.accessory`
    /// and `ApplePersistenceIgnoreState` don't reliably stop that restore, so
    /// this is the deterministic backstop. Cleared by `WindowAccess.open`.
    static var evictRestoredWindows = false

    /// Start evicting restored/auto windows after a menu-bar-only launch. Sweeps
    /// a few times to catch windows SwiftUI restores asynchronously (or without
    /// firing a key notification); the flag itself persists until the first real
    /// open, so even a late restore is caught.
    static func beginLaunchSuppression() {
        evictRestoredWindows = true
        for delay: Double in [0, 0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sync() }
        }
    }

    static func sync() {
        guard !AppState.isUITesting else { return }
        let menuBarOnly = AppSettings.load().menuBarOnly

        if menuBarOnly {
            for window in NSApp.windows where isContentWindow(window) {
                window.isRestorable = false                 // never restore in menu-bar mode
                if evictRestoredWindows { window.close() }   // restored/auto → evict
            }
            if evictRestoredWindows { setPolicy(.accessory); return }
        }

        // The menu bar popover is a borderless, non-normal-level panel; only
        // titled, normal-level windows (main / onboarding / settings) count.
        let hasWindow = NSApp.windows.contains(where: isContentWindow)
        setPolicy((!menuBarOnly || hasWindow) ? .regular : .accessory)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && window.level == .normal
    }

    private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

/// Opens SwiftUI windows from non-View code (AppDelegate, AppState). SwiftUI's
/// `openWindow` only exists inside the View tree, so views register it here and
/// requests made before a view is alive are queued and flushed on registration.
@MainActor
final class WindowAccess {
    static let shared = WindowAccess()

    private var opener: ((String) -> Void)?
    private var pending: [String] = []

    /// Called from the first view that comes alive (the menu bar label at
    /// launch, then the popover/window). Flushes anything queued before now.
    func register(_ opener: @escaping (String) -> Void) {
        self.opener = opener
        let queued = pending
        pending.removeAll()
        queued.forEach(open)
    }

    func open(_ id: String) {
        // An explicit, user-initiated open: cancel any launch-time window
        // eviction, then switch to a regular, Dock-visible app so the window
        // gets standard chrome and the app menu. `willClose` drops back to
        // accessory afterwards when menu-bar-only.
        DockPolicy.evictRestoredWindows = false
        guard let application = NSApp else {
            pending.append(id)
            return
        }
        application.setActivationPolicy(.regular)
        application.activate()
        if id == "main", let existing = Self.visibleMainWindow(in: application) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let opener {
            opener(id)
        } else {
            pending.append(id)
        }
    }

    /// The visible main SwiftUI window, matched by its scene identifier —
    /// `navigationTitle` retitles the window per tab (e.g. "Timeline"), so
    /// matching on the title silently stops finding it.
    static func visibleMainWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { window in
            guard window.isVisible else { return false }
#if LOKALBOT_UI_TEST_HOST
            if window.identifier?.rawValue == "main.window" { return true }
#endif
            return window.identifier?.rawValue == "main"
        }
    }
}
