import Foundation

enum ExternalMeetingSource: String, CaseIterable, Codable, Sendable {
    case granola
    case otter
    case fireflies
    case fathom
    case screenpipe
    case zoom
    case voiceMemos = "voice-memos"
    case macWhisper = "macwhisper"
    case wisprFlow = "wispr-flow"

    var title: String {
        switch self {
        case .granola: "Granola"
        case .otter: "Otter"
        case .fireflies: "Fireflies"
        case .fathom: "Fathom"
        case .screenpipe: "Screenpipe"
        case .zoom: "Zoom"
        case .voiceMemos: "Voice Memos"
        case .macWhisper: "MacWhisper"
        case .wisprFlow: "Wispr Flow"
        }
    }

    var exportHint: String {
        ExternalMeetingReaders.reader(for: self).exportHint
    }

    var defaultLocations: [String] {
        ExternalMeetingReaders.reader(for: self).defaultLocations
    }
}

struct ExternalMeeting: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var start: TimeInterval?
        var end: TimeInterval?
        var speaker: String?
        var text: String
        var isMe: Bool = false

        init(start: TimeInterval? = nil, end: TimeInterval? = nil, speaker: String? = nil,
             text: String, isMe: Bool = false) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.text = text
            self.isMe = isMe
        }
    }

    struct ActionItem: Equatable, Sendable {
        var text: String
        var owner: String?

        init(text: String, owner: String? = nil) {
            self.text = text
            self.owner = owner
        }
    }

    var source: ExternalMeetingSource
    var sourceID: String
    var title: String
    var startedAt: Date?
    var duration: TimeInterval?
    var participants: [String]
    var lines: [Line]
    var notes: String?
    var actionItems: [ActionItem]
    var audioURL: URL?
    var origin: URL

    init(source: ExternalMeetingSource, sourceID: String, title: String, startedAt: Date? = nil,
         duration: TimeInterval? = nil, participants: [String] = [], lines: [Line] = [],
         notes: String? = nil, actionItems: [ActionItem] = [], audioURL: URL? = nil, origin: URL) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.participants = participants
        self.lines = lines
        self.notes = notes
        self.actionItems = actionItems
        self.audioURL = audioURL
        self.origin = origin
    }

    var importKey: String { "\(source.rawValue)/\(sourceID)" }

    var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && actionItems.isEmpty
            && audioURL == nil
    }
}

struct ExternalImportScan: Sendable {
    struct Problem: Equatable, Sendable {
        var path: String
        var reason: String
    }

    var meetings: [ExternalMeeting]
    var problems: [Problem]

    init(meetings: [ExternalMeeting] = [], problems: [Problem] = []) {
        self.meetings = meetings
        self.problems = problems
    }

    mutating func append(_ other: ExternalImportScan) {
        meetings += other.meetings
        problems += other.problems
    }
}

protocol ExternalMeetingReader {
    static var source: ExternalMeetingSource { get }
    static var exportHint: String { get }
    static var defaultLocations: [String] { get }
    static func recognizes(_ url: URL) -> Bool
    static func read(_ url: URL) throws -> ExternalImportScan
}

enum ExternalImportError: LocalizedError, Equatable {
    case notFound(String)
    case unrecognized(ExternalMeetingSource, String)
    case unreadable(String, String)
    case notImplemented(ExternalMeetingSource)
    case noDefaultLocation(ExternalMeetingSource)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "Nothing is at \(path)."
        case .unrecognized(let source, let path):
            "\(path) doesn't look like a \(source.title) export. \(source.exportHint)"
        case .unreadable(let path, let reason):
            "Couldn't read \(path): \(reason)"
        case .notImplemented(let source):
            "Importing from \(source.title) isn't available in this version yet."
        case .noDefaultLocation(let source):
            "LokalBot didn't find \(source.title) data on this computer. \(source.exportHint)"
        }
    }
}

enum ExternalMeetingReaders {
    static func reader(for source: ExternalMeetingSource) -> any ExternalMeetingReader.Type {
        switch source {
        case .granola: GranolaMeetingReader.self
        case .otter: OtterMeetingReader.self
        case .fireflies: FirefliesMeetingReader.self
        case .fathom: FathomMeetingReader.self
        case .screenpipe: ScreenpipeMeetingReader.self
        case .zoom: ZoomMeetingReader.self
        case .voiceMemos: VoiceMemosMeetingReader.self
        case .macWhisper: MacWhisperMeetingReader.self
        case .wisprFlow: WisprFlowMeetingReader.self
        }
    }

    static func existingDefaultLocations(for source: ExternalMeetingSource,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        source.defaultLocations.compactMap { path in
            let url = expand(path, home: home)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func expand(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    static func scan(_ source: ExternalMeetingSource, urls: [URL]) -> (scan: ExternalImportScan, cleanup: @Sendable () -> Void) {
        let reader = reader(for: source)
        var result = ExternalImportScan()
        var temporaryFolders: [URL] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.problems.append(.init(path: url.path, reason: ExternalImportError.notFound(url.path).localizedDescription))
                continue
            }
            var input = url
            if url.pathExtension.lowercased() == "zip" {
                do {
                    let folder = try ExternalImportArchive.unzip(url)
                    temporaryFolders.append(folder)
                    input = folder
                } catch {
                    result.problems.append(.init(path: url.path, reason: error.localizedDescription))
                    continue
                }
            }
            do {
                result.append(try reader.read(input))
            } catch {
                result.problems.append(.init(path: url.path, reason: error.localizedDescription))
            }
        }
        temporaryFolders += stagedFolders(in: result.meetings)
        var seen = Set<String>()
        result.meetings = result.meetings.filter { meeting in
            !meeting.isEmpty && seen.insert(meeting.importKey).inserted
        }
        let folders = temporaryFolders
        let cleanup: @Sendable () -> Void = {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
        return (result, cleanup)
    }
}

extension ExternalMeetingReaders {
    static func stagedFolders(in meetings: [ExternalMeeting],
                              temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> [URL] {
        let root = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var folders: [URL] = []
        for audio in meetings.compactMap(\.audioURL) {
            let folder = audio.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard folder.lastPathComponent.hasPrefix("lokalbot-import-"),
                  folder.deletingLastPathComponent().path == root,
                  !folders.contains(folder) else { continue }
            folders.append(folder)
        }
        return folders
    }
}

enum ExternalImportArchive {
    static func unzip(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw ExternalImportError.unreadable(url.lastPathComponent, "the archive couldn't be unpacked")
        }
        return folder
    }
}
