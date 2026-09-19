import AVFoundation
import Foundation

/// Builds a new meeting from completed source meetings without deleting any
/// source folder. The merged timeline is the selected source ranges laid
/// end-to-end; transcript speakers are namespaced by source so a label such as
/// "Me" in one recording can never silently claim a voice in another recording.
/// Source records are marked as folded into the new meeting so the normal
/// library view shows one merged row instead of duplicates.
enum MeetingMergeService {

    struct Result: Sendable {
        let meeting: Meeting
        let sourceMeetings: [Meeting]
        let transcriptSegmentCount: Int
    }

    enum MergeError: LocalizedError {
        case needsAtLeastTwo
        case recordingStillActive(String)
        case processingInProgress(String)
        case alreadyMerged(String)
        case noUsableEvidence(String)
        case invalidDuration(String)
        case cannotCreateMeeting(String)
        case noAudioTracks
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .needsAtLeastTwo:
                "Select at least two completed meetings to merge."
            case .recordingStillActive(let title):
                "\(title) is still recording. Stop it before merging."
            case .processingInProgress(let title):
                "\(title) is still being processed. Wait for it to finish before merging."
            case .alreadyMerged(let title):
                "\(title) is already folded into another merged meeting."
            case .noUsableEvidence(let title):
                "\(title) has no readable audio or transcript to merge."
            case .invalidDuration(let title):
                "\(title) has no usable recorded duration."
            case .cannotCreateMeeting(let message):
                "The merged meeting could not be created: \(message)"
            case .noAudioTracks:
                "No readable audio tracks were found in the selected meetings."
            case .exportFailed(let message):
                "The merged audio could not be written: \(message)"
            }
        }
    }

    private struct Source {
        let meeting: Meeting
        let folder: URL
        let duration: TimeInterval
        let rangeStart: TimeInterval
        let rangeEnd: TimeInterval

    }

    private struct Manifest: Codable {
        struct Source: Codable {
            let id: UUID
            let title: String
            let startedAt: Date
            let duration: TimeInterval
        }

        var version = 1
        let sources: [Source]
    }

    /// Merge source records in chronological order. A caller can pass a
    /// custom title; otherwise a readable title is generated from the first
    /// source and the number of additional meetings.
    static func merge(
        meetings: [Meeting],
        title: String,
        storage: StorageManager
    ) async throws -> Result {
        let sources = try prepareSources(meetings: meetings, storage: storage)
        let sourceTitle = normalizedTitle(title, sources: sources)
        let appName = "Merged meetings"
        let created: Meeting
        do {
            created = try storage.createMeetingFolder(title: sourceTitle, appName: appName)
        } catch {
            throw MergeError.cannotCreateMeeting(error.localizedDescription)
        }

        let folder = created.folderURL(in: storage)
        var foldedSources: [Meeting] = []
        do {
            var merged = created
            let totalDuration = sources.reduce(0) { $0 + $1.duration }
            merged.startedAt = sources.first?.meeting.startedAt ?? created.startedAt
            merged.endedAt = merged.startedAt.addingTimeInterval(totalDuration)
            merged.recordedDuration = totalDuration
            merged.mergedSourceMeetingIDs = sources.map { $0.meeting.id }

            let mergedTranscript = try makeTranscript(from: sources)
            if let mergedTranscript {
                try write(mergedTranscript, to: folder)
            }

            let audio = try await exportAudio(from: sources, to: folder)
            if !audio.mic, !audio.system, mergedTranscript == nil {
                throw MergeError.noAudioTracks
            }
            merged.hasSystemTrack = audio.system

            writeSourceSummary(
                title: sourceTitle,
                meeting: merged,
                sources: sources,
                to: folder)
            try writeSourceNotes(sources, to: folder)
            try writeManifest(sources, to: folder)
            try storage.saveMeta(merged)

            for source in sources {
                var folded = source.meeting
                folded.mergedIntoMeetingID = merged.id
                try storage.saveMeta(folded)
                foldedSources.append(folded)
            }

            return Result(
                meeting: merged,
                sourceMeetings: foldedSources,
                transcriptSegmentCount: mergedTranscript?.segments.count ?? 0)
        } catch {
            for source in foldedSources {
                var restored = source
                restored.mergedIntoMeetingID = nil
                try? storage.saveMeta(restored)
            }
            try? storage.deleteMeeting(created)
            if let error = error as? MergeError { throw error }
            throw MergeError.cannotCreateMeeting(error.localizedDescription)
        }
    }

    private static func prepareSources(
        meetings: [Meeting],
        storage: StorageManager
    ) throws -> [Source] {
        guard meetings.count >= 2 else { throw MergeError.needsAtLeastTwo }
        var seen: Set<UUID> = []
        let ordered = meetings.sorted { $0.startedAt < $1.startedAt }
        var sources: [Source] = []

        for meeting in ordered {
            guard seen.insert(meeting.id).inserted else { continue }
            guard meeting.mergedIntoMeetingID == nil else {
                throw MergeError.alreadyMerged(meeting.displayTitle)
            }
            guard meeting.endedAt != nil else {
                throw MergeError.recordingStillActive(meeting.displayTitle)
            }

            let folder = meeting.folderURL(in: storage)
            let transcriptURL = folder.appendingPathComponent("transcript.json")
            let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
            let hasAudio = MeetingAudioFiles.Track.allCases.contains {
                MeetingAudioFiles.readableURL(for: $0, in: folder) != nil
            }
            guard hasTranscript || hasAudio else {
                throw MergeError.noUsableEvidence(meeting.displayTitle)
            }

            let rawDuration = meeting.recordedDuration
                ?? MeetingAudioFiles.longestDuration(in: folder)
                ?? meeting.duration
                ?? 0
            guard rawDuration.isFinite, rawDuration > 0 else {
                throw MergeError.invalidDuration(meeting.displayTitle)
            }

            let requestedStart = meeting.contentRange?.start ?? 0
            let requestedEnd = meeting.contentRange?.end ?? rawDuration
            let start = max(0, min(requestedStart, rawDuration))
            let end = max(start, min(requestedEnd, rawDuration))
            guard end > start else { throw MergeError.invalidDuration(meeting.displayTitle) }
            sources.append(Source(
                meeting: meeting,
                folder: folder,
                duration: end - start,
                rangeStart: start,
                rangeEnd: end))
        }

        guard sources.count >= 2 else { throw MergeError.needsAtLeastTwo }
        return sources
    }

    private static func normalizedTitle(_ title: String, sources: [Source]) -> String {
        let cleaned = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        let first = sources.first?.meeting.displayTitle ?? "Meeting"
        return "Merged: \(first) + \(max(0, sources.count - 1)) more"
    }

    private static func makeTranscript(from sources: [Source]) throws -> Transcript? {
        var segments: [Transcript.Segment] = []
        var aliases: [String: String] = [:]
        var identityIDs: [String: String] = [:]
        var offset: TimeInterval = 0

        for (sourceIndex, source) in sources.enumerated() {
            let url = source.folder.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url) else {
                offset += source.duration
                continue
            }
            let transcript: Transcript
            do {
                transcript = try JSONDecoder().decode(Transcript.self, from: data)
            } catch {
                throw MergeError.cannotCreateMeeting(
                    "the transcript for \(source.meeting.displayTitle) could not be read")
            }

            for segment in transcript.segments {
                guard segment.start >= source.rangeStart,
                      segment.end <= source.rangeEnd,
                      segment.end > segment.start,
                      !segment.displayText.isEmpty else { continue }
                var mergedSegment = segment
                let originalKey = Transcript.canonicalSpeakerKey(segment.speaker)
                let safeKey = originalKey.isEmpty ? "speaker" : originalKey
                let namespacedKey = "source\(sourceIndex + 1):\(safeKey)"
                mergedSegment.speaker = namespacedKey
                mergedSegment.start = offset + segment.start - source.rangeStart
                mergedSegment.end = offset + segment.end - source.rangeStart
                segments.append(mergedSegment)

                // Every visible speaker receives a source-scoped display name.
                // This preserves a confirmed source alias while making the
                // provenance obvious in a merged transcript.
                let sourceLabel = transcript.displaySpeaker(for: originalKey)
                aliases[namespacedKey] = "\(sourceLabel) · source \(sourceIndex + 1)"
                if let identityID = transcript.speakerCalendarIdentityIDs[originalKey] {
                    identityIDs[namespacedKey] = identityID
                }
            }
            offset += source.duration
        }

        guard !segments.isEmpty else { return nil }
        segments.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }
        return Transcript(
            segments: segments,
            engine: "merged",
            speakerAliases: aliases,
            speakerCalendarIdentityIDs: identityIDs)
    }

    private static func write(_ transcript: Transcript, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(
            to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(transcript.markdown.utf8).write(
            to: folder.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private static func exportAudio(
        from sources: [Source],
        to folder: URL
    ) async throws -> (mic: Bool, system: Bool) {
        var mic = false
        var system = false
        do {
            mic = try await export(track: .mic, from: sources,
                                   to: folder.appendingPathComponent("mic.m4a"))
            system = try await export(track: .system, from: sources,
                                      to: folder.appendingPathComponent("system.m4a"))
        } catch let error as MergeError {
            throw error
        } catch {
            throw MergeError.exportFailed(error.localizedDescription)
        }
        return (mic, system)
    }

    private static func export(
        track: MeetingAudioFiles.Track,
        from sources: [Source],
        to outputURL: URL
    ) async throws -> Bool {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }

        var cursor = CMTime.zero
        var inserted = false
        for source in sources {
            if let url = MeetingAudioFiles.readableURL(for: track, in: source.folder) {
                let asset = AVURLAsset(url: url)
                let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
                if let sourceTrack = sourceTracks.first {
                    let timeRange = try await sourceTrack.load(.timeRange)
                    let trackStart = CMTimeGetSeconds(timeRange.start)
                    let trackEnd = trackStart + CMTimeGetSeconds(timeRange.duration)
                    let start = max(source.rangeStart, trackStart)
                    let end = min(source.rangeEnd, trackEnd)
                    if start.isFinite, end.isFinite, end > start {
                        let timeRange = CMTimeRange(
                            start: CMTime(seconds: start, preferredTimescale: 600),
                            duration: CMTime(seconds: end - start, preferredTimescale: 600))
                        // Preserve silence at the beginning of a selected range
                        // when a source track starts late. Transcript offsets are
                        // relative to `rangeStart`, so audio must share that base.
                        let destination = CMTimeAdd(
                            cursor,
                            CMTime(
                                seconds: max(0, start - source.rangeStart),
                                preferredTimescale: 600))
                        try compositionTrack.insertTimeRange(
                            timeRange, of: sourceTrack, at: destination)
                        inserted = true
                    }
                }
            }
            // Advance over the source's complete selected range even when one
            // track is missing, keeping mic/system/transcript time aligned.
            cursor = CMTimeAdd(
                cursor,
                CMTime(seconds: source.duration, preferredTimescale: 600))
        }

        guard inserted else { return false }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A) else {
            throw MergeError.exportFailed("the audio exporter is unavailable")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await exporter.export(to: outputURL, as: .m4a)
        } catch {
            throw MergeError.exportFailed(error.localizedDescription)
        }
        return true
    }

    private static func writeSourceSummary(
        title: String,
        meeting: Meeting,
        sources: [Source],
        to folder: URL
    ) {
        let date = meeting.startedAt.formatted(date: .long, time: .shortened)
        var body = "# \(title) — \(date)\n"
        body += "**Duration:** \(meeting.durationLabel) · **Sources:** \(sources.count)\n\n"
        body += "This is a non-destructive merge. Source evidence remains on disk for provenance, "
        body += "while the source rows are folded into this merged meeting. Speaker names stay "
        body += "scoped to their source meeting until you confirm a name.\n\n"
        for source in sources {
            body += "## \(source.meeting.displayTitle)\n\n"
            if let summary = try? String(
                contentsOf: source.folder.appendingPathComponent("summary.md"), encoding: .utf8),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            } else {
                body += "No saved summary was available for this source meeting.\n\n"
            }
        }
        try? Data(body.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
    }

    private static func writeSourceNotes(_ sources: [Source], to folder: URL) throws {
        var notes: [String] = []
        for source in sources {
            guard let text = MeetingNotes.load(from: source.folder) else { continue }
            notes.append("## \(source.meeting.displayTitle)\n\n\(text)")
        }
        try MeetingNotes.writeChecked(notes.joined(separator: "\n\n"), to: folder)
    }

    private static func writeManifest(_ sources: [Source], to folder: URL) throws {
        let manifest = Manifest(sources: sources.map {
            .init(id: $0.meeting.id, title: $0.meeting.displayTitle,
                  startedAt: $0.meeting.startedAt, duration: $0.duration)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: folder.appendingPathComponent("merge-manifest.json"), options: .atomic)
    }
}
