import Foundation
import Combine

/// The single, always-alive owner of the persisted `AppSettings` value.
///
/// Long-lived services (pipeline, dictation, cotyping, chat tools, screenshots)
/// capture this store instead of weak-referencing `AppState`: a weak capture
/// with a `?? AppSettings()` fallback would silently hand out factory-default
/// settings if `AppState` were ever released — an incorrect success. The store
/// makes "settings always exist" true in the type system.
///
/// `AppState.settings` remains the UI-facing binding surface; its `didSet`
/// writes through here, so the store is always current.
@MainActor
final class SettingsStore: ObservableObject {
    private var persistTask: Task<Void, Never>?

    @Published var current: AppSettings {
        didSet {
            guard current != oldValue else { return }
            SpeakerAttribution.microphoneIsUser = current.microphoneIsUser
            ModelDownloadRouting.source = current.modelDownloadSource
            persistTask?.cancel()
            let snapshot = current
            persistTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                snapshot.save()
                self?.persistTask = nil
            }
        }
    }

    init(initialSettings: AppSettings? = nil) {
        current = initialSettings ?? AppSettings.load()
        // Transcript identity and the download source are read from many
        // model-layer call sites; the store is the one place they enter the process.
        SpeakerAttribution.microphoneIsUser = current.microphoneIsUser
        ModelDownloadRouting.source = current.modelDownloadSource
    }

    /// Flush debounced text-field edits before application termination.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        current.save()
    }
}
