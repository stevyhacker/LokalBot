import Foundation

/// Read-only lookups over the on-disk meeting library. Shared by the app and
/// the embedded `lokalbot-cli` so a single source of truth resolves paths,
/// short IDs, and "latest". Pure Foundation — no AppKit / SwiftUI deps so the
/// CLI binary stays light.
enum SessionLookup {

    /// The app's meeting library. `AppDirectories` hard-codes the app's bundle
    /// id (not `Bundle.main.bundleIdentifier`) so the CLI process, whose own
    /// bundle id differs, resolves the same library the app writes — and it
    /// honors the `LOKALBOT_STORAGE_ROOT` override, so the CLI can be pointed
    /// at an isolated test library exactly like the app.
    static var storageRootURL: URL {
        AppDirectories.libraryRoot
    }

    /// 8-character truncation of a Meeting's UUID — what `list` prints and
    /// what `get <id>` accepts. Stable, case-insensitive.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// All meetings, newest first. Orphan repair (closing in-progress meetings
    /// from the audio mtime) lives in `StorageManager` and isn't run here —
    /// this is read-only on purpose.
    static func loadAllMeetings() throws -> [Meeting] {
        try loadAllMeetings(root: storageRootURL)
    }

    /// Root-explicit variant for exporters and isolated-library callers. This
    /// avoids accidentally mixing the default production library into output
    /// generated for a caller-supplied storage root.
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

    /// Find by short ID (8-char prefix), full UUID string, or the literal `"latest"`.
    /// Returns nil if no match or the short prefix is ambiguous.
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

    /// The on-disk folder for a meeting.
    static func folderURL(for meeting: Meeting) -> URL {
        storageRootURL.appendingPathComponent(meeting.relativePath, isDirectory: true)
    }

    /// Convenience accessors for the standard artifacts the pipeline writes.
    static func summaryMarkdown(for meeting: Meeting) -> String? {
        contents(at: folderURL(for: meeting).appendingPathComponent("summary.md"))
    }

    static func transcriptMarkdown(for meeting: Meeting) -> String? {
        contents(at: folderURL(for: meeting).appendingPathComponent("transcript.md"))
    }

    static func transcript(for meeting: Meeting) -> Transcript? {
        let url = folderURL(for: meeting).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    private static func contents(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
