import AVFoundation

enum MeetingAudioAsset {
    struct PreparedAsset {
        let composition: AVMutableComposition
        let audioMix: AVMutableAudioMix
        let duration: TimeInterval
        let trackCount: Int
    }

    enum AudioAssetError: LocalizedError {
        case noPlayableTracks
        case exportSessionUnavailable
        case exportFailed(String)
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .noPlayableTracks:
                "No playable audio tracks were found for this meeting."
            case .exportSessionUnavailable:
                "This recording could not be prepared for export."
            case .exportFailed(let message):
                "Audio export failed: \(message)"
            case .exportCancelled:
                "Audio export was cancelled."
            }
        }
    }

    private struct Source {
        let url: URL
        let gain: Float
    }

    static func prepare(folder: URL, hasSystemTrack: Bool) throws -> PreparedAsset {
        let sources = existingSources(folder: folder, hasSystemTrack: hasSystemTrack)
        guard !sources.isEmpty else { throw AudioAssetError.noPlayableTracks }

        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        var longest = CMTime.zero

        for source in sources {
            let asset = AVURLAsset(url: source.url)
            guard let sourceTrack = asset.tracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }

            let timeRange = sourceTrack.timeRange
            let seconds = CMTimeGetSeconds(timeRange.duration)
            guard seconds.isFinite, seconds > 0 else { continue }

            try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)

            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            input.setVolume(source.gain, at: .zero)
            parameters.append(input)

            if CMTimeCompare(timeRange.duration, longest) > 0 {
                longest = timeRange.duration
            }
        }

        guard !parameters.isEmpty else { throw AudioAssetError.noPlayableTracks }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters

        return PreparedAsset(
            composition: composition,
            audioMix: mix,
            duration: CMTimeGetSeconds(longest),
            trackCount: parameters.count
        )
    }

    static func exportMixedRecording(folder: URL, hasSystemTrack: Bool, to outputURL: URL) async throws {
        let prepared = try prepare(folder: folder, hasSystemTrack: hasSystemTrack)
        guard let exporter = AVAssetExportSession(
            asset: prepared.composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioAssetError.exportSessionUnavailable
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exporter.audioMix = prepared.audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: AudioAssetError.exportCancelled)
                case .failed:
                    continuation.resume(throwing: AudioAssetError.exportFailed(
                        exporter.error?.localizedDescription ?? "unknown error"
                    ))
                default:
                    continuation.resume(throwing: AudioAssetError.exportFailed(
                        exporter.error?.localizedDescription ?? "export did not complete"
                    ))
                }
            }
        }
    }

    /// The meeting's source files paired with the gain each should play at.
    /// Shared by the live `MeetingPlayer` (which renders them as independent
    /// players) and the offline export (which folds the same set into one
    /// composition), so what you hear matches what you export.
    static func playbackSources(folder: URL, hasSystemTrack: Bool) -> [(url: URL, gain: Float)] {
        existingSources(folder: folder, hasSystemTrack: hasSystemTrack).map { ($0.url, $0.gain) }
    }

    private static func existingSources(folder: URL, hasSystemTrack: Bool) -> [Source] {
        let mic = MeetingAudioFiles.readableURL(for: .mic, in: folder)
        let system = hasSystemTrack
            ? MeetingAudioFiles.readableURL(for: .system, in: folder)
            : nil

        switch (mic, system) {
        case (.some(let mic), .some(let system)):
            // The mic track can contain speaker bleed; keep the clean system
            // track dominant and leave enough local voice to understand replies.
            return [Source(url: system, gain: 0.85), Source(url: mic, gain: 0.55)]
        case (.some(let mic), .none):
            return [Source(url: mic, gain: 1.0)]
        case (.none, .some(let system)):
            return [Source(url: system, gain: 1.0)]
        case (.none, .none):
            return []
        }
    }
}
