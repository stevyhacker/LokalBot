import ArgumentParser
import Foundation

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Bring meetings in from another app, after the person approves it in LokalBot.",
        discussion: """
            Reads another app's export or local files and adds the meetings
            LokalBot doesn't have yet: notes, transcripts, action items, and
            recordings. The files are only read, never changed. Importing the
            same export again adds nothing twice.

            --dry-run reads the files here and prints what they hold, without
            LokalBot or any access. Otherwise the request goes to LokalBot,
            which reads the files itself and asks the person on an approval
            card (needs "Allow external agents to change LokalBot settings").
            --wait follows it: exit 0 approved, 4 declined, 5 expired.

              lokalbot-cli import sources
              lokalbot-cli import otter ~/Downloads/otter-export.zip --dry-run
              lokalbot-cli import screenpipe --wait 120
            """)

    @Argument(help: ArgumentHelp(
        "The app: " + ExternalMeetingSource.allCases.map(\.rawValue).joined(separator: ", ")
            + ". Or `sources` to list them with where to export.",
        valueName: "source"))
    var source: String

    @Argument(help: ArgumentHelp(
        "Export files, folders, or .zip archives. Defaults to where the app keeps its data on this computer, when LokalBot can read it there.",
        valueName: "path"))
    var paths: [String] = []

    @Flag(name: .long, help: "Read the files and print what an import would bring in, changing nothing.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print a plain-text table instead of JSON.")
    var table: Bool = false

    @OptionGroup var approval: ApprovalWaitOptions

    @OptionGroup var launch: AppLaunchOptions

    func run() throws {
        if source == "sources" {
            print(table ? Self.sourcesTable() : ControlOutput.json(Self.sourcesJSON()))
            return
        }
        guard let source = ExternalMeetingSource(rawValue: source) else {
            throw ValidationError("Unknown source \(source). Choose one of: "
                + ExternalMeetingSource.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let urls = paths.isEmpty
            ? ExternalMeetingReaders.existingDefaultLocations(for: source)
            : paths.map { ExternalMeetingReaders.expand(($0 as NSString).expandingTildeInPath).standardizedFileURL }
        guard !urls.isEmpty else {
            throw ValidationError(ExternalImportError.noDefaultLocation(source).localizedDescription)
        }
        if dryRun {
            let result = ExternalMeetingReaders.scan(source, urls: urls)
            defer { result.cleanup() }
            print(table ? Self.previewTable(result.scan, source: source)
                        : ControlOutput.json(Self.previewJSON(result.scan, source: source)))
            return
        }
        try ControlOutput.sendForApproval(
            .meetingsImport,
            params: ["source": .string(source.rawValue), "paths": .array(urls.map { .string($0.path) })],
            launch: launch, wait: approval.wait)
    }

    static func sourcesJSON() -> JSONValue {
        .array(ExternalMeetingSource.allCases.map { source in
            [
                "source": .string(source.rawValue),
                "title": .string(source.title),
                "howToExport": .string(source.exportHint),
                "foundOnThisComputer": .array(ExternalMeetingReaders.existingDefaultLocations(for: source)
                    .map { .string($0.path) }),
            ]
        })
    }

    static func sourcesTable() -> String {
        ExternalMeetingSource.allCases.map { source in
            let found = ExternalMeetingReaders.existingDefaultLocations(for: source).map(\.path)
            return "\(source.rawValue)\t\(source.title)\n  \(source.exportHint)"
                + (found.isEmpty ? "" : "\n  Found: " + found.joined(separator: ", "))
        }.joined(separator: "\n")
    }

    /// What the files hold, newest first. Titles and counts only: notes and
    /// transcripts stay in the files.
    static func previewJSON(_ scan: ExternalImportScan, source: ExternalMeetingSource) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let meetings = scan.meetings.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        return [
            "source": .string(source.rawValue),
            "found": .number(Double(meetings.count)),
            "meetings": .array(meetings.map { meeting in
                var object: [String: JSONValue] = [
                    "id": .string(meeting.sourceID),
                    "title": .string(meeting.title),
                    "transcriptLines": .number(Double(meeting.lines.count)),
                    "hasNotes": .bool(!(meeting.notes ?? "").isEmpty),
                    "actionItems": .number(Double(meeting.actionItems.count)),
                    "hasRecording": .bool(meeting.audioURL != nil),
                    "file": .string(meeting.origin.path),
                ]
                if let start = meeting.startedAt { object["startedAt"] = .string(formatter.string(from: start)) }
                if let duration = meeting.duration { object["durationSeconds"] = .number(duration.rounded()) }
                return .object(object)
            }),
            "problems": .array(scan.problems.map { ["path": .string($0.path), "reason": .string($0.reason)] }),
        ]
    }

    static func previewTable(_ scan: ExternalImportScan, source: ExternalMeetingSource) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var rows = scan.meetings
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .map { meeting -> String in
                let date = meeting.startedAt.map(formatter.string(from:)) ?? "—"
                let parts = [
                    meeting.lines.isEmpty ? nil : "\(meeting.lines.count) lines",
                    (meeting.notes ?? "").isEmpty ? nil : "notes",
                    meeting.actionItems.isEmpty ? nil : "\(meeting.actionItems.count) actions",
                    meeting.audioURL == nil ? nil : "recording",
                ].compactMap { $0 }
                return "\(date)\t\(meeting.title)\t\(parts.joined(separator: ", "))"
            }
        rows.insert("\(scan.meetings.count) \(source.title) meetings", at: 0)
        rows += scan.problems.map { "Couldn't read \($0.path): \($0.reason)" }
        return rows.joined(separator: "\n")
    }
}
