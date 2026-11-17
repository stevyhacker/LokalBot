import Foundation
import SQLite3

/// Reads Apple Voice Memos recordings: the app's own `Recordings` folder, or
/// `.m4a` and `.qta` files dragged out of it.
///
/// The folder holds `CloudRecordings.db`, a Core Data store whose
/// `ZCLOUDRECORDING` rows give each recording's id (`ZUNIQUEID`), title
/// (`ZENCRYPTEDTITLE`, plain text despite its name, or the older
/// `ZCUSTOMLABEL`), start (`ZDATE`, seconds since 2001), length (`ZDURATION`),
/// audio file (`ZPATH`), and whether it is in Recently Deleted
/// (`ZEVICTIONDATE`). Recent releases write the transcript into the audio
/// file: a `tsrp` atom in an `.m4a` track's user data, or the
/// `com.apple.VoiceMemos.tsrp` item of a `.qta` track's QuickTime metadata,
/// holding a Foundation `AttributedString` in its JSON coding whose runs,
/// usually one word each, carry `timeRange: [start, end]` in seconds. Each
/// `.m4a` also carries the recording's id as the iTunes item
/// `voice-memo-uuid`, the same value as `ZUNIQUEID`, so a dragged-out copy
/// and the library row are one meeting.
///
/// The database is opened read-only and immutable, so SQLite never touches
/// its journal; a recording whose row is still only in the write-ahead log is
/// read from its audio file like a dragged-out copy.
enum VoiceMemosMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.voiceMemos
    static let exportHint = "In Voice Memos, drag recordings to a Finder window to save them, then import those files. "
        + "For every recording with its title and date, import Voice Memos' Recordings folder instead: "
        + "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings."
    static let defaultLocations = ["~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"]

    static let databaseName = "CloudRecordings.db"
    private static let audioExtensions: Set<String> = ["m4a", "qta"]
    /// Top-level atoms an MPEG-4 or QuickTime file can start with.
    private static let leadingAtoms: Set<String> = ["ftyp", "wide", "free", "skip", "mdat", "moov", "pnot"]
    /// What a recording is called when nothing names it.
    static let untitled = "Voice memo"

    static func recognizes(_ url: URL) -> Bool {
        if isDatabase(url) { return true }
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return false }
        // A file that can't be opened is still offered, so reading it can say why.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8) else { return true }
        // An empty file is a recording Voice Memos keeps only in iCloud.
        if head.isEmpty { return true }
        guard head.count == 8 else { return false }
        return leadingAtoms.contains(String(decoding: head.suffix(4), as: UTF8.self))
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        guard isDirectory.boolValue else {
            guard recognizes(url) else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
            if isDatabase(url) { return try readLibrary(url).scan }
            do {
                return ExternalImportScan(meetings: [try readRecording(url)])
            } catch {
                throw ExternalImportError.unreadable(url.lastPathComponent, reason(for: error))
            }
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw ExternalImportError.unreadable(url.lastPathComponent, isPermissionError(error)
                ? RecordingError.permissionReason : "the folder couldn't be opened")
        }
        let files = ExternalImportText.files(in: url).filter { !isInsideComposition($0) }
        var result = ExternalImportScan()
        var claimed = Set<String>()
        var recognizedAny = false
        for database in files where isDatabase(database) {
            recognizedAny = true
            do {
                let library = try readLibrary(database)
                result.append(library.scan)
                claimed.formUnion(library.claimed)
            } catch {
                result.problems.append(.init(path: database.path, reason: reason(for: error)))
            }
        }
        for file in files where !isDatabase(file) && !claimed.contains(file.standardizedFileURL.path) && recognizes(file) {
            recognizedAny = true
            do {
                result.meetings.append(try readRecording(file))
            } catch {
                result.problems.append(.init(path: file.path, reason: reason(for: error)))
            }
        }
        guard recognizedAny else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
        return result
    }

    // MARK: The library database

    private static func isDatabase(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("cloudrecordings") && url.pathExtension.lowercased() == "db"
    }

    /// Fragments of an edited recording in the older library layout, which
    /// are parts of the recording beside them, not recordings of their own.
    private static func isInsideComposition(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains { $0.lowercased().hasSuffix(".composition") }
    }

    /// The recordings a library database lists, and every audio file it names,
    /// so the folder walk doesn't read them again, including the ones in
    /// Recently Deleted.
    private static func readLibrary(_ database: URL) throws -> (scan: ExternalImportScan, claimed: Set<String>) {
        let rows = try VoiceMemosLibrary.rows(in: database)
        let folder = database.deletingLastPathComponent()
        var scan = ExternalImportScan()
        var claimed = Set<String>()
        var notOnThisMac = 0
        for row in rows {
            let audio = row.path.flatMap { audioURL(for: $0, in: folder) }
            if let audio { claimed.insert(audio.standardizedFileURL.path) }
            guard !row.isRecentlyDeleted else { continue }
            guard let audio, fileSize(audio) > 0 else {
                notOnThisMac += 1
                continue
            }
            do {
                scan.meetings.append(try readRecording(audio, row: row))
            } catch {
                scan.problems.append(.init(path: audio.path, reason: reason(for: error)))
            }
        }
        if notOnThisMac > 0 {
            let count = notOnThisMac == 1 ? "1 recording isn't" : "\(notOnThisMac) recordings aren't"
            scan.problems.append(.init(path: folder.path, reason: "\(count) on this Mac: Voice Memos keeps the audio in iCloud. "
                + "Open them in Voice Memos to download them, then import again."))
        }
        return (scan, claimed)
    }

    /// The audio file a row's `ZPATH` names, which is usually a file name in
    /// the database's folder and sometimes an absolute path into it. A path
    /// that leads out of the folder names nothing.
    private static func audioURL(for path: String, in folder: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let relative = trimmed.hasPrefix("/") ? (trimmed as NSString).lastPathComponent : trimmed
        let root = folder.standardizedFileURL
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    // MARK: Recordings

    /// One recording, with what the library row says about it when there is one.
    private static func readRecording(_ url: URL, row: VoiceMemosLibrary.Row? = nil) throws -> ExternalMeeting {
        guard fileSize(url) > 0 else { throw RecordingError.empty }
        let movie = try VoiceMemoMovie(contentsOf: url)
        let manifest = CompositionManifest(beside: url)
        let duration = row?.duration ?? movie.duration
        let title = [row?.title, row?.customLabel, row?.sortingLabel, movie.title, manifest?.title, fileTitle(url)]
            .compactMap { cleanTitle($0) }
            .first ?? untitled
        let startedAt = row?.date ?? manifest?.date ?? originalStamp(url) ?? movie.creationDate ?? movie.dateTag
            ?? movie.creationTime.map { $0.addingTimeInterval(-(duration ?? 0)) }
        let sourceID = [row?.uniqueID, movie.memoID, manifest?.memoID].compactMap { normalizedID($0) }.first
            ?? fallbackID(url, title: title, startedAt: startedAt, duration: duration)
        let lines = movie.transcript.map(transcriptLines(from:)) ?? []
        return ExternalMeeting(source: source, sourceID: sourceID, title: title, startedAt: startedAt,
                               duration: duration, lines: lines, audioURL: url, origin: url)
    }

    /// A title that names something: not empty, and not the date placeholder
    /// older devices show for a title they can't read ("2023-08-11T07:53:31Z").
    private static func cleanTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#, options: .regularExpression) == nil
        else { return nil }
        return value
    }

    /// The file name as a title, unless it is the time stamp Voice Memos names
    /// its own files with ("20260304 101500-1A2B3C4D.m4a").
    private static func fileTitle(_ url: URL) -> String? {
        originalStamp(url) == nil ? ExternalImportText.title(fromFileName: url) : nil
    }

    /// When a recording started, from the name Voice Memos gives its own files:
    /// the device's local time, read in this Mac's time zone.
    private static func originalStamp(_ url: URL) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.range(of: #"^\d{8} \d{6}(-[0-9A-Fa-f]{8})?$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return formatter.date(from: String(stem.prefix(15)))
    }

    /// A recording id as Voice Memos writes it: an upper-case UUID.
    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return UUID(uuidString: value)?.uuidString ?? value
    }

    /// For a file that carries no id: its original name when Voice Memos gave
    /// it one, else its title, start, and length.
    private static func fallbackID(_ url: URL, title: String, startedAt: Date?, duration: TimeInterval?) -> String {
        if originalStamp(url) != nil {
            return ExternalImportText.stableID("voice-memos-file", url.deletingPathExtension().lastPathComponent)
        }
        let start = startedAt.map { String(Int64(($0.timeIntervalSince1970 * 1_000).rounded())) } ?? ""
        let length = duration.map { String(Int64(($0 * 1_000).rounded())) } ?? ""
        return ExternalImportText.stableID("voice-memos", title, start, length)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoPermission { return true }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let codes = [nsError.code, underlying?.code ?? 0]
        let posix = [nsError.domain, underlying?.domain ?? ""].contains(NSPOSIXErrorDomain)
        return posix && (codes.contains(Int(EPERM)) || codes.contains(Int(EACCES)))
    }

    private static func reason(for error: Error) -> String {
        switch error {
        case let error as RecordingError: error.reason
        case ExternalImportError.unreadable(_, let reason): reason
        default: isPermissionError(error) ? RecordingError.permissionReason : "the file couldn't be read"
        }
    }

    // MARK: Transcripts

    /// A pause this long starts a new line.
    private static let pauseBreak: TimeInterval = 1.5
    /// A line this long ends at its next sentence end.
    private static let sentenceBreak: TimeInterval = 4
    /// No line runs longer than this.
    private static let longestLine: TimeInterval = 30

    /// The lines of a transcript Voice Memos wrote into a recording: its
    /// words, grouped at pauses and sentence ends. Empty when the transcript
    /// is empty or isn't the JSON Voice Memos writes.
    static func transcriptLines(from data: Data) -> [ExternalMeeting.Line] {
        var json = data
        // A QuickTime metadata value can come with its `data` header, and a
        // payload can be padded with zeros.
        if let brace = json.prefix(32).firstIndex(of: UInt8(ascii: "{")) { json = json[brace...] }
        while json.last == 0 { json.removeLast() }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json))) as? [String: Any] else { return [] }
        let words = transcriptWords(root["attributedString"])
        var lines: [ExternalMeeting.Line] = []
        var text = ""
        var start: TimeInterval?
        var end: TimeInterval?
        func flush() {
            let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !cleaned.isEmpty { lines.append(.init(start: start, end: end, text: cleaned)) }
            text = ""
            start = nil
            end = nil
        }
        for word in words {
            if let range = word.range {
                if let lineStart = start, let lineEnd = end {
                    let length = range.upperBound - lineStart
                    if range.lowerBound - lineEnd >= pauseBreak || word.text.hasPrefix("\n") || length > longestLine
                        || (endsSentence(text) && length >= sentenceBreak) {
                        flush()
                    }
                }
                start = start ?? range.lowerBound
                end = max(end ?? range.upperBound, range.upperBound)
            }
            text += word.text
        }
        flush()
        return lines
    }

    private struct Word {
        var text: String
        var range: ClosedRange<TimeInterval>?
    }

    /// The runs of an `AttributedString` in either of its JSON codings: text
    /// and attributes interleaved (`["Hi", {…}, " there", {…}]`), or text and
    /// indexes into an `attributeTable` (`{"runs": ["Hi", 0], "attributeTable": [{…}]}`).
    /// A transcript with no speech is a plain string.
    private static func transcriptWords(_ value: Any?) -> [Word] {
        if let string = value as? String { return [Word(text: string)] }
        if let interleaved = value as? [Any] {
            var words: [Word] = []
            for item in interleaved {
                if let text = item as? String {
                    words.append(Word(text: text))
                } else if let attributes = item as? [String: Any], !words.isEmpty, words[words.count - 1].range == nil {
                    words[words.count - 1].range = timeRange(attributes)
                }
            }
            return words
        }
        guard let separated = value as? [String: Any], let runs = separated["runs"] as? [Any] else { return [] }
        let table = separated["attributeTable"] as? [Any] ?? []
        var words: [Word] = []
        for item in runs {
            if let text = item as? String {
                words.append(Word(text: text))
            } else if let index = (item as? NSNumber)?.intValue, !words.isEmpty, table.indices.contains(index),
                      let attributes = table[index] as? [String: Any] {
                words[words.count - 1].range = timeRange(attributes)
            }
        }
        return words
    }

    /// `timeRange` is a start and an end in seconds, not a start and a length.
    private static func timeRange(_ attributes: [String: Any]) -> ClosedRange<TimeInterval>? {
        guard let pair = attributes["timeRange"] as? [Any], pair.count == 2,
              let start = (pair[0] as? NSNumber)?.doubleValue, let end = (pair[1] as? NSNumber)?.doubleValue,
              start.isFinite, end.isFinite, start >= 0, start <= end, end < 10_000_000 else { return nil }
        return start...end
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        return trimmed.last.map { ".?!…。？！".contains($0) } ?? false
    }
}

// MARK: - Errors

private enum RecordingError: Error {
    case empty
    case noMovieHeader
    case damaged
    case tooLarge

    static let permissionReason = "macOS didn't let LokalBot read it. Choose Voice Memos' Recordings folder in the import panel, "
        + "or allow LokalBot Full Disk Access in System Settings > Privacy & Security."

    var reason: String {
        switch self {
        case .empty: "the file is empty; Voice Memos may keep this recording only in iCloud"
        case .noMovieHeader: "it has no movie header, so it isn't a complete recording"
        case .damaged: "the file is damaged or cut short"
        case .tooLarge: "its header is larger than any recording's"
        }
    }
}

// MARK: - The movie header

/// What a Voice Memos recording says about itself in its movie header
/// (`moov`), read without its audio: length and creation time (`mvhd`),
/// iTunes tags (`©nam`, `©too`, `----:com.apple.iTunes:voice-memo-uuid`), the
/// `date` user data string, QuickTime metadata (`com.apple.quicktime.*`), and
/// the transcript.
private struct VoiceMemoMovie {
    /// No real movie header comes near this; a larger one is damage.
    static let largestHeader: UInt64 = 64 * 1_024 * 1_024
    /// Seconds from 1904-01-01, where QuickTime times count from, to 1970-01-01.
    static let quickTimeEpoch: TimeInterval = 2_082_844_800

    var duration: TimeInterval?
    /// `mvhd`'s creation time. Voice Memos appears to stamp it when it
    /// finishes writing, so it is the end of the recording, or of an export.
    var creationTime: Date?
    var title: String?
    var encoder: String?
    var memoID: String?
    /// The `date` user data string, in UTC.
    var dateTag: Date?
    /// `com.apple.quicktime.creationdate`, which carries its offset.
    var creationDate: Date?
    var transcript: Data?

    private let bytes: [UInt8]

    init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var offset: UInt64 = 0
        var movie: [UInt8]?
        while movie == nil, length >= 8, offset <= length - 8 {
            try handle.seek(toOffset: offset)
            let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { throw RecordingError.damaged }
            var size = Self.integer(header, at: 0, length: 4)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { throw RecordingError.damaged }
                size = Self.integer(header, at: 8, length: 8)
                headerSize = 16
            } else if size == 0 {
                size = length - offset
            }
            guard size >= headerSize, size <= length - offset else { throw RecordingError.damaged }
            if header[4..<8].elementsEqual("moov".utf8) {
                let payloadSize = size - headerSize
                guard payloadSize <= Self.largestHeader else { throw RecordingError.tooLarge }
                try handle.seek(toOffset: offset + headerSize)
                let payload = [UInt8](try handle.read(upToCount: Int(payloadSize)) ?? Data())
                guard payload.count == Int(payloadSize) else { throw RecordingError.damaged }
                movie = payload
            }
            offset += size
        }
        guard let movie else { throw RecordingError.noMovieHeader }
        bytes = movie
        parse()
    }

    private mutating func parse() {
        let movie = 0..<bytes.count
        if let header = children("mvhd", in: movie).first { readMovieHeader(header) }
        for userData in children("udta", in: movie) {
            readUserData(userData)
            transcript = transcript ?? children("tsrp", in: userData).first.map { Data(bytes[$0]) }
        }
        for metadata in children("meta", in: movie) { readQuickTimeMetadata(metadata) }
        // The transcript is track metadata; a movie-level one is the fallback.
        var trackTranscript: Data?
        for track in children("trak", in: movie) where trackTranscript == nil {
            let userData = children("udta", in: track) + children("mdia", in: track).flatMap { children("udta", in: $0) }
            for container in userData where trackTranscript == nil {
                trackTranscript = children("tsrp", in: container).first.map { Data(bytes[$0]) }
            }
            for metadata in children("meta", in: track) where trackTranscript == nil {
                trackTranscript = quickTimeItems(metadata)["com.apple.VoiceMemos.tsrp"].map { Data(bytes[$0]) }
            }
        }
        transcript = trackTranscript ?? transcript
    }

    private mutating func readMovieHeader(_ header: Range<Int>) {
        guard header.count >= 4 else { return }
        let isVersion1 = bytes[header.lowerBound] == 1
        let timeLength = isVersion1 ? 8 : 4
        let creationOffset = header.lowerBound + 4
        let timescaleOffset = creationOffset + 2 * timeLength
        guard timescaleOffset + 4 + timeLength <= header.upperBound else { return }
        let created = TimeInterval(Self.integer(bytes, at: creationOffset, length: timeLength)) - Self.quickTimeEpoch
        // Before 2001 or in the future is an unset or wrong clock.
        if created > 978_307_200, created < Date().timeIntervalSince1970 + 86_400 {
            creationTime = Date(timeIntervalSince1970: created)
        }
        let timescale = Self.integer(bytes, at: timescaleOffset, length: 4)
        let units = Self.integer(bytes, at: timescaleOffset + 4, length: timeLength)
        if timescale > 0, units > 0, units < UInt64(UInt32.max) * 1_000 {
            duration = TimeInterval(units) / TimeInterval(timescale)
        }
    }

    /// `moov/udta`: the `date` string and the iTunes tags in `meta/ilst`.
    private mutating func readUserData(_ userData: Range<Int>) {
        // `date` is a bare string; a QuickTime `©day` text atom has a length
        // and language before it, which the date pattern skips.
        for atom in atoms(in: userData) where atom.type == Self.code("date") || atom.type == 0xA964_6179 {
            dateTag = dateTag ?? Self.isoDate(in: text(atom.payload))
        }
        for metadata in children("meta", in: userData) {
            let start = metadataStart(metadata)
            for list in children("ilst", in: start..<metadata.upperBound) {
                for item in atoms(in: list) {
                    switch item.type {
                    case 0xA96E_616D: title = title ?? dataValue(in: item.payload).map(text)  // ©nam
                    case 0xA974_6F6F: encoder = encoder ?? dataValue(in: item.payload).map(text)  // ©too
                    case 0xA964_6179: dateTag = dateTag ?? dataValue(in: item.payload).flatMap { Self.isoDate(in: text($0)) }  // ©day
                    case Self.code("----"): readFreeform(item.payload)
                    default: break
                    }
                }
            }
        }
    }

    /// An iTunes freeform item: `mean`, `name`, and `data`.
    private mutating func readFreeform(_ item: Range<Int>) {
        guard let name = children("name", in: item).first, name.count > 4,
              text((name.lowerBound + 4)..<name.upperBound) == "voice-memo-uuid",
              let value = dataValue(in: item) else { return }
        memoID = memoID ?? text(value)
    }

    /// `moov/meta` in the QuickTime style, keyed by names in `keys`.
    private mutating func readQuickTimeMetadata(_ metadata: Range<Int>) {
        for (key, value) in quickTimeItems(metadata) {
            switch key {
            case "com.apple.quicktime.title": title = title ?? text(value)
            case "com.apple.quicktime.software": encoder = encoder ?? text(value)
            case "com.apple.quicktime.creationdate": creationDate = creationDate ?? Self.isoDate(in: text(value))
            default:
                if key.hasSuffix("voice-memo-uuid") { memoID = memoID ?? text(value) }
            }
        }
    }

    /// The values of a QuickTime metadata atom, by key: `keys` lists names in
    /// the `mdta` namespace, and each `ilst` item's type is its key's 1-based
    /// index, holding a `data` atom.
    private func quickTimeItems(_ metadata: Range<Int>) -> [String: Range<Int>] {
        let start = metadataStart(metadata)
        guard let keys = children("keys", in: start..<metadata.upperBound).first, keys.count >= 8 else { return [:] }
        var names: [UInt64: String] = [:]
        let count = Self.integer(bytes, at: keys.lowerBound + 4, length: 4)
        var offset = keys.lowerBound + 8
        var index: UInt64 = 1
        while index <= count, offset + 8 <= keys.upperBound {
            let size = Int(Self.integer(bytes, at: offset, length: 4))
            guard size >= 8, size <= keys.upperBound - offset else { break }
            names[index] = text((offset + 8)..<(offset + size))
            offset += size
            index += 1
        }
        var values: [String: Range<Int>] = [:]
        for list in children("ilst", in: start..<metadata.upperBound) {
            for item in atoms(in: list) {
                if let name = names[UInt64(item.type)], values[name] == nil, let value = dataValue(in: item.payload) {
                    values[name] = value
                }
            }
        }
        return values
    }

    /// An ISO `meta` atom starts with a version and flags, which are zero; a
    /// QuickTime one starts with its first child, whose size isn't.
    private func metadataStart(_ metadata: Range<Int>) -> Int {
        metadata.count >= 4 && Self.integer(bytes, at: metadata.lowerBound, length: 4) == 0
            ? metadata.lowerBound + 4 : metadata.lowerBound
    }

    /// The value in a `data` atom, after its type and locale.
    private func dataValue(in item: Range<Int>) -> Range<Int>? {
        guard let data = children("data", in: item).first, data.count >= 8 else { return nil }
        return (data.lowerBound + 8)..<data.upperBound
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    /// The first ISO 8601 date in `text`, with or without a colon in its offset.
    private static func isoDate(in text: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(text[range]).replacingOccurrences(
            of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
        return ExternalImportText.date(found)
    }

    // MARK: Atoms

    private struct Atom {
        var type: UInt32
        var payload: Range<Int>
    }

    private static func code(_ type: String) -> UInt32 {
        type.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private func children(_ type: String, in range: Range<Int>) -> [Range<Int>] {
        let code = Self.code(type)
        return atoms(in: range).filter { $0.type == code }.map(\.payload)
    }

    /// The atoms directly inside `range`, up to the first whose size is damaged.
    private func atoms(in range: Range<Int>) -> [Atom] {
        var atoms: [Atom] = []
        var offset = range.lowerBound
        while range.upperBound - offset >= 8 {
            var size = Self.integer(bytes, at: offset, length: 4)
            var headerSize = 8
            if size == 1 {
                guard range.upperBound - offset >= 16 else { break }
                size = Self.integer(bytes, at: offset + 8, length: 8)
                headerSize = 16
            } else if size == 0 {
                size = UInt64(range.upperBound - offset)
            }
            guard size >= UInt64(headerSize), size <= UInt64(range.upperBound - offset) else { break }
            let end = offset + Int(size)
            atoms.append(Atom(type: UInt32(Self.integer(bytes, at: offset + 4, length: 4)), payload: (offset + headerSize)..<end))
            offset = end
        }
        return atoms
    }

    /// A big-endian unsigned integer; the caller keeps it in bounds.
    private static func integer(_ bytes: [UInt8], at offset: Int, length: Int) -> UInt64 {
        bytes[offset..<(offset + length)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

// MARK: - The older library layout

/// `<recording>.composition/manifest.plist`, which older Voice Memos
/// libraries and device backups keep beside an edited recording.
private struct CompositionManifest {
    var title: String?
    var date: Date?
    var memoID: String?

    init?(beside audio: URL) {
        let url = audio.deletingPathExtension().appendingPathExtension("composition")
            .appendingPathComponent("manifest.plist")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        title = plist["RCSavedRecordingTitle"] as? String
        date = plist["RCSavedRecordingCreationDate"] as? Date
        memoID = plist["RCSavedRecordingUUID"] as? String
    }
}

// MARK: - The database

/// `CloudRecordings.db`, opened read-only and immutable: SQLite reads the
/// main file only and never creates or touches `-wal` or `-shm` files.
/// Every attribute is optional in Voice Memos' Core Data model, so columns
/// the table lacks read as NULL.
private enum VoiceMemosLibrary {
    struct Row {
        var uniqueID: String?
        var title: String?
        var customLabel: String?
        var sortingLabel: String?
        var date: Date?
        var duration: TimeInterval?
        var path: String?
        var isRecentlyDeleted: Bool
    }

    static func rows(in database: URL) throws -> [Row] {
        let name = database.lastPathComponent
        let encoded = database.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? database.path
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        let status = sqlite3_open_v2("file:\(encoded)?mode=ro&immutable=1", &handle,
                                     SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let handle else { throw failure(status, name) }

        var columns = Set<String>()
        try each(handle, "PRAGMA table_info(ZCLOUDRECORDING)", name) { statement in
            if let column = text(statement, 1) { columns.insert(column) }
        }
        guard columns.contains("ZPATH") else {
            throw ExternalImportError.unreadable(name, "it isn't a Voice Memos library: it has no recordings table")
        }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let query = """
            SELECT \(column("ZUNIQUEID")), \(column("ZENCRYPTEDTITLE")), \(column("ZCUSTOMLABEL")),
                   \(column("ZCUSTOMLABELFORSORTING")), \(column("ZDATE")), \(column("ZDURATION")), ZPATH,
                   \(column("ZEVICTIONDATE"))
            FROM ZCLOUDRECORDING ORDER BY \(columns.contains("ZDATE") ? "ZDATE" : "rowid")
            """
        var rows: [Row] = []
        try each(handle, query, name) { statement in
            // Dates far from any real recording's are damage.
            let date = number(statement, 4).flatMap { abs($0) < 1e10 ? Date(timeIntervalSinceReferenceDate: $0) : nil }
            let duration = number(statement, 5).flatMap { $0 > 0 && $0 < 10_000_000 ? $0 : nil }
            rows.append(Row(uniqueID: text(statement, 0), title: text(statement, 1), customLabel: text(statement, 2),
                            sortingLabel: text(statement, 3), date: date, duration: duration, path: text(statement, 6),
                            isRecentlyDeleted: sqlite3_column_type(statement, 7) != SQLITE_NULL))
        }
        return rows
    }

    private static func each(_ handle: OpaquePointer, _ sql: String, _ name: String,
                             _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure(prepared, name) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw failure(step, name) }
            try body(statement)
        }
    }

    /// Text, or a blob that is valid UTF-8; nil for anything else.
    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_TEXT, SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return nil }
            let data = Data(bytes: pointer, count: count)
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private static func number(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, index)
            return value.isFinite ? value : nil
        case SQLITE_TEXT:
            return text(statement, index).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        default:
            return nil
        }
    }

    /// SQLite's codes in words that never quote the database's contents.
    private static func failure(_ status: Int32, _ name: String) -> ExternalImportError {
        let reason: String
        switch status & 0xFF {
        case SQLITE_AUTH, SQLITE_PERM, SQLITE_CANTOPEN: reason = RecordingError.permissionReason
        case SQLITE_NOTADB: reason = "it isn't a database"
        case SQLITE_CORRUPT: reason = "the database is damaged, or changed while LokalBot read it; try again"
        default: reason = "the database couldn't be read (SQLite error \(status))"
        }
        return .unreadable(name, reason)
    }
}
