import Foundation

enum SessionLookup {

    static var storageRootURL: URL {
        AppDirectories.libraryRoot
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    static func loadAllMeetings() throws -> [Meeting] {
        try loadAllMeetings(root: storageRootURL)
    }

    static func loadAllMeetings(root: URL, includeMergedSources: Bool = false) throws -> [Meeting] {
        let fm = FileManager.default
        let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
        guard fm.fileExists(atPath: meetingsRoot.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enumerator = fm.enumerator(at: meetingsRoot,
                                             includingPropertiesForKeys: nil) else { return [] }
        var meetings: [Meeting] = []
        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            guard let data = try? Data(contentsOf: url),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            meetings.append(meeting)
        }
        let resolved = Meeting.resolvingMergeRelationships(in: meetings)
        return resolved.filter { includeMergedSources || !$0.isMergedSource }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func find(id: String, in meetings: [Meeting]? = nil) throws -> Meeting? {
        let candidates = try meetings ?? loadAllMeetings()
        let needle = id.lowercased()
        if needle == "latest" { return candidates.first }
        if let uuid = UUID(uuidString: needle) {
            return candidates.first { $0.id == uuid }
        }
        let matches = candidates.filter { Self.shortID($0.id).hasPrefix(needle) }
        return matches.count == 1 ? matches.first : nil
    }

    static func folderURL(for meeting: Meeting) -> URL {
        folderURL(for: meeting, root: storageRootURL)
    }

    static func folderURL(for meeting: Meeting, root: URL) -> URL {
        root.appendingPathComponent(meeting.relativePath, isDirectory: true)
    }

    static func summaryMarkdown(for meeting: Meeting) -> String? {
        summaryMarkdown(for: meeting, root: storageRootURL)
    }

    static func summaryMarkdown(for meeting: Meeting, root: URL) -> String? {
        contents(at: folderURL(for: meeting, root: root).appendingPathComponent("summary.md"))
    }

    static func transcriptMarkdown(for meeting: Meeting) -> String? {
        contents(at: folderURL(for: meeting).appendingPathComponent("transcript.md"))
    }

    static func hasSummary(for meeting: Meeting) -> Bool {
        isReadable(folderURL(for: meeting).appendingPathComponent("summary.md"))
    }

    static func hasTranscriptMarkdown(for meeting: Meeting) -> Bool {
        isReadable(folderURL(for: meeting).appendingPathComponent("transcript.md"))
    }

    private static func isReadable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }

    static func transcript(for meeting: Meeting) -> Transcript? {
        transcriptData(for: meeting, root: storageRootURL).flatMap(transcript(from:))
    }

    static func transcriptData(for meeting: Meeting, root: URL) -> Data? {
        try? Data(contentsOf: folderURL(for: meeting, root: root).appendingPathComponent("transcript.json"))
    }

    static func transcript(from data: Data) -> Transcript? {
        try? JSONDecoder().decode(Transcript.self, from: data)
    }

    private static func contents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
