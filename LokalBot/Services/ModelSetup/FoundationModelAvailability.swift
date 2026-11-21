import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationModelAvailability {
    enum State: Equatable, Sendable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    static let unsupportedMessage = "Requires macOS 26 and Apple Intelligence"

    @MainActor
    static func current() -> State {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return mapped(SystemLanguageModel.default.availability)
        }
        #endif
        return .unavailable(reason: unsupportedMessage)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func mapped(_ availability: SystemLanguageModel.Availability) -> State {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac isn't eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use this model.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The Apple on-device model is still downloading or preparing.")
        @unknown default:
            return .unavailable(reason: "Apple Intelligence is unavailable on this device.")
        }
    }
    #endif
}
