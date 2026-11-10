import CoreGraphics

/// Pure transition rule for the permission helper floating over System Settings.
/// The controller polls often, so unchanged state must collapse to `.none` to
/// avoid repeatedly ordering the panel and making it flicker.
nonisolated enum PermissionOverlayTracker {
    nonisolated enum Transition: Equatable {
        case present
        case reposition
        case hide
        case none
    }

    static func transition(
        settingsFrame: CGRect?,
        hasPresented: Bool,
        isVisible: Bool,
        lastFrame: CGRect?
    ) -> Transition {
        guard let settingsFrame else {
            return isVisible ? .hide : .none
        }

        guard hasPresented else {
            return .present
        }

        if !isVisible || settingsFrame != lastFrame {
            return .reposition
        }

        return .none
    }

    /// How long System Settings may take to open before the walkthrough
    /// gives up on it.
    static let launchGraceSeconds: Double = 30

    /// The walkthrough is over without a grant: System Settings was closed
    /// after the overlay had been shown, or never opened. Without this the
    /// tracking timer ran for the rest of the session, and the overlay came
    /// back whenever System Settings was next opened for any reason.
    static func shouldEnd(settingsRunning: Bool, hasPresented: Bool, secondsTracked: Double) -> Bool {
        guard !settingsRunning else { return false }
        return hasPresented || secondsTracked >= launchGraceSeconds
    }
}
