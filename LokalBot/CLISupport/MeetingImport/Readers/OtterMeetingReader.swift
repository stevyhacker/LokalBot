import Foundation

/// Reads Otter.ai conversations from what Otter's Export dialog gives: TXT,
/// DOCX, and SRT files, one at a time or many in a bulk export's ZIP, with
/// the MP3 its Audio toggle adds. Otter keeps nothing on this computer that
/// LokalBot can read, so it always needs an export. PDF exports aren't read.
///
/// A TXT turn is a header, the speaker's name, two spaces, and the time it
/// starts (`Ana Petrović  0:07`, `1:02:10` past the hour), then its words on
/// the next line and a blank line. An export made without the names or the
/// times leaves that part of the header out, and one made with neither is
/// paragraphs alone. The file closes with `Transcribed by https://otter.ai`
/// unless the branding is removed. Word and PDF exports open with the
/// title, the date and length (`Wed, Mar 4, 2026 10:15AM • 32:15`),
/// `SUMMARY KEYWORDS`, and `SPEAKERS`. An SRT names the speaker on the first
/// cue of each turn (`Ana: …`). Summary sections the dialog adds (Overview,
/// Action Items, Outline) are read by their headings wherever they stand.
///
/// Exports carry no conversation id, so a meeting's id hashes its file name
/// (without Otter's `_otter_ai` suffix or a browser's ` (1)`) and the words
/// of its transcript: the same conversation exported again, as TXT, DOCX, or
/// SRT, gets the same id.
enum OtterMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.otter
    static let exportHint = "In Otter, open the conversation, click the three dots, select Export, and choose TXT, DOCX, or SRT with Show speaker names and Show timestamps on (turn on Audio too to keep the recording). To export many at once on Business or Enterprise, select them in My Conversations, click Export, and choose the ZIP file Otter emails you."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "txt":
            if hasOtterSuffix(url) { return true }
            guard let peek = OtterPeek(url) else { return false }
            return OtterLayout.looksLikeExport(head: peek.head, tail: peek.tail)
        case "srt":
            if hasOtterSuffix(url) { return true }
            return OtterPeek(url)?.head.contains("-->") ?? false
        case "docx":
            return OtterPeek.startsAsZip(url)
        default:
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

    private static let transcriptExtensions: Set<String> = ["txt", "docx", "srt"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav"]
    private static let pdfReason = "Otter's PDF export can't be read. Export the conversation as TXT, DOCX, or SRT instead."

    /// The files of one conversation: its exports in different formats and
    /// the recording that came with them.
    private struct Group {
        var key: String
        var files: [URL]
        var audio: URL?

        var folder: String { files.first?.deletingLastPathComponent().standardizedFileURL.path ?? "" }
    }

    /// One file the person chose. A transcript takes the recording named
    /// like it from its folder; a recording chosen on its own reads the
    /// transcripts named like it, so choosing both gives one meeting.
    private static func readFile(_ url: URL) throws -> ExternalImportScan {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { throw ExternalImportError.unreadable(url.lastPathComponent, pdfReason) }
        let siblings = ExternalImportText.files(in: url.deletingLastPathComponent(), recursive: false)
            .filter { $0.standardizedFileURL != url.standardizedFileURL && groupKey($0) == groupKey(url) }
        if transcriptExtensions.contains(ext) {
            let audio = siblings.first { audioExtensions.contains($0.pathExtension.lowercased()) }
            return try readGroup(Group(key: groupKey(url), files: [url], audio: audio), direct: true)
        }
        if audioExtensions.contains(ext) {
            let transcripts = siblings.filter { transcriptExtensions.contains($0.pathExtension.lowercased()) && recognizes($0) }
            guard !transcripts.isEmpty else { throw ExternalImportError.unrecognized(source, url.path) }
            return try readGroup(Group(key: groupKey(url), files: transcripts, audio: url), direct: true)
        }
        throw ExternalImportError.unrecognized(source, url.path)
    }

    /// A folder, such as an unpacked bulk export: every Otter file in it,
    /// grouped by conversation.
    private static func readFolder(_ folder: URL) throws -> ExternalImportScan {
        var groups: [Group] = []
        var index: [String: Int] = [:]
        var audio: [URL] = []
        var pdfs: [URL] = []
        for file in ExternalImportText.files(in: folder) {
            let ext = file.pathExtension.lowercased()
            if transcriptExtensions.contains(ext) {
                guard recognizes(file) else { continue }
                var key = groupKey(file)
                // Two files of one format are two conversations whose names
                // only differ in punctuation.
                if let at = index[key], groups[at].files.contains(where: { $0.pathExtension.lowercased() == ext }) {
                    key += "\u{1F}" + file.lastPathComponent
                }
                if let at = index[key] {
                    groups[at].files.append(file)
                } else {
                    index[key] = groups.count
                    groups.append(Group(key: key, files: [file]))
                }
            } else if audioExtensions.contains(ext) {
                audio.append(file)
            } else if ext == "pdf" {
                pdfs.append(file)
            }
        }

        var unpaired: [URL] = []
        for file in audio {
            if let at = index[groupKey(file)], groups[at].audio == nil {
                groups[at].audio = file
            } else {
                unpaired.append(file)
            }
        }
        // One transcript and one recording alone in a folder belong
        // together even when Otter named them apart.
        for file in unpaired {
            let folderPath = file.deletingLastPathComponent().standardizedFileURL.path
            let inFolder = groups.indices.filter { groups[$0].folder == folderPath }
            let recordings = audio.filter { $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }
            if inFolder.count == 1, recordings.count == 1, groups[inFolder[0]].audio == nil {
                groups[inFolder[0]].audio = file
            }
        }

        var scan = ExternalImportScan()
        for group in groups {
            scan.append(try readGroup(group, direct: false))
        }
        let transcriptKeys = Set(groups.flatMap { $0.files.map(groupKey) })
        for pdf in pdfs where !transcriptKeys.contains(groupKey(pdf)) && (hasOtterSuffix(pdf) || groups.isEmpty) {
            scan.problems.append(.init(path: pdf.path, reason: pdfReason))
        }
        if scan.meetings.isEmpty && scan.problems.isEmpty {
            throw ExternalImportError.unrecognized(source, folder.path)
        }
        return scan
    }

    /// Reads a conversation's files into one meeting. When the person chose
    /// the file itself, a file that can't be read throws; in a folder it
    /// becomes a problem and the rest is still read.
    private static func readGroup(_ group: Group, direct: Bool) throws -> ExternalImportScan {
        var scan = ExternalImportScan()
        var exports: [(url: URL, export: OtterExport)] = []
        for file in group.files {
            do {
                let export = try OtterExport.read(file)
                // Any Word file in a folder passes `recognizes`; only one
                // laid out like Otter's is read.
                if !direct, file.pathExtension.lowercased() == "docx", !export.hasOtterMarks { continue }
                exports.append((file, export))
            } catch {
                let reason = (error as? OtterReadError)?.reason ?? "it couldn't be opened"
                if direct { throw ExternalImportError.unreadable(file.lastPathComponent, reason) }
                scan.problems.append(.init(path: file.path, reason: reason))
            }
        }
        guard !exports.isEmpty else { return scan }
        let meeting = merge(exports, audio: group.audio)
        if meeting.isEmpty {
            let file = exports[0].url
            let reason = "it holds no transcript or notes"
            if direct { throw ExternalImportError.unreadable(file.lastPathComponent, reason) }
            scan.problems.append(.init(path: file.path, reason: reason))
        } else {
            scan.meetings.append(meeting)
        }
        return scan
    }

    // MARK: - One meeting from a conversation's exports

    private static func merge(_ exports: [(url: URL, export: OtterExport)], audio: URL?) -> ExternalMeeting {
        let ordered = exports.sorted { formatRank($0.url) < formatRank($1.url) }
        // The transcript that says the most: speakers, then times. TXT
        // wins a tie, since its turns are whole paragraphs.
        var chosen = ordered[0]
        for item in ordered.dropFirst() where transcriptScore(item.export) > transcriptScore(chosen.export) {
            chosen = item
        }
        let lines = chosen.export.lines
        let notes = ordered.lazy.compactMap(\.export.notesMarkdown).first
        let startedAt = ordered.lazy.compactMap(\.export.startedAt).first
        let duration = ordered.lazy.compactMap(\.export.duration).first
        let actionItems = ordered.first { !$0.export.actionItems.isEmpty }?.export.actionItems ?? []

        var seen = Set<String>()
        var participants: [String] = []
        for name in ordered.flatMap(\.export.speakers) + lines.compactMap(\.speaker) {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !OtterSpeakers.isGeneric(cleaned), seen.insert(cleaned.lowercased()).inserted else { continue }
            participants.append(cleaned)
        }

        let titleKey = normalized(baseName(chosen.url, droppingCopyNumber: true))
        let words = normalized(lines.map(\.text).joined(separator: " "))
        let sourceID: String
        if words.isEmpty {
            let start = startedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            sourceID = ExternalImportText.stableID("otter-notes", titleKey, start, normalized(notes ?? ""))
        } else {
            sourceID = ExternalImportText.stableID("otter-transcript", titleKey, words)
        }

        return ExternalMeeting(
            source: source, sourceID: sourceID,
            title: ordered.lazy.compactMap(\.export.title).first ?? displayTitle(chosen.url),
            startedAt: startedAt, duration: duration, participants: participants, lines: lines,
            notes: notes, actionItems: actionItems, audioURL: audio, origin: chosen.url)
    }

    private static func formatRank(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "txt": 0
        case "docx": 1
        default: 2
        }
    }

    private static func transcriptScore(_ export: OtterExport) -> Int {
        guard !export.lines.isEmpty else { return -1 }
        return (export.lines.contains { $0.speaker != nil } ? 2 : 0) + (export.lines.contains { $0.start != nil } ? 1 : 0)
    }

    // MARK: - Names

    /// Otter names a download after the conversation, sometimes with
    /// `_otter_ai` or `_otter.ai` after it.
    private static func hasOtterSuffix(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        return name.range(of: #"(^|[ ._-])otter[._]ai$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func baseName(_ url: URL, droppingCopyNumber: Bool) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if droppingCopyNumber {
            name = name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        }
        return name.replacingOccurrences(of: #"(^|[ ._-])otter[._]ai$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Files of one conversation share a folder and a name.
    private static func groupKey(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path + "\u{1F}" + normalized(baseName(url, droppingCopyNumber: false))
    }

    private static func displayTitle(_ url: URL) -> String {
        let title = baseName(url, droppingCopyNumber: true).replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Otter conversation" : title
    }

    /// Lower-case words without punctuation, so the same words written by
    /// different formats compare equal.
    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - What one export file holds

/// Why a file couldn't be read, in words that never quote it.
private struct OtterReadError: Error {
    var reason: String
}

private struct OtterSection {
    enum Kind: Equatable {
        case notes(String)
        case actionItems
    }

    var kind: Kind
    var rows: [String] = []
}

private struct OtterExport {
    var title: String?
    var startedAt: Date?
    var duration: TimeInterval?
    /// The `SPEAKERS` list of a Word or PDF export's opening.
    var speakers: [String] = []
    var keywords: String?
    var sections: [OtterSection] = []
    /// Text before the transcript that no heading claims.
    var otherNotes: [String] = []
    var lines: [ExternalMeeting.Line] = []
    /// Otter's closing line, its turn headers, or its opening block.
    var hasOtterMarks = false

    static func read(_ url: URL) throws -> OtterExport {
        switch url.pathExtension.lowercased() {
        case "srt":
            var export = OtterExport()
            export.lines = OtterSubRip.lines(try text(url))
            export.duration = export.lines.compactMap(\.end).max()
            export.hasOtterMarks = true
            return export
        case "docx":
            return OtterLayout.parse(try OtterDocx.text(url))
        default:
            return OtterLayout.parse(try text(url))
        }
    }

    private static func text(_ url: URL) throws -> String {
        do {
            return try ExternalImportText.readText(url)
        } catch {
            throw OtterReadError(reason: "it couldn't be opened")
        }
    }

    var notesMarkdown: String? {
        var parts: [String] = []
        if !otherNotes.isEmpty { parts.append(otherNotes.joined(separator: "\n\n")) }
        for section in sections {
            guard case .notes(let name) = section.kind else { continue }
            let body = Self.markdownBody(section.rows)
            if !body.isEmpty { parts.append("## \(name)\n\n\(body)") }
        }
        if let keywords, !keywords.isEmpty { parts.append("**Keywords:** \(keywords)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var actionItems: [ExternalMeeting.ActionItem] {
        sections.filter { $0.kind == .actionItems }.flatMap { OtterActionItems.parse($0.rows) }
    }

    /// A section's rows as Markdown: Otter's round bullets become list items
    /// and runs of blank rows one paragraph break.
    private static func markdownBody(_ rows: [String]) -> String {
        var out: [String] = []
        for row in rows {
            if row.isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
                continue
            }
            var line = row
            for bullet in ["• ", "◦ ", "▪ ", "· "] where line.hasPrefix(bullet) {
                line = "- " + line.dropFirst(bullet.count)
            }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

// MARK: - TXT and DOCX layout

/// Reads Otter's text layout: an optional opening block (title, date,
/// keywords, speakers, summary sections), then turns under headers.
private enum OtterLayout {
    private enum Mode {
        /// Headers with times: `Ana  0:07`, or `Unknown 0:00` for a name
        /// Otter's opening lists or a label of its own.
        case named
        /// `0:07` alone: exported without speaker names.
        case times
        /// `Ana  ` alone: exported without timestamps.
        case names
        /// Paragraphs alone.
        case paragraphs
    }

    private struct Header {
        enum Kind { case wide, known, time, name }

        var kind: Kind
        var speaker: String?
        var start: TimeInterval?
        /// Rows it takes: two when a name and its time stand on rows of
        /// their own, as a Word file can lay them out.
        var rows = 1
    }

    static func parse(_ text: String) -> OtterExport {
        var export = OtterExport()
        var rows = text.components(separatedBy: "\n")
        for index in rows.indices where isClosingLine(rows[index]) {
            rows[index] = ""
            export.hasOtterMarks = true
        }

        var known = Set(listedSpeakers(rows).map { $0.lowercased() })
        for row in rows {
            if let header = nameAndTime(row), header.wide, OtterSpeakers.nameLike(header.name) {
                known.insert(header.name.lowercased())
            }
        }
        let headerAt: (Int) -> Header? = { header(in: rows, at: $0, known: known) }

        // Pick the layout and where the transcript starts.
        var mode = Mode.paragraphs
        var bodyStart = 0
        var afterHeader = false
        for index in rows.indices {
            if isBlank(rows[index]) { continue }
            if let found = headerAt(index), found.kind == .wide || (found.kind == .known && found.start != nil && !afterHeader) {
                mode = .named
                bodyStart = index
                break
            }
            afterHeader = headerAt(index) != nil
        }
        if mode != .named {
            bodyStart = openingEnd(rows, headerAt: headerAt)
            if let first = rows[bodyStart...].firstIndex(where: { !isBlank($0) }), let found = headerAt(first) {
                switch found.kind {
                case .time: mode = .times
                case .name: mode = .names
                case .known: mode = found.start == nil ? .names : .times
                case .wide: mode = .named
                }
            }
        }

        export.readSections(rows[..<bodyStart], allowTitle: true)
        if mode != .paragraphs { export.hasOtterMarks = true }

        var turns: [(speaker: String?, start: TimeInterval?, words: [String])] = []
        var index = bodyStart
        var previousBlank = true
        afterHeader = false
        while index < rows.count {
            let row = rows[index]
            if isBlank(row) {
                previousBlank = true
                index += 1
                continue
            }
            if previousBlank, index > bodyStart, OtterHeading(row)?.endsTranscript == true {
                export.readSections(rows[index...], allowTitle: false)
                break
            }
            if mode != .paragraphs, let found = headerAt(index), accepts(found, mode: mode, afterHeader: afterHeader) {
                let speaker = found.speaker.flatMap { OtterSpeakers.name(stripInitial($0, known: known)) }
                turns.append((speaker, found.start, []))
                afterHeader = true
                previousBlank = false
                index += found.rows
                continue
            }
            let words = row.trimmingCharacters(in: .whitespaces)
            if mode == .paragraphs || turns.isEmpty {
                turns.append((nil, nil, [words]))
            } else {
                turns[turns.count - 1].words.append(words)
            }
            afterHeader = false
            previousBlank = false
            index += 1
        }

        export.lines = turns.compactMap { turn in
            let text = turn.words.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ExternalMeeting.Line(start: turn.start, speaker: turn.speaker, text: text)
        }
        return export
    }

    /// A quick look at a file's first and last bytes: Otter's closing
    /// line, its keyword heading, or turn headers with words under them.
    static func looksLikeExport(head: String, tail: String) -> Bool {
        if tail.range(of: "transcribed by https://otter.ai", options: .caseInsensitive) != nil { return true }
        let rows = head.components(separatedBy: "\n")
        if rows.contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "SUMMARY KEYWORDS" }) { return true }
        // The last row may be cut short, so it is never weighed.
        let worded = rows.indices.dropLast().filter { index in
            guard let header = nameAndTime(rows[index]), header.wide, OtterSpeakers.nameLike(header.name) else { return false }
            return !isBlank(rows[index + 1]) && nameAndTime(rows[index + 1]) == nil
        }
        let first = rows.firstIndex { !isBlank($0) }
        return worded.count >= 2 || (first != nil && worded.first == first)
    }

    private static func accepts(_ header: Header, mode: Mode, afterHeader: Bool) -> Bool {
        switch (mode, header.kind) {
        case (.named, .wide): true
        case (.named, .known): header.start != nil && !afterHeader
        case (.times, .time), (.times, .known): header.start != nil && !afterHeader
        case (.names, .name), (.names, .known): !afterHeader
        default: false
        }
    }

    private static func header(in rows: [String], at index: Int, known: Set<String>) -> Header? {
        let row = rows[index]
        guard !isBlank(row) else { return nil }
        let isKnown: (String) -> Bool = { name in
            known.contains(name.lowercased()) || OtterSpeakers.isGeneric(name)
                || known.contains(stripInitial(name, known: known).lowercased())
        }
        if let found = nameAndTime(row), OtterSpeakers.nameLike(found.name) {
            if found.wide { return Header(kind: .wide, speaker: found.name, start: found.start) }
            if isKnown(found.name) { return Header(kind: .known, speaker: found.name, start: found.start) }
        }
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        if isClock(trimmed), let start = ExternalImportText.timestamp(trimmed) {
            return Header(kind: .time, start: start)
        }
        if isKnown(trimmed), OtterSpeakers.nameLike(trimmed) {
            // A listed name with its time on the next row.
            if index + 1 < rows.count {
                let next = rows[index + 1].trimmingCharacters(in: .whitespaces)
                if isClock(next), let start = ExternalImportText.timestamp(next) {
                    return Header(kind: .known, speaker: trimmed, start: start, rows: 2)
                }
            }
            return Header(kind: .known, speaker: trimmed)
        }
        if OtterSpeakers.nameLike(trimmed), hasWideTrailingGap(row) {
            return Header(kind: .name, speaker: trimmed)
        }
        return nil
    }

    /// Where Otter's opening block ends, when a transcript without timed
    /// headers follows it: the title, the date, the keyword and speaker
    /// lists, and summary sections, each running to a blank row.
    private static func openingEnd(_ rows: [String], headerAt: (Int) -> Header?) -> Int {
        guard var index = rows.firstIndex(where: { !isBlank($0) }) else { return rows.count }
        let firstRow = index
        let nextFilled: (Int) -> Int? = { from in rows[from...].firstIndex { !isBlank($0) } }
        if OtterHeading(rows[index]) == nil, !OtterDate.isDateLine(rows[index]) {
            guard let next = nextFilled(index + 1),
                  OtterDate.isDateLine(rows[next]) || OtterHeading(rows[next]) != nil else { return firstRow }
            index = next
        }
        var sawMarker = false
        while let at = nextFilled(index) {
            index = at
            if OtterDate.isDateLine(rows[index]) {
                sawMarker = true
                index += 1
                continue
            }
            guard let heading = OtterHeading(rows[index]) else { break }
            sawMarker = true
            index += 1
            if heading == .transcript { break }
            var taken = 0
            while index < rows.count, !isBlank(rows[index]), OtterHeading(rows[index]) == nil, headerAt(index) == nil {
                // The keyword and speaker lists are one row each.
                if (heading == .keywords || heading == .speakers) && taken == 1 { break }
                index += 1
                taken += 1
            }
        }
        return sawMarker ? index : firstRow
    }

    /// The names under a `SPEAKERS` heading near the top.
    private static func listedSpeakers(_ rows: [String]) -> [String] {
        let top = rows.prefix(80)
        guard let heading = top.firstIndex(where: { OtterHeading($0) == .speakers }),
              let list = top[(heading + 1)...].first(where: { !isBlank($0) }) else { return [] }
        return OtterSpeakers.split(list)
    }

    /// "Ana Petrović  0:07": the name, whether two spaces or a tab part it
    /// from the time, and the time. Read from the end, without a pattern.
    static func nameAndTime(_ row: String) -> (name: String, wide: Bool, start: TimeInterval)? {
        let line = trimmedEnd(row)
        guard let gap = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let clock = line[line.index(after: gap)...]
        guard isClock(clock), let start = ExternalImportText.timestamp(String(clock)) else { return nil }
        var nameEnd = gap
        while nameEnd > line.startIndex, line[line.index(before: nameEnd)] == " " || line[line.index(before: nameEnd)] == "\t" {
            nameEnd = line.index(before: nameEnd)
        }
        let separator = line[nameEnd...gap]
        let name = line[..<nameEnd].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, separator.count >= 2 || separator.contains("\t"), start)
    }

    /// `0:07`, `12:30`, `75:12`, or `1:02:10`: whole minutes and seconds.
    private static func isClock<S: StringProtocol>(_ text: S) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.enumerated().allSatisfy { index, part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && (index == 0 ? part.count <= 3 : part.count == 2)
        }
    }

    /// A name-alone header ends with the two spaces Otter writes after each
    /// part of a header; a paragraph's line doesn't.
    private static func hasWideTrailingGap(_ row: String) -> Bool {
        let trailing = row[trimmedEnd(row).endIndex...]
        return trailing.count >= 2 || trailing.contains("\t")
    }

    /// "A Ana Petrović" in a layout that puts a speaker's initial before
    /// their name, as Otter's PDF does, read as "Ana Petrović".
    private static func stripInitial(_ name: String, known: Set<String>) -> String {
        let parts = name.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 1, let rest = parts.last,
              rest.prefix(1).uppercased() == parts[0].uppercased(),
              known.contains(rest.lowercased()) || OtterSpeakers.isGeneric(String(rest)) else { return name }
        return String(rest)
    }

    private static func isClosingLine(_ row: String) -> Bool {
        row.trimmingCharacters(in: .whitespaces)
            .range(of: #"^transcribed by https?://otter\.ai/?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isBlank(_ row: String) -> Bool {
        row.allSatisfy(\.isWhitespace)
    }

    private static func trimmedEnd(_ row: String) -> Substring {
        var end = row.endIndex
        while end > row.startIndex, row[row.index(before: end)].isWhitespace {
            end = row.index(before: end)
        }
        return row[..<end]
    }
}

private extension OtterExport {
    /// Reads the opening block, or summary sections after the transcript:
    /// the title (the first row, before anything else), the date line, the
    /// keyword and speaker lists, and sections by their headings.
    mutating func readSections(_ rows: ArraySlice<String>, allowTitle: Bool) {
        enum State: Equatable {
            case none, keywords, speakers, transcript
            case section(Int)
        }
        var state = State.none
        var sawContent = false
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                switch state {
                case .keywords, .speakers: state = .none
                case .section(let index): sections[index].rows.append("")
                case .none, .transcript: break
                }
                continue
            }
            if let heading = OtterHeading(trimmed) {
                sawContent = true
                switch heading {
                case .keywords:
                    state = .keywords
                    hasOtterMarks = true
                case .speakers:
                    state = .speakers
                    hasOtterMarks = true
                case .transcript:
                    state = .transcript
                case .actionItems:
                    sections.append(OtterSection(kind: .actionItems))
                    state = .section(sections.count - 1)
                case .notes(let name):
                    sections.append(OtterSection(kind: .notes(name)))
                    state = .section(sections.count - 1)
                }
                continue
            }
            if startedAt == nil, OtterDate.isDateLine(trimmed) {
                // An old export's date has no year; its length still counts.
                let parsed = OtterDate.parse(trimmed)
                startedAt = parsed.date
                duration = parsed.duration ?? duration
                hasOtterMarks = true
                sawContent = true
                continue
            }
            if allowTitle, !sawContent, title == nil, trimmed.count <= 200 {
                title = trimmed
                sawContent = true
                continue
            }
            sawContent = true
            switch state {
            case .keywords: keywords = keywords.map { "\($0) \(trimmed)" } ?? trimmed
            case .speakers: speakers += OtterSpeakers.split(trimmed)
            case .section(let index): sections[index].rows.append(trimmed)
            case .none, .transcript: otherNotes.append(trimmed)
            }
        }
    }
}

/// A heading Otter writes in an export's opening block or summary.
private enum OtterHeading: Equatable {
    case keywords, speakers, transcript, actionItems
    case notes(String)

    init?(_ row: String) {
        var text = row.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        if text.hasSuffix(":") { text.removeLast() }
        switch text.uppercased() {
        case "SUMMARY KEYWORDS", "KEYWORDS": self = .keywords
        case "SPEAKERS": self = .speakers
        case "TRANSCRIPT": self = .transcript
        case "ACTION ITEMS", "ACTION ITEM": self = .actionItems
        case "OVERVIEW", "SUMMARY", "OUTLINE", "INSIGHTS", "TAKEAWAYS", "HIGHLIGHTS", "NOTES":
            self = .notes(text.prefix(1).uppercased() + text.dropFirst().lowercased())
        default:
            return nil
        }
    }

    /// Distinct enough to end a transcript when one stands after a blank
    /// line, as a summary exported after the transcript does.
    var endsTranscript: Bool {
        switch self {
        case .keywords, .actionItems: true
        case .notes(let name): ["Overview", "Outline", "Insights", "Takeaways"].contains(name)
        case .speakers, .transcript: false
        }
    }
}

private enum OtterSpeakers {
    /// "Unknown Speaker" is someone Otter couldn't tell apart, so the line
    /// has no speaker; "Speaker 2" is a distinct voice without a name.
    static func name(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        return name.isEmpty || lower == "unknown speaker" || lower == "unknown" ? nil : name
    }

    /// Labels that name nobody, kept off the participant list.
    static func isGeneric(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lower == "unknown" || lower == "unknown speaker"
            || lower.range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }

    /// Short, starting with a letter, without sentence punctuation.
    static func nameLike(_ text: String) -> Bool {
        guard (1...60).contains(text.count), text.first?.isLetter == true,
              !text.contains(where: { ":?!;\"".contains($0) }),
              !text.hasSuffix("."), !text.hasSuffix(",") else { return false }
        return text.split(separator: " ").count <= 8
    }

    static func split(_ list: String) -> [String] {
        list.components(separatedBy: CharacterSet(charactersIn: ",;•"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Otter's date line: `Wed, Mar 4, 2026 10:15AM • 32:15`, in the time zone
/// of whoever exported it, which LokalBot takes to be this computer's.
private enum OtterDate {
    static func isDateLine(_ row: String) -> Bool {
        let text = row.trimmingCharacters(in: .whitespaces)
        guard text.count <= 80,
              text.range(of: #"^(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,\s"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return false }
        return parse(text).date != nil || text.contains("•")
            || text.range(of: #"\d\s?[ap]\.?m\.?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func parse(_ row: String) -> (date: Date?, duration: TimeInterval?) {
        var value = row.trimmingCharacters(in: .whitespaces)
        var duration: TimeInterval?
        if let bullet = value.firstIndex(where: { "•·|".contains($0) }) {
            duration = ExternalImportText.timestamp(String(value[value.index(after: bullet)...]))
            value = value[..<bullet].trimmingCharacters(in: .whitespaces)
        }
        if let date = date(value) { return (date, duration) }
        // "… 10:15AM 32:15" when the bullet was lost on the way.
        if duration == nil, let space = value.lastIndex(of: " "),
           let length = ExternalImportText.timestamp(String(value[value.index(after: space)...])),
           let date = date(String(value[..<space])) {
            return (date, length)
        }
        return (nil, duration)
    }

    private static func date(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: "a.m.", with: "am", options: .caseInsensitive)
            .replacingOccurrences(of: "p.m.", with: "pm", options: .caseInsensitive)
        let lower = text.lowercased()
        if lower.hasSuffix("am") || lower.hasSuffix("pm") {
            text = text.dropLast(2).trimmingCharacters(in: .whitespaces) + (lower.hasSuffix("am") ? "AM" : "PM")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        for format in ["EEE, MMM d, yyyy h:mma", "EEE, MMMM d, yyyy h:mma", "EEEE, MMMM d, yyyy h:mma", "EEE., MMM d, yyyy h:mma",
                       "MMM d, yyyy h:mma", "EEE, M/d/yyyy h:mma", "EEE, M/d/yy h:mma",
                       "EEE, MMM d, yyyy H:mm", "EEE, d MMM yyyy H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Action items under an `Action Items` heading: one per bulleted row, an
/// owner from a trailing "(Name)" or a name row heading the rows under it.
private enum OtterActionItems {
    static func parse(_ rows: [String]) -> [ExternalMeeting.ActionItem] {
        let filled = rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bulleted = filled.contains { stripBullet($0) != nil }
        var owner: String?
        var items: [ExternalMeeting.ActionItem] = []
        for row in filled {
            if let text = stripBullet(row) {
                items.append(item(text, owner: owner))
                continue
            }
            let name = row.hasSuffix(":") ? String(row.dropLast()) : row
            if bulleted, OtterSpeakers.nameLike(name), name.split(separator: " ").count <= 4 {
                owner = name
                continue
            }
            items.append(item(stripCheckbox(row), owner: nil))
        }
        return items.filter { !$0.text.isEmpty }
    }

    private static func item(_ text: String, owner: String?) -> ExternalMeeting.ActionItem {
        var text = text.trimmingCharacters(in: .whitespaces)
        var owner = owner
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            let name = String(text[open.upperBound..<text.index(before: text.endIndex)])
            if OtterSpeakers.nameLike(name), name.split(separator: " ").count <= 4, name.first?.isUppercase == true,
               !name.contains(where: \.isNumber) {
                owner = name
                text = String(text[..<open.lowerBound])
            }
        }
        return ExternalMeeting.ActionItem(text: text, owner: owner)
    }

    private static func stripBullet(_ row: String) -> String? {
        for bullet in ["- ", "* ", "• ", "◦ ", "▪ ", "– "] where row.hasPrefix(bullet) {
            return stripCheckbox(String(row.dropFirst(bullet.count)))
        }
        if let range = row.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            return stripCheckbox(String(row[range.upperBound...]))
        }
        if let checkbox = checkboxPrefix(row) { return String(row.dropFirst(checkbox.count)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private static func stripCheckbox(_ text: String) -> String {
        guard let checkbox = checkboxPrefix(text) else { return text }
        return String(text.dropFirst(checkbox.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func checkboxPrefix(_ text: String) -> String? {
        ["[ ] ", "[x] ", "[X] ", "☐ ", "☑ ", "☒ ", "□ ", "✓ ", "✔ "].first { text.hasPrefix($0) }
    }
}

// MARK: - SRT

private enum OtterSubRip {
    /// Otter names the speaker on the first cue of a turn only, so cues
    /// without a name continue the turn before them.
    static func lines(_ text: String) -> [ExternalMeeting.Line] {
        let cues = SubtitleTranscript.parse(text)
        guard cues.first?.speaker != nil else { return cues.map(unnamingUnknown) }
        var merged: [ExternalMeeting.Line] = []
        var speaker: String?
        for var cue in cues {
            if let named = cue.speaker { speaker = named } else { cue.speaker = speaker }
            if let last = merged.last, last.speaker == cue.speaker, let lastEnd = last.end, let start = cue.start,
               start - lastEnd < 1.5, last.text.count + cue.text.count < 600 {
                merged[merged.count - 1].text += " " + cue.text
                merged[merged.count - 1].end = cue.end
            } else {
                merged.append(cue)
            }
        }
        return merged.map(unnamingUnknown)
    }

    private static func unnamingUnknown(_ line: ExternalMeeting.Line) -> ExternalMeeting.Line {
        var line = line
        line.speaker = line.speaker.flatMap(OtterSpeakers.name)
        return line
    }
}

// MARK: - DOCX

/// A Word file's paragraphs, one per row, read from `word/document.xml`
/// with the `tar` that ships with macOS (bsdtar reads ZIP), which streams
/// the one entry without writing to disk and takes the path literally.
private enum OtterDocx {
    static func text(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOf", url.path, "word/document.xml"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw OtterReadError(reason: "the Word file couldn't be opened")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw OtterReadError(reason: "it isn't a Word file that can be unpacked")
        }
        let collector = OtterDocxParagraphs()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse() else { throw OtterReadError(reason: "the Word file's text couldn't be read") }
        return collector.paragraphs.joined(separator: "\n")
    }
}

private final class OtterDocxParagraphs: NSObject, XMLParserDelegate {
    private static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private(set) var paragraphs: [String] = []
    private var open: [String] = []
    private var runDepth = 0
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard namespaceURI == Self.word else { return }
        switch elementName {
        case "p": open.append("")
        case "r": runDepth += 1
        case "t": inText = true
        // Tab stops in a paragraph's properties are `tab` too; only a run's
        // tab is text.
        case "tab" where runDepth > 0: append("\t")
        case "br" where runDepth > 0, "cr" where runDepth > 0: append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard namespaceURI == Self.word else { return }
        switch elementName {
        case "p": if let paragraph = open.popLast() { paragraphs.append(paragraph) }
        case "r": runDepth = max(0, runDepth - 1)
        case "t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { append(string) }
    }

    private func append(_ text: String) {
        guard !open.isEmpty else { return }
        open[open.count - 1] += text
    }
}

// MARK: - Peeking

/// A file's first and last bytes as text, for `recognizes`.
private struct OtterPeek {
    var head: String
    var tail: String

    init?(_ url: URL, headBytes: Int = 16_384, tailBytes: Int = 512) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let headData = try? handle.read(upToCount: headBytes), !headData.isEmpty else { return nil }
        var tailData = headData
        if let size = try? handle.seekToEnd(), size > UInt64(headData.count) {
            let start = size - min(UInt64(tailBytes), size - UInt64(headData.count))
            // Keep a UTF-16 file's tail on a character boundary.
            try? handle.seek(toOffset: start - start % 2)
            tailData = (try? handle.read(upToCount: tailBytes + 1)) ?? Data()
        }
        let encoding = Self.encoding(of: headData)
        head = Self.decode(headData, encoding)
        tail = Self.decode(tailData, encoding)
    }

    static func startsAsZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private static func encoding(of data: Data) -> String.Encoding {
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return .utf8
    }

    private static func decode(_ data: Data, _ encoding: String.Encoding) -> String {
        let text: String
        if encoding == .utf8 {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(data: data.prefix(data.count - data.count % 2), encoding: encoding) ?? ""
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
