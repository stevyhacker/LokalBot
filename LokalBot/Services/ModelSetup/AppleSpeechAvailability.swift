import Foundation
import Synchronization

#if canImport(Speech)
import Speech
#endif

/// Availability decision for macOS's built-in `SpeechAnalyzer` transcription,
/// keeping macOS 26 SDK symbols isolated from the macOS 15.0 deployment target.
enum AppleSpeechAvailability {
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

    static let unsupportedMessage = "Requires macOS 26 or later"
    static let unavailableOnDeviceMessage = "Apple Speech isn't available on this Mac."

    // Automation uses a synchronous readiness gate. ModelRoles refreshes this
    // from macOS when the selected configuration changes or preparation ends.
    private static let installedLanguages = Mutex<Set<TranscriptionLanguage>>([])

    static func hasPreparedAsset(for language: TranscriptionLanguage) -> Bool {
        installedLanguages.withLock { $0.contains(language) }
    }

    static func refreshAssetReadiness(for language: TranscriptionLanguage) async -> Bool {
        let installed = await AppleSpeechEngine.shared.isAssetInstalled(language: language.code)
        if !Task.isCancelled {
            installedLanguages.withLock {
                if installed { $0.insert(language) } else { $0.remove(language) }
            }
        }
        return installed
    }

    /// True when running on macOS 26+ and `SpeechTranscriber` reports on-device availability.
    nonisolated static var isSystemSupported: Bool {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        #endif
        return false
    }

    private nonisolated static var isOSSupported: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Pure availability mapping for deterministic unit tests across OS gates.
    nonisolated static func state(systemSupported: Bool, osSupported: Bool) -> State {
        guard osSupported else {
            return .unavailable(reason: unsupportedMessage)
        }
        guard systemSupported else {
            return .unavailable(reason: unavailableOnDeviceMessage)
        }
        return .available
    }

    @MainActor
    static func current() -> State {
        state(systemSupported: isSystemSupported, osSupported: isOSSupported)
    }
}
