import Foundation
@testable import LokalBot

enum MeetingFixture {
    struct Spec {
        var id: UUID
        var title: String
        var startedAt: Date
        var summary: String?
        var transcriptLines: [String]

        init(
            id: UUID = UUID(),
            title: String,
            startedAt: Date,
            summary: String? = nil,
            transcriptLines: [String] = []
        ) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.summary = summary
            self.transcriptLines = transcriptLines
        }
    }

    static func write(_ specs: [Spec], under root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for spec in specs {
            let short = SessionLookup.shortID(spec.id)
            let relative = "meetings/2026/07/\(short)-fixture"
            let folder = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true)

            let meeting = Meeting(
                id: spec.id,
                title: spec.title,
                appName: "Fixture",
                startedAt: spec.startedAt,
                endedAt: spec.startedAt.addingTimeInterval(1800),
                relativePath: relative)
            try encoder.encode(meeting)
                .write(to: folder.appendingPathComponent("meta.json"))

            if let summary = spec.summary {
                try summary.write(
                    to: folder.appendingPathComponent("summary.md"),
                    atomically: true,
                    encoding: .utf8)
            }
            if !spec.transcriptLines.isEmpty {
                let segments = spec.transcriptLines.enumerated().map { index, line in
                    Transcript.Segment(
                        start: Double(index * 10),
                        end: Double(index * 10 + 9),
                        speaker: index.isMultiple(of: 2) ? "me" : "them",
                        text: line,
                        confidence: nil)
                }
                let transcript = Transcript(segments: segments, engine: "fixture")
                try encoder.encode(transcript)
                    .write(to: folder.appendingPathComponent("transcript.json"))
                try spec.transcriptLines.joined(separator: "\n")
                    .write(
                        to: folder.appendingPathComponent("transcript.md"),
                        atomically: true,
                        encoding: .utf8)
            }
        }
    }
}
