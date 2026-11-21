import CoreGraphics

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

    static let launchGraceSeconds: Double = 30

    static func shouldEnd(settingsRunning: Bool, hasPresented: Bool, secondsTracked: Double) -> Bool {
        guard !settingsRunning else { return false }
        return hasPresented || secondsTracked >= launchGraceSeconds
    }
}
