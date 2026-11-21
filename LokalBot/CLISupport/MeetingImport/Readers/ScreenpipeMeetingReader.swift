import Foundation
import SQLite3

enum ScreenpipeMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.screenpipe
    static let exportHint = "No export is needed: choose Screenpipe's data folder, .screenpipe in your home folder, which holds its meetings and transcripts. Choose Quit screenpipe from its menu bar icon first so the latest meetings are included."
    static let defaultLocations = ["~/.screenpipe"]

    static let conversationGap: TimeInterval = 5 * 60
    static let minimumConversationLength: TimeInterval = 60
    static let minimumConversationWords = 30

    static func recognizes(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return activeIndex(in: url) != nil || isFile(url.appendingPathComponent("db.sqlite"))
        }
        guard databaseExtensions.contains(url.pathExtension.lowercased()),
              !url.lastPathComponent.lowercased().hasPrefix("recovered-"),
              let header = fileHeader(url) else { return false }
        return header.starts(with: sqliteHeader) || header.starts(with: vaultHeader)
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        let candidates: [URL]
        if isDirectory.boolValue {
            candidates = databases(in: url)
        } else {
            guard recognizes(url) else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
            candidates = [url]
        }

        var scan = ExternalImportScan()
        var seen = Set<String>()
        var compressed: [(database: URL, keys: Set<String>)] = []
        var foundScreenpipe = false
        for database in candidates {
            do {
                let result = try readDatabase(database)
                foundScreenpipe = true
                for meeting in result.meetings where seen.insert(meeting.importKey).inserted {
                    scan.meetings.append(meeting)
                }
                if !result.compressedKeys.isEmpty { compressed.append((database, result.compressedKeys)) }
            } catch ScreenpipeReadFailure.notScreenpipe {
                continue
            } catch ScreenpipeReadFailure.unreadable(let reason) {
                guard isDirectory.boolValue else {
                    throw ExternalImportError.unreadable(database.lastPathComponent, reason)
                }
                scan.problems.append(.init(path: database.path, reason: reason))
            }
        }
        guard foundScreenpipe || !scan.problems.isEmpty else {
            throw ExternalImportError.unrecognized(source, url.lastPathComponent)
        }
        for entry in compressed {
            let missing = entry.keys.subtracting(seen).count
            if missing > 0 { scan.problems.append(.init(path: entry.database.path, reason: compressedReason(missing))) }
        }
        scan.meetings.sort { lhs, rhs in
            let left = lhs.startedAt ?? .distantPast
            let right = rhs.startedAt ?? .distantPast
            return left != right ? left < right : lhs.sourceID < rhs.sourceID
        }
        return scan
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)
    private static let vaultHeader = Data("SPVAULT1".utf8)
    private static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "db"]

    private static func databases(in folder: URL) -> [URL] {
        let original = folder.appendingPathComponent("db.sqlite")
        if let index = activeIndex(in: folder) {
            return isFile(original) ? [index, original] : [index]
        }
        if isFile(original) { return [original] }
        let found = ExternalImportText.files(in: folder).filter(recognizes)
        return found.filter { $0.lastPathComponent == "index.sqlite" } + found.filter { $0.lastPathComponent != "index.sqlite" }
    }

    private static func activeIndex(in folder: URL) -> URL? {
        let descriptor = folder.appendingPathComponent("storage.json")
        guard isFile(descriptor),
              let size = (try? FileManager.default.attributesOfItem(atPath: descriptor.path))?[.size] as? NSNumber,
              size.intValue < 1_000_000,
              let data = try? Data(contentsOf: descriptor),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = object["index"] as? String, !index.hasPrefix("/") else { return nil }
        let parts = index.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = parts.reduce(folder) { $0.appendingPathComponent($1) }
        return isFile(url) ? url : nil
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func fileHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 16)
    }

    private static func compressedReason(_ count: Int) -> String {
        let meetings = count == 1 ? "1 meeting keeps its" : "\(count) meetings keep their"
        return "\(meetings) transcript in Screenpipe's compressed storage, which LokalBot can't read. Quit Screenpipe, run "
            + "npx screenpipe storage export-sqlite ~/.screenpipe ~/Desktop/screenpipe-export.sqlite in Terminal, "
            + "then import that file."
    }

    private struct DatabaseResult {
        var meetings: [ExternalMeeting]
        var compressedKeys: Set<String>
    }

    private struct MeetingRow {
        var id: Int64
        var start: Int64
        var end: Int64
        var app: String
        var title: String
        var attendees: String
        var note: String
        var identity: String
    }

    private struct Utterance {
        var id: Int64
        var isLive: Bool
        var time: Int64
        var start: Int64
        var end: Int64?
        var text: String
        var isCompressed: Bool
        var speaker: String?
        var isNamed: Bool
        var isMe: Bool
        var device: String
        var isInput: Bool
        var stamp: String
    }

    private struct Schema {
        var tables: Set<String>
        var transcriptions: Set<String> = []
        var chunks: Set<String> = []
        var speakers: Set<String> = []
        var meetings: Set<String> = []
        var segments: Set<String> = []

        init(_ database: ImmutableDatabase) throws {
            tables = try database.tables()
            transcriptions = try database.columns(of: "audio_transcriptions")
            if tables.contains("audio_chunks") { chunks = try database.columns(of: "audio_chunks") }
            if tables.contains("speakers") { speakers = try database.columns(of: "speakers") }
            if tables.contains("meetings") { meetings = try database.columns(of: "meetings") }
            if tables.contains("meeting_transcript_segments") {
                segments = try database.columns(of: "meeting_transcript_segments")
            }
        }

        var hasMeetings: Bool { meetings.contains("id") && meetings.contains("meeting_start") }
    }

    private static func readDatabase(_ url: URL) throws -> DatabaseResult {
        let header = fileHeader(url) ?? Data()
        if header.starts(with: vaultHeader) {
            throw ScreenpipeReadFailure.unreadable("Screenpipe's vault is locked; unlock it in Screenpipe, then import again")
        }
        guard header.starts(with: sqliteHeader) else { throw ScreenpipeReadFailure.notScreenpipe }
        let database = try ImmutableDatabase(url)
        guard try database.tables().contains("audio_transcriptions") else { throw ScreenpipeReadFailure.notScreenpipe }
        let schema = try Schema(database)

        let windows = MeetingWindows(try readMeetings(database, schema))
        let live = try readLiveSegments(database, schema)
        let cutoff = schema.hasMeetings ? meetingsBegan(database, schema) ?? windows.earliestStart : nil
        var inMeetings = [[Utterance]](repeating: [], count: windows.meetings.count)
        var loose: [Utterance] = []
        try readTranscriptions(database, schema) { time in
            let indices = windows.indices(containing: time)
            let isLoose = indices.isEmpty && (cutoff.map { time < $0 } ?? true)
            return indices.isEmpty && !isLoose ? nil : (indices, isLoose)
        } add: { utterance, indices, isLoose in
            for index in indices { inMeetings[index].append(utterance) }
            if isLoose { loose.append(utterance) }
        }

        var result = DatabaseResult(meetings: [], compressedKeys: [])
        for (index, row) in windows.meetings.enumerated() {
            let utterances = combine(live: live[row.id] ?? [], background: inMeetings[index])
            let sourceID = "meeting-\(row.id)-\(ExternalImportText.stableID(row.identity).prefix(12))"
            if utterances.contains(where: \.isCompressed) {
                result.compressedKeys.insert(importKey(sourceID))
                continue
            }
            let notes = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !utterances.isEmpty || !notes.isEmpty else { continue }
            result.meetings.append(ExternalMeeting(
                source: source, sourceID: sourceID, title: title(for: row),
                startedAt: date(row.start), duration: Double(row.end - row.start) / 1_000,
                participants: participants(attendees: row.attendees, utterances: utterances),
                lines: utterances.map { line($0, from: row.start) },
                notes: notes.isEmpty ? nil : notes,
                actionItems: notes.isEmpty ? [] : actionItems(inNotes: notes),
                origin: url))
        }
        for group in conversations(loose) {
            let first = group[0]
            let finish = group.map { $0.end ?? $0.start }.max() ?? first.start
            let span = Double(finish - first.start) / 1_000
            let sourceID = "conversation-\(first.id)-\(ExternalImportText.stableID(first.stamp).prefix(12))"
            if group.contains(where: \.isCompressed) {
                if span >= minimumConversationLength { result.compressedKeys.insert(importKey(sourceID)) }
                continue
            }
            let words = group.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            guard span >= minimumConversationLength, words >= minimumConversationWords else { continue }
            result.meetings.append(ExternalMeeting(
                source: source, sourceID: sourceID, title: "Screenpipe conversation",
                startedAt: date(first.start), duration: span,
                participants: participants(attendees: "", utterances: group),
                lines: group.map { line($0, from: first.start) }, origin: url))
        }
        return result
    }

    private static func importKey(_ sourceID: String) -> String { "\(source.rawValue)/\(sourceID)" }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func title(for row: MeetingRow) -> String {
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let app = row.app.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.isEmpty || app.lowercased() == "manual" ? "Screenpipe meeting" : "\(app) meeting"
    }

    private static func line(_ utterance: Utterance, from origin: Int64) -> ExternalMeeting.Line {
        let start = Double(max(0, utterance.start - origin)) / 1_000
        let end = utterance.end.map { max(start, Double($0 - origin) / 1_000) }
        return ExternalMeeting.Line(start: start, end: end, speaker: utterance.speaker,
                                    text: utterance.text, isMe: utterance.isMe)
    }

    private static func inOrder(_ lhs: Utterance, _ rhs: Utterance) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        return lhs.id < rhs.id
    }

    private static func combine(live: [Utterance], background: [Utterance]) -> [Utterance] {
        var liveTimes: [String: [Int64]] = [:]
        for utterance in live where !utterance.isCompressed {
            liveTimes[duplicateKey(utterance), default: []].append(utterance.time)
        }
        let kept = background.filter { utterance in
            guard !utterance.isCompressed, let times = liveTimes[duplicateKey(utterance)] else { return true }
            return !times.contains { abs($0 - utterance.time) <= 15_000 }
        }
        return (live + kept).sorted(by: inOrder)
    }

    private static func duplicateKey(_ utterance: Utterance) -> String {
        [utterance.device, utterance.isInput ? "input" : "output", utterance.text].joined(separator: "\u{1F}")
    }

    private static func conversations(_ utterances: [Utterance]) -> [[Utterance]] {
        let gap = Int64(conversationGap * 1_000)
        var groups: [[Utterance]] = []
        var current: [Utterance] = []
        var reach = Int64.min
        for utterance in utterances.sorted(by: inOrder) {
            if !current.isEmpty, utterance.start - reach > gap {
                groups.append(current)
                current = []
            }
            reach = current.isEmpty ? (utterance.end ?? utterance.start) : max(reach, utterance.end ?? utterance.start)
            current.append(utterance)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func participants(attendees: String, utterances: [Utterance]) -> [String] {
        let candidates = attendees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            + utterances.filter(\.isNamed).compactMap(\.speaker)
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func isLabel(_ name: String) -> Bool {
        name.range(of: #"^(speaker|unknown)[ _#-]*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func milliseconds(_ column: String) -> String {
        "(CASE typeof(\(column)) "
            + "WHEN 'integer' THEN (CASE WHEN abs(\(column)) > 100000000000 THEN \(column) ELSE \(column) * 1000 END) "
            + "WHEN 'real' THEN CAST(round(CASE WHEN \(column) > 10000000 THEN \(column) * 1000.0 "
            + "ELSE (\(column) - 2440587.5) * 86400000.0 END) AS INTEGER) "
            + "WHEN 'text' THEN CAST(round((julianday(\(column)) - 2440587.5) * 86400000.0) AS INTEGER) END)"
    }

    private static func column(_ name: String, in columns: Set<String>, table: String = "") -> String {
        columns.contains(name) ? (table.isEmpty ? name : "\(table).\(name)") : "NULL"
    }

    private static func readMeetings(_ database: ImmutableDatabase, _ schema: Schema) throws -> [MeetingRow] {
        guard schema.hasMeetings else { return [] }
        let columns = schema.meetings
        let end = columns.contains("meeting_end") ? milliseconds("meeting_end") : "NULL"
        let sql = """
            SELECT id, \(milliseconds("meeting_start")), \(end), \(column("meeting_app", in: columns)),
                   \(column("title", in: columns)), \(column("attendees", in: columns)), \(column("note", in: columns)),
                   COALESCE(CAST(\(column("created_at", in: columns)) AS TEXT), CAST(meeting_start AS TEXT))
            FROM meetings
            """
        var rows: [MeetingRow] = []
        try database.rows(sql) { row in
            guard let id = row.int(0), let start = row.int(1), let end = row.int(2) else { return }
            rows.append(MeetingRow(id: id, start: start, end: max(start, end), app: row.text(3) ?? "",
                                   title: row.text(4) ?? "", attendees: row.text(5) ?? "",
                                   note: row.text(6) ?? "", identity: row.text(7) ?? String(start)))
        }
        return rows
    }

    private static func meetingsBegan(_ database: ImmutableDatabase, _ schema: Schema) -> Int64? {
        guard schema.tables.contains("_sqlx_migrations") else { return nil }
        var began: Int64?
        try? database.rows(
            "SELECT \(milliseconds("installed_on")) FROM _sqlx_migrations WHERE version = 20260225000000"
        ) { began = $0.int(0) }
        return began
    }

    private static func readLiveSegments(_ database: ImmutableDatabase,
                                         _ schema: Schema) throws -> [Int64: [Utterance]] {
        let columns = schema.segments
        guard columns.contains("meeting_id"), columns.contains("transcript"), columns.contains("captured_at") else {
            return [:]
        }
        let joinsSpeakers = columns.contains("speaker_id") && schema.speakers.contains("id")
            && schema.speakers.contains("name")
        let label = column("speaker_name", in: columns, table: "mts")
        let speaker = joinsSpeakers ? "COALESCE(NULLIF(TRIM(s.name), ''), \(label))" : label
        let compressed = columns.contains("_archive_mask") ? "((mts._archive_mask & 1) = 0)" : "0"
        var sql = """
            SELECT \(columns.contains("id") ? "mts.id" : "mts.rowid"), mts.meeting_id, \(milliseconds("mts.captured_at")),
                   CAST(mts.captured_at AS TEXT), \(column("device_name", in: columns, table: "mts")),
                   \(column("device_type", in: columns, table: "mts")), \(speaker), \(compressed), mts.transcript
            FROM meeting_transcript_segments mts
            """
        if joinsSpeakers { sql += " LEFT JOIN speakers s ON s.id = mts.speaker_id" }
        sql += " WHERE (TRIM(mts.transcript) != '' OR \(compressed))"
        var segments: [Int64: [Utterance]] = [:]
        try database.rows(sql) { row in
            guard let meetingID = row.int(1), let time = row.int(2) else { return }
            let kind = (row.text(5) ?? "").lowercased()
            let isCompressed = row.bool(7) == true
            let name = trimmed(row.text(6))
            segments[meetingID, default: []].append(Utterance(
                id: row.int(0) ?? 0, isLive: true, time: time, start: time, end: nil,
                text: isCompressed ? "" : trimmed(row.text(8)) ?? "", isCompressed: isCompressed,
                speaker: name, isNamed: name.map { !isLabel($0) } ?? false, isMe: kind == "input",
                device: row.text(4) ?? "", isInput: kind != "output", stamp: row.text(3) ?? ""))
        }
        return segments
    }

    private static func readTranscriptions(
        _ database: ImmutableDatabase, _ schema: Schema,
        place: (Int64) -> (indices: [Int], isLoose: Bool)?,
        add: (Utterance, [Int], Bool) -> Void
    ) throws {
        let columns = schema.transcriptions
        let joinsChunks = columns.contains("audio_chunk_id") && schema.chunks.contains("id")
        let joinsSpeakers = columns.contains("speaker_id") && schema.speakers.contains("id")
        let compressed = columns.contains("_archive_mask") ? "((at._archive_mask & 1) = 0)" : "0"
        let chunkTime = joinsChunks && schema.chunks.contains("timestamp") ? milliseconds("ac.timestamp") : "NULL"
        let chunkPath = joinsChunks ? column("file_path", in: schema.chunks, table: "ac") : "NULL"
        let speakerName = joinsSpeakers ? column("name", in: schema.speakers, table: "s") : "NULL"
        var sql = """
            SELECT \(columns.contains("id") ? "at.id" : "at.rowid"), \(milliseconds("at.timestamp")), \(chunkTime),
                   CAST(at.timestamp AS TEXT), \(column("device", in: columns, table: "at")),
                   \(column("is_input_device", in: columns, table: "at")), \(column("speaker_id", in: columns, table: "at")),
                   \(speakerName), \(column("start_time", in: columns, table: "at")),
                   \(column("end_time", in: columns, table: "at")),
                   \(column("transcription_engine", in: columns, table: "at")), \(chunkPath), \(compressed), at.transcription
            FROM audio_transcriptions at
            """
        if joinsChunks { sql += " LEFT JOIN audio_chunks ac ON ac.id = at.audio_chunk_id" }
        if joinsSpeakers { sql += " LEFT JOIN speakers s ON s.id = at.speaker_id" }
        sql += " WHERE (TRIM(at.transcription) != '' OR \(compressed))"
        if chunkPath != "NULL" { sql += " AND (ac.file_path IS NULL OR ac.file_path NOT LIKE 'cloud://%')" }
        if joinsSpeakers, schema.speakers.contains("hallucination") {
            sql += " AND (s.id IS NULL OR COALESCE(s.hallucination, 0) = 0)"
        }
        try database.rows(sql) { row in
            guard let time = row.int(1) ?? row.int(2), let placement = place(time) else { return }
            var start = time
            var end: Int64?
            if (row.text(10) ?? "").lowercased() != "live", let from = row.double(8), let to = row.double(9),
               from.isFinite, to.isFinite, from >= 0, to > from {
                start = time + Int64((from * 1_000).rounded())
                end = time + Int64((to * 1_000).rounded())
            }
            let device = trimmed(row.text(4)) ?? ""
            let isInput = (device.isEmpty ? nil : row.bool(5)) ?? inputFromChunk(row.text(11))
            let name = trimmed(row.text(7))
            let isCompressed = row.bool(12) == true
            add(Utterance(
                id: row.int(0) ?? 0, isLive: false, time: time, start: start, end: end,
                text: isCompressed ? "" : trimmed(row.text(13)) ?? "", isCompressed: isCompressed,
                speaker: name ?? row.int(6).map { "Unknown #\($0)" }, isNamed: name.map { !isLabel($0) } ?? false,
                isMe: isInput == true, device: device, isInput: isInput ?? true, stamp: row.text(3) ?? ""),
                placement.indices, placement.isLoose)
        }
    }

    private static func inputFromChunk(_ path: String?) -> Bool? {
        guard let name = path.map({ ($0 as NSString).lastPathComponent.lowercased() }) else { return nil }
        if name.contains(" (input)_") { return true }
        if name.contains(" (output)_") { return false }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private struct MeetingWindows {
        let meetings: [MeetingRow]
        private let reach: [Int64]

        init(_ rows: [MeetingRow]) {
            meetings = rows.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
            var latest = Int64.min
            reach = meetings.map { row in
                latest = max(latest, row.end)
                return latest
            }
        }

        var earliestStart: Int64? { meetings.first?.start }

        func indices(containing time: Int64) -> [Int] {
            var low = 0
            var high = meetings.count
            while low < high {
                let middle = (low + high) / 2
                if meetings[middle].start <= time { low = middle + 1 } else { high = middle }
            }
            var found: [Int] = []
            var index = low - 1
            while index >= 0, reach[index] >= time {
                if meetings[index].end >= time { found.append(index) }
                index -= 1
            }
            return found
        }
    }

    static func actionItems(inNotes notes: String) -> [ExternalMeeting.ActionItem] {
        var items: [ExternalMeeting.ActionItem] = []
        var sectionLevel: Int?
        var owner: String?
        for raw in notes.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let heading = heading(in: line) {
                if let level = sectionLevel, heading.level > level, isName(heading.text) {
                    owner = heading.text
                    continue
                }
                sectionLevel = isActionHeading(heading.text) ? heading.level : nil
                owner = nil
                continue
            }
            guard sectionLevel != nil, let text = bullet(in: line) else { continue }
            items.append(ownedItem(text, owner: owner))
        }
        return items
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes) {
            let rest = line.dropFirst(hashes)
            guard rest.first == " " || rest.first == "\t" else { return nil }
            return (hashes, rest.trimmingCharacters(in: CharacterSet(charactersIn: "#:").union(.whitespaces)))
        }
        if line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
            let text = line.dropFirst(2).dropLast(2).trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
            return text.contains("**") ? nil : (7, text)
        }
        if line.hasSuffix(":"), bullet(in: line) == nil {
            let text = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            if text.split(separator: " ").count <= 4, isActionHeading(text) { return (7, text) }
        }
        return nil
    }

    private static func isActionHeading(_ text: String) -> Bool {
        text.range(of: #"\b(action|next step|to-?do|follow[- ]?up)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func bullet(in line: String) -> String? {
        var rest: Substring
        if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
            rest = line.dropFirst(2)
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            let after = line.dropFirst(digits.count)
            guard (1...3).contains(digits.count), let mark = after.first, mark == "." || mark == ")",
                  after.dropFirst().first == " " else { return nil }
            rest = after.dropFirst(2)
        }
        var text = rest.trimmingCharacters(in: .whitespaces)
        for box in ["[ ]", "[x]", "[X]"] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }

    private static func ownedItem(_ text: String, owner: String?) -> ExternalMeeting.ActionItem {
        if text.hasPrefix("**"), let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            let name = text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
            var rest = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if let first = rest.first, ":-–—".contains(first) {
                rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if isName(name), !rest.isEmpty { return .init(text: rest, owner: name) }
        }
        if text.hasPrefix("@"), let space = text.firstIndex(of: " ") {
            let name = String(text[text.index(after: text.startIndex)..<space])
            let rest = text[space...].trimmingCharacters(in: .whitespaces)
            if isName(name), !rest.isEmpty { return .init(text: rest, owner: name) }
        }
        return .init(text: text, owner: owner)
    }

    private static func isName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return !text.isEmpty && text.count <= 40 && (1...4).contains(words.count) && text.first?.isLetter == true
            && text.allSatisfy { $0.isLetter || " .'-".contains($0) } && !isActionHeading(text)
            && text.range(of: #"\b(decision|note|summary|question|risk|blocker|topic|highlight|takeaway|discussion|context|agenda|overview|detail|update|outcome|key point|owner|done|completed)s?\b"#,
                          options: [.regularExpression, .caseInsensitive]) == nil
    }
}

private final class ImmutableDatabase {
    private let handle: OpaquePointer

    init(_ url: URL) throws {
        let uri = URL(fileURLWithPath: url.path).absoluteString + "?mode=ro&immutable=1"
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(uri, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ImmutableDatabase.failure(result)
        }
        handle = opened
    }

    deinit {
        sqlite3_close(handle)
    }

    static func failure(_ code: Int32) -> Error {
        ScreenpipeReadFailure.unreadable("SQLite couldn't read it (\(String(cString: sqlite3_errstr(code))))")
    }

    func rows(_ sql: String, _ body: (ImmutableRow) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ImmutableDatabase.failure(prepared)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw ImmutableDatabase.failure(step) }
            try body(ImmutableRow(statement: statement))
        }
    }

    func tables() throws -> Set<String> {
        var names = Set<String>()
        try rows("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')") { row in
            if let name = row.text(0) { names.insert(name) }
        }
        return names
    }

    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try rows("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\")") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }
}

private struct ImmutableRow {
    let statement: OpaquePointer

    private func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }

    func int(_ index: Int32) -> Int64? { isNull(index) ? nil : sqlite3_column_int64(statement, index) }

    func double(_ index: Int32) -> Double? { isNull(index) ? nil : sqlite3_column_double(statement, index) }

    func text(_ index: Int32) -> String? {
        guard !isNull(index), let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func bool(_ index: Int32) -> Bool? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return nil
        case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_double(statement, index) != 0
        default:
            switch (text(index) ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "t", "yes": return true
            case "0", "false", "f", "no": return false
            default: return nil
            }
        }
    }
}

private enum ScreenpipeReadFailure: Error {
    case notScreenpipe
    case unreadable(String)
}
