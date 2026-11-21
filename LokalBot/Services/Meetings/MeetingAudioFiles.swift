import Foundation

enum MeetingAudioFiles {

    private static let completenessTolerance: TimeInterval = 0.1

    enum Track: String, CaseIterable {
        case mic
        case system

        var primaryFileName: String { "\(rawValue).m4a" }

        var portableFileName: String { "\(rawValue).wav" }

        var recoveryFileName: String {
            switch self {
            case .mic: AudioPreviewTee.micFileName
            case .system: AudioPreviewTee.systemFileName
            }
        }
    }

    static func primaryURL(for track: Track, in folder: URL) -> URL {
        folder.appendingPathComponent(track.primaryFileName)
    }

    static func recoveryURL(for track: Track, in folder: URL) -> URL {
        folder.appendingPathComponent(track.recoveryFileName)
    }

    static func portableURL(for track: Track, in folder: URL) -> URL {
        folder.appendingPathComponent(track.portableFileName)
    }

    static func readableURL(for track: Track, in folder: URL) -> URL? {
        preferredURL(for: track, in: folder, minimumDuration: 0)
    }

    static func transcribableURL(for track: Track, in folder: URL) -> URL? {
        preferredURL(for: track, in: folder,
                     minimumDuration: AudioFileInspector.minimumTranscribableDuration)
    }

    static func duration(for track: Track, in folder: URL) -> TimeInterval? {
        guard let url = readableURL(for: track, in: folder) else { return nil }
        return AudioFileInspector.duration(at: url)
    }

    static func longestDuration(in folder: URL) -> TimeInterval? {
        Track.allCases.compactMap { duration(for: $0, in: folder) }.max()
    }

    static func removeRedundantRecoveryFiles(in folder: URL) {
        for track in Track.allCases {
            let primary = primaryURL(for: track, in: folder)
            guard readableURL(for: track, in: folder) == primary else { continue }
            let preview = recoveryURL(for: track, in: folder)
            let rebuilt = try? AudioRecoveryJournal.recover(previewURL: preview)
            if FileManager.default.fileExists(atPath: AudioRecoveryJournal.directory(for: preview).path),
               AudioRecoveryJournal.receipt(previewURL: preview)?.complete != true { continue }
            let sources = [preview, rebuilt].compactMap { $0 }
            guard let complete = AudioFileInspector.fullyDecodedDuration(at: primary),
                  sources.compactMap({ AudioFileInspector.duration(at: $0) }).allSatisfy({ $0 <= complete + 0.1 }) else {
                continue
            }
            for source in sources { try? FileManager.default.removeItem(at: source) }
            if rebuilt != nil, AudioRecoveryJournal.receipt(previewURL: preview)?.complete == true {
                try? FileManager.default.removeItem(at: AudioRecoveryJournal.directory(for: preview))
                try? FileManager.default.removeItem(at: AudioRecoveryJournal.receiptURL(for: preview))
            }
        }
    }

    private static func preferredURL(for track: Track, in folder: URL,
                                     minimumDuration: TimeInterval) -> URL? {
        let primary = primaryURL(for: track, in: folder)
        let preview = recoveryURL(for: track, in: folder)
        let rebuilt = try? AudioRecoveryJournal.recover(previewURL: preview)
        let recovery = [preview, rebuilt].compactMap { $0 }.max {
            (AudioFileInspector.duration(at: $0) ?? 0) < (AudioFileInspector.duration(at: $1) ?? 0)
        } ?? preview
        let hasRecovery = AudioFileInspector.duration(at: recovery) != nil
        let primaryDuration = (hasRecovery ? AudioFileInspector.fullyDecodedDuration(at: primary)
            : AudioFileInspector.duration(at: primary))
            .flatMap { $0 >= minimumDuration && $0 > 0 ? $0 : nil }
        let recoveryDuration = AudioFileInspector.duration(at: recovery)
            .flatMap { $0 >= minimumDuration && $0 > 0 ? $0 : nil }

        switch (primaryDuration, recoveryDuration) {
        case (.some(let primaryDuration), .some(let recoveryDuration)):
            return recoveryDuration > primaryDuration + completenessTolerance ? recovery : primary
        case (.some, .none):
            return primary
        case (.none, .some):
            return recovery
        case (.none, .none):
            let portable = portableURL(for: track, in: folder)
            guard let duration = AudioFileInspector.duration(at: portable),
                  duration >= minimumDuration, duration > 0 else { return nil }
            return portable
        }
    }

    static func recoveryNeedsAttention(in folder: URL) -> Bool {
        Track.allCases.contains { track in
            let preview = recoveryURL(for: track, in: folder)
            return FileManager.default.fileExists(atPath: AudioRecoveryJournal.directory(for: preview).path)
                && AudioRecoveryJournal.receipt(previewURL: preview)?.complete != true
        }
    }
}
