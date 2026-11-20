import Foundation

struct CotypingFocusCapabilityFlickerGate: Sendable {
    static let requiredConsecutiveBlockedReads = 2

    nonisolated enum Decision: Equatable, Sendable {
        case apply
        case suppress(pendingBlockedReadCount: Int)
    }

    private var lastDeliveredSupportedIdentity: String?
    private var consecutiveBlockedReadCount = 0

    mutating func evaluate(_ focus: CotypingFocus) -> Decision {
        switch focus.capability {
        case .supported:
            lastDeliveredSupportedIdentity = focus.field?.focusIdentityKey ?? focus.focusIdentityKey
            consecutiveBlockedReadCount = 0
            return .apply

        case .blocked(let reason):
            guard Self.isSmoothableBlockedReason(reason),
                  let lastIdentity = lastDeliveredSupportedIdentity,
                  let currentIdentity = focus.focusIdentityKey ?? focus.field?.focusIdentityKey,
                  currentIdentity == lastIdentity else {
                lastDeliveredSupportedIdentity = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }

            consecutiveBlockedReadCount += 1
            if consecutiveBlockedReadCount >= Self.requiredConsecutiveBlockedReads {
                lastDeliveredSupportedIdentity = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }
            return .suppress(pendingBlockedReadCount: consecutiveBlockedReadCount)

        case .unsupported:
            lastDeliveredSupportedIdentity = nil
            consecutiveBlockedReadCount = 0
            return .apply
        }
    }

    nonisolated static func isSmoothableBlockedReason(_ reason: String) -> Bool {
        reason == "Text selected."
    }
}
