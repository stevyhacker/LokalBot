#if DEBUG
import CoreGraphics
import Foundation

/// Wraps the live environment and records every answer with its time.
/// `finish(to:)` scrubs and writes the trace; nothing unscrubbed is written.
final class CaptureTraceRecorder: @unchecked Sendable {
    /// The recorder a `--record-capture` launch or the Debug menu installed.
    @MainActor static var active: CaptureTraceRecorder?

    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var events: [CaptureTrace.Event] = []
    let scenario: String
    let origin: CaptureTrace.Header.Origin
    private let base: CaptureEnvironment

    init(scenario: String, origin: CaptureTrace.Header.Origin, base: CaptureEnvironment = .live) {
        self.scenario = scenario
        self.origin = origin
        self.base = base
    }

    func record(_ event: (TimeInterval) -> CaptureTrace.Event) {
        let t = ProcessInfo.processInfo.systemUptime - started
        lock.lock()
        events.append(event(t))
        lock.unlock()
    }

    var environment: CaptureEnvironment {
        CaptureEnvironment(workspace: Workspace(recorder: self, base: base.workspace),
                           accessibility: Accessibility(recorder: self, base: base.accessibility),
                           windows: Windows(recorder: self, base: base.windows),
                           audio: Audio(recorder: self, base: base.audio),
                           clock: base.clock)
    }

    func finish(to directory: URL, recordedAt: Date = Date()) throws -> URL {
        lock.lock()
        let snapshot = events
        lock.unlock()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let raw = CaptureTrace(
            header: .init(schemaVersion: CaptureTrace.currentSchemaVersion,
                          macOSVersion: "\(version.majorVersion).\(version.minorVersion)",
                          origin: origin, scenario: scenario, scrubberVersion: nil, recordedAt: recordedAt),
            events: snapshot)
        let scrubbed = CaptureTraceScrubber().scrub(raw)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let url = directory.appendingPathComponent("\(formatter.string(from: recordedAt))-\(scenario).json")
        try scrubbed.write(to: url)
        return url
    }

    private struct Workspace: WorkspaceSource {
        let recorder: CaptureTraceRecorder
        let base: any WorkspaceSource
        func frontmostApplication() -> RunningApp? {
            let value = base.frontmostApplication()
            recorder.record { .init(t: $0, query: .frontmost, app: value) }
            return value
        }
        func runningApplications() -> [RunningApp] {
            let value = base.runningApplications()
            recorder.record { .init(t: $0, query: .runningApps, apps: value) }
            return value
        }
        func isRunning(processID: pid_t) -> Bool {
            let value = base.isRunning(processID: processID)
            recorder.record { .init(t: $0, query: .isRunning, processID: processID, flag: value) }
            return value
        }
        func secondsSinceLastInput() -> TimeInterval {
            let value = base.secondsSinceLastInput()
            recorder.record { .init(t: $0, query: .idleSeconds, seconds: value) }
            return value
        }
    }

    private struct Accessibility: AccessibilitySource {
        let recorder: CaptureTraceRecorder
        let base: any AccessibilitySource
        func isTrusted() -> Bool {
            let value = base.isTrusted()
            recorder.record { .init(t: $0, query: .trusted, flag: value) }
            return value
        }
        func read(processID: pid_t, includeText: Bool) -> AccessibilityRead {
            let value = base.read(processID: processID, includeText: includeText)
            recorder.record { .init(t: $0, query: .axRead, processID: processID, includeText: includeText, read: value) }
            return value
        }
        /// Recorded as a metadata read, which is what replay answers it with.
        func readWindow(processID: pid_t) -> AccessibilityRead {
            let value = base.readWindow(processID: processID)
            recorder.record { .init(t: $0, query: .axRead, processID: processID, includeText: false, read: value) }
            return value
        }
        func focusedWindowTitle(processID: pid_t) -> String? {
            let value = base.focusedWindowTitle(processID: processID)
            recorder.record { .init(t: $0, query: .focusedTitle, processID: processID, title: value) }
            return value
        }
        func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot? {
            let value = base.browserMeetingSnapshot(processID: processID, expectedURL: expectedURL)
            recorder.record { .init(t: $0, query: .browserSnapshot, processID: processID, browser: value) }
            return value
        }
        func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue? {
            let value = base.browserReadIssue(processID: processID)
            recorder.record { .init(t: $0, query: .browserReadIssue, processID: processID, issue: value) }
            return value
        }
    }

    private struct Windows: WindowSource {
        let recorder: CaptureTraceRecorder
        let base: any WindowSource
        func screenCaptureGranted() -> Bool {
            let value = base.screenCaptureGranted()
            recorder.record { .init(t: $0, query: .screenCaptureGranted, flag: value) }
            return value
        }
        func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window] {
            let value = try await base.onScreenWindows()
            recorder.record { .init(t: $0, query: .windows, windows: value) }
            return value
        }
        func captureImage(windowID: CGWindowID) async throws -> CGImage {
            try await base.captureImage(windowID: windowID) // pixels are never recorded
        }
    }

    private struct Audio: AudioProcessSource {
        let recorder: CaptureTraceRecorder
        let base: any AudioProcessSource
        func processes() throws -> [AudioProcess] {
            let value = try base.processes()
            recorder.record { .init(t: $0, query: .audioProcesses, processes: value) }
            return value
        }
        func isProcessRunningInput(processID: pid_t) -> Bool {
            let value = base.isProcessRunningInput(processID: processID)
            recorder.record { .init(t: $0, query: .inputRunning, processID: processID, flag: value) }
            return value
        }
    }
}
#endif
