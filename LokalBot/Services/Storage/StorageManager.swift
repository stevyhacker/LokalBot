import Foundation

final class StorageManager {

    let rootURL: URL

    init(rootURL: URL = AppDirectories.libraryRoot) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL.appendingPathComponent("meetings"),
                                                 withIntermediateDirectories: true)
    }

    func createMeetingFolder(title: String, appName: String) throws -> Meeting {
        let now = Date()
        let relative = try reserveMeetingFolder(title: title, startedAt: now)
        let meeting = Meeting(id: UUID(), title: title, appName: appName,
                              startedAt: now, endedAt: nil, relativePath: relative)
        try saveMeta(meeting)
        return meeting
    }

    func reserveMeetingFolder(title: String, startedAt: Date) throws -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: startedAt)
        let m = String(format: "%02d", cal.component(.month, from: startedAt))
        let d = String(format: "%02d", cal.component(.day, from: startedAt))

        let base = Self.folderSlug(title)
        var slug = "\(d)-\(base)"
        var relative = "meetings/\(y)/\(m)/\(slug)"
        var counter = 2
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(relative).path) {
            slug = "\(d)-\(base)-\(counter)"
            relative = "meetings/\(y)/\(m)/\(slug)"
            counter += 1
        }

        let folder = rootURL.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return relative
    }

    func saveMeta(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = meeting.folderURL(in: self).appendingPathComponent("meta.json")
        try encoder.encode(meeting).write(to: url, options: .atomic)
    }

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
                if meeting.endedAt == nil {
                    let folder = url.deletingLastPathComponent()
                    for track in MeetingAudioFiles.Track.allCases {
                        _ = try? AudioRecoveryJournal.recover(
                            previewURL: MeetingAudioFiles.recoveryURL(for: track, in: folder))
                    }
                    let audioURLs = MeetingAudioFiles.Track.allCases.flatMap { track in
                        [MeetingAudioFiles.primaryURL(for: track, in: folder),
                         MeetingAudioFiles.recoveryURL(for: track, in: folder)]
                    }
                    let mtime = audioURLs.compactMap { audioURL in
                        (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.modificationDate]
                            as? Date
                    }.max()
                    let duration = MeetingAudioFiles.longestDuration(in: folder) ?? 0
                    meeting.endedAt = max(mtime ?? meeting.startedAt,
                                          meeting.startedAt.addingTimeInterval(duration))
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
                AppLog.line("Meeting merge recovery failed: \(error.localizedDescription)")
            }
        }
        if !includeMergedSources {
            result.removeAll(where: \.isMergedSource)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    func restoreMergedSource(_ source: Meeting) throws -> Meeting {
        guard let mergedID = source.mergedIntoMeetingID else { return source }
        try SearchIndex.restoreMergedSource(source.id, from: mergedID,
            databaseURL: rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        var restored = source
        restored.mergedIntoMeetingID = nil
        try saveMeta(restored)
        return restored
    }

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

    func deleteMeeting(_ meeting: Meeting) throws {
        try DreamStore(root: rootURL).withMeetingEvidenceMutation(for: [meeting]) {
            try FileManager.default.removeItem(at: meeting.folderURL(in: self))
        }
    }

    static func folderSlug(_ title: String) -> String {
        var slug = slugify(title)
        while slug.utf8.count > 120 { slug.removeLast() }
        return slug
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
            .applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

extension Meeting {
    func folderURL(in storage: StorageManager) -> URL {
        storage.rootURL.appendingPathComponent(relativePath, isDirectory: true)
    }
}
