import Foundation

@MainActor
final class DictationAudioHandoff {
    private var audioURL: URL?

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

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
