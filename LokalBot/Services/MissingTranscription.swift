import Foundation

/// Finds finished recordings whose transcript is missing or incomplete, so the
/// pipeline can queue them once. Recordings from before processing intent was
/// durable can have audio but no transcript and no job; merges made before a
/// merge re-transcribed untranscribed sources can leave a whole source's span
/// of the merged transcript empty.
enum MissingTranscription {
    enum Reason: Equatable, Sendable {
        case neverTranscribed
        case mergedGap
    }

    /// Written before a merged-gap repair is queued, so a span that stays
    /// empty (for example, silence) is not re-transcribed on every launch.
    static let gapRepairMarkerFileName = "transcript-gap-repair.json"
    /// Shorter recordings hold no speech worth a model run.
    static let minimumRecordingSeconds: TimeInterval = 5
    /// A merged source shorter than this may legitimately have no segments.
    static let minimumGapSeconds: TimeInterval = 30

    static func reason(for meeting: Meeting, folder: URL) -> Reason? {
        guard meeting.mergedIntoMeetingID == nil, meeting.endedAt != nil else { return nil }
        let duration = meeting.recordedDuration ?? meeting.duration ?? 0
        guard duration >= minimumRecordingSeconds,
              MeetingAudioFiles.Track.allCases.contains(where: {
                  MeetingAudioFiles.readableURL(for: $0, in: folder) != nil
              }) else { return nil }
        let transcriptURL = folder.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return .neverTranscribed }
        return hasMergedSourceGap(in: folder) ? .mergedGap : nil
    }

    /// True when a merged meeting's transcript has no segment at all within
    /// the span of one of its sources.
    static func hasMergedSourceGap(in folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.appendingPathComponent(gapRepairMarkerFileName).path),
              let manifestData = try? Data(contentsOf: folder.appendingPathComponent("merge-manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let sources = manifest["sources"] as? [[String: Any]],
              let transcriptData = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: transcriptData)
        else { return false }
        var offset: TimeInterval = 0
        for source in sources {
            let duration = (source["duration"] as? Double) ?? 0
            defer { offset += max(0, duration) }
            guard duration >= minimumGapSeconds else { continue }
            let span = offset...(offset + duration)
            let covered = transcript.segments.contains { segment in
                segment.end > span.lowerBound && segment.start < span.upperBound
            }
            if !covered { return true }
        }
        return false
    }

    static func markGapRepairRequested(in folder: URL, at date: Date = Date()) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["requestedAt": ISO8601DateFormatter().string(from: date)])
        try data.write(to: folder.appendingPathComponent(gapRepairMarkerFileName), options: .atomic)
    }
}
