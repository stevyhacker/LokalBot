import Foundation

/// Reads what Fireflies.ai lets a person download for a meeting, from the
/// Download icon at the bottom of the meeting: the transcript (JSON, SRT, CSV,
/// or MD), the summary (JSON or MD), and the audio (MP3) or video (MP4). It
/// also reads JSON shaped like the Fireflies API's `transcript`, which API
/// backup tools save, and the text transcripts, summaries, and JSON metadata
/// of an account data export. Files of one meeting are put together by name
/// ("Weekly sync transcript.json" and "Weekly sync summary.md") or by sharing a
/// folder of their own. PDF and DOCX downloads aren't read.
///
/// Fireflies doesn't document the layout of its downloads, so each format is
/// read defensively: JSON keys match without regard to case or underscores,
/// times may be seconds, milliseconds, or "00:01:02", and text transcripts
/// may put the speaker and time before each line or on a line above it.
enum FirefliesMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.fireflies
    static let exportHint = "In Fireflies, open the meeting from Meetings, click the Download icon at the bottom, and download the Transcript as JSON (or SRT) and the Summary as JSON or MD; add the Audio (MP3) to keep the recording. Choose those files or a folder holding them, or the .zip from Fireflies' account data export."
    /// Fireflies keeps meetings in its cloud; nothing readable stays on the Mac.
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool {
        let kind = Kind(url)
        guard kind.isParsed, let head = peek(url) else { return false }
        switch kind {
        case .json:
            return looksLikeFirefliesJSON(head)
        case .subtitle:
            return head.contains("-->")
        case .table:
            let header = head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return tableColumns(delimitedRows(header, delimiter: delimiter(for: url, header: header)).first ?? []) != nil
        case .text:
            return looksLikeFirefliesText(head)
        case .media, .unsupported, .other:
            return false
        }
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        return isDirectory.boolValue ? try readFolder(url) : try readFile(url)
    }

    // MARK: - Files and folders

    private enum Kind: Equatable {
        case json, subtitle, table, text, media, unsupported, other

        init(_ url: URL) {
            switch url.pathExtension.lowercased() {
            case "json": self = .json
            case "srt", "vtt": self = .subtitle
            case "csv", "tsv": self = .table
            case "md", "markdown", "txt": self = .text
            case "mp3", "m4a", "wav", "mp4": self = .media
            case "pdf", "docx", "doc": self = .unsupported
            default: self = .other
            }
        }

        var isParsed: Bool { [.json, .subtitle, .table, .text].contains(self) }
    }

    /// Why one file couldn't be read. Never quotes the file.
    private enum Failure: Error {
        case unreadable, invalidJSON, empty

        var reason: String {
            switch self {
            case .unreadable: "it couldn't be opened as text"
            case .invalidJSON: "it isn't valid JSON"
            case .empty: "it holds no Fireflies transcript, notes, or action items"
            }
        }
    }

    /// What one file says about a meeting. Several pieces of one meeting
    /// (transcript, summary, metadata) are merged before it becomes one.
    private struct Piece {
        var file: URL
        var id: String?
        var title: String?
        var startedAt: Date?
        var duration: TimeInterval?
        var participants: [String] = []
        var lines: [ExternalMeeting.Line] = []
        var notes: String?
        var actions: [ExternalMeeting.ActionItem] = []
        /// Came from a JSON file holding several meetings.
        var fromCollection = false
        /// Came from JSON, whose fields win over text guessed from a layout.
        var isStructured = false

        var hasContent: Bool {
            !lines.isEmpty || !(notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !actions.isEmpty
        }
    }

    private static func readFile(_ url: URL) throws -> ExternalImportScan {
        switch Kind(url) {
        case .media:
            // A recording chosen on its own: LokalBot transcribes it.
            let title = fallbackTitle(for: url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let meeting = ExternalMeeting(
                source: source, sourceID: ExternalImportText.stableID("fireflies-recording", key(title), String(size)),
                title: title, audioURL: url, origin: url)
            return ExternalImportScan(meetings: [meeting])
        case .unsupported:
            throw ExternalImportError.unreadable(
                url.lastPathComponent, "LokalBot reads Fireflies' JSON, SRT, CSV, and MD downloads, not PDF or Word files.")
        case .other:
            throw ExternalImportError.unrecognized(source, url.path)
        case .json, .subtitle, .table, .text:
            break
        }
        let pieces: [Piece]
        do {
            pieces = try parse(url)
        } catch {
            throw ExternalImportError.unreadable(url.lastPathComponent, ((error as? Failure) ?? .unreadable).reason)
        }
        let meetings = pieces.map { meeting(from: $0, media: nil) }.filter { !$0.isEmpty }
        guard !meetings.isEmpty else {
            throw ExternalImportError.unreadable(url.lastPathComponent, Failure.empty.reason)
        }
        return ExternalImportScan(meetings: meetings)
    }

    private static func readFolder(_ folder: URL) throws -> ExternalImportScan {
        var scan = ExternalImportScan()
        var pieces: [Piece] = []
        var media: [URL] = []
        for file in ExternalImportText.files(in: folder) {
            if Kind(file) == .media {
                // A recording only joins a meeting whose transcript or notes
                // sit beside it; on its own it is just an audio file.
                media.append(file)
                continue
            }
            guard recognizes(file) else { continue }
            do {
                let found = try parse(file)
                if found.contains(where: { $0.hasContent || $0.id != nil }) {
                    pieces += found
                } else {
                    scan.problems.append(.init(path: file.path, reason: Failure.empty.reason))
                }
            } catch {
                scan.problems.append(.init(path: file.path, reason: ((error as? Failure) ?? .unreadable).reason))
            }
        }
        scan.meetings = assemble(pieces, media: media)
        if scan.meetings.isEmpty && scan.problems.isEmpty {
            throw ExternalImportError.unrecognized(source, folder.path)
        }
        return scan
    }

    private static func parse(_ url: URL) throws -> [Piece] {
        switch Kind(url) {
        case .json:
            return try jsonPieces(url)
        case .subtitle:
            let text = try readText(url)
            var piece = Piece(file: url)
            piece.lines = SubtitleTranscript.parse(text).filter { !isBranding($0.text) }
            piece.id = viewID(in: text)
            return [piece]
        case .table:
            return [tablePiece(url, text: try readText(url))]
        case .text:
            return [textPiece(url, text: try readText(url))]
        case .media, .unsupported, .other:
            return []
        }
    }

    private static func readText(_ url: URL) throws -> String {
        do {
            return try ExternalImportText.readText(url)
        } catch {
            throw Failure.unreadable
        }
    }

    /// The first 64 KB, for the quick checks in `recognizes`.
    private static func peek(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), !data.isEmpty else { return nil }
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.prefix(data.count - data.count % 2), encoding: .utf16) ?? ""
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func looksLikeFirefliesJSON(_ head: String) -> Bool {
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        let squeezed = trimmed.lowercased().replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let markers = ["\"sentences\"", "\"speakername\"", "\"transcripturl\"", "\"actionitems\"", "\"shorthandbullet\"",
                       "\"rawtext\"", "\"meetingattendees\"", "\"bulletgist\"", "fireflies"]
        if markers.contains(where: squeezed.contains) { return true }
        if squeezed.contains("\"speaker") && (squeezed.contains("\"text\"") || squeezed.contains("\"sentence")) { return true }
        // Meeting details without a transcript, as an account export keeps them.
        return squeezed.contains("\"title\"")
            && ["\"date", "\"duration\"", "\"participants\"", "\"organizer"].contains(where: squeezed.contains)
    }

    private static func looksLikeFirefliesText(_ head: String) -> Bool {
        let rows = head.components(separatedBy: "\n").prefix(400).map { $0.trimmingCharacters(in: .whitespaces) }
        let sections = Set(rows.compactMap { row -> String? in
            guard let heading = headingText(row) ?? sectionLead(row) else { return nil }
            return sectionKind(heading) == nil ? nil : key(heading)
        })
        let tokens = rows.map(classify)
        let labeled = tokens.filter(\.isLabeled).count
        let filled = tokens.filter { !$0.isBlank }.count
        let transcriptLike = labeled >= 3 && labeled * 10 >= filled * 3
        if head.lowercased().contains("fireflies") { return !sections.isEmpty || labeled >= 2 }
        return sections.count >= 2 || transcriptLike
    }

    // MARK: - Putting meetings together

    /// One meeting per group of files: a folder's files that share a name
    /// once words like "transcript" or "summary" are dropped, or all of a
    /// folder's files when it holds one meeting. Meetings from a JSON file
    /// that holds several take in the groups that name their id or title.
    private static func assemble(_ pieces: [Piece], media: [URL]) -> [ExternalMeeting] {
        let collected = pieces.filter(\.fromCollection)
        let single = pieces.filter { !$0.fromCollection }
        var stemsByFolder: [String: Set<String>] = [:]
        for file in single.map(\.file) + media {
            let stem = groupStem(file)
            if !stem.isEmpty { stemsByFolder[file.deletingLastPathComponent().path, default: []].insert(stem) }
        }
        func groupKey(_ file: URL) -> (folder: String, stem: String) {
            let folder = file.deletingLastPathComponent().path
            var stem = groupStem(file)
            if stem.isEmpty, let stems = stemsByFolder[folder], stems.count == 1, let only = stems.first { stem = only }
            return (folder, stem)
        }

        var order: [String] = []
        var groups: [String: (stem: String, pieces: [Piece], media: [URL])] = [:]
        for piece in single {
            let group = groupKey(piece.file)
            let id = group.folder + "\u{1F}" + group.stem
            if groups[id] == nil {
                order.append(id)
                groups[id] = (group.stem, [], [])
            }
            groups[id]?.pieces.append(piece)
        }
        for file in media {
            let group = groupKey(file)
            groups[group.folder + "\u{1F}" + group.stem]?.media.append(file)
        }

        var absorbed = Array(repeating: [Piece](), count: collected.count)
        var absorbedMedia = Array(repeating: [URL](), count: collected.count)
        var meetings: [ExternalMeeting] = []
        for id in order {
            guard let group = groups[id] else { continue }
            var ids: [String] = []
            for piece in group.pieces { if let pieceID = piece.id, !ids.contains(pieceID) { ids.append(pieceID) } }
            if ids.count > 1 {
                // Different meetings that happen to share a name: keep them apart.
                for pieceID in ids {
                    meetings.append(meeting(from: merge(group.pieces.filter { $0.id == pieceID }), media: nil))
                }
                for piece in group.pieces where piece.id == nil { meetings.append(meeting(from: piece, media: nil)) }
                continue
            }
            if ids.isEmpty, let match = collectedMatch(group.stem, files: group.pieces.map(\.file) + group.media, in: collected) {
                absorbed[match] += group.pieces
                absorbedMedia[match] += group.media
                continue
            }
            meetings.append(meeting(from: merge(group.pieces), media: preferredMedia(group.media)))
        }
        for (index, piece) in collected.enumerated() {
            meetings.append(meeting(from: merge([piece] + absorbed[index]), media: preferredMedia(absorbedMedia[index])))
        }
        return meetings.filter { !$0.isEmpty }
    }

    /// The meeting of a several-meeting JSON file that a group of files
    /// belongs to: one whose id is in a file's path, else the only one with
    /// the group's name as its title.
    private static func collectedMatch(_ stem: String, files: [URL], in collected: [Piece]) -> Int? {
        let paths = files.map { $0.path.lowercased() }
        if let index = collected.indices.first(where: { index in
            guard let id = collected[index].id?.lowercased(), id.count >= 6 else { return false }
            return paths.contains { $0.contains(id) }
        }) {
            return index
        }
        guard !stem.isEmpty else { return nil }
        let titled = collected.indices.filter { key(collected[$0].title ?? "") == stem }
        return titled.count == 1 ? titled.first : nil
    }

    private static func preferredMedia(_ files: [URL]) -> URL? {
        files.first { ["mp3", "m4a", "wav"].contains($0.pathExtension.lowercased()) } ?? files.first
    }

    /// One meeting from its pieces. JSON wins over text guessed from a
    /// layout, and a timed transcript wins over an untimed one.
    private static func merge(_ pieces: [Piece]) -> Piece {
        let ordered = pieces.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.id != nil ? 0 : 1, lhs.element.isStructured ? 0 : 1, lhs.offset)
            let right = (rhs.element.id != nil ? 0 : 1, rhs.element.isStructured ? 0 : 1, rhs.offset)
            return left < right
        }.map(\.element)
        guard var merged = ordered.first else { return Piece(file: URL(fileURLWithPath: "/")) }
        for piece in ordered.dropFirst() {
            merged.id = merged.id ?? piece.id
            if (merged.title ?? "").isEmpty { merged.title = piece.title }
            merged.startedAt = merged.startedAt ?? piece.startedAt
            merged.duration = merged.duration ?? piece.duration
            merged.participants = uniqueNames(merged.participants + piece.participants)
            let isTimed = merged.lines.contains { $0.start != nil }
            if merged.lines.isEmpty || (!isTimed && piece.lines.contains { $0.start != nil }) {
                merged.lines = piece.lines
            }
            if (merged.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { merged.notes = piece.notes }
            if merged.actions.isEmpty { merged.actions = piece.actions }
        }
        return merged
    }

    private static func meeting(from piece: Piece, media: URL?) -> ExternalMeeting {
        let title = piece.title.map(collapseSpaces).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle(for: piece.file)
        var participants = piece.participants
        if participants.isEmpty {
            participants = uniqueNames(piece.lines.compactMap(\.speaker).filter { !isGenericSpeaker($0) })
        }
        return ExternalMeeting(
            source: source, sourceID: sourceID(for: piece, title: title), title: title, startedAt: piece.startedAt,
            duration: piece.duration, participants: participants, lines: piece.lines, notes: piece.notes,
            actionItems: piece.actions, audioURL: media, origin: piece.file)
    }

    /// Fireflies' own id when a file kept it (a JSON `id` or a link to the
    /// meeting); otherwise a hash of the start and title, or of the title and
    /// the first words, which a newer download of the same meeting repeats.
    private static func sourceID(for piece: Piece, title: String) -> String {
        if let id = piece.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        if let start = piece.startedAt {
            return ExternalImportText.stableID("fireflies", String(Int(start.timeIntervalSince1970.rounded())), key(title))
        }
        let opening = piece.lines.prefix(3).map(\.text).joined(separator: " ")
        let anchor = opening.isEmpty ? String((piece.notes ?? "").prefix(300)) : opening
        return ExternalImportText.stableID("fireflies", key(title), key(anchor))
    }

    // MARK: - Names

    private static let roleWords = "transcript|transcription|summary|ai notes|notes|audio|video|recording|metadata|meta|captions|subtitles|action items|fireflies"

    /// A file's name without words that only say which part of a meeting it
    /// holds, as letters and digits: "Weekly_sync - Transcript" is "weekly sync".
    private static func groupStem(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        var previous = ""
        while stem != previous {
            previous = stem
            stem = stem.replacingOccurrences(of: "(^|[\\s_.()\\[\\]–—-])(\(roleWords))[)\\]]?\\s*$", with: "",
                                             options: .regularExpression)
            stem = stem.replacingOccurrences(of: "^(\(roleWords))\\s*[_:.–—-]+", with: "", options: .regularExpression)
        }
        return key(stem)
    }

    /// A readable title from a file name, keeping the words of the title.
    private static func fallbackTitle(for url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        stem = stem.replacingOccurrences(of: "\\s*[_.(\\[–—-]+\\s*(\(roleWords))[)\\]]?\\s*$", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        // "Design sync transcript", but not "Team notes" or "Spatial audio".
        stem = stem.replacingOccurrences(of: "\\s+(transcript|transcription|summary|captions|subtitles|metadata)\\s*$",
                                         with: "", options: [.regularExpression, .caseInsensitive])
        stem = stem.replacingOccurrences(of: "^(\(roleWords))\\s*[_:.–—-]+\\s*", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        stem = collapseSpaces(stem.replacingOccurrences(of: "_", with: " "))
        if !stem.isEmpty, groupStem(url) != "" { return stem }
        // "transcript.txt" in a folder of its own: the folder names the meeting.
        let folder = collapseSpaces(url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "_", with: " "))
        return folder.isEmpty || folder == "/" ? "Fireflies meeting" : folder
    }

    /// Letters and digits only, lowercased, words separated by one space.
    private static func key(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let cleaned = collapseSpaces(name)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { return nil }
            return cleaned
        }
    }

    private static func isGenericSpeaker(_ name: String) -> Bool {
        name.range(of: "^(speaker|unknown speaker|unknown)( \\d+)?$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isNameLike(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.count <= 40 && name.first?.isLetter == true
            && !name.contains(where: { ".?!,;:\"()[]*#".contains($0) })
            && name.split(separator: " ").count <= 5
    }

    /// The meeting's id in a link to it, "app.fireflies.ai/view/Title::ID".
    private static func viewID(in text: String) -> String? {
        guard let range = text.range(of: #"app\.fireflies\.ai/view/[^\s)\]"'<>]+"#, options: .regularExpression) else {
            return nil
        }
        var slug = String(text[range].dropFirst("app.fireflies.ai/view/".count))
        if let cut = slug.firstIndex(where: { $0 == "?" || $0 == "#" }) { slug = String(slug[..<cut]) }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
        if let separator = slug.range(of: "::", options: .backwards) {
            let id = String(slug[separator.upperBound...])
            return id.count >= 6 && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? id : nil
        }
        // Without "::" only a bare id counts; a title alone isn't unique.
        return slug.count >= 16 && slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? slug : nil
    }

    /// "Powered by Fireflies.ai" and links back to Fireflies, which branded
    /// downloads add and which say nothing about the meeting.
    private static func isBranding(_ line: String) -> Bool {
        let lowered = line.lowercased()
        guard lowered.contains("fireflies"), line.split(separator: " ").count <= 15 else { return false }
        return lowered.contains("fireflies.ai")
            || lowered.range(of: "^\\W*(powered|generated|transcribed|created|made|recorded|summarized)\\s+(by|with|using)\\b",
                             options: .regularExpression) != nil
    }

    // MARK: - JSON

    private static func jsonPieces(_ url: URL) throws -> [Piece] {
        let text = try readText(url)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw Failure.invalidJSON
        }
        var root = object
        // GraphQL answers wrap the payload: {"data": {"transcript": {…}}}.
        if let dictionary = root as? [String: Any], let data = field(dictionary, "data"), data is [String: Any] || data is [Any] {
            root = data
        }
        if let dictionary = root as? [String: Any], dictionary.count <= 2 {
            if var inner = field(dictionary, "transcript") as? [String: Any] {
                // {"transcript": {…}, "summary": {…}} keeps the summary beside it.
                if field(inner, "summary") == nil, let summary = field(dictionary, "summary") { inner["summary"] = summary }
                root = inner
            } else if let list = (field(dictionary, "transcripts") ?? field(dictionary, "meetings")) as? [Any] {
                root = list
            }
        }
        if let list = root as? [Any] {
            let dictionaries = list.compactMap { $0 as? [String: Any] }
            if dictionaries.contains(where: isMeetingObject) {
                var pieces = dictionaries.filter(isMeetingObject).map { meetingPiece($0, file: url) }
                if pieces.count > 1 { for index in pieces.indices { pieces[index].fromCollection = true } }
                return pieces
            }
            var piece = Piece(file: url)
            piece.isStructured = true
            piece.lines = sentenceLines(list, speakers: [:], duration: nil)
            piece.id = viewID(in: text)
            return [piece]
        }
        guard let dictionary = root as? [String: Any] else { throw Failure.empty }
        return [meetingPiece(dictionary, file: url)]
    }

    private static func isMeetingObject(_ dictionary: [String: Any]) -> Bool {
        if field(dictionary, "sentences", "transcripturl", "datestring", "meetingattendees", "summary", "organizeremail",
                 "title", "meetingtitle") != nil {
            return true
        }
        return field(dictionary, "id") != nil && field(dictionary, "date") != nil
    }

    private static func meetingPiece(_ dictionary: [String: Any], file: URL) -> Piece {
        var piece = Piece(file: file)
        piece.isStructured = true
        piece.id = string(field(dictionary, "id", "transcriptid", "meetingid"))
            ?? viewID(in: string(field(dictionary, "transcripturl", "url", "link")) ?? "")
        piece.title = string(field(dictionary, "title", "meetingtitle", "name"))
        piece.startedAt = date(field(dictionary, "datestring", "date", "startedat", "startdate", "meetingdate", "createdat"))

        var speakers: [String: String] = [:]
        var names: [String] = []
        for case let speaker as [String: Any] in (field(dictionary, "speakers") as? [Any]) ?? [] {
            guard let name = string(field(speaker, "name", "displayname")) else { continue }
            if let id = string(field(speaker, "id", "speakerid")) { speakers[id] = name }
            if !isGenericSpeaker(name) { names.append(name) }
        }
        var emails = Set<String>()
        for case let attendee as [String: Any] in (field(dictionary, "meetingattendees", "attendees") as? [Any]) ?? [] {
            let email = string(field(attendee, "email"))
            if let email { emails.insert(email.lowercased()) }
            if let name = string(field(attendee, "displayname", "name")) ?? email { names.append(name) }
        }
        // Fireflies sometimes keeps every address in one comma-separated string.
        let addresses = ((field(dictionary, "participants") as? [Any]) ?? [field(dictionary, "participants") as Any])
            .compactMap { string($0) }
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) } }
        for address in addresses where !address.isEmpty && !emails.contains(address.lowercased()) {
            names.append(address)
        }
        piece.participants = uniqueNames(names)

        var minutes = number(field(dictionary, "duration"))
        if minutes == nil, let seconds = number(field(dictionary, "durationseconds", "durationsec")) { minutes = seconds / 60 }
        let content = field(dictionary, "sentences", "transcript", "segments", "utterances", "lines", "entries", "captions")
        if let list = content as? [Any] {
            piece.lines = sentenceLines(list, speakers: speakers, duration: minutes.map { $0 * 60 })
        } else if let text = string(content) {
            piece.lines = transcriptLines(text.components(separatedBy: "\n"))
        }
        if let minutes {
            // The API counts minutes. A file that counted seconds gives about
            // the transcript's own length, which as minutes would be far too long.
            let lastTime = piece.lines.compactMap { $0.end ?? $0.start }.max() ?? 0
            let countsSeconds = lastTime > 60 && (lastTime * 0.5...lastTime * 2).contains(minutes)
            piece.duration = countsSeconds ? minutes : minutes * 60
        }

        let summaryValue = field(dictionary, "summary", "aisummary", "ainotes", "notes")
        if let summary = summaryValue as? [String: Any] {
            (piece.notes, piece.actions) = summaryNotes(summary)
        } else if let text = string(summaryValue) {
            let document = textDocument(text, role: .summary)
            piece.notes = document.notes
            piece.actions = document.actions
        }
        // A summary download may keep its fields at the top level.
        let topLevel = summaryNotes(dictionary)
        if piece.notes == nil { piece.notes = topLevel.notes }
        if piece.actions.isEmpty { piece.actions = topLevel.actions }
        return piece
    }

    /// Fireflies' summary fields as Markdown, in the order its meeting page
    /// shows them, and its action items. Action items stay out of the notes;
    /// the writer lists them after.
    private static func summaryNotes(_ summary: [String: Any]) -> (notes: String?, actions: [ExternalMeeting.ActionItem]) {
        var sections: [String] = []
        func add(_ heading: String, _ value: Any?) {
            guard let body = markdownBody(value) else { return }
            sections.append("## \(heading)\n\n\(body)")
        }
        add("Overview", field(summary, "overview") ?? field(summary, "shortsummary") ?? field(summary, "gist")
            ?? field(summary, "shortoverview") ?? (field(summary, "summary") as? String))
        let shorthand = field(summary, "shorthandbullet")
        let detailed = field(summary, "notes", "detailednotes") as? String
        add("Notes", shorthand ?? detailed)
        if shorthand != nil { add("Detailed notes", detailed) }
        if shorthand == nil && detailed == nil { add("Highlights", field(summary, "bulletgist")) }
        add("Outline", field(summary, "outline"))
        add("Topics", field(summary, "topicsdiscussed", "topics"))
        for case let section as [String: Any] in (field(summary, "extendedsections") as? [Any]) ?? [] {
            add(string(field(section, "title", "heading", "name")) ?? "More", field(section, "content", "text", "body"))
        }
        if let keywords = field(summary, "keywords") {
            let list = (keywords as? [Any])?.compactMap { string($0) }.joined(separator: ", ") ?? string(keywords) ?? ""
            if !list.isEmpty { sections.append("**Keywords:** \(list)") }
        }
        let notes = sections.joined(separator: "\n\n")
        return (notes.isEmpty ? nil : notes, actionItems(field(summary, "actionitems", "actions", "nextsteps")))
    }

    private static func markdownBody(_ value: Any?) -> String? {
        if let text = string(value) { return text }
        guard let list = value as? [Any] else { return nil }
        let items = list.compactMap { item -> String? in
            if let dictionary = item as? [String: Any] {
                return string(field(dictionary, "text", "content", "title", "name"))
            }
            return string(item)
        }
        return items.isEmpty ? nil : items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func actionItems(_ value: Any?) -> [ExternalMeeting.ActionItem] {
        if let text = string(value) { return actionItems(fromText: text) }
        guard let list = value as? [Any] else { return [] }
        return list.flatMap { item -> [ExternalMeeting.ActionItem] in
            if let dictionary = item as? [String: Any] {
                guard let text = string(field(dictionary, "text", "task", "title", "content", "description")) else { return [] }
                let owner = string(field(dictionary, "owner", "assignee", "assignedto", "speaker", "name"))
                return [.init(text: stripActionDecoration(text), owner: owner.flatMap(ownerName))]
            }
            return string(item).map(actionItems(fromText:)) ?? []
        }
    }

    /// Fireflies writes action items as lines grouped under each owner's
    /// name in bold, each ending with when it was said: "**Ana**\nSend the
    /// deck (03:12)".
    private static func actionItems(fromText text: String) -> [ExternalMeeting.ActionItem] {
        var owner: String?
        var items: [ExternalMeeting.ActionItem] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isBranding(line) else { continue }
            if let heading = headingText(line) {
                if sectionKind(heading) == nil, isNameLike(heading) { owner = ownerName(heading) }
                continue
            }
            let isBold = line.hasPrefix("**") && (line.hasSuffix("**") || line.hasSuffix("**:"))
            let hasBullet = line.range(of: "^([-*•‣◦+]|\\d{1,3}[.)])\\s", options: .regularExpression) != nil
            var plain = stripActionDecoration(line)
            if plain.hasSuffix(":"), isBold || !hasBullet, isNameLike(String(plain.dropLast())) {
                plain = String(plain.dropLast())
                if sectionKind(plain) == nil { owner = ownerName(plain) }
                continue
            }
            if isBold, !hasBullet, isNameLike(plain) {
                if sectionKind(plain) == nil { owner = ownerName(plain) }
                continue
            }
            guard !plain.isEmpty, sectionKind(plain) != .actions else { continue }
            items.append(.init(text: plain, owner: owner))
        }
        return items
    }

    /// An item without its bullet, checkbox, bold, or trailing "(03:12)".
    private static func stripActionDecoration(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: "^([-*•‣◦+]|\\d{1,3}[.)])\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "^\\[[ xX]?\\]\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(
            of: "\\s*[(\\[]\\s*\\d{1,2}:\\d{2}(:\\d{2})?(\\s*[-–,]\\s*\\d{1,2}:\\d{2}(:\\d{2})?)*\\s*[)\\]]\\s*$", with: "",
            options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func ownerName(_ name: String) -> String? {
        let cleaned = collapseSpaces(name.replacingOccurrences(of: "**", with: ""))
        return ["", "unassigned", "everyone", "all", "team", "general", "other", "others"].contains(cleaned.lowercased())
            ? nil : cleaned
    }

    /// Sentences as transcript lines, joined into turns the way subtitle
    /// cues are, so a meeting reads the same from JSON or SRT.
    private static func sentenceLines(_ list: [Any], speakers: [String: String], duration: TimeInterval?) -> [ExternalMeeting.Line] {
        var lines: [ExternalMeeting.Line] = []
        var inMilliseconds = false
        var namedMilliseconds = false
        for item in list {
            if let text = string(item) {
                let split = ExternalImportText.splitSpeaker(text)
                lines.append(.init(speaker: split.speaker, text: split.text))
                continue
            }
            guard let sentence = item as? [String: Any],
                  let text = string(field(sentence, "text", "rawtext", "sentence", "content", "words", "transcript", "caption"))
            else { continue }
            var speaker: String?
            let named = field(sentence, "speakername", "speaker", "name", "speakerlabel")
            if let nested = named as? [String: Any] {
                speaker = string(field(nested, "name", "displayname"))
            } else if !(named is NSNumber) {
                speaker = string(named)
            }
            if speaker == nil, let id = string(field(sentence, "speakerid") ?? (named as? NSNumber)) {
                speaker = speakers[id] ?? "Speaker \(id)"
            }
            var start = time(field(sentence, "starttime", "start", "time", "timestamp", "startseconds", "offset"))
            var end = time(field(sentence, "endtime", "end", "endseconds"))
            if let milliseconds = time(field(sentence, "startms", "starttimems", "startmilliseconds")) {
                start = milliseconds / 1_000
                end = time(field(sentence, "endms", "endtimems", "endmilliseconds")).map { $0 / 1_000 } ?? end
                namedMilliseconds = true
            }
            lines.append(.init(start: start, end: end, speaker: speaker, text: text))
        }
        // Times in milliseconds would put the meeting's end many times past
        // its length, or days away when the file doesn't say its length.
        let latest = lines.compactMap { $0.end ?? $0.start }.max() ?? 0
        if let duration, duration > 0 {
            inMilliseconds = latest > max(duration * 20, 1_000)
        } else {
            inMilliseconds = latest > 86_400
        }
        if inMilliseconds, !namedMilliseconds {
            lines = lines.map { line in
                var scaled = line
                scaled.start = line.start.map { $0 / 1_000 }
                scaled.end = line.end.map { $0 / 1_000 }
                return scaled
            }
        }
        return turns(lines.filter { !isBranding($0.text) || $0.speaker != nil })
    }

    private static func turns(_ lines: [ExternalMeeting.Line]) -> [ExternalMeeting.Line] {
        var result: [ExternalMeeting.Line] = []
        for line in lines {
            if var last = result.last, last.speaker == line.speaker, last.text.count + line.text.count < 600 {
                let close: Bool
                if let start = line.start, let previous = last.end ?? last.start {
                    close = start - previous < 1.5
                } else {
                    close = line.start == nil && last.start == nil
                }
                if close {
                    last.text += " " + line.text
                    last.end = line.end
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(line)
        }
        return result
    }

    /// A value under any of `names`, matching keys without regard to case,
    /// underscores, or spaces: "speakername" finds "speaker_name".
    private static func field(_ dictionary: [String: Any], _ names: String...) -> Any? {
        for name in names {
            if let value = dictionary[name], !(value is NSNull) { return value }
        }
        var compact: [String: Any] = [:]
        for (candidate, value) in dictionary where !(value is NSNull) {
            let name = key(candidate).replacingOccurrences(of: " ", with: "")
            if compact[name] == nil { compact[name] = value }
        }
        for name in names {
            if let value = compact[name] { return value }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Seconds from a number or from "62.5" or "00:01:02.5".
    private static func time(_ value: Any?) -> TimeInterval? {
        if let seconds = number(value), seconds >= 0 { return seconds }
        guard let text = value as? String else { return nil }
        return ExternalImportText.timestamp(text)
    }

    /// The API's `date` counts milliseconds since 1970; other files may
    /// count seconds or write ISO 8601.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String, let parsed = ExternalImportText.date(text) ?? looseDate(text) { return parsed }
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
    }

    private static func looseDate(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: " at ", with: " ").replacingOccurrences(of: ",", with: " ")
        text = text.replacingOccurrences(of: "(\\d)(st|nd|rd|th)\\b", with: "$1", options: .regularExpression)
        text = collapseSpaces(text)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["EEE MMM d yyyy h:mm a", "EEE MMM d yyyy HH:mm", "EEE MMM d yyyy", "EEEE MMMM d yyyy h:mm a",
                       "EEEE MMMM d yyyy", "MMM d yyyy h:mm a", "MMM d yyyy HH:mm", "MMM d yyyy", "MMMM d yyyy h:mm a",
                       "MMMM d yyyy HH:mm", "MMMM d yyyy", "d MMM yyyy HH:mm", "d MMM yyyy", "d MMMM yyyy",
                       "MM/dd/yyyy h:mm a", "MM/dd/yyyy HH:mm", "MM/dd/yyyy", "yyyy-MM-dd HH:mm", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) { return parsed }
        }
        return nil
    }

    // MARK: - CSV

    private static func tablePiece(_ url: URL, text: String) -> Piece {
        var piece = Piece(file: url)
        let header = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let rows = delimitedRows(text, delimiter: delimiter(for: url, header: header))
        guard let first = rows.first, let columns = tableColumns(first) else { return piece }
        var lines: [ExternalMeeting.Line] = []
        for row in rows.dropFirst() {
            guard columns.text < row.count else { continue }
            let text = row[columns.text].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            func cell(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            var start = cell(columns.start).flatMap(time)
            var end = cell(columns.end).flatMap(time)
            if columns.inMilliseconds {
                start = start.map { $0 / 1_000 }
                end = end.map { $0 / 1_000 }
            }
            lines.append(.init(start: start, end: end, speaker: cell(columns.speaker), text: text))
        }
        piece.lines = turns(lines.filter { !isBranding($0.text) || $0.speaker != nil })
        piece.id = viewID(in: text)
        return piece
    }

    private static func delimiter(for url: URL, header: String) -> Character {
        if url.pathExtension.lowercased() == "tsv" { return "\t" }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { candidate in (candidate, header.filter { $0 == candidate }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// Which columns hold the speaker, text, and times, from the header.
    private static func tableColumns(_ header: [String]) -> (speaker: Int?, text: Int, start: Int?, end: Int?, inMilliseconds: Bool)? {
        let names = header.map { key($0).replacingOccurrences(of: " ", with: "") }
        func exact(_ options: [String]) -> Int? { names.firstIndex(where: options.contains) }
        func containing(_ part: String, unless other: String = "\u{0}") -> Int? {
            names.firstIndex { $0.contains(part) && !$0.contains(other) }
        }
        let textOptions = ["text", "sentence", "sentences", "transcript", "content", "words", "utterance", "dialogue",
                           "message", "rawtext", "caption", "speech"]
        guard let text = exact(textOptions) ?? containing("sentence") ?? containing("text") else { return nil }
        let speaker = exact(["speaker", "speakername", "name", "speakerlabel", "participant", "who"]) ?? containing("speaker")
        let start = exact(["start", "starttime", "time", "timestamp", "startseconds", "startsec", "begin", "startms", "starttimems"])
            ?? containing("start") ?? containing("time", unless: "end")
        let end = exact(["end", "endtime", "endseconds", "endsec", "endms", "endtimems"]) ?? containing("end")
        guard speaker != nil || start != nil else { return nil }
        let inMilliseconds = start.map { names[$0].hasSuffix("ms") || names[$0].contains("millis") } ?? false
        return (speaker, text, start, end == start ? nil : end, inMilliseconds)
    }

    /// RFC 4180 rows: quoted fields may hold the delimiter, quotes ("") and
    /// line breaks.
    private static func delimitedRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: row.append(field); field = ""
            case "\n":
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            default: field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: - Markdown and text

    private enum Role { case transcript, summary, unknown }

    private enum SectionKind { case notes, actions, transcript }

    /// What a text download says: a title and details at the top, then
    /// summary sections, action items, and the transcript, in any order.
    private struct TextDocument {
        var title: String?
        var startedAt: Date?
        var duration: TimeInterval?
        var participants: [String] = []
        var lines: [ExternalMeeting.Line] = []
        var notes: String?
        var actions: [ExternalMeeting.ActionItem] = []
    }

    private static func textPiece(_ url: URL, text: String) -> Piece {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let role: Role = stem.contains("transcript") || stem.contains("caption") ? .transcript
            : stem.contains("summary") || stem.contains("notes") ? .summary : .unknown
        let document = textDocument(text, role: role)
        var piece = Piece(file: url)
        piece.id = viewID(in: text)
        piece.title = document.title
        piece.startedAt = document.startedAt
        piece.duration = document.duration
        piece.participants = document.participants
        piece.lines = document.lines
        piece.notes = document.notes
        piece.actions = document.actions
        return piece
    }

    private static func textDocument(_ text: String, role: Role) -> TextDocument {
        var document = TextDocument()
        var sections: [(kind: SectionKind?, rows: [String])] = [(nil, [])]
        var dateText: String?
        var timeText: String?
        for row in text.components(separatedBy: "\n") {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if let heading = headingText(trimmed) {
                let kind = sectionKind(heading)
                if kind == nil, trimmed.hasPrefix("# "), document.title == nil, sections.count == 1 {
                    document.title = heading
                } else if kind != nil || trimmed.hasPrefix("#") {
                    // Notes keep their headings; a transcript's isn't a line.
                    sections.append((kind ?? .notes, kind == .transcript ? [] : [row]))
                } else {
                    sections[sections.count - 1].rows.append(row)
                }
                continue
            }
            if let lead = sectionLead(trimmed), let kind = sectionKind(lead) {
                // "Action items: Send the deck" starts a section on one line.
                let rest = trimmed.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                sections.append((kind, kind == .notes ? [row] : [rest]))
                continue
            }
            if sections.count == 1, let detail = metadata(trimmed) {
                switch detail.key {
                case "title", "meeting title", "meeting":
                    if document.title == nil, !detail.value.contains("://") { document.title = detail.value }
                case "date", "meeting date", "date time", "date and time", "created", "created at", "started", "start":
                    dateText = detail.value
                case "time":
                    timeText = detail.value
                case "participants", "attendees", "speakers":
                    document.participants = uniqueNames(detail.value.split(whereSeparator: { $0 == "," || $0 == ";" })
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                case "duration":
                    document.duration = durationValue(detail.value)
                default:
                    break
                }
                continue
            }
            sections[sections.count - 1].rows.append(row)
        }
        if let dateText {
            document.startedAt = timeText.flatMap { looseDate(dateText + " " + $0) } ?? date(dateText)
        }

        // The part before any heading: a transcript when most of it is
        // spoken lines, else notes.
        let preamble = sections[0].rows
        let preambleKind: SectionKind
        switch role {
        case .transcript: preambleKind = .transcript
        case .summary: preambleKind = .notes
        case .unknown: preambleKind = isTranscript(preamble) ? .transcript : .notes
        }
        sections[0].kind = preambleKind

        var noteRows: [String] = []
        var transcriptRows: [String] = []
        var actionRows: [String] = []
        for section in sections {
            switch section.kind ?? .notes {
            case .transcript:
                transcriptRows += section.rows
            case .actions:
                actionRows += section.rows
                noteRows += section.rows
            case .notes:
                noteRows += section.rows
            }
        }
        document.lines = transcriptLines(transcriptRows)
        document.actions = actionItems(fromText: actionRows.joined(separator: "\n"))
        let notes = noteRows.filter { !isBranding($0) }.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        document.notes = notes.isEmpty ? nil : notes
        return document
    }

    private static func isTranscript(_ rows: [String]) -> Bool {
        let tokens = rows.map(classify)
        let labeled = tokens.filter(\.isLabeled).count
        let filled = tokens.filter { !$0.isBlank }.count
        return labeled >= 2 && labeled * 10 >= filled * 3
    }

    /// The text of a Markdown heading, a line in bold, or a line that is only
    /// a known section name such as "Action Items:".
    private static func headingText(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(hashes)
            guard hashes <= 6, rest.first == " " else { return nil }
            let text = cleanHeading(String(rest))
            return text.isEmpty ? nil : text
        }
        if line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 {
            let text = cleanHeading(line)
            return sectionKind(text) == nil || text.contains("**") ? nil : text
        }
        let text = cleanHeading(line)
        return line.count <= 40 && sectionKind(text) != nil ? text : nil
    }

    private static func cleanHeading(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix("#") || cleaned.hasSuffix(":") { cleaned.removeLast() }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// The name before the colon of "Overview: …".
    private static func sectionLead(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let lead = cleanHeading(String(line[..<colon]))
        return lead.count <= 30 ? lead : nil
    }

    private static func sectionKind(_ heading: String) -> SectionKind? {
        switch key(heading) {
        case "action items", "action item", "next steps", "tasks", "follow ups", "todo", "to do", "to dos", "todos":
            return .actions
        case "transcript", "full transcript", "meeting transcript", "transcription":
            return .transcript
        case "overview", "summary", "meeting summary", "short summary", "gist", "notes", "meeting notes", "ai notes",
             "detailed notes", "shorthand bullet", "shorthand notes", "bullet gist", "outline", "keywords", "topics",
             "topics discussed", "highlights", "key points", "key takeaways", "takeaways", "decisions", "chapters":
            return .notes
        default:
            return nil
        }
    }

    private static func metadata(_ line: String) -> (key: String, value: String)? {
        let cleaned = line.replacingOccurrences(of: "**", with: "")
        guard let colon = cleaned.firstIndex(of: ":") else { return nil }
        let name = key(String(cleaned[..<colon]))
        let value = cleaned[cleaned.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let known = ["title", "meeting title", "meeting", "date", "meeting date", "date time", "date and time", "created",
                     "created at", "started", "start", "time", "participants", "attendees", "speakers", "duration",
                     "organizer", "host", "link", "meeting link", "transcript link", "url", "view transcript",
                     "view in fireflies", "recording"]
        return known.contains(name) && !value.isEmpty ? (name, value) : nil
    }

    /// "00:32:10", "32 min", or "1h 5m" in seconds.
    private static func durationValue(_ value: String) -> TimeInterval? {
        if let seconds = ExternalImportText.timestamp(value) { return seconds }
        var total: TimeInterval = 0
        var found = false
        let pattern = "(\\d+(?:\\.\\d+)?)\\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)\\b"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: value), let unitRange = Range(match.range(at: 2), in: value),
                  let amount = Double(value[numberRange]) else { continue }
            let unit = value[unitRange].lowercased()
            total += amount * (unit.hasPrefix("h") ? 3_600 : unit.hasPrefix("m") ? 60 : 1)
            found = true
        }
        return found ? total : nil
    }

    // MARK: - Text transcripts

    /// One row of a text transcript.
    private enum Row {
        case blank
        /// A time on its own line, for the line below it.
        case time(TimeInterval)
        /// A speaker, and maybe a time, above what they said. `firm` when the
        /// row can't be anything else ("**Ana**", "Ana:", "Ana (00:01)").
        case header(speaker: String, start: TimeInterval?, firm: Bool)
        case spoken(speaker: String?, start: TimeInterval?, text: String)
        case text(String)

        var isBlank: Bool {
            if case .blank = self { return true }
            return false
        }

        var isLabeled: Bool {
            switch self {
            case .header: true
            case .spoken(let speaker, let start, _): speaker != nil || start != nil
            default: false
            }
        }
    }

    private static let timePattern = "(\\d{1,2}:\\d{2}(?::\\d{2})?(?:[.,]\\d+)?)"
    private static let leadingTime = try? NSRegularExpression(
        pattern: "^[\\[(]?\(timePattern)[\\])]?\\s*(?:[-–—|:]\\s*)?(.*)$")
    private static let trailingTime = try? NSRegularExpression(
        pattern: "^(.+?)\\s*([-–—|·])?\\s*([\\[(])?\(timePattern)([\\])])?\\s*(:)?\\s*(.*)$")

    private static func captures(_ expression: NSRegularExpression?, in text: String) -> [String?]? {
        guard let expression,
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func classify(_ raw: String) -> Row {
        var line = raw.trimmingCharacters(in: .whitespaces)
        line = line.replacingOccurrences(of: "^(?:[-*•>]\\s+)+", with: "", options: .regularExpression)
        guard !line.isEmpty, !isBranding(line) else { return .blank }
        let isBold = line.hasPrefix("**") || line.hasPrefix("__")
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .blank }

        if let parts = captures(leadingTime, in: line), let stamp = parts[0], let seconds = ExternalImportText.timestamp(stamp) {
            let rest = (parts[1] ?? "").trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .time(seconds) }
            let split = ExternalImportText.splitSpeaker(rest)
            if let speaker = split.speaker, sectionKind(speaker) == nil {
                return .spoken(speaker: speaker, start: seconds, text: split.text)
            }
            if rest.hasSuffix(":"), isNameLike(String(rest.dropLast())) {
                return .header(speaker: String(rest.dropLast()), start: seconds, firm: true)
            }
            if isNameLike(rest) { return .header(speaker: rest, start: seconds, firm: isBold) }
            return .spoken(speaker: nil, start: seconds, text: rest)
        }
        if let parts = captures(trailingTime, in: line), let name = parts[0], isNameLike(name),
           let stamp = parts[3], let seconds = ExternalImportText.timestamp(stamp) {
            let bracketed = parts[2] != nil && parts[4] != nil
            let rest = (parts[6] ?? "").trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .header(speaker: name, start: seconds, firm: bracketed || isBold || parts[1] != nil) }
            if bracketed || parts[5] != nil { return .spoken(speaker: name, start: seconds, text: rest) }
        }
        if line.hasSuffix(":"), isNameLike(String(line.dropLast())), sectionKind(String(line.dropLast())) == nil {
            return .header(speaker: String(line.dropLast()), start: nil, firm: true)
        }
        let split = ExternalImportText.splitSpeaker(line)
        if let speaker = split.speaker, sectionKind(speaker) == nil, metadata(line) == nil {
            return .spoken(speaker: speaker, start: nil, text: split.text)
        }
        if isBold, isNameLike(line) { return .header(speaker: line, start: nil, firm: true) }
        return .text(line)
    }

    /// Lines from a text transcript in any of the layouts Fireflies and
    /// other tools write: "[00:01:02] Ana: …", "Ana (00:01): …", "Ana: …",
    /// or the speaker and time on a line above what they said.
    private static func transcriptLines(_ rows: [String]) -> [ExternalMeeting.Line] {
        let tokens = rows.map(classify)
        let labeled = tokens.contains { $0.isLabeled }
        var lines: [ExternalMeeting.Line] = []
        var header: (speaker: String?, start: TimeInterval?)?
        var pendingTime: TimeInterval?
        var speakerInEffect: String?
        var canContinue = false

        func add(_ speaker: String?, _ start: TimeInterval?, _ text: String) {
            lines.append(.init(start: start, speaker: speaker, text: text))
            header = nil
            pendingTime = nil
            canContinue = labeled
        }

        for (index, token) in tokens.enumerated() {
            switch token {
            case .blank:
                canContinue = false
            case .time(let seconds):
                if header != nil, header?.start == nil { header?.start = seconds } else { pendingTime = seconds }
                canContinue = false
            case .header(let speaker, let start, let firm):
                let next = tokens[(index + 1)...].first { !$0.isBlank }
                let headsText: Bool
                switch next {
                case .text?, .time?: headsText = true
                default: headsText = false
                }
                if firm || headsText {
                    header = (speaker, start ?? pendingTime)
                    pendingTime = nil
                    speakerInEffect = speaker
                    canContinue = false
                } else {
                    add(speakerInEffect, start ?? pendingTime, speaker)
                }
            case .spoken(let speaker, let start, let text):
                if let speaker { speakerInEffect = speaker }
                add(speaker ?? header?.speaker ?? speakerInEffect, start ?? header?.start ?? pendingTime, text)
            case .text(let text):
                if let current = header {
                    add(current.speaker, current.start ?? pendingTime, text)
                } else if canContinue, pendingTime == nil, !lines.isEmpty {
                    lines[lines.count - 1].text += " " + text
                } else {
                    add(labeled ? speakerInEffect : nil, pendingTime, text)
                }
            }
        }
        return lines
    }
}
