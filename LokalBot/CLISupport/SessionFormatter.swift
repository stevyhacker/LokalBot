import Foundation

enum SessionFormatter {

    struct GetOptions: Equatable {
        var includeSummary: Bool
        var includeTranscript: Bool
        var includeMetadata: Bool
        var transcriptCharacters: Int?
        var transcriptFrom: TimeInterval?

        static let all = GetOptions(includeSummary: true,
                                    includeTranscript: true,
                                    includeMetadata: true)
    }

    static let listSummaryBudget = 20_000
    static let listSummaryCap = 5_000
    static let defaultSummaryListCount = 10
    static let maximumSummaryListCount = 50

    static func listJSON(_ meetings: [Meeting], includeSummary: Bool = false) -> String {
        let summaries = includeSummary
            ? listSummaries(meetings.map(SessionLookup.summaryMarkdown(for:)))
            : Array(repeating: nil, count: meetings.count)
        let entries = meetings.indices.map { index in
            let meeting = meetings[index]
            return ListEntry(
                id: SessionLookup.shortID(meeting.id),
                uuid: meeting.id.uuidString.lowercased(),
                title: meeting.title,
                date: Self.iso8601.string(from: meeting.startedAt),
                duration_seconds: meeting.duration ?? 0,
                app_source: meeting.appName,
                has_system_track: meeting.hasSystemTrack,
                has_summary: SessionLookup.hasSummary(for: meeting),
                has_transcript: SessionLookup.hasTranscriptMarkdown(for: meeting),
                summary: summaries[index]?.text,
                summary_truncated: summaries[index]?.truncated == true ? true : nil,
                sample: meeting.isSample ? true : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(entries), encoding: .utf8)) ?? "[]"
    }

    static func listTable(_ meetings: [Meeting], includeSummary: Bool = false) -> String {
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
        let table = renderTable(header: header, rows: rows)
        guard includeSummary else { return table }
        let summaries = listSummaries(meetings.map(SessionLookup.summaryMarkdown(for:)))
        let sections = zip(meetings, summaries).compactMap { meeting, summary in
            summary.map { "── \(SessionLookup.shortID(meeting.id)) · \(meeting.title)\n\($0.text)" }
        }
        return ([table] + sections).joined(separator: "\n\n")
    }

    enum ListIncludeError: Error, Equatable {
        case transcript
        case unknown([String])
    }

    static func listIncludesSummary(_ include: String) throws -> Bool {
        let parts = Set(include.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        if parts.contains("transcript") { throw ListIncludeError.transcript }
        let unknown = parts.subtracting(["metadata", "summary"])
        guard unknown.isEmpty else { throw ListIncludeError.unknown(unknown.sorted()) }
        return parts.contains("summary")
    }

    static func listSummaries(_ summaries: [String?]) -> [(text: String, truncated: Bool)?] {
        let texts = summaries.map { summary -> String? in
            guard let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let present = texts.indices.filter { texts[$0] != nil }
        let shares = summaryShares(present.map { texts[$0]?.count ?? 0 },
                                   budget: listSummaryBudget, cap: listSummaryCap)
        var result: [(text: String, truncated: Bool)?] = Array(repeating: nil, count: texts.count)
        for (index, share) in zip(present, shares) {
            if let text = texts[index] { result[index] = shortened(text, to: share) }
        }
        return result
    }

    static func summaryShares(_ lengths: [Int], budget: Int, cap: Int) -> [Int] {
        var shares = Array(repeating: 0, count: lengths.count)
        var remaining = budget
        let order = lengths.indices.sorted { (lengths[$0], $0) < (lengths[$1], $1) }
        for (position, index) in order.enumerated() {
            shares[index] = min(lengths[index], cap, remaining / (order.count - position))
            remaining -= shares[index]
        }
        return shares
    }

    static func shortened(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        var kept = String(text.prefix(max(0, limit - 2)))
        if let newline = kept.lastIndex(of: "\n"),
           kept.distance(from: kept.startIndex, to: newline) >= kept.count / 2 {
            kept = String(kept[..<newline])
        }
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return (kept + "\n…", true)
    }

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
            folder: SessionLookup.folderURL(for: meeting).path(percentEncoded: false),
            sample: meeting.isSample ? true : nil)
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
            if meeting.isSample {
                lines.append("")
                lines.append("**Sample:** LokalBot's sample meeting. The people and the company are made up, "
                    + "and the voices are synthetic.")
            }
            lines.append("")
        }
        if options.includeSummary, let summary = SessionLookup.summaryMarkdown(for: meeting) {
            lines.append("## Summary")
            lines.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        if options.includeTranscript, let limit = options.transcriptCharacters,
           let transcript = SessionLookup.transcript(for: meeting) {
            let window = transcriptWindow(transcript, from: options.transcriptFrom ?? 0, maxCharacters: limit)
            lines.append("## Transcript")
            lines.append(window.text)
            if let next = window.nextFrom {
                lines.append("")
                lines.append("[Transcript continues. Call get_meeting with transcript_from \"\(next)\" to read on.]")
            }
            lines.append("")
        } else if options.includeTranscript, let transcript = SessionLookup.transcriptMarkdown(for: meeting) {
            lines.append("## Transcript")
            lines.append(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func transcriptWindow(_ transcript: Transcript, from start: TimeInterval,
                                 maxCharacters: Int) -> (text: String, nextFrom: String?) {
        let roster = transcript.speakerRoster
        var kept: [String] = []
        var used = 0
        for segment in transcript.segments where segment.start >= start {
            guard let line = transcript.markdownLine(segment, roster: roster) else { continue }
            if !kept.isEmpty, used + line.count + 2 > maxCharacters {
                return (kept.joined(separator: "\n\n"), Transcript.stamp(segment.start))
            }
            kept.append(line)
            used += line.count + 2
        }
        return (kept.joined(separator: "\n\n"), nil)
    }

    static func seconds(fromStamp stamp: String) -> TimeInterval? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    struct SearchHit: Encodable {
        var meeting_id: String
        var meeting_title: String
        var match_kind: String
        var snippet: String
        var timestamp: String?
        var sample: Bool?
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
        var summary: String?
        var summary_truncated: Bool?
        var sample: Bool?
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
        var sample: Bool?
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
