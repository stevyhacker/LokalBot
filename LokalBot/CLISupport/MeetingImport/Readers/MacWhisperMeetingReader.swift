import Foundation
import SQLite3

enum MacWhisperMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.macWhisper
    static let exportHint = "Choose .whisper files (in MacWhisper, File › Save As…, or drag a transcript from the history sidebar into Finder) or what the Export button saved: SRT, VTT, TXT, CSV, JSON, Markdown, or DOCX. To bring in your whole MacWhisper history, choose main.sqlite in ~/Library/Application Support/MacWhisper/Database."
    static let defaultLocations = ["~/Library/Application Support/MacWhisper/Database/main.sqlite"]

    static func recognizes(_ url: URL) -> Bool {
        kind(of: url, chosen: false) != nil
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        if isDirectory.boolValue { return try readFolder(url) }
        guard let kind = kind(of: url, chosen: true) else {
            throw ExternalImportError.unrecognized(source, url.path)
        }
        let siblings = kind.isExport ? recordings(in: ExternalImportText.files(in: url.deletingLastPathComponent(), recursive: false)) : [:]
        do {
            return try read(url, as: kind, recording: siblings[groupKey(url)])
        } catch let failure as Failure {
            throw ExternalImportError.unreadable(url.lastPathComponent, failure.reason)
        }
    }

    fileprivate struct Failure: Error {
        var reason: String
    }

    fileprivate enum Kind: Int {
        case whisper, json, subtitles, csv, text, docx, database

        var isExport: Bool { self != .whisper && self != .database }
    }

    private static let recordingExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "aac", "caf", "flac", "mp4", "mov", "m4v"]

    private static func kind(of url: URL, chosen: Bool) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "whisper":
            return .whisper
        case "srt", "vtt":
            return .subtitles
        case "txt", "md", "markdown":
            return looksLikeText(url) ? .text : nil
        case "csv":
            return looksLikeText(url) ? .csv : nil
        case "docx":
            return head(of: url, count: 4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) ? .docx : nil
        case "json":
            let start = String(decoding: head(of: url, count: 65_536), as: UTF8.self)
            let known = start.contains("\"segments\"") || start.contains("\"transcripts\"")
                || (start.contains("\"timestamp\"") && start.contains("\"text\""))
            return known ? .json : nil
        case "sqlite", "sqlite3", "db":
            guard chosen || url.lastPathComponent == "main.sqlite" else { return nil }
            return head(of: url, count: 16) == Data("SQLite format 3\u{0}".utf8) ? .database : nil
        default:
            return nil
        }
    }

    private static func head(of url: URL, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        let start = head(of: url, count: 4_096)
        if start.starts(with: [0xFF, 0xFE]) || start.starts(with: [0xFE, 0xFF]) { return true }
        return !start.contains(0)
    }

    private static func groupKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func recordings(in files: [URL]) -> [String: URL] {
        var found: [String: URL] = [:]
        for file in files where recordingExtensions.contains(file.pathExtension.lowercased()) {
            let key = groupKey(file)
            if found[key] == nil { found[key] = file }
        }
        return found
    }

    private static func readFolder(_ folder: URL) throws -> ExternalImportScan {
        let files = ExternalImportText.files(in: folder)
        var chosen: [String: (url: URL, kind: Kind)] = [:]
        var order: [String] = []
        for file in files {
            guard let kind = kind(of: file, chosen: false) else { continue }
            let key = kind.isExport || kind == .whisper ? groupKey(file) : file.path
            if let existing = chosen[key] {
                if kind.rawValue < existing.kind.rawValue { chosen[key] = (file, kind) }
            } else {
                chosen[key] = (file, kind)
                order.append(key)
            }
        }
        guard !order.isEmpty else { throw ExternalImportError.unrecognized(source, folder.path) }
        let siblings = recordings(in: files)
        var result = ExternalImportScan()
        for key in order {
            guard let item = chosen[key] else { continue }
            do {
                result.append(try read(item.url, as: item.kind, recording: item.kind.isExport ? siblings[key] : nil))
            } catch let failure as Failure {
                result.problems.append(.init(path: item.url.path, reason: failure.reason))
            } catch {
                result.problems.append(.init(path: item.url.path, reason: "it couldn't be read"))
            }
        }
        return result
    }

    private static func read(_ url: URL, as kind: Kind, recording: URL?) throws -> ExternalImportScan {
        switch kind {
        case .database:
            return try MacWhisperLibrary.read(url)
        case .whisper:
            return try WhisperDocument.read(url)
        case .json:
            return try readJSON(url, recording: recording)
        case .subtitles:
            let lines = SubtitleTranscript.parse(try text(of: url))
            return ExternalImportScan(meetings: [try exportedMeeting(lines, title: nil, origin: url, recording: recording)])
        case .csv:
            let lines = MacWhisperCSV.parse(try text(of: url))
            return ExternalImportScan(meetings: [try exportedMeeting(lines, title: nil, origin: url, recording: recording)])
        case .text:
            let parsed = MacWhisperText.parse(try text(of: url))
            return ExternalImportScan(meetings: [try exportedMeeting(parsed.lines, title: parsed.title, origin: url, recording: recording)])
        case .docx:
            let parsed = MacWhisperText.parse(try docxText(url))
            return ExternalImportScan(meetings: [try exportedMeeting(parsed.lines, title: nil, origin: url, recording: recording)])
        }
    }

    private static func text(of url: URL) throws -> String {
        do {
            return try ExternalImportText.readText(url)
        } catch {
            throw Failure(reason: "the file couldn't be opened")
        }
    }

    private static func exportedMeeting(_ lines: [ExternalMeeting.Line], title: String?, origin: URL,
                                        recording: URL?) throws -> ExternalMeeting {
        guard !lines.isEmpty || recording != nil else {
            throw Failure(reason: "it holds no transcript")
        }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
            ?? ExternalImportText.title(fromFileName: origin)
        let words = lines.map(\.text).joined(separator: " ").lowercased()
            .split(whereSeparator: \.isWhitespace)
        let sourceID: String
        if words.isEmpty {
            sourceID = ExternalImportText.stableID("macwhisper-export", name.lowercased())
        } else if words.count < 20 {
            sourceID = ExternalImportText.stableID("macwhisper-export", words.joined(separator: " "), name.lowercased())
        } else {
            sourceID = ExternalImportText.stableID("macwhisper-export", words.joined(separator: " "))
        }
        return ExternalMeeting(
            source: source, sourceID: sourceID, title: name, duration: lines.compactMap(\.end).max(),
            participants: participants(in: lines), lines: lines, audioURL: recording, origin: origin)
    }

    private static func readJSON(_ url: URL, recording: URL?) throws -> ExternalImportScan {
        guard let data = try? Data(contentsOf: url) else { throw Failure(reason: "the file couldn't be opened") }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure(reason: "it isn't valid JSON")
        }
        if let object = root as? [String: Any], object["transcripts"] is [Any] {
            let folder = url.deletingLastPathComponent()
            let isMetadata = url.lastPathComponent.lowercased() == "metadata.json"
            let audio = folder.appendingPathComponent("originalAudio")
            let meeting = try WhisperDocument.meeting(
                object, origin: url, fileTitle: isMetadata ? nil : ExternalImportText.title(fromFileName: url),
                recording: { name, fileExtension in
                    guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
                    return WhisperDocument.copyRecording(audio, name: name, fileExtension: fileExtension)
                })
            return ExternalImportScan(meetings: [meeting])
        }
        var lines: [ExternalMeeting.Line] = []
        var title: String?
        if let object = root as? [String: Any], let segments = object["segments"] as? [Any] {
            lines = timedLines(segments.compactMap { $0 as? [String: Any] })
            title = (object["title"] as? String)?.nonBlank
        } else if let array = root as? [Any] {
            lines = timedLines(array.compactMap { $0 as? [String: Any] })
        } else {
            throw Failure(reason: "it doesn't hold a MacWhisper transcript")
        }
        return ExternalImportScan(meetings: [try exportedMeeting(lines, title: title, origin: url, recording: recording)])
    }

    private static func timedLines(_ segments: [[String: Any]]) -> [ExternalMeeting.Line] {
        let numbers = segments.flatMap { [number($0["start"]), number($0["end"])].compactMap { $0 } }
        let scale: Double = numbers.contains { $0 != $0.rounded() } ? 1 : 1_000
        return segments.compactMap { segment in
            guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            var start = number(segment["start"]).map { $0 / scale }
            var end = number(segment["end"]).map { $0 / scale }
            if let stamp = segment["timestamp"] as? String {
                let range = timeRange(stamp)
                start = range.start ?? start
                end = range.end ?? end
            }
            if let begin = start, let finish = end { end = max(begin, finish) }
            return ExternalMeeting.Line(start: start, end: end, speaker: speakerName(segment["speaker"]), text: text)
        }
    }

    private static func timeRange(_ value: String) -> (start: TimeInterval?, end: TimeInterval?) {
        let parts = value.replacingOccurrences(of: "-->", with: "-").replacingOccurrences(of: "–", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
        guard let first = parts.first else { return (nil, nil) }
        return (ExternalImportText.timestamp(String(first)),
                parts.count > 1 ? ExternalImportText.timestamp(String(parts[1])) : nil)
    }

    private static func docxText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let archive = try? MacWhisperZip(data),
              let entry = archive.entry(named: "document.xml"),
              let xml = try? archive.contents(of: entry),
              let paragraphs = DocxParagraphs.read(xml) else {
            throw Failure(reason: "it isn't a Word document LokalBot can open")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    fileprivate static func participants(in lines: [ExternalMeeting.Line]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in lines {
            guard let name = line.speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !isGenericSpeaker(name), seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    fileprivate static func isGenericSpeaker(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if ["unknown", "unknown speaker", "speaker"].contains(lower) { return true }
        guard lower.hasPrefix("speaker") else { return false }
        let rest = lower.dropFirst("speaker".count).trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    fileprivate static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    fileprivate static func speakerName(_ value: Any?) -> String? {
        if let name = value as? String { return name.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank }
        if let object = value as? [String: Any] {
            return (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        }
        return nil
    }

    fileprivate static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            if seconds > 100_000_000_000 { return Date(timeIntervalSince1970: seconds / 1_000) }
            if seconds >= 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
            return seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : nil
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let parsed = ExternalImportText.date(text) { return parsed }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss.SS", "yyyy-MM-dd HH:mm:ss.S"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) { return parsed }
        }
        return nil
    }

    fileprivate static func actionItems(in notes: String?) -> [ExternalMeeting.ActionItem] {
        guard let notes else { return [] }
        let sectionWords = ["action item", "next step", "to-do", "todo", "to do", "follow-up", "follow up"]
        var items: [ExternalMeeting.ActionItem] = []
        var inSection = false
        for raw in notes.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let bullet = bulletText(line) else {
                if isHeadingLike(line) {
                    let lower = line.lowercased()
                    inSection = sectionWords.contains { lower.contains($0) }
                }
                continue
            }
            if bullet.isCheckbox || inSection, !bullet.text.isEmpty {
                items.append(.init(text: bullet.text))
            }
        }
        return items
    }

    private static func bulletText(_ line: String) -> (text: String, isCheckbox: Bool)? {
        var rest = Substring(line)
        if let marker = rest.first, "-*•+".contains(marker), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2)
        } else if let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }), dot > rest.startIndex,
                  rest[..<dot].allSatisfy(\.isNumber), rest[rest.index(after: dot)...].first == " " {
            rest = rest[rest.index(after: dot)...]
        } else {
            return nil
        }
        rest = rest.drop { $0 == " " }
        var isCheckbox = false
        for box in ["[ ]", "[x]", "[X]"] where rest.hasPrefix(box) {
            rest = rest.dropFirst(box.count)
            isCheckbox = true
        }
        let text = rest.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        return (text, isCheckbox)
    }

    private static func isHeadingLike(_ line: String) -> Bool {
        line.hasPrefix("#") || (line.hasPrefix("**") && line.hasSuffix("**"))
            || (line.hasSuffix(":") && line.count <= 60)
    }

    fileprivate static func cleanedAITitle(_ value: String?) -> String? {
        guard let value else { return nil }
        for raw in value.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            for prefix in ["subject:", "title:", "topic:"] where line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“” "))
            guard !line.isEmpty else { continue }
            return line.count > 120 ? String(line.prefix(120)) : line
        }
        return nil
    }
}

private extension String {
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private enum WhisperDocument {
    typealias Failure = MacWhisperMeetingReader.Failure

    static func read(_ url: URL) throws -> ExternalImportScan {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            throw Failure(reason: "the file couldn't be opened")
        }
        if MacWhisperZip.isZip(data) {
            guard let archive = try? MacWhisperZip(data) else {
                throw Failure(reason: "it isn't a .whisper document LokalBot can open")
            }
            guard let entry = archive.entry(named: "metadata.json"),
                  let json = try? archive.contents(of: entry),
                  let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
                throw Failure(reason: "it has no MacWhisper transcript inside")
            }
            var problems: [ExternalImportScan.Problem] = []
            let meeting = try meeting(object, origin: url, fileTitle: ExternalImportText.title(fromFileName: url),
                                      recording: { name, fileExtension in
                guard let audio = archive.entry(named: "originalAudio") else { return nil }
                let unpacked = unpackRecording(audio, from: archive, name: name, fileExtension: fileExtension)
                if unpacked == nil {
                    problems.append(.init(path: url.path, reason: "its recording couldn't be unpacked, so only the transcript was read"))
                }
                return unpacked
            })
            return ExternalImportScan(meetings: [meeting], problems: problems)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(reason: "it isn't a .whisper document LokalBot can open")
        }
        return ExternalImportScan(meetings: [
            try meeting(object, origin: url, fileTitle: ExternalImportText.title(fromFileName: url), recording: { _, _ in nil }),
        ])
    }

    static func meeting(_ metadata: [String: Any], origin: URL, fileTitle: String?,
                        recording: (String, String) -> URL?) throws -> ExternalMeeting {
        guard let segments = metadata["transcripts"] as? [Any] else {
            throw Failure(reason: "it doesn't hold a MacWhisper transcript")
        }
        let reader = MacWhisperMeetingReader.self
        var lines: [ExternalMeeting.Line] = []
        for case let segment as [String: Any] in segments {
            guard let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let start = reader.number(segment["start"]).map { $0 / 1_000 }
            let end = reader.number(segment["end"]).map { $0 / 1_000 }
            lines.append(.init(start: start, end: end.map { max($0, start ?? $0) },
                               speaker: reader.speakerName(segment["speaker"]), text: text))
        }
        var participants = reader.participants(in: lines)
        for case let speaker as [String: Any] in metadata["speakers"] as? [Any] ?? [] {
            guard let name = reader.speakerName(speaker), !reader.isGenericSpeaker(name),
                  !participants.contains(where: { $0.lowercased() == name.lowercased() }) else { continue }
            participants.append(name)
        }
        let mediaName = (metadata["originalMediaFilename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let created = reader.date(metadata["dateCreated"])
        let title = (metadata["userChosenTitle"] as? String)?.nonBlank
            ?? (metadata["title"] as? String)?.nonBlank
            ?? reader.cleanedAITitle(metadata["aiTitle"] as? String)
            ?? fileTitle
            ?? mediaName.nonBlank.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? ""
        let sourceID: String
        if let created {
            sourceID = ExternalImportText.stableID(
                "whisper", String(format: "%.3f", created.timeIntervalSinceReferenceDate), mediaName)
        } else {
            let words = lines.map(\.text).joined(separator: " ").lowercased().split(whereSeparator: \.isWhitespace)
            sourceID = ExternalImportText.stableID("whisper", words.joined(separator: " "), mediaName, title.lowercased())
        }
        let notes = (metadata["aiSummary"] as? String)?.nonBlank
        let rawExtension = (metadata["originalMediaExtension"] as? String ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let baseName = mediaName.nonBlank ?? title.nonBlank ?? "MacWhisper recording"
        return ExternalMeeting(
            source: reader.source, sourceID: sourceID, title: title, startedAt: created,
            duration: lines.compactMap(\.end).max(), participants: participants, lines: lines, notes: notes,
            actionItems: reader.actionItems(in: notes), audioURL: recording(baseName, rawExtension), origin: origin)
    }

    static func unpackRecording(_ entry: MacWhisperZip.Entry, from archive: MacWhisperZip,
                                name: String, fileExtension: String) -> URL? {
        let key = ["whisper-audio", String(entry.crc), String(entry.compressedSize), String(entry.size)]
        return stage(name: name, fileExtension: fileExtension, sniff: { archive.head(of: entry) }, key: key) { target in
            try archive.write(entry, to: target)
        }
    }

    static func copyRecording(_ audio: URL, name: String, fileExtension: String) -> URL? {
        let values = try? audio.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let start: Data = {
            guard let handle = try? FileHandle(forReadingFrom: audio) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 65_536)) ?? Data()
        }()
        let key = ["whisper-audio-file", String(values?.fileSize ?? 0),
                   String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
                   start.map { String(format: "%02x", $0) }.joined()]
        let sniff: () -> Data = { start.prefix(16) }
        return stage(name: name, fileExtension: fileExtension, sniff: sniff, key: key) { target in
            try FileManager.default.copyItem(at: audio, to: target)
        }
    }

    private static func stage(name: String, fileExtension: String, sniff: () -> Data, key: [String],
                              write: (URL) throws -> Void) -> URL? {
        let fileManager = FileManager.default
        var ext = fileExtension
        if ext.isEmpty || ext.count > 10 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            ext = sniffedExtension(sniff())
        }
        var stem = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if URL(fileURLWithPath: stem).pathExtension.lowercased() == ext {
            stem = URL(fileURLWithPath: stem).deletingPathExtension().lastPathComponent
        }
        if stem.isEmpty { stem = "MacWhisper recording" }
        if stem.count > 100 { stem = String(stem.prefix(100)) }
        let folder = fileManager.temporaryDirectory.appendingPathComponent(
            "lokalbot-import-macwhisper-\(ExternalImportText.stableID(key))", isDirectory: true)
        let target = folder.appendingPathComponent("\(stem).\(ext)")
        if fileManager.fileExists(atPath: target.path) { return target }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: partial) }
            try write(partial)
            try fileManager.moveItem(at: partial, to: target)
            return target
        } catch {
            return fileManager.fileExists(atPath: target.path) ? target : nil
        }
    }

    static func sniffedExtension(_ head: Data) -> String {
        let bytes = [UInt8](head.prefix(12))
        func ascii(_ range: Range<Int>) -> String {
            guard bytes.count >= range.upperBound else { return "" }
            return String(decoding: bytes[range], as: UTF8.self)
        }
        if ascii(4..<8) == "ftyp" { return ascii(8..<12).hasPrefix("M4A") ? "m4a" : "mp4" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "FORM" { return "aiff" }
        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 {
            return bytes[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return "m4a"
    }
}

private struct MacWhisperZip {
    struct Entry {
        var name: String
        var method: Int
        var crc: Int
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    private struct Malformed: Error {}

    let data: Data
    let entries: [Entry]

    init(_ data: Data) throws {
        self.data = data
        entries = try Self.centralDirectory(of: data)
    }

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    func entry(named name: String) -> Entry? {
        entries.filter { entry in
            let parts = entry.name.split(separator: "/")
            return parts.last.map(String.init) == name && !parts.contains("__MACOSX")
        }.min { $0.name.count < $1.name.count }
    }

    func contents(of entry: Entry) throws -> Data {
        let range = try dataRange(of: entry)
        switch entry.method {
        case 0:
            return data.subdata(in: range)
        case 8:
            let inflated = try (data.subdata(in: range) as NSData).decompressed(using: .zlib) as Data
            guard inflated.count == entry.size else { throw Malformed() }
            return inflated
        default:
            throw Malformed()
        }
    }

    func write(_ entry: Entry, to url: URL) throws {
        if entry.method == 0 {
            try data[try dataRange(of: entry)].write(to: url)
        } else {
            try contents(of: entry).write(to: url)
        }
    }

    func head(of entry: Entry) -> Data {
        guard let range = try? dataRange(of: entry) else { return Data() }
        if entry.method == 0 { return data.subdata(in: range.lowerBound..<min(range.upperBound, range.lowerBound + 16)) }
        return ((try? contents(of: entry)) ?? Data()).prefix(16)
    }

    private func dataRange(of entry: Entry) throws -> Range<Int> {
        let base = entry.localHeaderOffset
        guard Self.uint32(data, base) == 0x0403_4B50 else { throw Malformed() }
        let nameLength = Self.uint16(data, base + 26)
        let extraLength = Self.uint16(data, base + 28)
        let start = base + 30 + nameLength + extraLength
        guard nameLength >= 0, extraLength >= 0, entry.compressedSize >= 0,
              start + entry.compressedSize <= data.count else { throw Malformed() }
        return (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)
    }

    private static func centralDirectory(of data: Data) throws -> [Entry] {
        let count = data.count
        guard count >= 22 else { throw Malformed() }
        var end = -1
        var offset = count - 22
        while offset >= max(0, count - 22 - 65_535) {
            if uint32(data, offset) == 0x0605_4B50 { end = offset; break }
            offset -= 1
        }
        guard end >= 0 else { throw Malformed() }
        var total = uint16(data, end + 10)
        var cursor = uint32(data, end + 16)
        if total == 0xFFFF || cursor == 0xFFFF_FFFF, end >= 20, uint32(data, end - 20) == 0x0706_4B50 {
            let record = uint64(data, end - 20 + 8)
            guard uint32(data, record) == 0x0606_4B50 else { throw Malformed() }
            total = uint64(data, record + 32)
            cursor = uint64(data, record + 48)
        }
        guard total >= 0, cursor >= 0 else { throw Malformed() }
        var entries: [Entry] = []
        for _ in 0..<total {
            guard uint32(data, cursor) == 0x0201_4B50 else { throw Malformed() }
            var compressed = uint32(data, cursor + 20)
            var size = uint32(data, cursor + 24)
            let nameLength = uint16(data, cursor + 28)
            let extraLength = uint16(data, cursor + 30)
            let commentLength = uint16(data, cursor + 32)
            var local = uint32(data, cursor + 42)
            let nameStart = cursor + 46
            guard nameLength >= 0, extraLength >= 0, commentLength >= 0,
                  nameStart + nameLength + extraLength <= count else { throw Malformed() }
            let nameBytes = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength))
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = uint16(data, extra)
                let length = uint16(data, extra + 2)
                if id == 0x0001 {
                    var field = extra + 4
                    let fieldEnd = field + length
                    if size == 0xFFFF_FFFF, field + 8 <= fieldEnd { size = uint64(data, field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= fieldEnd { compressed = uint64(data, field); field += 8 }
                    if local == 0xFFFF_FFFF, field + 8 <= fieldEnd { local = uint64(data, field) }
                }
                extra += 4 + max(length, 0)
            }
            entries.append(Entry(name: String(decoding: nameBytes, as: UTF8.self), method: uint16(data, cursor + 10),
                                 crc: uint32(data, cursor + 16), compressedSize: compressed, size: size,
                                 localHeaderOffset: local))
            cursor = extraEnd + commentLength
        }
        return entries
    }

    private static func byte(_ data: Data, _ offset: Int) -> Int {
        Int(data[data.startIndex + offset])
    }

    private static func uint16(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return -1 }
        return byte(data, offset) | byte(data, offset + 1) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return -1 }
        return uint16(data, offset) | uint16(data, offset + 2) << 16
    }

    private static func uint64(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 8 <= data.count else { return -1 }
        let value = UInt64(uint32(data, offset)) | UInt64(uint32(data, offset + 4)) << 32
        return value > UInt64(Int.max) ? -1 : Int(value)
    }
}

private final class DocxParagraphs: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var current = ""
    private var inText = false

    static func read(_ xml: Data) -> [String]? {
        let collector = DocxParagraphs()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.paragraphs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:t": inText = true
        case "w:tab": current += "\t"
        case "w:br", "w:cr": current += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "w:t": inText = false
        case "w:p":
            paragraphs.append(current)
            current = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }
}

private enum MacWhisperCSV {
    static func parse(_ text: String) -> [ExternalMeeting.Line] {
        let firstLine = text.prefix { $0 != "\n" }
        let delimiter: Character = firstLine.contains(";") ? ";" : (firstLine.contains("\t") ? "\t" : ",")
        var rows = self.rows(text, delimiter: delimiter).filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let first = rows.first else { return [] }
        var columns = (start: 0, end: 1, text: 2, speaker: 3)
        let isHeader = !first.contains { time($0) != nil }
            && first.contains { ["start", "begin", "text", "transcript", "speaker"].contains(where: $0.lowercased().contains) }
        if isHeader {
            rows.removeFirst()
            var found = (start: -1, end: -1, text: -1, speaker: -1)
            for (index, name) in first.enumerated() {
                let lower = name.lowercased()
                if lower.contains("speaker") || lower == "name" {
                    found.speaker = index
                } else if lower.contains("start") || lower.contains("begin") || lower == "from" {
                    found.start = index
                } else if lower.contains("end") || lower.contains("stop") || lower == "to" {
                    found.end = index
                } else if lower.contains("text") || lower.contains("transcript") || lower.contains("content") {
                    found.text = index
                }
            }
            columns = (found.start, found.end, found.text >= 0 ? found.text : 2, found.speaker)
        } else if rows.allSatisfy({ $0.count >= 4 }) {
            let average: (Int) -> Double = { column in
                Double(rows.reduce(0) { $0 + $1[column].count }) / Double(max(rows.count, 1))
            }
            if average(3) > average(2) { columns = (0, 1, 3, 2) }
        }
        return rows.compactMap { row in
            func field(_ index: Int) -> String? {
                index >= 0 && index < row.count ? row[index].trimmingCharacters(in: .whitespaces) : nil
            }
            guard let text = field(columns.text), !text.isEmpty else { return nil }
            let start = field(columns.start).flatMap(time)
            let end = field(columns.end).flatMap(time)
            return ExternalMeeting.Line(start: start, end: end.map { max($0, start ?? $0) },
                                        speaker: field(columns.speaker)?.nonBlank, text: text)
        }
    }

    private static func time(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return ExternalImportText.timestamp(trimmed) ?? Double(trimmed)
    }

    private static func rows(_ text: String, delimiter: Character) -> [[String]] {
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
                    let next = iterator.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        quoted = false
                        pending = next
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private enum MacWhisperText {
    private enum Item {
        case blank
        case heading(String)
        case time(TimeInterval, TimeInterval?)
        case timed(TimeInterval, TimeInterval?, String)
        case text(String)
    }

    static func parse(_ text: String) -> (title: String?, lines: [ExternalMeeting.Line]) {
        let token = #"(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?"#
        let separator = #"\s*(?:-->|–|—|-)\s*"#
        let patterns = (
            only: regex(#"^[\[(]?\s*("# + token + ")(?:" + separator + "(" + token + #"))?\s*[\])]?$"#),
            bracketed: regex(#"^[\[(]\s*("# + token + ")(?:" + separator + "(" + token + #"))?\s*[\])]\s*(.+)$"#),
            range: regex("^(" + token + ")" + separator + "(" + token + #")\s+(.+)$"#),
            bare: regex("^(" + token + #")\s+(.+)$"#))

        var cleaned: [(text: String, isHeading: Bool)] = []
        var bareCount = 0
        var textCount = 0
        for raw in text.components(separatedBy: "\n") {
            let line = clean(raw)
            cleaned.append(line)
            guard !line.text.isEmpty, !line.isHeading else { continue }
            textCount += 1
            if match(patterns.only, line.text) == nil, match(patterns.bare, line.text) != nil { bareCount += 1 }
        }
        let bareTimes = bareCount >= 2 && bareCount * 2 >= textCount

        var items: [Item] = []
        for line in cleaned {
            if line.text.isEmpty {
                items.append(.blank)
            } else if line.isHeading {
                items.append(.heading(line.text))
            } else if let groups = match(patterns.only, line.text), let start = ExternalImportText.timestamp(groups[0]) {
                items.append(.time(start, groups[1].isEmpty ? nil : ExternalImportText.timestamp(groups[1])))
            } else if let groups = match(patterns.bracketed, line.text) ?? match(patterns.range, line.text),
                      let start = ExternalImportText.timestamp(groups[0]) {
                items.append(.timed(start, groups[1].isEmpty ? nil : ExternalImportText.timestamp(groups[1]), groups[2]))
            } else if bareTimes, let groups = match(patterns.bare, line.text),
                      let start = ExternalImportText.timestamp(groups[0]) {
                items.append(.timed(start, nil, groups[1]))
            } else {
                items.append(.text(line.text))
            }
        }

        var title: String?
        if let first = items.firstIndex(where: { if case .blank = $0 { return false } else { return true } }),
           case .heading(let heading) = items[first], raw(text).hasPrefix("# ") {
            title = heading
            items.remove(at: first)
        }

        let speakers = speakerHeaders(in: items)
        var prefixCounts: [String: Int] = [:]
        for item in items {
            if case .text(let line) = item, let name = ExternalImportText.splitSpeaker(line).speaker {
                prefixCounts[name, default: 0] += 1
            }
        }
        let knownPrefix: (String) -> Bool = { name in
            (prefixCounts[name] ?? 0) >= 2 || MacWhisperMeetingReader.isGenericSpeaker(name) || speakers.contains(name)
        }
        func split(_ line: String) -> (speaker: String?, text: String) {
            let parts = ExternalImportText.splitSpeaker(line)
            guard let name = parts.speaker, knownPrefix(name) else { return (nil, line) }
            return (name, parts.text)
        }

        var lines: [ExternalMeeting.Line] = []
        var current: ExternalMeeting.Line?
        var speaker: String?
        var pending: (start: TimeInterval, end: TimeInterval?)?
        func flush() {
            if let line = current, !line.text.isEmpty { lines.append(line) }
            current = nil
        }
        for item in items {
            switch item {
            case .blank:
                flush()
            case .heading(let line):
                flush()
                if let name = headerName(line), speakers.contains(name) { speaker = name }
            case .time(let start, let end):
                flush()
                pending = (start, end)
            case .timed(let start, let end, let rest):
                flush()
                let parts = ExternalImportText.splitSpeaker(rest)
                current = .init(start: start, end: end, speaker: parts.speaker ?? speaker, text: parts.text)
                pending = nil
            case .text(let line):
                if let name = headerName(line), speakers.contains(name) {
                    flush()
                    speaker = name
                    continue
                }
                let parts = split(line)
                if current == nil || parts.speaker != nil {
                    flush()
                    current = .init(start: pending?.start, end: pending?.end, speaker: parts.speaker ?? speaker, text: parts.text)
                    pending = nil
                } else {
                    current?.text += " " + line
                }
            }
        }
        flush()
        return (title, lines)
    }

    private static func raw(_ text: String) -> String {
        text.drop { $0.isWhitespace }.description
    }

    private static func speakerHeaders(in items: [Item]) -> Set<String> {
        var counts: [String: Int] = [:]
        var accepted = Set<String>()
        func neighbor(_ index: Int, step: Int) -> Item? {
            var cursor = index + step
            while cursor >= 0 && cursor < items.count {
                if case .blank = items[cursor] { cursor += step; continue }
                return items[cursor]
            }
            return nil
        }
        for (index, item) in items.enumerated() {
            let line: String
            let isHeading: Bool
            switch item {
            case .text(let text): line = text; isHeading = false
            case .heading(let text): line = text; isHeading = true
            default: continue
            }
            guard let name = headerName(line) else { continue }
            let next = neighbor(index, step: 1)
            switch next {
            case .text?, .time?, .timed?: break
            default: continue
            }
            var besideTime = false
            if case .time? = next { besideTime = true }
            if case .time? = neighbor(index, step: -1) { besideTime = true }
            if isHeading || besideTime || MacWhisperMeetingReader.isGenericSpeaker(name) { accepted.insert(name) }
            counts[name, default: 0] += 1
        }
        for (name, count) in counts where count >= 2 { accepted.insert(name) }
        return accepted.isEmpty ? accepted : accepted.union(counts.keys)
    }

    private static func headerName(_ line: String) -> String? {
        var name = line.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(":") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, name.count <= 40, name.first?.isLetter == true,
              !name.contains(where: { ".?!,;:\"()[]".contains($0) }),
              name.split(separator: " ").count <= 5 else { return nil }
        return name
    }

    private static func clean(_ raw: String) -> (text: String, isHeading: Bool) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var isHeading = false
        if line.hasPrefix("#") {
            let rest = line.drop { $0 == "#" }
            if rest.first == " " {
                line = rest.trimmingCharacters(in: .whitespaces)
                isHeading = true
            }
        }
        if line.hasPrefix("> ") { line = String(line.dropFirst(2)) }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for marker in ["*", "_"] where line.count > 2 && line.hasPrefix(marker) && line.hasSuffix(marker) {
            line = String(line.dropFirst().dropLast())
        }
        return (line.trimmingCharacters(in: .whitespaces), isHeading)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func match(_ expression: NSRegularExpression?, _ line: String) -> [String]? {
        guard let expression,
              let result = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

private enum MacWhisperLibrary {
    typealias Failure = MacWhisperMeetingReader.Failure

    static func read(_ url: URL) throws -> ExternalImportScan {
        let database = try MacWhisperDatabase(url)
        let tables = database.tables()
        guard tables.contains("session"), tables.contains("transcriptline") else {
            throw Failure(reason: "it isn't MacWhisper's library")
        }
        let reader = MacWhisperMeetingReader.self
        let sessions = database.records("session", [
            "id", "dateCreated", "dateDeleted", "isTransient", "userChosenTitle", "aiTitle", "aiSummary",
            "aiSummaryShort", "originalFilename", "playbackDuration", "recordedMeetingID",
            "systemAudioRecordingID", "voiceMemoID", "podcastID", "downloadMetadataID",
        ])
        let meetings = index(database.records("recordedmeeting", ["id", "title", "matchedCalendarTitle", "date", "duration", "dateDeleted"]))
        let appAudio = index(database.records("systemaudiorecording", ["id", "title", "date", "duration", "dateDeleted"]))
        let memos = index(database.records("voicememos", ["id", "title"]))
        var speakers: [String: String] = [:]
        for row in database.records("speaker", ["id", "name"]) {
            if let key = key(row["id"]), let name = row["name"] as? String { speakers[key] = name }
        }
        var media: [String: [String]] = [:]
        for row in database.records("mediafile", ["sessionId", "filename"]) {
            if let key = key(row["sessionid"]), let name = row["filename"] as? String { media[key, default: []].append(name) }
        }
        var lines: [String: [(order: Double, line: ExternalMeeting.Line)]] = [:]
        for (position, row) in database.records("transcriptline", ["sessionId", "text", "start", "end", "speakerID", "orderIndex"]).enumerated() {
            guard let key = key(row["sessionid"]),
                  let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let start = reader.number(row["start"]).map { $0 / 1_000 }
            let end = reader.number(row["end"]).map { $0 / 1_000 }
            let line = ExternalMeeting.Line(start: start, end: end.map { max($0, start ?? $0) },
                                            speaker: self.key(row["speakerid"]).flatMap { speakers[$0] }, text: text)
            let order = reader.number(row["orderindex"]) ?? start ?? Double(position)
            lines[key, default: []].append((order, line))
        }
        let fullTexts = database.fullTextsWithoutLines()
        let mediaFolder = url.deletingLastPathComponent().appendingPathComponent("ExternalMedia", isDirectory: true)

        var result = ExternalImportScan()
        for row in sessions {
            guard let id = key(row["id"]),
                  !isSet(row["datedeleted"]), !isTrue(row["istransient"]),
                  row["podcastid"] == nil, row["downloadmetadataid"] == nil else { continue }
            let meeting = key(row["recordedmeetingid"]).flatMap { meetings[$0] }
            let appRecording = key(row["systemaudiorecordingid"]).flatMap { appAudio[$0] }
            let memo = key(row["voicememoid"]).flatMap { memos[$0] }
            if isSet(meeting?["datedeleted"]) || isSet(appRecording?["datedeleted"]) { continue }
            let recording = meeting ?? appRecording

            var transcript = (lines[id] ?? []).enumerated()
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .map(\.element.line)
            if transcript.isEmpty, let fullText = fullTexts[id] {
                transcript = fullText.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { ExternalMeeting.Line(text: $0) }
            }
            let notes = (row["aisummary"] as? String)?.nonBlank ?? (row["aisummaryshort"] as? String)?.nonBlank
            let title = [
                row["userchosentitle"] as? String, meeting?["matchedcalendartitle"] as? String,
                reader.cleanedAITitle(row["aititle"] as? String), meeting?["title"] as? String,
                appRecording?["title"] as? String, memo?["title"] as? String, row["originalfilename"] as? String,
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank }.first ?? ""
            let recordedFor = reader.number(recording?["duration"])
            var startedAt = reader.date(row["datecreated"])
            if let stopped = reader.date(recording?["date"]) {
                startedAt = stopped.addingTimeInterval(-(recordedFor ?? 0))
            }
            result.meetings.append(ExternalMeeting(
                source: reader.source, sourceID: id, title: title, startedAt: startedAt,
                duration: recordedFor ?? reader.number(row["playbackduration"]) ?? transcript.compactMap(\.end).max(),
                participants: reader.participants(in: transcript), lines: transcript, notes: notes,
                actionItems: reader.actionItems(in: notes),
                audioURL: recordingFile(media[id] ?? [], in: mediaFolder), origin: url))
        }
        return result
    }

    private static func recordingFile(_ names: [String], in folder: URL) -> URL? {
        let files = names.map { folder.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.count == 1 { return files[0] }
        let whole = files.filter { file in
            let name = file.lastPathComponent.lowercased()
            return !["_track-", "_mic-audio", "_app-audio"].contains(where: name.contains)
        }
        return whole.count == 1 ? whole[0] : nil
    }

    private static func index(_ rows: [[String: Any]]) -> [String: [String: Any]] {
        var byID: [String: [String: Any]] = [:]
        for row in rows { if let id = key(row["id"]) { byID[id] = row } }
        return byID
    }

    static func key(_ value: Any?) -> String? {
        if let data = value as? Data, !data.isEmpty { return data.map { String(format: "%02x", $0) }.joined() }
        if let text = value as? String, !text.isEmpty { return text.replacingOccurrences(of: "-", with: "").lowercased() }
        if let number = value as? Int64 { return String(number) }
        return nil
    }

    private static func isSet(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let number = MacWhisperMeetingReader.number(value) { return number != 0 }
        return !((value as? String)?.isEmpty ?? false)
    }

    private static func isTrue(_ value: Any?) -> Bool {
        (MacWhisperMeetingReader.number(value) ?? 0) != 0
    }
}

private final class MacWhisperDatabase {
    private let handle: OpaquePointer
    private let snapshot: URL?

    init(_ url: URL) throws {
        let fileManager = FileManager.default
        let log = URL(fileURLWithPath: url.path + "-wal")
        let logSize = (try? log.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var target = url
        var parameters = "immutable=1"
        var snapshot: URL?
        if logSize > 0 {
            let folder = fileManager.temporaryDirectory
                .appendingPathComponent("lokalbot-import-macwhisper-db-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                snapshot = folder
                target = folder.appendingPathComponent("main.sqlite")
                try fileManager.copyItem(at: url, to: target)
                try fileManager.copyItem(at: log, to: URL(fileURLWithPath: target.path + "-wal"))
                parameters = "mode=ro"
            } catch {
                if let snapshot { try? fileManager.removeItem(at: snapshot) }
                throw MacWhisperMeetingReader.Failure(reason: "the database couldn't be copied for reading")
            }
        }
        let path = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.path
        var connection: OpaquePointer?
        let status = sqlite3_open_v2("file:\(path)?\(parameters)", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            if let snapshot { try? fileManager.removeItem(at: snapshot) }
            throw MacWhisperMeetingReader.Failure(reason: "the database couldn't be opened")
        }
        sqlite3_busy_timeout(connection, 2_000)
        handle = connection
        self.snapshot = snapshot
    }

    deinit {
        sqlite3_close(handle)
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    func tables() -> Set<String> {
        Set(rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { ($0["name"] as? String)?.lowercased() })
    }

    func columns(_ table: String) -> [String: String] {
        var names: [String: String] = [:]
        for row in rows("PRAGMA table_info(\(quoted(table)))") {
            if let name = row["name"] as? String { names[name.lowercased()] = name }
        }
        return names
    }

    func records(_ table: String, _ wanted: [String]) -> [[String: Any]] {
        let present = columns(table)
        let picked = wanted.compactMap { present[$0.lowercased()] }
        guard !picked.isEmpty else { return [] }
        return rows("SELECT \(picked.map(quoted).joined(separator: ", ")) FROM \(quoted(table))")
    }

    func fullTextsWithoutLines() -> [String: String] {
        let session = columns("session")
        let lines = columns("transcriptline")
        guard let id = session["id"], let fullText = session["fulltext"], let sessionID = lines["sessionid"] else { return [:] }
        let sql = "SELECT \(quoted(id)) AS id, \(quoted(fullText)) AS fulltext FROM \"session\" "
            + "WHERE \(quoted(id)) NOT IN (SELECT \(quoted(sessionID)) FROM \"transcriptline\" WHERE \(quoted(sessionID)) IS NOT NULL)"
        var texts: [String: String] = [:]
        for row in rows(sql) {
            if let key = MacWhisperLibrary.key(row["id"]), let text = (row["fulltext"] as? String)?.nonBlank { texts[key] = text }
        }
        return texts
    }

    private func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func rows(_ sql: String) -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column).map({ String(cString: $0).lowercased() }) else { continue }
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) { row[name] = String(cString: text) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row[name] = Data(bytes: bytes, count: count)
                    }
                default:
                    break
                }
            }
            result.append(row)
        }
        return result
    }
}
