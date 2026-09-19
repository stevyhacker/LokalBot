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
        let resolved = Meeting.resolvingMergeRelationships(in: result)
        for index in result.indices {
            guard result[index].mergedIntoMeetingID != resolved[index].mergedIntoMeetingID else { continue }
            do {
                if result[index].isMergedSource, !resolved[index].isMergedSource {
                    result[index] = try restoreMergedSource(result[index])
                } else {
                    result[index] = resolved[index]
                    try saveMeta(resolved[index])
                }
            } catch {
                // Keep the old marker if either SQLite or metadata repair
                // failed. A later load retries instead of losing the journal.
                AppLog.line("Meeting merge recovery failed: \(error.localizedDescription)")
            }
        }
        if !includeMergedSources {
            result.removeAll(where: \.isMergedSource)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Only call after removing the generated parent. The on-disk source
    /// marker is the recovery journal until both indexes have been reopened.
    func restoreMergedSource(_ source: Meeting) throws -> Meeting {
        guard let mergedID = source.mergedIntoMeetingID else { return source }
        try SearchIndex.restoreMergedSource(source.id, from: mergedID,
            databaseURL: rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        var restored = source
        restored.mergedIntoMeetingID = nil
        try saveMeta(restored)
        return restored
    }

    /// Permanent deletion is different from Undo: remove every retained
    /// descendant before its parent. A failed/interrupted delete therefore
    /// leaves surviving sources folded, and retries skip already removed ones.
    func deletionOrder(for meeting: Meeting) throws -> [Meeting] {
        let all = try SessionLookup.loadAllMeetings(root: rootURL, includeMergedSources: true)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var visiting: Set<UUID> = []
        var visited: Set<UUID> = []
        var ordered: [Meeting] = []
        func visit(_ current: Meeting) throws {
            guard !visited.contains(current.id) else { return }
            guard visiting.insert(current.id).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for id in current.mergedSourceMeetingIDs ?? [] {
                guard let source = byID[id] else { continue }
                guard source.mergedIntoMeetingID == current.id else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try visit(source)
            }
            visiting.remove(current.id)
            visited.insert(current.id)
            ordered.append(current)
        }
        try visit(byID[meeting.id] ?? meeting)
        return ordered
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
