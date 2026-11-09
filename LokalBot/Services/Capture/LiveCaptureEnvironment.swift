import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// `RunningApp` values for NSWorkspace's running applications. Each property
/// read on an `NSRunningApplication` is a synchronous LaunchServices round
/// trip, and NSWorkspace hands back fresh objects on every call for the
/// ~100 processes without a bundle id. The meeting detector mapped all ~200
/// apps twice per 2-second tick on the main thread, which a live profile on
/// 2026-10-01 showed as 40–70 ms stalls every tick.
///
/// The list is now read once and kept until an app launches or quits
/// (NSWorkspace posts both), or at most `maximumAge`. Every caller looks apps
/// up by bundle id; the processes that churn have none. Values are also kept
/// per application object, retained while cached so an identifier is never
/// reused, so a refresh only reads apps it has not seen.
final class RunningApplicationCache: @unchecked Sendable {
    static let shared = RunningApplicationCache(observeWorkspace: true)
    static let maximumAge: TimeInterval = 30

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: (app: NSRunningApplication, value: RunningApp)] = [:]
    private var snapshot: (values: [RunningApp], takenAt: TimeInterval)?
    private let makeValue: (NSRunningApplication) -> RunningApp
    private let uptime: () -> TimeInterval
    private var observers: [NSObjectProtocol] = []

    init(makeValue: @escaping (NSRunningApplication) -> RunningApp = RunningApp.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         observeWorkspace: Bool = false) {
        self.makeValue = makeValue
        self.uptime = uptime
        guard observeWorkspace else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            })
        }
    }

    /// The running applications, re-read only after a launch, a quit, or
    /// `maximumAge`.
    func runningApplications(_ read: () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications })
        -> [RunningApp] {
        let now = uptime()
        if let cached = lock.withLock({ snapshot }), now - cached.takenAt < Self.maximumAge {
            return cached.values
        }
        let values = values(for: read())
        lock.withLock { snapshot = (values, now) }
        return values
    }

    func invalidate() {
        lock.withLock { snapshot = nil }
    }

    func values(for apps: [NSRunningApplication]) -> [RunningApp] {
        lock.withLock {
            var next: [ObjectIdentifier: (app: NSRunningApplication, value: RunningApp)] = [:]
            next.reserveCapacity(apps.count)
            var values: [RunningApp] = []
            values.reserveCapacity(apps.count)
            for app in apps {
                let key = ObjectIdentifier(app)
                let value = entries[key]?.value ?? makeValue(app)
                next[key] = (app, value)
                values.append(value)
            }
            entries = next
            return values
        }
    }

    func value(for app: NSRunningApplication) -> RunningApp {
        lock.withLock {
            let key = ObjectIdentifier(app)
            if let cached = entries[key] { return cached.value }
            let value = makeValue(app)
            entries[key] = (app, value)
            return value
        }
    }
}

struct LiveWorkspaceSource: WorkspaceSource {
    func frontmostApplication() -> RunningApp? {
        NSWorkspace.shared.frontmostApplication.map(RunningApplicationCache.shared.value(for:))
    }

    func runningApplications() -> [RunningApp] {
        RunningApplicationCache.shared.runningApplications()
    }

    func isRunning(processID: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processID) != nil
    }

    func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

struct LiveAccessibilitySource: AccessibilitySource {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func read(processID: pid_t, includeText: Bool) -> AccessibilityRead {
        let snapshot = ScreenAccessibilityReader.resolve(processID: processID, reading: includeText ? .text : .metadata)
        let failure = snapshot == nil && includeText
            ? ScreenAccessibilityReader.lastTextReadFailure(for: processID) : nil
        return AccessibilityRead(snapshot: snapshot, failure: failure)
    }

    func readWindow(processID: pid_t) -> AccessibilityRead {
        AccessibilityRead(snapshot: ScreenAccessibilityReader.resolve(processID: processID, reading: .window),
                          failure: nil)
    }

    func readPrivacy(processID: pid_t, nodeLimit: Int?) -> AccessibilityRead {
        AccessibilityRead(snapshot: ScreenAccessibilityReader.resolve(
            processID: processID, reading: .privacy, nodeLimit: nodeLimit ?? 320), failure: nil)
    }

    func focusedWindowTitle(processID: pid_t) -> String? {
        FocusedWindowTitleLookup.resolveTitle(processID: processID)
    }

    func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot? {
        BrowserMeetingSession.liveSnapshot(processID: processID, expectedURL: expectedURL)
    }

    func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue? {
        BrowserMeetingSession.lastReadIssue(processID: processID)
    }
}

/// Keeps the last ScreenCaptureKit window list so a capture uses the same
/// `SCWindow` the selection came from, exactly as before the seam existed.
final class LiveWindowSource: WindowSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [CGWindowID: SCWindow] = [:]

    func screenCaptureGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        lock.lock()
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        lock.unlock()
        return content.windows.compactMap { window in
            guard let application = window.owningApplication else { return nil }
            return ScreenshotCaptureLayout.Window(
                id: window.windowID, processID: application.processID, appName: application.applicationName,
                title: window.title ?? "", frame: window.frame)
        }
    }

    func captureImage(windowID: CGWindowID) async throws -> CGImage {
        lock.lock()
        let window = windows[windowID]
        lock.unlock()
        guard let window else { throw CaptureEnvironmentError.windowUnavailable(windowID) }
        // Bound the source frame before ScreenCaptureKit allocates it. Vision
        // receives this same readable 1,500 px frame in the worker; requesting
        // a native 5K/6K IOSurface only inflated transient memory.
        let configuration = SCStreamConfiguration()
        // This filter contains only the AX-checked window. Display capture,
        // even with app exclusions, can include unchecked background domains.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)),
            pixelHeight: Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.showsCursor = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

struct LiveAudioProcessSource: AudioProcessSource {
    func processes() throws -> [AudioProcess] { try CoreAudioUtils.listAudioProcesses() }
    func isProcessRunningInput(processID: pid_t) -> Bool { CoreAudioUtils.isProcessRunningInput(pid: processID) }
}

@MainActor
private final class DispatchCaptureTimer: CaptureTimer {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

@MainActor
private final class FoundationCaptureTimer: CaptureTimer {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

struct LiveCaptureClock: CaptureClock {
    func now() -> Date { Date() }
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

    @MainActor
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchCaptureTimer(item: item)
    }

    @MainActor
    func repeating(every seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated { work() }
        }
        return FoundationCaptureTimer(timer: timer)
    }
}
