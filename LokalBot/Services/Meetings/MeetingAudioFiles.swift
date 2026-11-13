import Foundation

/// Resolves the durable AAC tracks and the crash-safe PCM preview tees for one
/// meeting. A process crash can leave `mic.m4a` / `system.m4a` unreadable
/// because their MP4 containers were never finalized; the append-only CAF tees
/// remain readable and must stay available for transcription and playback.
/// Meetings recorded, imported or merged by the Windows and Linux app keep
/// 16 kHz `mic.wav` / `system.wav` tracks instead; they are read only when a
/// folder has neither an AAC track nor a recovery tee.
enum MeetingAudioFiles {

    /// Container finalization and the PCM tee can differ by a small encoder
    /// tail. A larger gap means the primary track was truncated and the CAF is
    /// the more complete recording.
    private static let completenessTolerance: TimeInterval = 0.1

    enum Track: String, CaseIterable {
        case mic
        case system

        var primaryFileName: String { "\(rawValue).m4a" }

        /// Written by the Windows and Linux app, which has no AAC encoder.
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

    /// Prefer the compact AAC track, falling back to the crash-safe CAF only
    /// when AAC cannot be decoded or is materially shorter. The latter covers
    /// a crash that leaves a technically readable but truncated MP4 container.
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

    /// A normal stop leaves a finalized primary track, so its duplicate CAF can
    /// be removed. If the primary is unreadable, preserving the CAF is a hard
    /// data-safety rule: it may be the user's only recoverable recording.
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
            // Keep checkpoints if reconstruction failed: they may be the only
            // surviving copies of intervals not described by the AAC header.
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
        // A readable AAC header alone cannot prove its payload is intact.
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
