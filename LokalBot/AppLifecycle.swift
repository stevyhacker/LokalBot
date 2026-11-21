import SwiftUI
import LaunchAtLogin

func uiTestDiagnosticLog(_ message: @autoclosure () -> String) {
#if LOKALBOT_UI_TEST_HOST
    guard ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_DIAGNOSTICS"] == "1" else {
        return
    }
    print("[LokalBot UI diagnostics] \(message())")
#endif
}

func lokalbotLaunchesMenuBarOnly() -> Bool {
    guard !AppState.isUITesting else { return false }
    let onboarded = UserDefaults.standard.bool(forKey: AppState.onboardingShownKey)
        || AppPermission.coreCases.allSatisfy { $0.isGranted }
    return AppSettings.load().menuBarOnly && onboarded
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var appState: AppState?

    private var uiTestWindow: NSWindow?
    private var uiTestSettingsWindow: NSWindow?
    private var terminationCleanupStarted = false
    private var terminationCleanupFinished = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppState.isUITesting {
            NSApp.setActivationPolicy(.regular)
            return
        }
        if lokalbotLaunchesMenuBarOnly() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let settings = Self.appState?.settings {
            AppAppearance.apply(theme: settings.appTheme)
        }
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
            WindowAccess.shared.hostOpener = { [weak self, weak app] id in
                guard id == WindowAccess.settingsID, let self, let app else { return false }
                self.openUITestWindow(app: app, kind: "settings", secondary: true)
                return true
            }
            forceActivateForUITests()
            return
        }
        if !UITestRuntime.isUnitTesting {
            Task.detached(priority: .utility) {
                TranscriptionModelStore.removeRetiredModels(appSupport: AppDirectories.applicationSupport)
            }
        }
        if lokalbotLaunchesMenuBarOnly() {
            if LaunchAtLogin.wasLaunchedAtLogin || AppControlProtocol.isBackgroundLaunch() || AgentSetup.isLaunch() {
                DispatchQueue.main.async { DockPolicy.beginLaunchSuppression() }
            } else {
                DispatchQueue.main.async { WindowAccess.shared.open("main") }
            }
        }
#if LOKALBOT_TEST_HOOKS
        if let app = Self.appState { FilmDirector.startIfRequested(app: app) }
#endif
        LaunchAtLoginState.shared.refresh()
        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { DockPolicy.sync() }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.appState?.githubStar.recordActiveDay()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowAccess.shared.open("main")
        } else if let main = WindowAccess.visibleMainWindow(in: sender) {
            main.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupFinished { return .terminateNow }
        guard !terminationCleanupStarted else { return .terminateLater }
        terminationCleanupStarted = true
        Task { @MainActor [weak self, weak sender] in
            if let app = Self.appState {
                guard await app.prepareForTermination() else {
                    self?.terminationCleanupStarted = false
                    sender?.reply(toApplicationShouldTerminate: false)
                    WindowAccess.shared.open("main")
                    return
                }
            } else {
                await LlamaServer.shared.stop()
                await LlamaServer.embedder.stop()
                await LlamaServer.cotyping.stop()
                await GraniteSpeechEngine.shared.shutdown()
                await QwenASREngine.accuracy.shutdown()
                await FileMediaEmbedderRuntime.shared.shutdown()
            }
            self?.terminationCleanupFinished = true
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private func openUITestWindow(app: AppState, kind: String? = nil, secondary: Bool = false) {
        let environment = ProcessInfo.processInfo.environment
        let windowKind = kind ?? environment["LOKALBOT_UI_TEST_WINDOW"] ?? Self.launchWindowKind(environment)
        let open = [uiTestWindow, uiTestSettingsWindow].compactMap { $0 }
        if let existing = open.first(where: { $0.identifier?.rawValue == "\(windowKind).window" }) {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let showsOnboarding = windowKind == "onboarding"
        let showsQuickRecall = windowKind == "quick-recall"
        let showsSettings = windowKind == "settings"
        let contentSize: NSSize
        if showsOnboarding {
            contentSize = NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height)
        } else if showsQuickRecall {
            contentSize = NSSize(width: QuickRecallView.size.width, height: QuickRecallView.size.height)
        } else {
            let visible = NSScreen.main?.visibleFrame.size
                ?? NSSize(width: 1180, height: 740)
            let ideal = showsSettings ? SettingsView.defaultSize : CGSize(width: 1180, height: 740)
            contentSize = NSSize(
                width: min(ideal.width, max(900, visible.width - 40)),
                height: min(ideal.height, max(620, visible.height - 40)))
        }
        let window = MeetingFindWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.meetingFindAction = { [weak app] in
            guard let app, app.canSearchSelectedMeeting else { return false }
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
        window.title = showsOnboarding ? "Welcome to LokalBot"
            : (showsQuickRecall ? "Quick Recall" : (showsSettings ? "Settings" : "LokalBot"))
        if showsQuickRecall || showsOnboarding || showsSettings {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        } else {
            window.toolbarStyle = .unified
        }
        window.identifier = NSUserInterfaceItemIdentifier("\(windowKind).window")
#if LOKALBOT_UI_TEST_HOST
        let captureSize = secondary ? [] : (ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_SIZE"] ?? "")
            .split(separator: "x").compactMap { Double($0) }
        if captureSize.count == 2 {
            window.setFrame(NSRect(origin: .zero, size: NSSize(width: captureSize[0], height: captureSize[1])),
                            display: false)
        }
#endif
        let hostingView = NSHostingView(rootView: uiTestRootView(app: app, windowKind: windowKind))
        hostingView.identifier = NSUserInterfaceItemIdentifier("\(windowKind).window.host")
        hostingView.setAccessibilityLabel(showsOnboarding ? "LokalBot setup"
            : (showsQuickRecall ? "Quick Recall" : (showsSettings ? "LokalBot settings" : "LokalBot workspace")))
#if LOKALBOT_UI_TEST_HOST
        if captureSize.count == 2 {
            hostingView.sizingOptions.remove(.minSize)
        }
#endif
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        if secondary { uiTestSettingsWindow = window } else { uiTestWindow = window }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.orderFrontRegardless()
        if showsQuickRecall {
            WindowAccess.shared.register { [weak self, weak app] id in
                guard id == "main", let app else { return }
                self?.openUITestWindow(app: app, kind: "main")
            }
        }
    }

    static func launchWindowKind(_ environment: [String: String]) -> String {
#if LOKALBOT_UI_TEST_HOST
        if let raw = environment["LOKALBOT_INITIAL_SECTION"],
           AppState.SettingsTab.opensSettings(sectionName: raw) { return "settings" }
#endif
        return "main"
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
            } else if windowKind == "settings" {
                SettingsView()
                    .environmentObject(app)
                    .brandTinted()
            } else if windowKind == "menu-bar" {
                MenuBarView(dictation: app.dictation)
                    .environmentObject(app)
                    .brandTinted()
            } else if windowKind == "live-preview", let meeting = app.meetings.first {
                NavigationStack {
                    LiveMeetingDetailView(meeting: meeting, transcriber: app.liveTranscriber)
                }
                .environmentObject(app)
                .brandTinted()
            } else {
                MainWindowView()
                    .environmentObject(app)
                    .brandTinted()
            }
        }
        .appLanguageRoot(app.settingsStore)
    }

#if LOKALBOT_UI_TEST_HOST
    @MainActor
    private func applyCaptureEnvironment(to app: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let style = env["LOKALBOT_CAPTURE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(
                named: style == "contrast-dark" ? .accessibilityHighContrastDarkAqua : (style == "dark" ? .darkAqua : .aqua))
        }
        if let raw = env["LOKALBOT_INITIAL_SECTION"] {
            if let section = AppState.NavSection(captureName: raw) {
                app.navSection = section
            } else if AppState.SettingsTab.opensSettings(sectionName: raw) {
                if ["write", "type"].contains(raw.lowercased()) { app.settingsTab = .writing }
                if let tab = AppState.SettingsTab(captureName: raw) { app.settingsTab = tab }
                if let tab = AppState.TypeTab(captureName: raw) {
                    app.settingsTab = tab == .cotyping ? .writing : .dictation
                }
            }
        }
        applyCaptureMeetingSelection(to: app, environment: env)
        applyRedesignCaptureState(to: app, environment: env)
        if env["LOKALBOT_CAPTURE_READY_FILE"] == nil,
           env["LOKALBOT_SELECT_FIRST"] == "1" || env["LOKALBOT_SELECT_INDEX"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak app] in
                guard let self, let app else { return }
                self.applyCaptureMeetingSelection(to: app, environment: env)
                self.applyRedesignCaptureState(to: app, environment: env)
            }
        }
        if env["LOKALBOT_DISMISS_ONBOARDING"] == "1" {
            UserDefaults.standard.set(true, forKey: "lokalbotv3.gettingStartedDismissed")
        }
        #if LOKALBOT_UI_TEST_HOST
        if env["LOKALBOT_RESET_SPLIT_VIEWS"] == "1" {
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let raw = env["LOKALBOT_CAPTURE_SIZE"] {
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
            let delay = Double(env["LOKALBOT_CAPTURE_DELAY"] ?? "") ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.uiTestWindow else {
                    NSApp.terminate(nil)
                    return
                }
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                Self.focusQuickRecallField(in: window)
                Self.raiseCaptureDensity(of: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Self.writeWindowCapture(window, to: path)
                    NSApp.terminate(nil)
                }
            }
        }
    }

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
                Self.focusQuickRecallField(in: window)
                Self.raiseCaptureDensity(of: window)
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

    private static var captureScale: CGFloat {
        let requested = Double(ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_SCALE"] ?? "") ?? 2
        return CGFloat(min(max(requested, 1), 4))
    }

    @MainActor
    private static func focusQuickRecallField(in window: NSWindow) {
        guard ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_WINDOW"] == "quick-recall",
              let content = window.contentView else { return }
        func editableField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(editableField).first
        }
        guard let field = editableField(in: content), window.makeFirstResponder(field) else { return }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    @MainActor
    private static func raiseCaptureDensity(of window: NSWindow) {
        let scale = captureScale
        guard scale > window.backingScaleFactor,
              let root = (window.contentView?.superview ?? window.contentView)?.layer else { return }
        func overrides(_ type: AnyClass, _ base: AnyClass, _ selector: Selector) -> Bool {
            class_getMethodImplementation(type, selector) != class_getMethodImplementation(base, selector)
        }
        func drawsOwnContent(_ layer: CALayer) -> Bool {
            if overrides(type(of: layer), CALayer.self, #selector(CALayer.draw(in:))) { return true }
            guard let view = layer.delegate as? NSView else { return false }
            return overrides(type(of: view), NSView.self, #selector(NSView.draw(_:)))
        }
        func raise(_ layer: CALayer) {
            if drawsOwnContent(layer) {
                layer.contentsScale = scale
                layer.setNeedsDisplay()
                layer.displayIfNeeded()
            }
            layer.sublayers?.forEach(raise)
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { raise(root) }
    }

    @MainActor
    private static func drawAttachedSheet(of window: NSWindow, into rep: NSBitmapImageRep) {
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { return }
        let view: NSView = content.superview ?? content
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let sheetRep = view.bitmapImageRepForCachingDisplay(in: bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        view.cacheDisplay(in: bounds, to: sheetRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSRect(origin: .zero, size: rep.size).fill(using: .sourceOver)
        let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        sheetRep.draw(in: NSRect(origin: origin, size: bounds.size), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private static func writeWindowCapture(_ window: NSWindow?, to path: String) {
        guard let window, let content = window.contentView else { return }
        let view: NSView = content.superview ?? content
        let bounds = view.bounds
        let scale = captureScale
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
        drawAttachedSheet(of: window, into: rep)
        guard let export = rep.converting(to: .sRGB,
                                          renderingIntent: .relativeColorimetric) else { return }
        export.size = bounds.size
        if let png = export.representation(using: .png, properties: [:]) {
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

final class MeetingFindWindow: NSWindow {
    var meetingFindAction: (() -> Bool)?

#if LOKALBOT_UI_TEST_HOST
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
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

@MainActor
enum DockPolicy {
    static var evictRestoredWindows = false

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
                window.isRestorable = false
                if evictRestoredWindows { window.close() }
            }
            if evictRestoredWindows { setPolicy(.accessory); return }
        }

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

@MainActor
final class WindowAccess {
    static let shared = WindowAccess()

    private var opener: ((String) -> Void)?
    private var pending: [String] = []

    func register(_ opener: @escaping (String) -> Void) {
        self.opener = opener
        let queued = pending
        pending.removeAll()
        queued.forEach(open)
    }

    static let settingsID = "settings"

    var hostOpener: ((String) -> Bool)?

    func open(_ id: String) {
        DockPolicy.evictRestoredWindows = false
        guard let application = NSApp else {
            pending.append(id)
            return
        }
        application.setActivationPolicy(.regular)
        application.activate()
        if id == "main" || id == Self.settingsID, let existing = Self.visibleWindow(id, in: application) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let hostOpener, hostOpener(id) { return }
        if let opener {
            opener(id)
        } else {
            pending.append(id)
        }
    }

    func close(_ id: String) {
        NSApp?.windows.filter { $0.identifier?.rawValue == id }.forEach { $0.close() }
    }

    static func visibleMainWindow(in application: NSApplication) -> NSWindow? {
        visibleWindow("main", in: application)
    }

    static func visibleWindow(_ id: String, in application: NSApplication) -> NSWindow? {
        application.windows.first { window in
            guard window.isVisible else { return false }
#if LOKALBOT_UI_TEST_HOST
            if window.identifier?.rawValue == "\(id).window" { return true }
#endif
            return window.identifier?.rawValue == id
        }
    }
}
