import Foundation

enum GranolaMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.granola
    static let exportHint = "In Granola, click your workspace name, open Settings → Profile, click Generate CSV under Export historical data, choose your workspaces, then pick the CSV or ZIP from the email Granola sends. A note copied with Copy notes, or a transcript copied from the transcript panel, also works once pasted into a .md or .txt file."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool {
        switch kind(of: url) {
        case .export, .copiedNotes, .copiedTranscript: true
        case .unreadable, .other: false
        }
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        guard isDirectory.boolValue else {
            let fileKind = kind(of: url)
            switch fileKind {
            case .other:
                throw ExternalImportError.unrecognized(source, url.lastPathComponent)
            case .unreadable(let reason):
                throw ExternalImportError.unreadable(url.lastPathComponent, reason)
            case .export, .copiedNotes, .copiedTranscript:
                let result = try readFile(url, kind: fileKind)
                return ExternalImportScan(meetings: result.found.map(\.meeting), problems: result.problems)
            }
        }
        var found: [Found] = []
        var problems: [ExternalImportScan.Problem] = []
        var sawGranola = false
        for file in ExternalImportText.files(in: url) {
            let fileKind = kind(of: file)
            switch fileKind {
            case .other:
                continue
            case .unreadable(let reason):
                problems.append(.init(path: file.path, reason: reason))
            case .export, .copiedNotes, .copiedTranscript:
                sawGranola = true
                do {
                    let result = try readFile(file, kind: fileKind)
                    found += result.found
                    problems += result.problems
                } catch {
                    problems.append(.init(path: file.path, reason: error.localizedDescription))
                }
            }
        }
        guard sawGranola || !problems.isEmpty else {
            throw ExternalImportError.unrecognized(source, url.lastPathComponent)
        }
        return ExternalImportScan(meetings: mergeCopies(found), problems: problems)
    }

    private enum FileKind: Equatable {
        case export
        case copiedNotes
        case copiedTranscript
        case unreadable(String)
        case other
    }

    private static let footerMarker = "Chat with meeting transcript:"
    private static let transcriptHeaderPrefixes = ["Meeting Title:", "Date:", "Meeting participants:"]
    private static let contentColumns: Set<String> = ["summary", "notes", "transcript"]

    private static func kind(of url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "csv":
            guard let head = readBytes(of: url, fromEnd: false, count: 16_384) else {
                return .unreadable("it couldn't be opened")
            }
            return isExportHeader(columns(inFirstLineOf: head)) ? .export : .other
        case "md", "markdown", "txt", "text":
            guard let headData = readBytes(of: url, fromEnd: false, count: 8_192) else { return .other }
            let head = normalized(String(decoding: headData, as: UTF8.self))
            let headLines = head.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = headLines.first(where: { !$0.isEmpty }),
               first == "Transcript:" || transcriptHeaderPrefixes.contains(where: { first.hasPrefix($0) }),
               headLines.contains("Transcript:") {
                return .copiedTranscript
            }
            let tail = readBytes(of: url, fromEnd: true, count: 8_192).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if tail.contains(footerMarker) || head.contains("notes.granola.ai/") || tail.contains("notes.granola.ai/") {
                return .copiedNotes
            }
            let opening = headLines.filter { !$0.isEmpty }.prefix(2)
            if opening.count == 2, opening.first?.hasPrefix("# ") == true, let dateLine = opening.last,
               notesDateLine(dateLine) != nil {
                return .copiedNotes
            }
            return .other
        default:
            return .other
        }
    }

    private static func readBytes(of url: URL, fromEnd: Bool, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if fromEnd {
            guard let end = try? handle.seekToEnd() else { return nil }
            try? handle.seek(toOffset: end > UInt64(count) ? end - UInt64(count) : 0)
        }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    private static func columns(inFirstLineOf data: Data) -> Set<String> {
        let text = normalized(String(decoding: data, as: UTF8.self))
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return Set(firstLine.split(separator: ",").map { columnName(String($0).replacingOccurrences(of: "\"", with: "")) })
    }

    private static func isExportHeader(_ columns: Set<String>) -> Bool {
        columns.contains("document_title")
            && (columns.contains("document_id") || columns.contains("document_created"))
            && !columns.isDisjoint(with: contentColumns)
    }

    private static func columnName(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalized(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private struct Found {
        enum Copy { case notes, transcript }
        var meeting: ExternalMeeting
        var copy: Copy?
        var pairKey: String?
    }

    private static func readFile(_ url: URL, kind: FileKind) throws -> (found: [Found], problems: [ExternalImportScan.Problem]) {
        let text: String
        do {
            text = normalized(try ExternalImportText.readText(url))
        } catch {
            throw ExternalImportError.unreadable(url.lastPathComponent, "it couldn't be opened")
        }
        switch kind {
        case .export:
            return try readExport(text, url: url)
        case .copiedNotes:
            return ([readCopiedNotes(text, url: url)], [])
        case .copiedTranscript:
            return ([readCopiedTranscript(text, url: url)], [])
        case .unreadable, .other:
            return ([], [])
        }
    }

    private static func readExport(_ text: String, url: URL) throws -> (found: [Found], problems: [ExternalImportScan.Problem]) {
        let table = parseCSV(text)
        guard let header = table.rows.first else {
            throw ExternalImportError.unreadable(url.lastPathComponent, "it has no header row")
        }
        let columns = header.map(columnName)
        guard isExportHeader(Set(columns)) else {
            throw ExternalImportError.unrecognized(source, url.lastPathComponent)
        }
        let index = Dictionary(columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [Found] = []
        for row in table.rows.dropFirst() {
            func value(_ column: String) -> String {
                guard let position = index[column], position < row.count else { return "" }
                return row[position]
            }
            let title = value("document_title").trimmingCharacters(in: .whitespacesAndNewlines)
            let created = value("document_created").trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = composeNotes(summary: value("summary"), typed: value("notes"))
            let transcriptText = value("transcript")
            let transcript = parseTranscript(transcriptText)
            let sourceID = documentID(value("document_id"))
                ?? (created.isEmpty
                    ? ExternalImportText.stableID("granola-export", title, notes ?? "", transcriptText)
                    : ExternalImportText.stableID("granola-export", created, title))
            found.append(Found(meeting: ExternalMeeting(
                source: source, sourceID: sourceID, title: title.isEmpty ? untitled : title,
                startedAt: exportDate(created), participants: transcript.names, lines: transcript.lines,
                notes: notes, actionItems: actionItems(in: notes), origin: url)))
        }
        var problems: [ExternalImportScan.Problem] = []
        if table.endsInsideQuotes {
            let read = found.count == 1 ? "1 complete row before it was read" : "\(found.count) complete rows before it were read"
            problems.append(.init(path: url.path, reason: "The file ends in the middle of a row, so the export looks cut off; \(read). Download the export again from Granola's email."))
        }
        return (found, problems)
    }

    private static let untitled = "\(ExternalMeetingSource.granola.title) meeting"

    private static func readCopiedNotes(_ text: String, url: URL) -> Found {
        let (body, link) = strippingFooter(text)
        var lines = body.components(separatedBy: "\n")
        var title = ExternalImportText.title(fromFileName: url)
        lines = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("# ") {
            let heading = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { title = heading }
            lines = Array(lines.dropFirst().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        var startedAt: Date?
        var participants: [String] = []
        if let first = lines.first, let line = notesDateLine(first) {
            startedAt = line.date
            participants = line.attendees
            lines.removeFirst()
        }
        let notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = link.flatMap(documentID(inLink:))
            ?? ExternalImportText.stableID("granola-copy", title.lowercased(), startedAt.map(dayKey) ?? notes)
        let meeting = ExternalMeeting(
            source: source, sourceID: sourceID, title: title, startedAt: startedAt, participants: participants,
            notes: notes.isEmpty ? nil : notes, actionItems: actionItems(in: notes), origin: url)
        return Found(meeting: meeting, copy: .notes, pairKey: pairKey(title: title, date: startedAt))
    }

    private static func readCopiedTranscript(_ text: String, url: URL) -> Found {
        let rows = text.components(separatedBy: "\n")
        var title = ExternalImportText.title(fromFileName: url)
        var dateText: String?
        var participants: [String] = []
        var bodyStart = rows.count
        for (offset, row) in rows.enumerated() {
            let line = row.trimmingCharacters(in: .whitespaces)
            if line == "Transcript:" {
                bodyStart = offset + 1
                break
            }
            if let value = value(of: "Meeting Title:", in: line), !value.isEmpty {
                title = value
            } else if let value = value(of: "Date:", in: line), !value.isEmpty {
                dateText = value
            } else if let value = value(of: "Meeting participants:", in: line) {
                participants = value.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        let body = rows.dropFirst(bodyStart).joined(separator: "\n")
        let transcript = parseTranscript(body)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let startedAt = dateText.flatMap { monthDay($0, before: modified ?? Date()) }
        for name in transcript.names where !participants.contains(name) {
            participants.append(name)
        }
        let sourceID = ExternalImportText.stableID(
            "granola-copy", title.lowercased(), startedAt.map(dayKey) ?? body.trimmingCharacters(in: .whitespacesAndNewlines))
        let meeting = ExternalMeeting(
            source: source, sourceID: sourceID, title: title, startedAt: startedAt, participants: participants,
            lines: transcript.lines, origin: url)
        return Found(meeting: meeting, copy: .transcript, pairKey: pairKey(title: title, date: startedAt))
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private static func mergeCopies(_ found: [Found]) -> [ExternalMeeting] {
        var meetings = found.map(\.meeting)
        var noteByKey: [String: Int] = [:]
        for (position, item) in found.enumerated() where item.copy == .notes {
            if let key = item.pairKey, noteByKey[key] == nil { noteByKey[key] = position }
        }
        var merged = Set<Int>()
        for (position, item) in found.enumerated() where item.copy == .transcript {
            guard let key = item.pairKey, let target = noteByKey[key], meetings[target].lines.isEmpty else { continue }
            meetings[target].lines = item.meeting.lines
            for name in item.meeting.participants where !meetings[target].participants.contains(name) {
                meetings[target].participants.append(name)
            }
            merged.insert(position)
        }
        return meetings.enumerated().filter { !merged.contains($0.offset) }.map(\.element)
    }

    private static func pairKey(title: String, date: Date?) -> String? {
        guard let date else { return nil }
        return "\(title.lowercased())|\(dayKey(date))"
    }

    private static func documentID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UUID(uuidString: trimmed) == nil ? trimmed : trimmed.lowercased()
    }

    private static func documentID(inLink link: String) -> String? {
        guard let range = link.range(of: #"/d/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                                     options: .regularExpression) else { return nil }
        return documentID(String(link[range].dropFirst(3)))
    }

    private static func exportDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let date = ExternalImportText.date(value) { return date }
        if value.count >= 9, value.allSatisfy(\.isNumber), let number = Double(value) {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number)
        }
        var iso = value.replacingOccurrences(of: #"\s+([+-]\d{2}(:?\d{2})?|Z)$"#, with: "$1", options: .regularExpression)
        iso = iso.replacingOccurrences(of: #"^(\d{4}-\d{2}-\d{2}) "#, with: "$1T", options: .regularExpression)
        iso = iso.replacingOccurrences(of: #"([+-]\d{2})$"#, with: "$1:00", options: .regularExpression)
        iso = iso.replacingOccurrences(of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
        return ExternalImportText.date(iso)
    }

    private static func notesDateLine(_ line: String) -> (date: Date, attendees: [String])? {
        let parts = line.components(separatedBy: "\u{00B7}")
        let datePart = parts[0].trimmingCharacters(in: .whitespaces)
        guard !datePart.isEmpty, datePart.count <= 20 else { return nil }
        var parsed: Date?
        for (locale, text) in [("en_GB", datePart), ("en_US_POSIX", datePart.replacingOccurrences(of: "Sept", with: "Sep"))] {
            for format in ["EEE, dd MMM yy", "EEE, d MMM yy", "EEE, dd MMM yyyy", "dd MMM yy"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: locale)
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = format
                if let date = formatter.date(from: text) {
                    parsed = date
                    break
                }
            }
            if parsed != nil { break }
        }
        guard let parsed, let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: parsed) else {
            return nil
        }
        let attendees = parts.dropFirst().joined(separator: "\u{00B7}").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (noon, attendees)
    }

    private static func monthDay(_ text: String, before reference: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d"
        guard let parsed = formatter.date(from: text.replacingOccurrences(of: "Sept", with: "Sep")) else { return nil }
        let calendar = Calendar.current
        let monthDay = calendar.dateComponents([.month, .day], from: parsed)
        var components = DateComponents()
        components.year = calendar.component(.year, from: reference)
        components.month = monthDay.month
        components.day = monthDay.day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        guard date > reference.addingTimeInterval(86_400) else { return date }
        components.year = (components.year ?? 0) - 1
        return calendar.date(from: components)
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func composeNotes(summary: String, typed: String) -> String? {
        let enhanced = strippingFooter(summary).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if enhanced.isEmpty { return mine.isEmpty ? nil : mine }
        if mine.isEmpty || enhanced.contains(mine) { return enhanced }
        return enhanced + "\n\n## My notes\n\n" + mine
    }

    private static func strippingFooter(_ text: String) -> (text: String, link: String?) {
        guard let marker = text.range(of: footerMarker, options: .backwards) else { return (text, nil) }
        let link = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.contains("\n") else { return (text, nil) }
        var lines = text[..<marker.lowerBound].components(separatedBy: "\n")
        while let last = lines.last?.trimmingCharacters(in: .whitespaces),
              last.isEmpty || (last.count >= 3 && Set(last).count == 1 && "-*_".contains(last.first ?? " ")) {
            lines.removeLast()
        }
        return (lines.joined(separator: "\n"), link)
    }

    private struct ListEntry {
        var indent: Int
        var text: String
        var checked: Bool?
        var inActionSection: Bool
    }

    private static func actionItems(in markdown: String?) -> [ExternalMeeting.ActionItem] {
        guard let markdown, !markdown.isEmpty else { return [] }
        var blocks: [[ListEntry]] = [[]]
        var inActionSection = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = headingText(trimmed) {
                inActionSection = isActionHeading(heading)
                blocks.append([])
            } else if var entry = listEntry(line) {
                entry.inActionSection = inActionSection
                blocks[blocks.count - 1].append(entry)
            } else if !trimmed.isEmpty, !line.hasPrefix(" ") {
                blocks.append([])
            }
        }
        var items: [ExternalMeeting.ActionItem] = []
        for block in blocks {
            var stack: [(indent: Int, owner: String?)] = []
            for (position, entry) in block.enumerated() {
                while let last = stack.last, last.indent >= entry.indent { stack.removeLast() }
                let inherited = stack.last?.owner
                let hasChildren = position + 1 < block.count && block[position + 1].indent > entry.indent
                guard entry.checked != true, entry.checked == false || entry.inActionSection else {
                    stack.append((entry.indent, inherited))
                    continue
                }
                if hasChildren, entry.checked == nil, let owner = ownerName(entry.text) {
                    stack.append((entry.indent, owner))
                    continue
                }
                var text = entry.text
                var owner = inherited
                if owner == nil, let split = ownerPrefix(text) {
                    owner = split.owner
                    text = split.text
                }
                let shown = displayText(text, in: markdown)
                if !shown.isEmpty { items.append(.init(text: shown, owner: owner)) }
                stack.append((entry.indent, owner))
            }
        }
        return items
    }

    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes) {
            let rest = line.dropFirst(hashes)
            guard rest.first?.isWhitespace == true else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        guard line.hasPrefix("**"), line.count > 4 else { return nil }
        var inner = line.dropFirst(2)
        if inner.hasSuffix(":") { inner = inner.dropLast() }
        guard inner.hasSuffix("**") else { return nil }
        inner = inner.dropLast(2)
        guard !inner.isEmpty, !inner.contains("*") else { return nil }
        return String(inner)
    }

    private static func isActionHeading(_ heading: String) -> Bool {
        heading.range(of: #"(?i)\b(action items?|actions|next steps?|to-?dos?|to do|follow[- ]?ups?|tasks)\b"#,
                      options: .regularExpression) != nil
    }

    private static func listEntry(_ line: String) -> ListEntry? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        var content: Substring
        if let marker = rest.first, "-*+•".contains(marker), rest.dropFirst().first == " " {
            content = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let afterDigits = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 3, let dot = afterDigits.first, dot == "." || dot == ")",
                  afterDigits.dropFirst().first == " " else { return nil }
            content = afterDigits.dropFirst(2)
        }
        var checked: Bool?
        for (box, state) in [("[ ]", false), ("[x]", true), ("[X]", true)] where content.hasPrefix(box) {
            checked = state
            content = content.dropFirst(box.count)
            break
        }
        let text = content.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ListEntry(indent: indent, text: text, checked: checked, inActionSection: false)
    }

    private static func ownerName(_ text: String) -> String? {
        var name = plainText(text)
        if name.hasSuffix(":") { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        let words = name.split(separator: " ")
        let particles: Set<String> = ["de", "da", "di", "van", "von", "der", "den", "la", "le", "du", "bin", "al"]
        guard (1...4).contains(words.count), words.first?.first?.isUppercase == true,
              words.allSatisfy({ $0.first?.isUppercase == true || particles.contains(String($0)) }),
              !name.contains(where: { ".?!;,()[]\"".contains($0) || $0.isNumber }) else { return nil }
        return name
    }

    private static func ownerPrefix(_ text: String) -> (owner: String, text: String)? {
        let split = ExternalImportText.splitSpeaker(plainText(text))
        guard let name = split.speaker, name.split(separator: " ").count <= 3, let owner = ownerName(name) else {
            return nil
        }
        return (owner, split.text)
    }

    private static func displayText(_ text: String, in markdown: String) -> String {
        let plain = plainText(text)
        return !plain.isEmpty && markdown.localizedCaseInsensitiveContains(plain) ? plain : text
    }

    private static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!&~<>|])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private enum Speaker {
        case me
        case unnamed
        case voice(String)
        case person(String)
    }

    private static func parseTranscript(_ text: String) -> (lines: [ExternalMeeting.Line], names: [String]) {
        let split = text.replacingOccurrences(of: #"[ \t]+(Speaker [A-Z]: )"#, with: "\n$1", options: .regularExpression)
        let rows = split.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else { return ([], []) }
        let labels = rows.map(label)
        var fixed = 0
        var named = 0
        var distinctNames = Set<String>()
        for item in labels {
            switch item?.speaker {
            case .person(let name)?:
                named += 1
                distinctNames.insert(name)
            case .some:
                fixed += 1
            case nil:
                break
            }
        }
        let takesNames = (fixed + named) * 2 >= rows.count && (fixed > 0 || distinctNames.count >= 2)
        let labeled = fixed > 0 || takesNames
        var lines: [ExternalMeeting.Line] = []
        var names: [String] = []
        var current: (name: String?, isMe: Bool) = (nil, false)
        for (row, item) in zip(rows, labels) {
            var body = row
            switch item?.speaker {
            case .me?:
                current = ("Me", true)
                body = item?.text ?? ""
            case .unnamed?:
                current = (nil, false)
                body = item?.text ?? ""
            case .voice(let name)?:
                current = (name, false)
                body = item?.text ?? ""
            case .person(let name)? where takesNames:
                current = (name, false)
                body = item?.text ?? ""
                if !names.contains(name) { names.append(name) }
            default:
                if !labeled { current = (nil, false) }
            }
            guard !body.isEmpty else { continue }
            lines.append(.init(speaker: current.name, text: body, isMe: current.isMe))
        }
        return (lines, names)
    }

    private static func label(_ row: String) -> (speaker: Speaker, text: String)? {
        guard let colon = row.firstIndex(of: ":") else { return nil }
        let name = row[..<colon].trimmingCharacters(in: .whitespaces)
        let text = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 60 else { return nil }
        switch name {
        case "Me":
            return (.me, text)
        case "Them", "Other participant", "assemblyai":
            return (.unnamed, text)
        default:
            break
        }
        if name.hasSuffix(" (me)") {
            return (.me, text)
        }
        if name.hasPrefix("Speaker ") {
            let tag = name.dropFirst("Speaker ".count)
            if (1...3).contains(tag.count), tag.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                return (.voice(name), text)
            }
        }
        if name.hasPrefix("[Room] ") {
            let room = name.dropFirst("[Room] ".count).trimmingCharacters(in: .whitespaces)
            return room.isEmpty ? nil : (.voice(room), text)
        }
        return isDisplayName(name) && !text.isEmpty ? (.person(name), text) : nil
    }

    private static func isDisplayName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter, !first.isLowercase,
              name.split(separator: " ").count <= 6,
              !name.contains(where: { "?!;,\"[]{}<>*_`#".contains($0) }) else { return false }
        return true
    }

    private struct CSVTable {
        var rows: [[String]]
        var endsInsideQuotes: Bool
    }

    private static func parseCSV(_ text: String) -> CSVTable {
        let quote = UInt8(ascii: "\"")
        let comma = UInt8(ascii: ",")
        let newline = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var position = 0
        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while position < bytes.count {
            let byte = bytes[position]
            if inQuotes {
                if byte == quote {
                    if position + 1 < bytes.count, bytes[position + 1] == quote {
                        field.append(quote)
                        position += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote && field.isEmpty {
                inQuotes = true
            } else if byte == comma {
                endField()
            } else if byte == newline {
                endRow()
            } else if byte == carriageReturn {
                if position + 1 < bytes.count, bytes[position + 1] == newline { position += 1 }
                endRow()
            } else {
                field.append(byte)
            }
            position += 1
        }
        if inQuotes { return CSVTable(rows: rows, endsInsideQuotes: true) }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return CSVTable(rows: rows, endsInsideQuotes: false)
    }
}
