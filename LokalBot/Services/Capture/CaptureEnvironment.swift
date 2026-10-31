import AppKit
import CoreGraphics
import Foundation

/// A running application as a value, so traces can record and replay it.
/// Property names match `NSRunningApplication`, so detection helpers compile
/// unchanged when their parameter type switches.
struct RunningApp: Codable, Equatable, Hashable, Sendable {
    var processIdentifier: pid_t
    var bundleIdentifier: String?
    var localizedName: String?

    init(processIdentifier: pid_t, bundleIdentifier: String?, localizedName: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }

    init(_ app: NSRunningApplication) {
        self.init(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                  localizedName: app.localizedName)
    }
}

/// One accessibility read of a process's focused window, with the reason
/// when no snapshot was produced.
struct AccessibilityRead: Codable, Equatable, Sendable {
    var snapshot: ScreenAccessibilitySnapshot?
    var failure: ScreenAccessibilityReader.TextReadFailure?
}

protocol WorkspaceSource: Sendable {
    func frontmostApplication() -> RunningApp?
    func runningApplications() -> [RunningApp]
    func isRunning(processID: pid_t) -> Bool
    func secondsSinceLastInput() -> TimeInterval
}

protocol AccessibilitySource: Sendable {
    func isTrusted() -> Bool
    func read(processID: pid_t, includeText: Bool) -> AccessibilityRead
    /// The focused window's title, frame, document, and focused-field state,
    /// without walking its contents for web pages.
    func readWindow(processID: pid_t) -> AccessibilityRead
    /// Secure fields and page addresses without text, over at most
    /// `nodeLimit` elements: a capture's recheck after its pixels were taken.
    func readPrivacy(processID: pid_t, nodeLimit: Int?) -> AccessibilityRead
    func focusedWindowTitle(processID: pid_t) -> String?
    func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot?
    func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue?
}

extension AccessibilitySource {
    /// Recorded and replayed environments answer with their metadata read.
    func readWindow(processID: pid_t) -> AccessibilityRead {
        read(processID: processID, includeText: false)
    }

    /// Recorded and replayed environments answer with their full read.
    func readPrivacy(processID: pid_t, nodeLimit: Int?) -> AccessibilityRead {
        read(processID: processID, includeText: true)
    }
}

protocol WindowSource: Sendable {
    func screenCaptureGranted() -> Bool
    func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window]
    /// Captures a window returned by the most recent `onScreenWindows()`.
    func captureImage(windowID: CGWindowID) async throws -> CGImage
}

protocol AudioProcessSource: Sendable {
    func processes() throws -> [AudioProcess]
    func isProcessRunningInput(processID: pid_t) -> Bool
}

@MainActor
protocol CaptureTimer: AnyObject {
    func cancel()
}

protocol CaptureClock: Sendable {
    func now() -> Date
    func uptime() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
    @MainActor func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer
    @MainActor func repeating(every seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer
}

enum CaptureEnvironmentError: Error, Equatable {
    case windowUnavailable(CGWindowID)
}

/// Every OS boundary the capture, tracking, and detection services read.
/// Live wraps today's calls; tests and the UI background host install a
/// replay; Debug builds can install a recorder. Services read `current`.
struct CaptureEnvironment: Sendable {
    var workspace: any WorkspaceSource
    var accessibility: any AccessibilitySource
    var windows: any WindowSource
    var audio: any AudioProcessSource
    var clock: any CaptureClock

    static let live = CaptureEnvironment(
        workspace: LiveWorkspaceSource(),
        accessibility: LiveAccessibilitySource(),
        windows: LiveWindowSource(),
        audio: LiveAudioProcessSource(),
        clock: LiveCaptureClock())

    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = live

    static var current: CaptureEnvironment {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

#if DEBUG
    static func install(_ environment: CaptureEnvironment) {
        lock.lock()
        installed = environment
        lock.unlock()
    }

    static func reset() { install(live) }
#endif
}
