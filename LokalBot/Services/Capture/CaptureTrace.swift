import CoreGraphics
import Foundation

struct CaptureTrace: Codable, Equatable {
    static let currentSchemaVersion = 1

    struct Header: Codable, Equatable {
        enum Origin: String, Codable { case scripted, real, reconstructed }
        var schemaVersion: Int
        var macOSVersion: String
        var origin: Origin
        var scenario: String
        var scrubberVersion: Int?
        var recordedAt: Date
    }

    enum Query: String, Codable {
        case frontmost, runningApps, isRunning, idleSeconds, trusted, axRead, focusedTitle
        case browserSnapshot, browserReadIssue, screenCaptureGranted, windows, audioProcesses, inputRunning
        case browserMicrophoneWindowsAllowed
    }

    struct Event: Codable, Equatable {
        var t: TimeInterval
        var query: Query
        var processID: pid_t?
        var includeText: Bool?
        var app: RunningApp?
        var apps: [RunningApp]?
        var flag: Bool?
        var seconds: Double?
        var read: AccessibilityRead?
        var title: String?
        var browser: BrowserMeetingSession.Snapshot?
        var issue: BrowserMeetingSession.ReadIssue?
        var windows: [ScreenshotCaptureLayout.Window]?
        var processes: [AudioProcess]?
        var microphoneWindows: BrowserMeetingSession.MicrophoneWindows?

        init(t: TimeInterval, query: Query, processID: pid_t? = nil, includeText: Bool? = nil,
             app: RunningApp? = nil, apps: [RunningApp]? = nil, flag: Bool? = nil, seconds: Double? = nil,
             read: AccessibilityRead? = nil, title: String? = nil,
             browser: BrowserMeetingSession.Snapshot? = nil, issue: BrowserMeetingSession.ReadIssue? = nil,
             windows: [ScreenshotCaptureLayout.Window]? = nil, processes: [AudioProcess]? = nil,
             microphoneWindows: BrowserMeetingSession.MicrophoneWindows? = nil) {
            self.t = t
            self.query = query
            self.processID = processID
            self.includeText = includeText
            self.app = app
            self.apps = apps
            self.flag = flag
            self.seconds = seconds
            self.read = read
            self.title = title
            self.browser = browser
            self.issue = issue
            self.windows = windows
            self.processes = processes
            self.microphoneWindows = microphoneWindows
        }

        var key: String { "\(query.rawValue)|\(processID ?? -1)|\(includeText.map(String.init) ?? "-")" }
    }

    var header: Header
    var events: [Event]

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func load(from url: URL) throws -> CaptureTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureTrace.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }
}
