import Foundation

public struct AppLockPolicy: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case active
        case inactive
        case background
    }

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var isObscured: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.isLocked = isEnabled
        self.isObscured = false
    }

    @discardableResult
    public mutating func transition(to phase: Phase) -> Bool {
        guard isEnabled else {
            isObscured = false
            return false
        }
        switch phase {
        case .background:
            isLocked = true
            isObscured = true
            return false
        case .inactive:
            isObscured = true
            return false
        case .active:
            isObscured = false
            return isLocked
        }
    }

    public mutating func finishUnlock(succeeded: Bool) {
        if succeeded {
            isLocked = false
        }
    }

    public mutating func applyEnableChange(enabled: Bool, authenticated: Bool) {
        if enabled {
            if authenticated {
                isEnabled = true
            }
        } else if !isLocked {
            isEnabled = false
            isObscured = false
        }
    }
}
