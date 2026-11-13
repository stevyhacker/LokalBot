import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Binary "can Apple Intelligence run right now?" decision plus a user-facing
/// reason, so views and engines never touch FoundationModels symbols directly.
///
/// FoundationModels ships only in the macOS 26 SDK, but LokalBot deploys to
/// macOS 15.0 — every framework reference therefore lives behind
/// `#if canImport(FoundationModels)` and `if #available(macOS 26.0, *)`. On
/// anything older the framework is simply unavailable and `current()` reports
/// the supported-OS requirement.
enum FoundationModelAvailability {
    /// A two-case enum rather than a Bool because the unavailable reason is
    /// shown verbatim in Settings — callers need the explanation, not just a
    /// flag. `Sendable` lets the `@MainActor` `current()` result cross back to
    /// the non-isolated engine that consumes it without a concurrency warning.
    enum State: Equatable, Sendable {
        case available
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        /// User-facing explanation when unavailable; `nil` when available.
        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Reason returned when the build runs below macOS 26 or the framework is
    /// absent. Kept as one constant so the engine's defensive fallback path
    /// reuses the exact wording.
    static let unsupportedMessage = "Requires macOS 26 and Apple Intelligence"

    /// Resolves availability against the live system model on macOS 26+, and
    /// reports `unsupportedMessage` everywhere else. `@MainActor` because the
    /// system model is observed from the UI layer and we keep all reads on one
    /// actor to avoid duplicating observation state.
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
    /// Translates Apple's availability cases into our user-facing reasons. The
    /// `@unknown default` keeps us compiling if Apple adds reasons in a later SDK.
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
