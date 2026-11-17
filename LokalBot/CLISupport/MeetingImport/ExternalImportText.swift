import CryptoKit
import Foundation

/// Parsing shared by the meeting readers: timestamps, dates, subtitle files,
/// text decoding, folder walks, and stable ids.
enum ExternalImportText {
    /// "01:02:03,450", "01:02:03.450", "1:02:03", "02:03", or "02:03.5" in
    /// seconds. Nil for anything else.
    static func timestamp(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                  let number = Double(part), number >= 0 else { return nil }
            if !isLast, number != number.rounded() { return nil }
            if index > 0, number >= 60 { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    /// ISO 8601 with or without fractional seconds or a time zone (a
    /// missing zone is read as UTC, as the formats that omit it mean).
    static func date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            [.withFullDate, .withFullTime, .withFractionalSeconds, .withSpaceBetweenDateAndTime],
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// A 32-character hex id from parts that identify a meeting when the
    /// source has no id of its own. The same parts always give the same id.
    static func stableID(_ parts: String...) -> String {
        stableID(parts)
    }

    static func stableID(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// UTF-8 (with or without a byte-order mark), else UTF-16 with a mark,
    /// else Windows-1252, the encodings exports use. Line endings become "\n".
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Regular files under `folder` (or `folder` itself when it is a file),
    /// sorted by path, skipping hidden files and macOS archive litter.
    static func files(in folder: URL, recursive: Bool = true) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [folder] }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard !url.pathComponents.contains("__MACOSX"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A title from a file name: no extension, underscores as spaces.
    static func title(fromFileName url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Imported meeting" : stem
    }

    /// Splits "Ana Petrović: Let's ship it" into a speaker and the rest when
    /// the part before the colon reads like a name: short, starting with a
    /// letter, and without sentence punctuation.
    static func splitSpeaker(_ line: String) -> (speaker: String?, text: String) {
        guard let colon = line.firstIndex(of: ":") else { return (nil, line) }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !rest.isEmpty,
              name.first?.isLetter == true,
              !name.contains(where: { ".?!,;\"()[]".contains($0) }),
              name.split(separator: " ").count <= 5 else { return (nil, line) }
        return (name, rest)
    }
}

/// SubRip (`.srt`) and WebVTT (`.vtt`) captions, the transcript exports
/// Otter, Fireflies, Zoom, and MacWhisper all offer. A speaker comes from a
/// WebVTT voice tag (`<v Ana>`) or a leading "Name:".
enum SubtitleTranscript {
    static func parse(_ text: String) -> [ExternalMeeting.Line] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [ExternalMeeting.Line] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = rows[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { continue }
            // WebVTT allows cue settings after the end time.
            let endField = timing[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = ExternalImportText.timestamp(timing[0]),
                  let end = ExternalImportText.timestamp(endField) else { continue }
            rows.removeFirst(timingIndex + 1)
            var speaker: String?
            var parts: [String] = []
            for row in rows {
                var content = row
                if let voice = voiceTag(in: content) {
                    speaker = voice.speaker
                    content = voice.text
                }
                content = stripTags(content).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { parts.append(content) }
            }
            var body = parts.joined(separator: " ")
            if speaker == nil {
                let split = ExternalImportText.splitSpeaker(body)
                speaker = split.speaker
                body = split.text
            }
            guard !body.isEmpty else { continue }
            // Consecutive cues from the same speaker read as one turn.
            if let last = lines.last, last.speaker == speaker, let lastEnd = last.end, start - lastEnd < 1.5,
               (last.text.count + body.count) < 600 {
                lines[lines.count - 1].text += " " + body
                lines[lines.count - 1].end = end
            } else {
                lines.append(ExternalMeeting.Line(start: start, end: max(end, start), speaker: speaker, text: body))
            }
        }
        return lines
    }

    private static func voiceTag(in row: String) -> (speaker: String, text: String)? {
        guard let open = row.range(of: "<v"), let close = row.range(of: ">", range: open.upperBound..<row.endIndex) else {
            return nil
        }
        var name = row[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        // `<v.loud Ana>` carries classes before the name.
        if name.hasPrefix("."), let space = name.firstIndex(of: " ") {
            name = String(name[space...]).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty else { return nil }
        let rest = row[close.upperBound...].replacingOccurrences(of: "</v>", with: "")
        return (name, rest)
    }

    private static func stripTags(_ row: String) -> String {
        row.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
