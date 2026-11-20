import AppKit

@MainActor
enum FocusReturn {
    static func frontmostOtherApplication() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !frontmost.isTerminated else { return nil }
        return frontmost
    }

    @discardableResult
    static func activate(_ application: NSRunningApplication,
                         timeout: Duration = .milliseconds(800)) async -> Bool {
        guard !application.isTerminated else { return false }
        if isFrontmost(application) { return true }
        NSApp.yieldActivation(to: application)
        application.activate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if isFrontmost(application) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isFrontmost(application)
    }

    private static func isFrontmost(_ application: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }
}
