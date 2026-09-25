import Foundation

/// Owns closed scratch audio while media restoration finishes. Cancellation
/// can discard it immediately, before the suspended transcription task resumes.
@MainActor
final class DictationAudioHandoff {
    private var audioURL: URL?

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    /// Transfers cleanup responsibility to the transcription/retry lifecycle.
    func take() -> URL? {
        defer { audioURL = nil }
        return audioURL
    }

    func discard() {
        guard let audioURL = take() else { return }
        try? FileManager.default.removeItem(at: audioURL)
    }

    deinit {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }
}
