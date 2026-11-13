import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns an audio or video file the user brings in into a meeting. The file's
/// audio becomes the meeting's system track, so it is diarized like call audio
/// and, like any remote participant's, its voices are never enrolled or matched
/// against voice profiles. The original file is only read; the meeting keeps
/// its own AAC copy, and the normal processing pipeline does the rest. A
/// recording from a paired phone or tablet takes the same path, except that it
/// becomes the microphone track: see `importDeviceRecording`.
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

    /// A recording a paired phone or tablet made.
    struct DeviceOrigin: Equatable, Sendable {
        /// The device chose it, so the meeting keeps it and a resend finds it.
        var id: UUID
        var title: String
        /// When the device started recording. The device's clock decides, but
        /// the meeting never ends in the future.
        var startedAt: Date?
        var deviceName: String
    }

    /// `sample` marks the import as LokalBot's sample meeting: it is titled in
    /// its own language, dated now, and carries its id.
    static func importRecording(from url: URL, storage: StorageManager,
                                now: Date = Date(),
                                sample: SampleMeeting.Recording? = nil) async throws -> Meeting {
        try await makeMeeting(from: url, storage: storage, now: now, plan: Plan(
            name: url.lastPathComponent, id: UUID(), title: sample?.title ?? Self.title(for: url),
            appName: appName, importedFileName: url.lastPathComponent, track: .system,
            sampleID: sample?.id, datedNow: sample != nil))
    }

    /// Makes a meeting of a recording from a paired device. It is the device's
    /// microphone, the person's own, so it becomes the microphone track: their
    /// speech counts as theirs under "My microphone is me", and other voices
    /// in the room are treated as the Mac's microphone treats them, not as call
    /// participants. Like any import it takes no screen context, because the
    /// person wasn't at this Mac.
    static func importDeviceRecording(from url: URL, origin: DeviceOrigin, storage: StorageManager,
                                      now: Date = Date()) async throws -> Meeting {
        try await makeMeeting(from: url, storage: storage, now: now, plan: Plan(
            name: origin.title, id: origin.id, title: origin.title, appName: origin.deviceName,
            importedFileName: "\(origin.id.uuidString).aac", track: .mic, statedStart: origin.startedAt,
            wholeDuration: adtsDuration(of: url), isOnlyCopy: true))
    }

    /// How long an ADTS stream really is: its frames counted, 1024 samples each.
    /// Stops at a frame cut short or damage, so it never overstates. Nil when
    /// it doesn't start with a frame.
    static func adtsDuration(of url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let sampleRates: [Double] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> TimeInterval? in
            var offset = 0
            var seconds: TimeInterval = 0
            while offset + 7 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 {
                let rateIndex = Int(bytes[offset + 2] >> 2) & 0xF
                let length = (Int(bytes[offset + 3]) & 0x3) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5]) >> 5
                guard rateIndex < sampleRates.count, length >= 7, offset + length <= bytes.count else { break }
                // Each ADTS frame holds 1 to 4 raw blocks of 1024 samples.
                seconds += Double(Int(bytes[offset + 6] & 0x3) + 1) * 1_024 / sampleRates[rateIndex]
                offset += length
            }
            return offset > 0 ? seconds : nil
        }
    }

    /// What differs between kinds of import.
    private struct Plan {
        /// How errors name the recording.
        var name: String
        var id: UUID
        var title: String
        var appName: String
        var importedFileName: String
        var track: MeetingAudioFiles.Track
        var sampleID: String?
        /// Outranks what the file itself says about when it began.
        var statedStart: Date?
        /// Recorded just now, whatever the file says.
        var datedNow = false
        /// What the conversion must keep, when that can be known.
        var wholeDuration: TimeInterval?
        /// The sender deletes its file once this returns, so the meeting has to
        /// be on the disk by then rather than in its cache.
        var isOnlyCopy = false
    }

    private static func makeMeeting(from url: URL, storage: StorageManager, now: Date,
                                    plan: Plan) async throws -> Meeting {
        let name = plan.name
        // Without precise timing AVFoundation guesses the length of a file with
        // no index (ADTS, some MP3s) from its first frames, and the export stops
        // there: 27 minutes that started loud and went quiet came out as 3.5.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
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
        let converted = staging.appendingPathComponent(plan.track.primaryFileName)
        try await exportAudio(from: audioTracks, to: converted, name: name)
        guard let duration = AudioFileInspector.duration(at: converted),
              duration >= AudioFileInspector.minimumTranscribableDuration else {
            throw ImportError.noAudio(name)
        }
        if let whole = plan.wholeDuration, duration < whole - 2 {
            lokalbotLog("import kept \(Int(duration)) s of \(Int(whole)) s")
            throw ImportError.conversionFailed(name, "only part of the audio could be read")
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let metadataDate: Date?
        if let item = try? await asset.load(.creationDate) {
            metadataDate = try? await item.load(.dateValue)
        } else {
            metadataDate = nil
        }
        let startedAt = plan.datedNow ? now.addingTimeInterval(-duration) : recordingStart(
            metadataDate: plan.statedStart ?? metadataDate, fileCreated: values?.creationDate,
            fileModified: values?.contentModificationDate, duration: duration, now: now)

        // The meeting appears in the library only once its metadata is
        // written, which is last, so a library scan never sees it half-made.
        let relativePath: String
        do {
            relativePath = try storage.reserveMeetingFolder(title: plan.title, startedAt: startedAt)
        } catch {
            throw ImportError.cannotCreateMeeting(name, error.localizedDescription)
        }
        var meeting = Meeting(id: plan.id, title: plan.title, appName: plan.appName,
                              startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
                              relativePath: relativePath)
        meeting.recordedDuration = duration
        meeting.hasSystemTrack = plan.track == .system
        meeting.importedFileNames = [plan.importedFileName]
        meeting.sampleID = plan.sampleID
        let folder = meeting.folderURL(in: storage)
        do {
            let audio = MeetingAudioFiles.primaryURL(for: plan.track, in: folder)
            try FileManager.default.moveItem(at: converted, to: audio)
            try storage.saveMeta(meeting)
            if plan.isOnlyCopy {
                for file in [audio, folder.appendingPathComponent("meta.json")] {
                    let handle = try FileHandle(forUpdating: file)
                    defer { try? handle.close() }
                    try handle.synchronize()
                }
            }
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
