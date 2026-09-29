import Foundation

/// Renders `Meeting` lists and individual sessions for the CLI in three
/// shapes: JSON (default — easy for agents to consume), plain-text table
/// (for humans), and combined Markdown (the in-app export plus tagged
/// transcripts so `[user]` / `[transcript]` are distinguishable).
///
/// Mirrors Seminarly's `SessionFormatter`. Pure value-in / string-out so it
/// can be unit-tested without the file system.
enum SessionFormatter {

    struct GetOptions: Equatable {
        var includeSummary: Bool
        var includeTranscript: Bool
        var includeMetadata: Bool

        static let all = GetOptions(includeSummary: true,
                                    includeTranscript: true,
                                    includeMetadata: true)
    }

    // MARK: - list

    static func listJSON(_ meetings: [Meeting]) -> String {
        let entries = meetings.map { meeting in
            ListEntry(
                id: SessionLookup.shortID(meeting.id),
                uuid: meeting.id.uuidString.lowercased(),
                title: meeting.title,
                date: Self.iso8601.string(from: meeting.startedAt),
                duration_seconds: meeting.duration ?? 0,
                app_source: meeting.appName,
                has_system_track: meeting.hasSystemTrack,
                has_summary: SessionLookup.summaryMarkdown(for: meeting) != nil,
                has_transcript: SessionLookup.transcriptMarkdown(for: meeting) != nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(entries), encoding: .utf8)) ?? "[]"
    }

    static func listTable(_ meetings: [Meeting]) -> String {
        guard !meetings.isEmpty else { return "(no meetings)" }
        let header = ["ID", "Date", "Duration", "App", "Title"]
        let rows: [[String]] = meetings.map { meeting in
            [
                SessionLookup.shortID(meeting.id),
                Self.shortDate.string(from: meeting.startedAt),
                meeting.durationLabel,
                meeting.appName,
                meeting.title,
            ]
        }
        return renderTable(header: header, rows: rows)
    }

    // MARK: - get

    static func getJSON(_ meeting: Meeting, options: GetOptions) -> String {
        let entry = GetEntry(
            id: SessionLookup.shortID(meeting.id),
            uuid: meeting.id.uuidString.lowercased(),
            title: meeting.title,
            date: Self.iso8601.string(from: meeting.startedAt),
            duration_seconds: meeting.duration ?? 0,
            app_source: meeting.appName,
            has_system_track: meeting.hasSystemTrack,
            summary: options.includeSummary ? SessionLookup.summaryMarkdown(for: meeting) : nil,
            transcript: options.includeTranscript ? SessionLookup.transcriptMarkdown(for: meeting) : nil,
            folder: SessionLookup.folderURL(for: meeting).path(percentEncoded: false))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(entry), encoding: .utf8)) ?? "{}"
    }

    static func getMarkdown(_ meeting: Meeting, options: GetOptions) -> String {
        var lines: [String] = []
        if options.includeMetadata {
            lines.append("# \(meeting.title)")
            lines.append("**Date:** \(Self.longDate.string(from: meeting.startedAt))  ")
            lines.append("**Duration:** \(meeting.durationLabel)  ")
            lines.append("**App:** \(meeting.appName)")
            lines.append("")
        }
        if options.includeSummary, let summary = SessionLookup.summaryMarkdown(for: meeting) {
            lines.append("## Summary")
            lines.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        if options.includeTranscript, let transcript = SessionLookup.transcriptMarkdown(for: meeting) {
            lines.append("## Transcript")
            lines.append(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - search

    struct SearchHit: Encodable {
        var meeting_id: String
        var meeting_title: String
        var match_kind: String          // "title" | "summary" | "transcript"
        var snippet: String
        var timestamp: String?          // "00:14:32" for transcript hits
    }

    static func searchJSON(_ hits: [SearchHit]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(hits), encoding: .utf8)) ?? "[]"
    }

    static func searchTable(_ hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "(no matches)" }
        let header = ["ID", "Kind", "Stamp", "Title — snippet"]
        let rows: [[String]] = hits.map { hit in
            let snippet = hit.snippet
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(80)
            return [hit.meeting_id, hit.match_kind, hit.timestamp ?? "—",
                    "\(hit.meeting_title) — \(snippet)"]
        }
        return renderTable(header: header, rows: rows)
    }

    // MARK: - Private

    private struct ListEntry: Encodable {
        var id: String
        var uuid: String
        var title: String
        var date: String
        var duration_seconds: TimeInterval
        var app_source: String
        var has_system_track: Bool
        var has_summary: Bool
        var has_transcript: Bool
    }

    private struct GetEntry: Encodable {
        var id: String
        var uuid: String
        var title: String
        var date: String
        var duration_seconds: TimeInterval
        var app_source: String
        var has_system_track: Bool
        var summary: String?
        var transcript: String?
        var folder: String
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static func renderTable(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = (0..<header.count).map { col in
            all.map { $0[col].count }.max() ?? 0
        }
        func pad(_ row: [String]) -> String {
            zip(row, widths).map { value, width in
                value.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        let bar = widths.map { String(repeating: "─", count: $0) }
        return ([pad(header), pad(bar)] + rows.map(pad)).joined(separator: "\n")
    }
}
