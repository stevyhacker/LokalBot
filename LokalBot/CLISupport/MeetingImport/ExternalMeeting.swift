import Foundation

/// Another app's meetings LokalBot can bring in. The raw value is what
/// `lokalbot-cli import` takes and what a meeting's `importSource.app` stores.
enum ExternalMeetingSource: String, CaseIterable, Codable, Sendable {
    case granola
    case otter
    case fireflies
    case fathom
    case screenpipe
    case zoom
    case voiceMemos = "voice-memos"
    case macWhisper = "macwhisper"

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
        }
    }

    /// What the person points LokalBot at, said the way the source's own
    /// menus say it. Shown in the import panel and by `import sources`.
    var exportHint: String {
        ExternalMeetingReaders.reader(for: self).exportHint
    }

    /// Where the source keeps data LokalBot can read on this computer, with
    /// `~` for the home folder. Used when the person names no file or folder.
    var defaultLocations: [String] {
        ExternalMeetingReaders.reader(for: self).defaultLocations
    }
}

/// One meeting as another app kept it, before LokalBot stores it. Readers
/// fill it from exports or local files; `ExternalMeetingWriter` turns it into
/// a meeting folder.
struct ExternalMeeting: Equatable, Sendable {
    /// One line of a transcript.
    struct Line: Equatable, Sendable {
        /// Seconds from the start of the meeting, when the source kept them.
        var start: TimeInterval?
        var end: TimeInterval?
        /// The name the source shows, such as "Ana" or "Speaker 2". Nil when
        /// the source names nobody.
        var speaker: String?
        var text: String
        /// The source says this came from the person's own microphone, as
        /// Granola does for its "microphone" lines. Such lines become "Me".
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
    /// Stable within the source: the same meeting read twice, from the same
    /// or a newer export, gets the same id, so importing again skips it.
    /// Prefer the source's own id; otherwise hash what can't change, such as
    /// the start time and title.
    var sourceID: String
    var title: String
    var startedAt: Date?
    var duration: TimeInterval?
    var participants: [String]
    var lines: [Line]
    /// The source's own notes or summary, as Markdown.
    var notes: String?
    var actionItems: [ActionItem]
    /// A recording to keep with the meeting. LokalBot transcribes it when the
    /// source had no transcript.
    var audioURL: URL?
    /// The file or folder this meeting was read from.
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

    /// The key a meeting's `importSource` is matched on.
    var importKey: String { "\(source.rawValue)/\(sourceID)" }

    /// Nothing worth a meeting: no transcript, notes, actions, or recording.
    var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && actionItems.isEmpty
            && audioURL == nil
    }
}

/// What reading a file or folder found: the meetings, and what couldn't be
/// read and why. Problems name files, never their contents.
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

/// Reads one source's exports or local files. A reader only reads: it never
/// writes, moves, or changes what it reads, and opens databases read-only.
protocol ExternalMeetingReader {
    static var source: ExternalMeetingSource { get }
    /// Where to find what this reader reads, said the way the source's own
    /// menus say it, in one or two sentences.
    static var exportHint: String { get }
    /// Paths with `~` for the home folder where the source keeps data this
    /// reader can read without an export. Empty when it needs an export.
    static var defaultLocations: [String] { get }
    /// A quick check, from names, extensions, or a header, that `url` holds
    /// this source's data. Used to pick files inside a folder.
    static func recognizes(_ url: URL) -> Bool
    /// Every meeting in `url`, a file or a folder. Throws only when nothing
    /// in it can be read; single bad items go to `problems`.
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
        }
    }

    /// The default locations that exist on this computer, expanded.
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

    /// Reads every url with `source`'s reader. A `.zip` is unpacked into a
    /// temporary folder first; `cleanup` removes those folders, so call it
    /// once nothing reads the meetings' `audioURL`s any more. Meetings with
    /// the same source id are kept once, and empty ones are dropped.
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

/// Unpacks a `.zip` export with `ditto`, which ships with macOS and keeps
/// Unicode file names intact.
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
