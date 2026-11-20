import Foundation

enum ZoomMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.zoom
    static let exportHint = "Choose the Zoom folder in Documents, or one meeting's folder in it; the Zoom app shows where it saves computer recordings under Settings › Recording › Local recording storage. For a cloud recording, open Recordings & Transcripts › Cloud recordings in the Zoom web portal, click the meeting, download its Audio only and Audio transcript files, and choose them."
    static let defaultLocations = ["~/Documents/Zoom"]

    static func recognizes(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return kind(of: url) != nil }
        if isRecordingFolderName(url.lastPathComponent) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children.contains { isRecordingFolderName($0.lastPathComponent) || kind(of: $0) != nil }
    }

    static func read(_ url: URL) throws -> ExternalImportScan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ExternalImportError.notFound(url.path)
        }
        let groups: [(group: Group, members: [Member])]
        if isDirectory.boolValue {
            let members = ExternalImportText.files(in: url).compactMap { file in
                kind(of: file).map { Member(url: file, kind: $0) }
            }
            guard !members.isEmpty else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
            groups = grouped(members)
        } else {
            guard let kind = kind(of: url) else { throw ExternalImportError.unrecognized(source, url.lastPathComponent) }
            groups = [recording(around: Member(url: url, kind: kind))]
        }
        var scan = ExternalImportScan()
        for (group, members) in groups {
            if let meeting = meeting(for: group, members: members, problems: &scan.problems) {
                scan.meetings.append(meeting)
            }
        }
        return scan
    }

    private enum Kind {
        case audio
        case participantAudio
        case video
        case subtitles
        case captions
        case chat
        case unconverted
    }

    private struct Member {
        var url: URL
        var kind: Kind
    }

    private static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let fromZoom = CloudStamp(name: url.lastPathComponent) != nil
            || isRecordingFolderName(recordingFolder(of: url).lastPathComponent)
        switch url.pathExtension.lowercased() {
        case "m4a":
            if isInAudioRecordFolder(url) { return .participantAudio }
            if isGenericAudio(stem) || CloudStamp(name: url.lastPathComponent) != nil { return .audio }
            guard fromZoom else { return nil }
            return looksLikeParticipantTrack(stem) ? .participantAudio : .audio
        case "mp4":
            return fromZoom || isGenericVideo(stem) ? .video : nil
        case "vtt":
            return .subtitles
        case "txt":
            let zoomNamed = fromZoom || name.hasPrefix("meeting_saved_") || name.hasPrefix("closed_caption")
            if name.contains("chat") { return zoomNamed || stem == "chat" ? .chat : nil }
            if name.contains("caption") || name.contains("transcript") { return zoomNamed ? .captions : nil }
            return nil
        case "zoom":
            return name.hasPrefix("double_click_to_convert") ? .unconverted : nil
        default:
            return nil
        }
    }

    private static func isGenericAudio(_ stem: String) -> Bool {
        guard stem.hasPrefix("audio") else { return false }
        var rest = stem.dropFirst(5)
        if rest.hasPrefix("_only") { rest = rest.dropFirst(5) }
        if rest.hasPrefix("_") { rest = rest.dropFirst() }
        return rest.allSatisfy(isDigit)
    }

    private static func looksLikeParticipantTrack(_ stem: String) -> Bool {
        stem.hasPrefix("audio") && stem.dropFirst(5).contains(where: \.isLetter) && stem.last.map(isDigit) == true
    }

    private static func isGenericVideo(_ stem: String) -> Bool {
        if stem.hasPrefix("zoom_") {
            let rest = stem.dropFirst(5)
            return !rest.isEmpty && rest.allSatisfy(isDigit)
        }
        return stem.hasPrefix("video") && stem.dropFirst(5).allSatisfy(isDigit)
    }

    private static func isInAudioRecordFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.lowercased() == "audio record"
    }

    private static func hasComputerRecordingName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "m4a": return isGenericAudio(stem) || isInAudioRecordFolder(url)
        case "mp4": return isGenericVideo(stem)
        case "txt": return stem == "chat" || name.hasPrefix("meeting_saved_") || name.hasPrefix("closed_caption")
        case "zoom": return name.hasPrefix("double_click_to_convert")
        default: return false
        }
    }

    private static func recordingFolder(of file: URL) -> URL {
        let parent = file.deletingLastPathComponent()
        return parent.lastPathComponent.lowercased() == "audio record" ? parent.deletingLastPathComponent() : parent
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func hasPattern(_ text: Substring, _ pattern: String) -> Bool {
        guard text.count >= pattern.count else { return false }
        return zip(text, pattern).allSatisfy { character, expected in
            expected == "#" ? isDigit(character) : character == expected
        }
    }

    private static func isRecordingFolderName(_ name: String) -> Bool {
        let name = Substring(name)
        return hasPattern(name, "####-##-## ##.##.##") && (name.count == 19 || name.dropFirst(19).first == " ")
    }

    private struct FolderStamp {
        var date: Date
        var secondsIntoDay: TimeInterval
        var topic: String

        init?(name: String) {
            let name = name.precomposedStringWithCanonicalMapping
            guard ZoomMeetingReader.isRecordingFolderName(name) else { return nil }
            let stamp = String(name.prefix(19))
            let rest = name.dropFirst(19)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            formatter.isLenient = true
            guard let date = formatter.date(from: stamp) else { return nil }
            self.date = date
            secondsIntoDay = stamp.suffix(8).split(separator: ".").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
            var words = rest.split(separator: " ").map(String.init)
            if words.count > 1, let last = words.last, (9...11).contains(last.count),
               last.allSatisfy(ZoomMeetingReader.isDigit) {
                words.removeLast()
            }
            topic = words.joined(separator: " ")
        }
    }

    private struct CloudStamp {
        var key: String
        var date: Date

        init?(name: String) {
            guard name.hasPrefix("GMT"), ZoomMeetingReader.hasPattern(name.dropFirst(3), "########-######") else {
                return nil
            }
            key = String(name.dropFirst(3).prefix(15))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            guard let date = formatter.date(from: key) else { return nil }
            self.date = date
        }
    }

    private enum Group: Hashable {
        case folder(String)
        case cloud(folder: String, stamp: String)
        case file(String)
    }

    private static func group(of file: URL) -> Group {
        let folder = recordingFolder(of: file).standardizedFileURL
        if isRecordingFolderName(folder.lastPathComponent) || hasComputerRecordingName(file) {
            return .folder(folder.path)
        }
        if let stamp = CloudStamp(name: file.lastPathComponent) {
            return .cloud(folder: folder.path, stamp: stamp.key)
        }
        return .file(file.standardizedFileURL.path)
    }

    private static func grouped(_ members: [Member]) -> [(group: Group, members: [Member])] {
        var order: [Group] = []
        var byGroup: [Group: [Member]] = [:]
        for member in members {
            let key = group(of: member.url)
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(member)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    private static func recording(around chosen: Member) -> (group: Group, members: [Member]) {
        let target = group(of: chosen.url)
        if case .file = target { return (target, [chosen]) }
        let siblings = ExternalImportText.files(in: recordingFolder(of: chosen.url), recursive: false)
            .compactMap { file in kind(of: file).map { Member(url: file, kind: $0) } }
            .filter { group(of: $0.url) == target }
        let chosenPath = chosen.url.standardizedFileURL.path
        let hasChosen = siblings.contains { $0.url.standardizedFileURL.path == chosenPath }
        return (target, hasChosen ? siblings : siblings + [chosen])
    }

    private static func meeting(for group: Group, members: [Member],
                                problems: inout [ExternalImportScan.Problem]) -> ExternalMeeting? {
        func files(_ kind: Kind) -> [URL] { members.filter { $0.kind == kind }.map(\.url) }
        let folderStamp: FolderStamp?
        if case .folder(let path) = group {
            folderStamp = FolderStamp(name: URL(fileURLWithPath: path).lastPathComponent)
        } else {
            folderStamp = nil
        }

        var audioURL = playable(ranked(files(.audio), by: audioRank), problems: &problems)
        if audioURL == nil {
            audioURL = playable(ranked(files(.video), by: videoRank), problems: &problems)
        }
        var subtitleFile: URL?
        var lines = transcript(ranked(files(.subtitles), by: subtitleRank), chosen: &subtitleFile, problems: &problems)
        if lines.isEmpty, audioURL == nil {
            lines = savedCaptions(ranked(files(.captions), by: captionRank),
                                  meetingClock: folderStamp?.secondsIntoDay, problems: &problems)
        }
        guard !lines.isEmpty || audioURL != nil else {
            if case .folder(let path) = group, !files(.unconverted).isEmpty {
                problems.append(.init(path: path, reason: "Zoom hasn't converted this recording yet. Double-click double_click_to_convert_01.zoom in its folder, or open it from Computer recordings in the Zoom app, then import again."))
            }
            return nil
        }

        let title: String
        let startedAt: Date?
        let sourceID: String
        let origin: URL
        switch group {
        case .folder(let path):
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let name = folder.lastPathComponent.precomposedStringWithCanonicalMapping
            title = folderStamp.map { $0.topic.isEmpty ? "Zoom meeting" : $0.topic } ?? name
            startedAt = folderStamp?.date
            sourceID = ExternalImportText.stableID("zoom-folder", name)
            origin = folder
        case .cloud(_, let stamp):
            title = "Zoom meeting"
            startedAt = CloudStamp(name: "GMT" + stamp)?.date
            sourceID = ExternalImportText.stableID("zoom-cloud", stamp)
            origin = audioURL ?? subtitleFile ?? members[0].url
        case .file(let path):
            let file = URL(fileURLWithPath: path)
            title = transcriptTitle(file)
            startedAt = nil
            sourceID = ExternalImportText.stableID(["zoom-file", title] + lines.map(\.text))
            origin = file
        }

        var participants: [String] = []
        for speaker in lines.compactMap(\.speaker)
        where !participants.contains(where: { $0.caseInsensitiveCompare(speaker) == .orderedSame }) {
            participants.append(speaker)
        }
        return ExternalMeeting(
            source: source, sourceID: sourceID, title: title, startedAt: startedAt,
            duration: lines.compactMap(\.end).max(), participants: participants, lines: lines,
            audioURL: audioURL, origin: origin)
    }

    private static func transcriptTitle(_ file: URL) -> String {
        var stem = file.deletingPathExtension()
        if ["transcript", "cc"].contains(stem.pathExtension.lowercased()) { stem = stem.deletingPathExtension() }
        return ExternalImportText.title(fromFileName: stem.appendingPathExtension(file.pathExtension))
    }

    private static func ranked(_ files: [URL], by rank: (URL) -> Int) -> [URL] {
        files.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func audioRank(_ url: URL) -> Int {
        isGenericAudio(url.deletingPathExtension().lastPathComponent.lowercased())
            || CloudStamp(name: url.lastPathComponent) != nil ? 0 : 1
    }

    private static func videoRank(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem.contains("_as_") { return 2 }
        return isGenericVideo(stem) || CloudStamp(name: url.lastPathComponent) != nil ? 0 : 1
    }

    private static func subtitleRank(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        if name.contains(".transcript") || name.contains("transcript.") { return 0 }
        if name.contains(".cc.") || name.contains("caption") { return 2 }
        return 1
    }

    private static func captionRank(_ url: URL) -> Int {
        url.lastPathComponent.lowercased().hasPrefix("meeting_saved_") ? 0 : 1
    }

    private static func playable(_ files: [URL], problems: inout [ExternalImportScan.Problem]) -> URL? {
        for file in files {
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                problems.append(.init(path: file.path, reason: "LokalBot can't open this recording."))
                continue
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0 else {
                problems.append(.init(path: file.path, reason: "This recording file is empty."))
                continue
            }
            return file
        }
        return nil
    }

    private static func transcript(_ files: [URL], chosen: inout URL?,
                                   problems: inout [ExternalImportScan.Problem]) -> [ExternalMeeting.Line] {
        var fallback: (file: URL, lines: [ExternalMeeting.Line])?
        for file in files {
            guard let text = readTranscript(file, problems: &problems) else { continue }
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
            guard trimmed.hasPrefix("WEBVTT") || trimmed.contains("-->") else {
                problems.append(.init(path: file.path, reason: "This isn't a WebVTT transcript."))
                continue
            }
            let lines = named(SubtitleTranscript.parse(trimmed))
            if lines.contains(where: { $0.speaker != nil }) {
                chosen = file
                return lines
            }
            if fallback == nil, !lines.isEmpty { fallback = (file, lines) }
        }
        chosen = fallback?.file
        return fallback?.lines ?? []
    }

    private static func savedCaptions(_ files: [URL], meetingClock: TimeInterval?,
                                      problems: inout [ExternalImportScan.Problem]) -> [ExternalMeeting.Line] {
        var fallback: [ExternalMeeting.Line] = []
        for file in files {
            guard let text = readTranscript(file, problems: &problems) else { continue }
            let lines = named(captionLines(text, meetingClock: meetingClock))
            if lines.contains(where: { $0.speaker != nil }) { return lines }
            if fallback.isEmpty { fallback = lines }
        }
        return fallback
    }

    private static func readTranscript(_ file: URL, problems: inout [ExternalImportScan.Problem]) -> String? {
        do {
            return try ExternalImportText.readText(file)
        } catch {
            problems.append(.init(path: file.path, reason: "LokalBot can't open this transcript."))
            return nil
        }
    }

    private static func named(_ lines: [ExternalMeeting.Line]) -> [ExternalMeeting.Line] {
        lines.map { line in
            var line = line
            if let speaker = line.speaker?.trimmingCharacters(in: .whitespaces),
               speaker.isEmpty || speaker.caseInsensitiveCompare("Unknown Speaker") == .orderedSame {
                line.speaker = nil
            }
            return line
        }
    }

    private static func captionLines(_ text: String, meetingClock: TimeInterval?) -> [ExternalMeeting.Line] {
        if text.contains("-->") { return SubtitleTranscript.parse(text) }
        var entries: [(clock: TimeInterval?, speaker: String?, words: [String], headed: Bool)] = []
        for raw in text.components(separatedBy: "\n") {
            let row = raw.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }
            if let header = captionHeader(row) {
                entries.append((header.clock, header.speaker, header.words.map { [$0] } ?? [], true))
            } else if let last = entries.last, last.headed {
                entries[entries.count - 1].words.append(row)
            } else {
                let split = ExternalImportText.splitSpeaker(row)
                entries.append((nil, split.speaker, [split.text], false))
            }
        }
        let wrapped: (TimeInterval) -> TimeInterval = { $0 < 0 ? $0 + 86_400 : $0 }
        var base = entries.lazy.compactMap(\.clock).first
        if let meetingClock, let first = base, wrapped(first - meetingClock) < 6 * 3_600 { base = meetingClock }
        return entries.compactMap { entry in
            let words = entry.words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return nil }
            let start = entry.clock.flatMap { clock in base.map { wrapped(clock - $0) } }
            return ExternalMeeting.Line(start: start, speaker: entry.speaker, text: words)
        }
    }

    private static func captionHeader(_ row: String) -> (clock: TimeInterval, speaker: String?, words: String?)? {
        if row.hasPrefix("["), let close = row.firstIndex(of: "]") {
            let inside = row[row.index(after: row.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            let after = row[row.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let clock = clockTime(inside) {
                let split = ExternalImportText.splitSpeaker(after)
                return (clock, split.speaker, split.text.isEmpty ? nil : split.text)
            }
            if let clock = clockTime(after), !inside.isEmpty { return (clock, inside, nil) }
            return nil
        }
        let token = row.prefix { !$0.isWhitespace }
        guard let clock = clockTime(String(token)) else { return nil }
        let rest = row.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return (clock, nil, nil) }
        let split = ExternalImportText.splitSpeaker(rest)
        return (clock, split.speaker, split.text)
    }

    private static func clockTime(_ text: String) -> TimeInterval? {
        guard text.filter({ $0 == ":" }).count == 2 else { return nil }
        return ExternalImportText.timestamp(text)
    }
}
