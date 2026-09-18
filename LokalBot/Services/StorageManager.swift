import Foundation

/// Owns the on-disk layout (design doc §6):
/// ~/Library/Application Support/me.dotenv.LokalBot/
///   meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}
///
/// Rooted at the bundle id, NOT "LokalBot": an unrelated app may own
/// ~/Library/Application Support/LokalBot/ on some machines, and its
/// "Meetings" folder would collide with our "meetings" on the default
/// case-insensitive filesystem.
final class StorageManager {

    let rootURL: URL

    init(rootURL: URL = AppDirectories.libraryRoot) {
        // UI-test isolation hook: when the env var points at a directory,
        // every read/write goes there instead of the user's real library.
        // Production launches never set it, so default behaviour is unchanged.
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL.appendingPathComponent("meetings"),
                                                 withIntermediateDirectories: true)
    }

    func createMeetingFolder(title: String, appName: String) throws -> Meeting {
        let now = Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = String(format: "%02d", cal.component(.month, from: now))
        let d = String(format: "%02d", cal.component(.day, from: now))

        var slug = "\(d)-\(Self.slugify(title))"
        var relative = "meetings/\(y)/\(m)/\(slug)"
        // De-dupe: second Zoom meeting the same day gets "-2", etc.
        var counter = 2
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(relative).path) {
            slug = "\(d)-\(Self.slugify(title))-\(counter)"
            relative = "meetings/\(y)/\(m)/\(slug)"
            counter += 1
        }

        let folder = rootURL.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let meeting = Meeting(id: UUID(), title: title, appName: appName,
                              startedAt: now, endedAt: nil, relativePath: relative)
        try saveMeta(meeting)
        return meeting
    }

    func saveMeta(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = meeting.folderURL(in: self).appendingPathComponent("meta.json")
        try encoder.encode(meeting).write(to: url, options: .atomic)
    }

    /// Scan the library for meta.json files. Fine for M1; replaced by the
    /// SQLite index in M3. Source meetings folded into a merged record remain
    /// on disk for provenance but are excluded from the normal library view.
    func loadMeetings(includeMergedSources: Bool = false) -> [Meeting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meetingsRoot = rootURL.appendingPathComponent("meetings")
        guard let enumerator = FileManager.default.enumerator(at: meetingsRoot,
                                                              includingPropertiesForKeys: nil) else { return [] }
        var result: [Meeting] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            if let data = try? Data(contentsOf: url),
               var meeting = try? decoder.decode(Meeting.self, from: data) {
                // Orphan repair: app killed mid-recording leaves endedAt nil
                // forever ("in progress"). Close it at the audio's last write.
                if meeting.endedAt == nil {
                    let folder = url.deletingLastPathComponent()
                    let audioURLs = MeetingAudioFiles.Track.allCases.flatMap { track in
                        [MeetingAudioFiles.primaryURL(for: track, in: folder),
                         MeetingAudioFiles.recoveryURL(for: track, in: folder)]
                    }
                    let mtime = audioURLs.compactMap { audioURL in
                        (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.modificationDate]
                            as? Date
                    }.max()
                    meeting.endedAt = mtime ?? meeting.startedAt
                    try? saveMeta(meeting)
                }
                let folder = url.deletingLastPathComponent()
                let hasSystemTrack = MeetingAudioFiles.transcribableURL(for: .system, in: folder) != nil
                if meeting.hasSystemTrack != hasSystemTrack {
                    meeting.hasSystemTrack = hasSystemTrack
                    try? saveMeta(meeting)
                }
                if meeting.recordedDuration == nil,
                   let recordedDuration = MeetingAudioFiles.longestDuration(in: folder) {
                    meeting.recordedDuration = recordedDuration
                    try? saveMeta(meeting)
                }
                result.append(meeting)
            }
        }
        // Merge records created before source folding was persisted still
        // carry their source IDs. Backfill the durable relationship once so
        // the new library projection does not show both sides of an old merge.
        var foldedBySource: [UUID: UUID] = [:]
        let mergedMeetingIDs = Set(result.filter(\.isMergedMeeting).map(\.id))
        for meeting in result where meeting.isMergedMeeting {
            for sourceID in meeting.mergedSourceMeetingIDs ?? [] {
                foldedBySource[sourceID] = meeting.id
            }
        }
        for index in result.indices {
            if result[index].mergedIntoMeetingID != nil,
               !mergedMeetingIDs.contains(result[index].mergedIntoMeetingID!) {
                // The merged record was removed before its source metadata
                // could be restored. Make the source visible again on reload.
                result[index].mergedIntoMeetingID = nil
                try? saveMeta(result[index])
            }
            guard result[index].mergedIntoMeetingID == nil,
                  let mergedID = foldedBySource[result[index].id] else { continue }
            result[index].mergedIntoMeetingID = mergedID
            try? saveMeta(result[index])
        }
        if !includeMergedSources {
            result.removeAll(where: \.isMergedSource)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Delete the durable meeting folder. Callers must only remove the meeting
    /// from in-memory/UI state after this succeeds; swallowing the filesystem
    /// error made failed deletions reappear on the next launch.
    func deleteMeeting(_ meeting: Meeting) throws {
        try FileManager.default.removeItem(at: meeting.folderURL(in: self))
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
            .applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

extension Meeting {
    /// Resolve this meeting's on-disk folder against a `StorageManager`'s
    /// root. Lives on `StorageManager.swift` (not `Meeting.swift`) so the
    /// embedded `lokalbot-cli` — which doesn't compile `StorageManager` —
    /// keeps the `Meeting` value type dependency-free.
    func folderURL(in storage: StorageManager) -> URL {
        storage.rootURL.appendingPathComponent(relativePath, isDirectory: true)
    }
}
