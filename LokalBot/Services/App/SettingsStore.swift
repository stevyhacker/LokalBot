import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    private var persistTask: Task<Void, Never>?

    @Published var current: AppSettings {
        didSet {
            guard current != oldValue else { return }
            SpeakerAttribution.microphoneIsUser = current.microphoneIsUser
            ModelDownloadRouting.source = current.modelDownloadSource
            RemoteTranscriptionConsent.current = .init(settings: current)
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
        SpeakerAttribution.microphoneIsUser = current.microphoneIsUser
        ModelDownloadRouting.source = current.modelDownloadSource
        RemoteTranscriptionConsent.current = .init(settings: current)
    }

    func flush() {
        persistTask?.cancel()
        persistTask = nil
        current.save()
    }
}
