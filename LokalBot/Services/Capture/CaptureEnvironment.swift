import AppKit
import CoreGraphics
import Foundation

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
    func readWindow(processID: pid_t) -> AccessibilityRead
    func readPrivacy(processID: pid_t, nodeLimit: Int?) -> AccessibilityRead
    func focusedWindowTitle(processID: pid_t) -> String?
    func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot?
    func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue?
    func browserMicrophoneWindowsAllowed(processID: pid_t) -> Bool
}

extension AccessibilitySource {
    func browserMicrophoneWindowsAllowed(processID: pid_t) -> Bool { false }

    func readWindow(processID: pid_t) -> AccessibilityRead {
        read(processID: processID, includeText: false)
    }

    func readPrivacy(processID: pid_t, nodeLimit: Int?) -> AccessibilityRead {
        read(processID: processID, includeText: true)
    }
}

protocol WindowSource: Sendable {
    func screenCaptureGranted() -> Bool
    func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window]
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
