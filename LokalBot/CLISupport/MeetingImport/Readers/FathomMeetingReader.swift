import Foundation

/// Reads what a person can take out of Fathom, which keeps calls in its cloud
/// and has no export file:
///
/// - the transcript a call page's "Copy Transcript" button copies, pasted into
///   a `.txt` or `.md` file: a "Title - Month Day" line, a "VIEW RECORDING"
///   line with the call's share link, `---`, then turns such as
///   "1:02:03 - Ana Petrović (Acme)" with indented speech, and BOOKMARK,
///   HIGHLIGHT, and ACTION ITEM marks inside them;
/// - the summary "Copy Summary" copies, plain or Markdown, with or without
///   links, under the same header;
/// - the MP4 "Download Video" saves, named after the meeting title;
/// - meeting JSON in the shape Fathom's API and webhooks return
///   (`recording_id`, `share_url`, `transcript`, `default_summary`,
///   `action_items`), alone, in a list response's `items`, or in an array.
///
/// Files of one call are joined by the share link they carry, and a video by
/// its file name. Nothing is written and nothing is fetched.
enum FathomMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.fathom
    static let exportHint = "In Fathom, open a call, click Copy Transcript and Copy Summary and paste each into a text file, and choose Download Video from the call's three-dot menu for the recording. Put them in one folder and choose it; meeting JSON saved from Fathom's API works too."
    /// Fathom keeps calls in its cloud, not on this Mac.
    static let defaultLocations: [String] = []

    /// "Download Video" saves MP4; Fathom's help lists MP3 as coming.
    private static let recordingExtensions: Set<String> = ["mp4", "mp3"]
    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]
    /// The sections of Fathom's default summary, and the API's "Summary".
    private static let sectionNames: Set<String> = ["meeting purpose", "key takeaways", "topics", "next steps",
                                                    "action items", "summary"]
    /// " - WATCH: <link>" or " - WATCH (5 secs): <link>" after a mark or a
    /// summary line, pointing back into the recording.
    private static let watchPattern = #"\s*-?\s*WATCH(\s*\([^)]*\))?:\s*\S+"#
    /// A Markdown link into Fathom; its text is kept and the link dropped,
    /// since it stops working once the account is gone.
    private static let fathomLinkPattern = #"\[([^\]]*)\]\(\s*https?://[^)\s]*fathom\.video[^)\s]*(\s+"[^"]*")?\s*\)"#

    // MARK: - Recognizing

    static func recognizes(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        if recordingExtensions.contains(fileExtension) {
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        if fileExtension == "json" { return head(of: url).map(looksLikeMeetingJSON) ?? false }
        if textExtensions.contains(fileExtension) { return head(of: url).map(looksLikeCopiedText) ?? false }
        return false
    }

    /// The first bytes of a file as text, for a cheap look at its header.
    private static func head(of url: URL, bytes: Int = 65_536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.prefix(data.count & ~1), encoding: .utf16)
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func looksLikeMeetingJSON(_ head: String) -> Bool {
        guard let first = head.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        let markers = ["\"recording_id\"", "\"share_url\"", "\"default_summary\"", "\"recording_start_time\"",
                       "\"matched_calendar_invitee_email\"", "fathom.video/"]
        if markers.contains(where: head.contains) { return true }
        // What the transcript and summary endpoints return on their own.
        return (head.contains("\"transcript\"") && head.contains("\"display_name\"") && head.contains("\"timestamp\""))
            || (head.contains("\"summary\"") && head.contains("\"markdown_formatted\""))
    }

    private static func looksLikeCopiedText(_ head: String) -> Bool {
        let rows = head.components(separatedBy: "\n")
        let opening = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(6)
        if opening.contains(where: { $0.localizedCaseInsensitiveContains("VIEW RECORDING") }) { return true }
        // Without the header: Fathom's turn lines, each followed by indented speech.
        var turns = 0
        for (index, row) in rows.enumerated() where turn(in: row) != nil {
            let next = rows[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if next?.first?.isWhitespace == true { turns += 1 }
        }
        return turns >= 2
    }

    // MARK: - Reading

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        guard isDirectory.boolValue else {
            guard recognizes(url) else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
            if isRecording(url) { return ExternalImportScan(meetings: [recordingMeeting(url)]) }
            do {
                return ExternalImportScan(meetings: assemble(try parts(in: url), recordings: []))
            } catch let failure as Failure {
                throw ExternalImportError.unreadable(url.lastPathComponent, failure.reason)
            }
        }
        let files = ExternalImportText.files(in: url).filter(recognizes)
        guard !files.isEmpty else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
        var found: [Part] = []
        var recordings: [URL] = []
        var problems: [ExternalImportScan.Problem] = []
        for file in files {
            if isRecording(file) {
                recordings.append(file)
                continue
            }
            do {
                found += try parts(in: file)
            } catch {
                let reason = (error as? Failure)?.reason ?? Failure.unopenable.reason
                problems.append(.init(path: file.path, reason: reason))
            }
        }
        return ExternalImportScan(meetings: assemble(found, recordings: recordings), problems: problems)
    }

    /// Why a file couldn't be read, said without quoting it.
    private enum Failure: Error {
        case unopenable, notJSON, noMeeting, noContent

        var reason: String {
            switch self {
            case .unopenable: "it couldn't be opened"
            case .notJSON: "it isn't valid JSON"
            case .noMeeting: "it holds no Fathom meeting"
            case .noContent: "it holds no Fathom transcript or summary"
            }
        }
    }

    /// What one file says about one call, before files of the same call are
    /// joined.
    private struct Part {
        /// Lower ranks win when files of one call disagree: the API's JSON has
        /// exact times and owners, a copied transcript beats a summary.
        enum Kind: Int {
            case json, transcript, summary
        }

        var kind: Kind
        var meeting: ExternalMeeting
        /// Names a downloaded video of this call may carry, normalized.
        var names: Set<String>
        /// The source listed its action items, done ones included, so other
        /// files' guesses don't add to them.
        var actionsListed = false
    }

    private static func isRecording(_ url: URL) -> Bool {
        recordingExtensions.contains(url.pathExtension.lowercased())
    }

    private static func parts(in file: URL) throws -> [Part] {
        if file.pathExtension.lowercased() == "json" {
            let data: Data
            do { data = try Data(contentsOf: file) } catch { throw Failure.unopenable }
            guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Failure.notJSON }
            let found = jsonMeetings(in: object, file: file)
            guard !found.isEmpty else { throw Failure.noMeeting }
            return found
        }
        let text: String
        do { text = try ExternalImportText.readText(file) } catch { throw Failure.unopenable }
        guard let part = copiedText(text, file: file) else { throw Failure.noContent }
        return [part]
    }

    /// Joins the files of each call, in the order they were found, then gives
    /// each video to the one call its name points to. A video no call claims,
    /// or more than one could, is a meeting of its own.
    private static func assemble(_ parts: [Part], recordings: [URL]) -> [ExternalMeeting] {
        var seen = Set<String>()
        let order = parts.map(\.meeting.sourceID).filter { seen.insert($0).inserted }
        var joined: [String: Part] = [:]
        let ranked = parts.enumerated().sorted {
            ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset)
        }
        for (_, part) in ranked {
            let id = part.meeting.sourceID
            joined[id] = joined[id].map { merge($0, part) } ?? part
        }
        var calls = order.compactMap { joined[$0] }
        var alone: [ExternalMeeting] = []
        for recording in recordings {
            let name = recordingName(recording)
            let claims = calls.indices.filter { !name.isEmpty && calls[$0].meeting.audioURL == nil && calls[$0].names.contains(name) }
            if claims.count == 1 {
                calls[claims[0]].meeting.audioURL = recording
            } else {
                alone.append(recordingMeeting(recording))
            }
        }
        return calls.map(\.meeting) + alone
    }

    private static func merge(_ base: Part, _ other: Part) -> Part {
        var merged = base
        var meeting = base.meeting
        let more = other.meeting
        if meeting.startedAt == nil { meeting.startedAt = more.startedAt }
        if meeting.duration == nil { meeting.duration = more.duration }
        if meeting.lines.isEmpty { meeting.lines = more.lines }
        if (meeting.notes ?? "").isEmpty { meeting.notes = more.notes }
        if meeting.audioURL == nil { meeting.audioURL = more.audioURL }
        meeting.participants = unique(meeting.participants + more.participants)
        if !base.actionsListed {
            if other.actionsListed {
                meeting.actionItems = more.actionItems
                merged.actionsListed = true
            } else {
                meeting.actionItems = mergeActions(meeting.actionItems, more.actionItems)
            }
        }
        merged.meeting = meeting
        merged.names.formUnion(other.names)
        return merged
    }

    private static func mergeActions(_ first: [ExternalMeeting.ActionItem],
                                     _ second: [ExternalMeeting.ActionItem]) -> [ExternalMeeting.ActionItem] {
        var items: [ExternalMeeting.ActionItem] = []
        for item in first + second {
            let key = item.text.lowercased()
            if let index = items.firstIndex(where: { $0.text.lowercased() == key }) {
                if items[index].owner == nil { items[index].owner = item.owner }
            } else {
                items.append(item)
            }
        }
        return items
    }

    /// A downloaded video or audio file no copied text or JSON claims.
    private static func recordingMeeting(_ url: URL) -> ExternalMeeting {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ExternalMeeting(
            source: source, sourceID: ExternalImportText.stableID("fathom-recording", url.lastPathComponent, String(size)),
            title: ExternalImportText.title(fromFileName: url), audioURL: url, origin: url)
    }

    /// A video's name as a call would know it: no extension, no " (1)" a
    /// browser adds to a second download of the same name.
    private static func recordingName(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        return normalizedName(stem)
    }

    private static func normalizedName(_ value: String) -> String {
        String(String.UnicodeScalarView(value.precomposedStringWithCanonicalMapping.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    // MARK: - Copied transcript and summary

    private struct Turn {
        var start: TimeInterval
        var speaker: String
        var text: [String] = []
    }

    /// A transcript or summary copied from a call page, or both pasted into
    /// one file. Nil when it holds neither.
    private static func copiedText(_ text: String, file: URL) -> Part? {
        let rows = text.components(separatedBy: "\n")
        let opening = rows.indices.filter { !rows[$0].trimmingCharacters(in: .whitespaces).isEmpty }.prefix(6)
        var headerLine: String?
        var recordingLine: String?
        var bodyStart = 0
        if let view = opening.first(where: { rows[$0].localizedCaseInsensitiveContains("VIEW RECORDING") }) {
            recordingLine = rows[view]
            if let first = opening.first, first < view { headerLine = cleanHeader(rows[first]) }
            bodyStart = view + 1
        } else if let first = opening.first, turn(in: rows[first]) == nil,
                  splitTitle(cleanHeader(rows[first])).date != nil {
            headerLine = cleanHeader(rows[first])
            bodyStart = first + 1
        }

        var turns: [Turn] = []
        var summaryRows: [String] = []
        var actions: [ExternalMeeting.ActionItem] = []
        var inTranscript = false
        for row in rows.dropFirst(bodyStart) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !inTranscript { summaryRows.append("") }
                continue
            }
            if trimmed == "---" || trimmed.localizedCaseInsensitiveContains("VIEW RECORDING")
                || (headerLine != nil && cleanHeader(trimmed) == headerLine) { continue }
            if let found = turn(in: row) {
                turns.append(Turn(start: found.start, speaker: found.speaker))
                inTranscript = true
                continue
            }
            // Speech is indented, so a section heading at the margin starts a
            // summary pasted after the transcript.
            if inTranscript, row.first?.isWhitespace == false, isSectionHeading(trimmed) { inTranscript = false }
            if let mark = annotation(trimmed) {
                if let action = mark.action { actions.append(.init(text: action)) }
                if inTranscript, let speech = mark.speech { turns[turns.count - 1].text.append(speech) }
                continue
            }
            if inTranscript {
                turns[turns.count - 1].text.append(trimmed)
            } else {
                summaryRows.append(row)
            }
        }

        let lines = turns.compactMap { turn -> ExternalMeeting.Line? in
            let text = turn.text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ExternalMeeting.Line(start: turn.start, speaker: turn.speaker, text: text)
        }
        let summary = summaryNotes(summaryRows)
        let actionItems = mergeActions(actions, summary.actions)
        guard !lines.isEmpty || summary.markdown != nil || !actionItems.isEmpty else { return nil }

        let header = headerLine.map(splitTitle) ?? (title: "", date: nil)
        let title = header.title.isEmpty ? ExternalImportText.title(fromFileName: file) : header.title
        var startedAt: Date?
        if let day = header.date.flatMap(monthDay) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            startedAt = startOfDay(day, onOrBefore: modified ?? Date())
        }
        var duration = recordingLine.flatMap(minutes).map { TimeInterval($0 * 60) }
        if let minutes = duration, let last = lines.compactMap(\.start).max() { duration = max(minutes, last) }
        if duration == 0 { duration = nil }
        let shareID = recordingLine.flatMap(fathomID) ?? fathomID(in: text)
        let sourceID = shareID ?? ExternalImportText.stableID(
            "fathom-copy", title, header.date ?? "", lines.first?.text ?? summary.markdown ?? "")

        var names: Set<String> = [normalizedName(file.deletingPathExtension().lastPathComponent), normalizedName(title)]
        if let date = header.date { names.insert(normalizedName("\(title) \(date)")) }
        names.remove("")
        return Part(
            kind: lines.isEmpty ? .summary : .transcript,
            meeting: ExternalMeeting(
                source: source, sourceID: sourceID, title: title, startedAt: startedAt, duration: duration,
                participants: unique(lines.compactMap(\.speaker)), lines: lines, notes: summary.markdown,
                actionItems: actionItems, origin: file),
            names: names)
    }

    /// "1:02:03 - Ana Petrović (Acme)" as a start and a name without the
    /// company or email Fathom puts in parentheses. Turn lines start at the
    /// margin; speech under them is indented.
    private static func turn(in row: String) -> (start: TimeInterval, speaker: String)? {
        guard let first = row.first, !first.isWhitespace else { return nil }
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("@") { body = body.dropFirst() }
        guard let dash = body.range(of: " - "),
              let start = ExternalImportText.timestamp(String(body[..<dash.lowerBound])) else { return nil }
        let name = body[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 120 else { return nil }
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return (start, name) }
        let bare = name[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return (start, bare.isEmpty ? name : bare)
    }

    /// A mark Fathom puts in a turn: "ACTION ITEM: …", "BOOKMARK: … - WATCH:
    /// <link>  speech", "HIGHLIGHT: …", or the " - WATCH: <link>  speech" line
    /// that can follow an action item. Speech after the link is kept.
    private static func annotation(_ trimmed: String) -> (action: String?, speech: String?)? {
        if trimmed.hasPrefix("- WATCH") || trimmed.hasPrefix("-WATCH") || trimmed.hasPrefix("WATCH") {
            let speech = splitWatch(trimmed).after
            return (nil, speech.isEmpty ? nil : speech)
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[..<colon])
        guard label.count >= 3, label.allSatisfy({ $0.isUppercase || $0 == " " }) else { return nil }
        guard ["ACTION ITEM", "BOOKMARK", "HIGHLIGHT"].contains(label) || trimmed.contains("WATCH") else { return nil }
        let parts = splitWatch(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        let action = label == "ACTION ITEM" && !parts.before.isEmpty ? parts.before : nil
        return (action, parts.after.isEmpty ? nil : parts.after)
    }

    private static func splitWatch(_ text: String) -> (before: String, after: String) {
        guard let range = text.range(of: watchPattern, options: .regularExpression) else {
            return (text.trimmingCharacters(in: .whitespaces), "")
        }
        return (text[..<range.lowerBound].trimmingCharacters(in: .whitespaces),
                text[range.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// A header line without Markdown: "# **Title - May 19**" → "Title - May 19".
    private static func cleanHeader(_ row: String) -> String {
        var text = row.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// "Weekly sync - Q3 - May 19" → ("Weekly sync - Q3", "May 19"). The date
    /// is nil when the last part isn't one.
    private static func splitTitle(_ header: String) -> (title: String, date: String?) {
        guard let dash = header.range(of: " - ", options: .backwards) else { return (header, nil) }
        let date = header[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        guard monthDay(date) != nil else { return (header, nil) }
        return (header[..<dash.lowerBound].trimmingCharacters(in: .whitespaces), date)
    }

    /// "May 19" or "May 19, 2025", as Fathom's header writes the call's day.
    private static func monthDay(_ value: String) -> DateComponents? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        for format in ["MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMMM d", "MMM d"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: value) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return DateComponents(year: format.contains("yyyy") ? parts.year : nil, month: parts.month, day: parts.day)
        }
        return nil
    }

    /// The day's local midnight. The header has no year, so it is the latest
    /// one that doesn't put the call after the file was saved.
    private static func startOfDay(_ day: DateComponents, onOrBefore reference: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = DateComponents(year: day.year, month: day.month, day: day.day)
        if parts.year == nil {
            let year = calendar.component(.year, from: reference)
            parts.year = year
            if let date = calendar.date(from: parts), date > reference.addingTimeInterval(86_400) { parts.year = year - 1 }
        }
        return calendar.date(from: parts)
    }

    /// "VIEW RECORDING - 48 mins (No highlights): …" → 48.
    private static func minutes(in row: String) -> Int? {
        guard let range = row.range(of: #"VIEW RECORDING\s*-\s*\d+\s*min"#,
                                    options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(row[range].filter(\.isNumber))
    }

    /// Fathom's id for a call: the token of its share link, else the id in a
    /// calls link.
    private static func fathomID(in text: String) -> String? {
        for (marker, prefix) in [("fathom.video/share/", ""), ("fathom.video/calls/", "call-")] {
            guard let range = text.range(of: marker) else { continue }
            let token = text[range.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            if !token.isEmpty { return prefix + token }
        }
        return nil
    }

    private static func isSectionHeading(_ trimmed: String) -> Bool {
        sectionNames.contains(headingName(trimmed).lowercased())
    }

    private static func headingName(_ trimmed: String) -> String {
        cleanHeader(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
    }

    /// Drops links into Fathom and the WATCH links after lines, keeping text.
    private static func withoutFathomLinks(_ text: String) -> String {
        text.replacingOccurrences(of: fathomLinkPattern, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: watchPattern, with: "", options: .regularExpression)
    }

    /// A copied summary as Markdown, and the action items it lists: its
    /// "Action Items" section, else its "Next Steps" with their owners. Plain
    /// copies get headings back: Fathom's section names, and a short line
    /// followed by bullets (a topic under "Topics").
    private static func summaryNotes(_ rows: [String]) -> (markdown: String?, actions: [ExternalMeeting.ActionItem]) {
        let cleaned = rows.map(withoutFathomLinks)
        let isMarkdown = cleaned.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var output: [String] = []
        var section = ""
        var bullets: [(section: String, indent: Int, text: String)] = []
        for (index, row) in cleaned.enumerated() {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append("")
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 2 { section = headingName(trimmed).lowercased() }
                output += ["", trimmed, ""]
                continue
            }
            if isBullet(trimmed) {
                let indent = row.prefix { $0.isWhitespace }.count
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                bullets.append((section, indent, text))
                output.append(String(repeating: " ", count: indent) + "- " + text)
                continue
            }
            let atMargin = row.first?.isWhitespace == false
            if !isMarkdown, atMargin, isPlainHeading(trimmed, followedBy: cleaned[(index + 1)...]) {
                let name = headingName(trimmed)
                if sectionNames.contains(name.lowercased()) {
                    section = name.lowercased()
                    output += ["", "## \(name)", ""]
                } else {
                    output += ["", (section == "topics" ? "### " : "## ") + name, ""]
                }
                continue
            }
            output.append(trimmed)
        }
        let markdown = output.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (markdown.isEmpty ? nil : markdown, summaryActions(bullets))
    }

    private static func isPlainHeading(_ trimmed: String, followedBy rest: ArraySlice<String>) -> Bool {
        if isSectionHeading(trimmed) { return true }
        guard trimmed.count <= 80, let last = trimmed.last, !".!?,;".contains(last) else { return false }
        let next = rest.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return next.map { isBullet($0.trimmingCharacters(in: .whitespaces)) } ?? false
    }

    private static func summaryActions(_ bullets: [(section: String, indent: Int, text: String)]) -> [ExternalMeeting.ActionItem] {
        let plain = { (text: String) in text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
        let listed = bullets.filter { $0.section == "action items" }
        if !listed.isEmpty {
            return listed.map { .init(text: plain($0.text)) }.filter { !$0.text.isEmpty }
        }
        let steps = bullets.filter { $0.section == "next steps" }
        guard let top = steps.map(\.indent).min() else { return [] }
        var items: [ExternalMeeting.ActionItem] = []
        var owner: String?
        for step in steps {
            let text = plain(step.text)
            guard !text.isEmpty else { continue }
            if step.indent == top {
                owner = nil
                if text.hasSuffix(":"), !text.dropLast().contains(":") {
                    owner = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                    continue
                }
                let split = ExternalImportText.splitSpeaker(text)
                items.append(.init(text: split.text, owner: split.speaker))
            } else {
                items.append(.init(text: text, owner: owner))
            }
        }
        return items
    }

    // MARK: - API and webhook JSON

    /// Meetings in a JSON file: one meeting object, a list response's
    /// `items`, or an array of them. The transcript and summary endpoints'
    /// `{"transcript": […]}` and `{"summary": {…}}` count too, titled from the
    /// file name.
    private static func jsonMeetings(in object: Any, file: URL) -> [Part] {
        var objects: [[String: Any]] = []
        if let array = object as? [Any] {
            objects = array.compactMap { $0 as? [String: Any] }
        } else if let dictionary = object as? [String: Any] {
            if let items = (dictionary["items"] ?? dictionary["meetings"] ?? dictionary["data"]) as? [Any] {
                objects = items.compactMap { $0 as? [String: Any] }
            } else {
                objects = [dictionary]
            }
        }
        return objects.enumerated().compactMap { jsonMeeting($0.element, file: file, position: $0.offset) }
    }

    private static func jsonMeeting(_ object: [String: Any], file: URL, position: Int) -> Part? {
        let summary = string((object["default_summary"] as? [String: Any])?["markdown_formatted"])
            ?? string((object["summary"] as? [String: Any])?["markdown_formatted"])
        let lines = (object["transcript"] as? [Any] ?? []).compactMap(jsonLine)
        let recordingID = string(object["recording_id"]) ?? (object["recording_id"] as? NSNumber)?.stringValue
        let shareID = string(object["share_url"]).flatMap(fathomID) ?? string(object["url"]).flatMap(fathomID)
        guard recordingID != nil || shareID != nil || !lines.isEmpty || summary != nil else { return nil }

        let title = string(object["title"]) ?? string(object["meeting_title"]) ?? ExternalImportText.title(fromFileName: file)
        let recordingStart = string(object["recording_start_time"]).flatMap(ExternalImportText.date)
        let recordingEnd = string(object["recording_end_time"]).flatMap(ExternalImportText.date)
        let startedAt = recordingStart
            ?? string(object["scheduled_start_time"]).flatMap(ExternalImportText.date)
            ?? string(object["created_at"]).flatMap(ExternalImportText.date)
        var duration: TimeInterval?
        if let recordingStart, let recordingEnd, recordingEnd > recordingStart {
            duration = recordingEnd.timeIntervalSince(recordingStart)
        }
        let invitees = (object["calendar_invitees"] as? [Any] ?? []).compactMap { value -> String? in
            guard let invitee = value as? [String: Any] else { return nil }
            return string(invitee["name"]) ?? string(invitee["matched_speaker_display_name"])
        }

        let actions = (object["action_items"] as? [Any] ?? []).compactMap { value -> (item: ExternalMeeting.ActionItem, done: Bool)? in
            guard let action = value as? [String: Any],
                  let text = string(action["description"]).map(withoutFathomLinks).flatMap(nonEmpty) else { return nil }
            let owner = string((action["assignee"] as? [String: Any])?["name"])
            return (.init(text: text, owner: owner), action["completed"] as? Bool ?? false)
        }
        let highlights = (object["highlights"] as? [Any] ?? []).compactMap(highlightRow)
        var sections: [String] = []
        if let summary { sections.append(withoutFathomLinks(summary).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !highlights.isEmpty { sections.append("## Highlights\n\n" + highlights.joined(separator: "\n")) }
        if actions.contains(where: \.done) {
            // The writer lists only open items, so a list with done ones is
            // written here, marked as Fathom has them.
            sections.append("## Action items\n\n" + actions.map { action in
                let owner = action.item.owner.map { " (\($0))" } ?? ""
                return "- [\(action.done ? "x" : " ")] \(action.item.text)\(owner)"
            }.joined(separator: "\n"))
        }
        let notes = sections.filter { !$0.isEmpty }.joined(separator: "\n\n")

        let sourceID = shareID ?? recordingID.map { "recording-\($0)" } ?? ExternalImportText.stableID(
            "fathom-json", file.lastPathComponent, String(position), title, lines.first?.text ?? summary ?? "")
        var names: Set<String> = [normalizedName(title)]
        if position == 0 { names.insert(normalizedName(file.deletingPathExtension().lastPathComponent)) }
        names.remove("")
        return Part(
            kind: .json,
            meeting: ExternalMeeting(
                source: source, sourceID: sourceID, title: title, startedAt: startedAt, duration: duration,
                participants: unique(invitees + lines.compactMap(\.speaker)), lines: lines,
                notes: notes.isEmpty ? nil : notes, actionItems: actions.filter { !$0.done }.map(\.item), origin: file),
            names: names, actionsListed: !actions.isEmpty)
    }

    /// `{"speaker": {"display_name": …}, "text": …, "timestamp": "00:05:32"}`.
    private static func jsonLine(_ value: Any) -> ExternalMeeting.Line? {
        guard let item = value as? [String: Any], let text = string(item["text"]) else { return nil }
        let speaker = string((item["speaker"] as? [String: Any])?["display_name"]) ?? string(item["speaker"])
        let start = string(item["timestamp"]).flatMap(ExternalImportText.timestamp) ?? number(item["timestamp"])
        return ExternalMeeting.Line(start: start, speaker: speaker, text: text)
    }

    /// "- **Objection** at 0:16: Pushed back on price — “They pushed back hard”".
    private static func highlightRow(_ value: Any) -> String? {
        guard let highlight = value as? [String: Any] else { return nil }
        let label = string(highlight["type"])
        let summary = string(highlight["summary"])
        let text = string(highlight["text"]).flatMap { $0 == summary ? nil : $0 }
        guard label != nil || summary != nil || text != nil else { return nil }
        let lead = [label.map { "**\($0)**" }, number(highlight["start_time"]).map { "at \(clock($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let body = [summary, text.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " — ")
        return "- " + [lead, body].filter { !$0.isEmpty }.joined(separator: ": ")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, whole % 60)
            : String(format: "%d:%02d", minutes, whole % 60)
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap(nonEmpty)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
