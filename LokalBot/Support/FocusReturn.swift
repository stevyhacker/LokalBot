import AppKit

/// Hands keyboard focus back to the app a person was using before a LokalBot
/// panel took it, so pasting or dictating lands where they were working.
@MainActor
enum FocusReturn {
    /// The frontmost app, unless it is LokalBot itself.
    static func frontmostOtherApplication() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !frontmost.isTerminated else { return nil }
        return frontmost
    }

    /// Activates `application` and waits until it is frontmost. False when it
    /// quit or did not come forward in time.
    @discardableResult
    static func activate(_ application: NSRunningApplication,
                         timeout: Duration = .milliseconds(800)) async -> Bool {
        guard !application.isTerminated else { return false }
        if isFrontmost(application) { return true }
        // macOS 14+ activation is cooperative: the active app yields first.
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
