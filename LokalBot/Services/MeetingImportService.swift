import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns an audio or video file the user brings in into a meeting. The file's
/// audio becomes the meeting's system track, so it is diarized like call audio
/// and, like any remote participant's, its voices are never enrolled or matched
/// against voice profiles. The original file is only read; the meeting keeps
/// its own AAC copy, and the normal processing pipeline does the rest.
enum MeetingImportService {

    /// Shown where a recorded meeting shows its meeting app.
    static let appName = "Imported file"

    /// What the import panel offers. A drop accepts the same kinds of file;
    /// AVFoundation decides whether it can actually read the audio.
    static let contentTypes: [UTType] = [.audio, .movie]

    enum ImportError: LocalizedError {
        case unreadable(String)
        case noAudio(String)
        case conversionFailed(String, String)
        case cannotCreateMeeting(String, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "LokalBot can't read audio from “\(name)”. Try an MP3, M4A, WAV, MP4, or MOV file."
            case .noAudio(let name):
                "“\(name)” has no audio to transcribe."
            case .conversionFailed(let name, let reason):
                "Couldn't convert the audio in “\(name)”: \(reason)"
            case .cannotCreateMeeting(let name, let reason):
                "Couldn't add “\(name)” to your meetings: \(reason)"
            }
        }
    }

    static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audiovisualContent) == true
    }

    /// `sample` marks the import as LokalBot's sample meeting: it is titled in
    /// its own language, dated now, and carries its id.
    static func importRecording(from url: URL, storage: StorageManager,
                                now: Date = Date(),
                                sample: SampleMeeting.Recording? = nil) async throws -> Meeting {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportError.unreadable(name)
        }
        guard !audioTracks.isEmpty else { throw ImportError.noAudio(name) }

        // Convert beside the library so the finished file moves into the
        // meeting folder without a cross-volume copy, and a failed conversion
        // never leaves a half-made meeting in the library.
        let staging: URL
        do {
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: storage.rootURL, create: true)
        } catch {
            throw ImportError.cannotCreateMeeting(name, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let converted = staging.appendingPathComponent(MeetingAudioFiles.Track.system.primaryFileName)
        try await exportAudio(from: audioTracks, to: converted, name: name)
        guard let duration = AudioFileInspector.duration(at: converted),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw ImportError.noAudio(name)
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let metadataDate: Date?
        if let item = try? await asset.load(.creationDate) {
            metadataDate = try? await item.load(.dateValue)
        } else {
            metadataDate = nil
        }
        // The sample was "recorded" just now, whatever its bundled file says.
        let startedAt = sample != nil ? now.addingTimeInterval(-duration) : recordingStart(
            metadataDate: metadataDate, fileCreated: values?.creationDate,
            fileModified: values?.contentModificationDate, duration: duration, now: now)

        // The meeting appears in the library only once its metadata is
        // written, which is last, so a library scan never sees it half-made.
        let meetingTitle = sample?.title ?? Self.title(for: url)
        let relativePath: String
        do {
            relativePath = try storage.reserveMeetingFolder(title: meetingTitle, startedAt: startedAt)
        } catch {
            throw ImportError.cannotCreateMeeting(name, error.localizedDescription)
        }
        var meeting = Meeting(id: UUID(), title: meetingTitle, appName: appName,
                              startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
                              relativePath: relativePath)
        meeting.recordedDuration = duration
        meeting.hasSystemTrack = true
        meeting.importedFileNames = [name]
        meeting.sampleID = sample?.id
        let folder = meeting.folderURL(in: storage)
        do {
            try FileManager.default.moveItem(
                at: converted, to: MeetingAudioFiles.primaryURL(for: .system, in: folder))
            try storage.saveMeta(meeting)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ImportError.cannotCreateMeeting(name, error.localizedDescription)
        }
        return meeting
    }

    /// The file name without its extension, so "Team sync.m4a" becomes
    /// "Team sync".
    static func title(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Imported recording" : stem
    }

    /// Best guess at when the recording began, never so late that it would
    /// end in the future. A recorder's own creation date names the start. File
    /// dates are weaker: modification usually marks when recording stopped and
    /// survives a copy, while a copy's creation date is when it was copied, so
    /// the earlier of the two readings wins. Dates before 2001 are unset
    /// container fields, not real recordings.
    static func recordingStart(metadataDate: Date?, fileCreated: Date?, fileModified: Date?,
                               duration: TimeInterval, now: Date) -> Date {
        let latest = now.addingTimeInterval(-duration)
        if let metadataDate = plausible(metadataDate) { return min(metadataDate, latest) }
        let readings = [plausible(fileCreated), plausible(fileModified)?.addingTimeInterval(-duration)]
            .compactMap { $0 }
        return min(readings.min() ?? latest, latest)
    }

    private static func plausible(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate > 0 else { return nil }
        return date
    }

    /// Every enabled audio track, mixed to AAC. A video's picture is dropped;
    /// a screen recording's separate microphone and system tracks are mixed.
    private static func exportAudio(from tracks: [AVAssetTrack], to outputURL: URL,
                                    name: String) async throws {
        var enabled: [AVAssetTrack] = []
        for track in tracks {
            let isEnabled = (try? await track.load(.isEnabled)) ?? true
            if isEnabled { enabled.append(track) }
        }
        let composition = AVMutableComposition()
        do {
            for track in enabled.isEmpty ? [tracks[0]] : enabled {
                let timeRange = try await track.load(.timeRange)
                guard let destination = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try destination.insertTimeRange(timeRange, of: track, at: timeRange.start)
            }
        } catch {
            throw ImportError.unreadable(name)
        }
        guard !composition.tracks.isEmpty else { throw ImportError.noAudio(name) }
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.conversionFailed(name, "the audio exporter is unavailable")
        }
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await exporter.export(to: outputURL, as: .m4a)
        } catch {
            throw ImportError.conversionFailed(name, error.localizedDescription)
        }
    }
}
