import AVFoundation
import Foundation

enum MeetingSelectionExtractService {

    enum ExtractError: LocalizedError {
        case recordingStillActive
        case invalidRange
        case invalidDuration
        case noAudioTracks
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .recordingStillActive:
                "Stop the recording before creating a meeting from a selection."
            case .invalidRange:
                "Choose a valid start and end time for the selection."
            case .invalidDuration:
                "This recording has no playable audio duration to extract."
            case .noAudioTracks:
                "No readable audio was found inside the selected range."
            case .exportFailed(let message):
                "Could not create audio for the new meeting: \(message)"
            }
        }
    }

    static let minimumSelectionDuration: TimeInterval = 0.25

    static func extract(
        from sourceMeeting: Meeting,
        range: Meeting.ContentRange,
        storage: StorageManager
    ) async throws -> Meeting {
        guard sourceMeeting.endedAt != nil else {
            throw ExtractError.recordingStillActive
        }
        guard range.isValid else {
            throw ExtractError.invalidRange
        }

        let sourceFolder = sourceMeeting.folderURL(in: storage)
        let rawDuration = max(
            sourceMeeting.recordedDuration ?? 0,
            MeetingAudioFiles.longestDuration(in: sourceFolder) ?? 0,
            sourceMeeting.duration ?? 0
        )
        guard rawDuration.isFinite, rawDuration > 0 else {
            throw ExtractError.invalidDuration
        }

        let start = max(0, min(range.start, rawDuration))
        let end = min(rawDuration, max(start, range.end))
        let sliceDuration = end - start
        guard sliceDuration >= minimumSelectionDuration else {
            throw ExtractError.invalidRange
        }

        let title = extractedTitle(from: sourceMeeting, start: start, end: end)
        let startedAt = sourceMeeting.startedAt.addingTimeInterval(start)
        let endedAt = startedAt.addingTimeInterval(sliceDuration)
        let relativePath = try storage.reserveMeetingFolder(title: title, startedAt: startedAt)
        let destFolder = storage.rootURL.appendingPathComponent(relativePath, isDirectory: true)

        do {
            let hasMic = try await exportTrack(
                .mic,
                from: sourceFolder,
                to: destFolder.appendingPathComponent("mic.m4a"),
                start: start,
                end: end)
            let hasSystem = try await exportTrack(
                .system,
                from: sourceFolder,
                to: destFolder.appendingPathComponent("system.m4a"),
                start: start,
                end: end)
            guard hasMic || hasSystem else {
                throw ExtractError.noAudioTracks
            }

            if let slicedTranscript = try sliceTranscript(
                from: sourceFolder,
                start: start,
                end: end,
                sliceDuration: sliceDuration) {
                try writeTranscript(slicedTranscript, to: destFolder)
            }

            if let notes = MeetingNotes.load(from: sourceFolder) {
                try MeetingNotes.writeChecked(notes, to: destFolder)
            }

            var created = Meeting(
                id: UUID(),
                title: title,
                appName: sourceMeeting.appName,
                startedAt: startedAt,
                endedAt: endedAt,
                relativePath: relativePath,
                hasSystemTrack: hasSystem
            )
            created.participantNameHints = sourceMeeting.participantNameHints
            created.calendarParticipantIdentities = sourceMeeting.calendarParticipantIdentities
            created.extractedFromMeetingID = sourceMeeting.id
            created.importedFileNames = sourceMeeting.importedFileNames
            created.recordedDuration = sliceDuration
            created.calendarEventID = nil
            created.calendarTitle = nil
            try storage.saveMeta(created)
            return created
        } catch {
            try? FileManager.default.removeItem(at: destFolder)
            if let extractError = error as? ExtractError { throw extractError }
            throw ExtractError.exportFailed(error.localizedDescription)
        }
    }

    static func extractedTitle(from sourceMeeting: Meeting, start: TimeInterval, end: TimeInterval) -> String {
        "\(sourceMeeting.displayTitle) (\(Transcript.shortStamp(start))–\(Transcript.shortStamp(end)))"
    }

    private static func exportTrack(
        _ track: MeetingAudioFiles.Track,
        from sourceFolder: URL,
        to outputURL: URL,
        start: TimeInterval,
        end: TimeInterval
    ) async throws -> Bool {
        guard let url = MeetingAudioFiles.readableURL(for: track, in: sourceFolder) else {
            return false
        }
        let asset = AVURLAsset(url: url)
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = sourceTracks.first else {
            return false
        }
        let trackTimeRange = try await sourceTrack.load(.timeRange)
        let trackStart = CMTimeGetSeconds(trackTimeRange.start)
        let trackEnd = trackStart + CMTimeGetSeconds(trackTimeRange.duration)
        let clipStart = max(start, trackStart)
        let clipEnd = min(end, trackEnd)
        guard clipStart.isFinite, clipEnd.isFinite, clipEnd > clipStart else {
            return false
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: clipStart, preferredTimescale: 600),
            duration: CMTime(seconds: clipEnd - clipStart, preferredTimescale: 600))
        let destination = CMTime(seconds: max(0, clipStart - start), preferredTimescale: 600)
        try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: destination)

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractError.exportFailed("the audio exporter is unavailable")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .m4a)
        return true
    }

    private static func sliceTranscript(
        from sourceFolder: URL,
        start: TimeInterval,
        end: TimeInterval,
        sliceDuration: TimeInterval
    ) throws -> Transcript? {
        let url = sourceFolder.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)

        var slicedSegments: [Transcript.Segment] = []
        for segment in transcript.segments {
            guard segment.end > start, segment.start < end, !segment.displayText.isEmpty else { continue }
            var copy = segment
            copy.start = max(0, segment.start - start)
            copy.end = min(sliceDuration, segment.end - start)
            guard copy.end > copy.start else { continue }
            slicedSegments.append(copy)
        }
        guard !slicedSegments.isEmpty else { return nil }

        let survivingKeys = Set(slicedSegments.map { Transcript.canonicalSpeakerKey($0.speaker) })
        let aliases = transcript.speakerAliases.filter { survivingKeys.contains($0.key) }
        let identityIDs = transcript.speakerCalendarIdentityIDs.filter { survivingKeys.contains($0.key) }
        return Transcript(
            segments: slicedSegments,
            engine: transcript.engine,
            speakerAliases: aliases,
            speakerCalendarIdentityIDs: identityIDs)
    }

    private static func writeTranscript(_ transcript: Transcript, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(
            to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(transcript.markdown.utf8).write(
            to: folder.appendingPathComponent("transcript.md"), options: .atomic)
    }
}
