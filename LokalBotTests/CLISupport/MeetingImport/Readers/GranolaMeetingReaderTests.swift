import XCTest
@testable import LokalBot

/// Every fixture is synthetic and built here: the shapes follow Granola's
/// historical data export (Settings → Profile → Generate CSV) and what its
/// "Copy notes" and transcript-panel copy put on the clipboard.
final class GranolaMeetingReaderTests: XCTestCase {
    private enum Fixture {
        static let header = "document_id,user_email,document_title,workspace_name,document_created,summary,notes,transcript"

        static let pricingSummary = """
            ### Decisions
            - Keep the Team plan at "fifteen" per seat, billed annually

            ### Next Steps
            - Ana Petrović
              - Send the revised deck
            - Leo: book the venue for the launch
            - [ ] Draft the pricing FAQ
            - [x] Share last quarter's numbers

            ---

            Chat with meeting transcript: [https://notes.granola.ai/t/0000aaaa](https://notes.granola.ai/t/0000aaaa)
            """

        static let pricingTranscript = "Me: Morning, everyone. \nAna Petrović: Let's keep the Team plan at fifteen. \nThem: Sounds right to me. \nAna Petrović: Billed annually, then. "

        static func field(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        static func row(_ cells: [String]) -> String {
            cells.map(field).joined(separator: ",")
        }

        /// UTF-8 with a byte-order mark, CRLF rows, every field quoted, and
        /// cells with commas, quotes, and line breaks.
        static var exportCSV: String {
            let rows = [
                header,
                row(["00000000-0000-4000-8000-000000000001", "owner@example.test", "Pricing, packaging review",
                     "Example Team", "2026-10-24T14:34:40.866Z", pricingSummary, "Ask about annual billing, too.",
                     pricingTranscript]),
                row(["00000000-0000-4000-8000-0000000000AB", "owner@example.test", "Hiring sync",
                     "Example Team", "2026-10-25 09:00:00+00", "", "Typed only",
                     "Hello there.\nand then she said: we ship on Friday\nGreat, thanks."]),
                row(["00000000-0000-4000-8000-000000000003", "owner@example.test", "",
                     "Example Team", "2026-10-26T08:15:00Z", "**Action Items:**\n1. Rebook the room", "",
                     "Speaker A: Hi. Speaker B: Hello there. \nSpeaker A: Bye."]),
                row(["00000000-0000-4000-8000-000000000004", "owner@example.test", "Board check-in",
                     "Example Team", "2026-10-27T10:00:00Z", "", "",
                     "Leo Marić (he/him): Morning. \nMe: Hi Leo. \n[Room] Board room: We can hear you."]),
            ]
            return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
        }

        static let copiedNotes = """
            # Weekly sync

            Tue, 03 Nov 26\u{00A0}\u{00B7}\u{00A0}Ana Petrović, Leo Marić

            ### Decisions

            - Ship on Thursday

            ### Action Items

            - [ ] Leo to update the changelog

            ---

            Chat with meeting transcript: https://notes.granola.ai/d/00000000-0000-4000-8000-0000000000cc
            """

        static let copiedNotesWithoutLink = "# Standup\n\nWed, 04 Nov 26\n\n- Nothing blocking\n"

        static let copiedTranscript = """
            Meeting Title: Weekly sync
            Date: Nov 3
            Meeting participants: Ana Petrović, Leo Marić

            Transcript:
            Me: Are we shipping Thursday? \nLeo Marić: Yes, Thursday works. \nAna Petrović: I'll tell support.
            """

        static func localNoon(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, to folder: URL, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func exportFile() throws -> URL {
        try write(Fixture.exportCSV, to: try temporaryDirectory("granola-export"), "granola-export.csv")
    }

    // MARK: Historical data export

    func testExportRoundTripKeepsTitleStartSpeakersNotesAndActions() throws {
        let csv = try exportFile()
        let scan = try GranolaMeetingReader.read(csv)
        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 4)

        let pricing = scan.meetings[0]
        XCTAssertEqual(pricing.source, .granola)
        XCTAssertEqual(pricing.sourceID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(pricing.title, "Pricing, packaging review")
        XCTAssertEqual(pricing.startedAt?.timeIntervalSince1970 ?? 0, 1_792_852_480.866, accuracy: 0.001)
        XCTAssertNil(pricing.duration)
        XCTAssertNil(pricing.audioURL, "Granola never keeps audio")
        XCTAssertEqual(pricing.origin, csv)
        XCTAssertEqual(pricing.participants, ["Ana Petrović"], "the owner's email is not a participant")
        XCTAssertEqual(pricing.lines.map(\.speaker), ["Me", "Ana Petrović", nil, "Ana Petrović"])
        XCTAssertEqual(pricing.lines.map(\.isMe), [true, false, false, false])
        XCTAssertEqual(pricing.lines.map(\.text), ["Morning, everyone.", "Let's keep the Team plan at fifteen.",
                                                   "Sounds right to me.", "Billed annually, then."])
        XCTAssertTrue(pricing.lines.allSatisfy { $0.start == nil && $0.end == nil }, "the export keeps no line times")

        let notes = try XCTUnwrap(pricing.notes)
        XCTAssertTrue(notes.hasPrefix("### Decisions\n- Keep the Team plan at \"fifteen\" per seat"))
        XCTAssertTrue(notes.hasSuffix("- [x] Share last quarter's numbers\n\n## My notes\n\nAsk about annual billing, too."))
        XCTAssertFalse(notes.contains("Chat with meeting transcript"), "the link back to Granola's cloud is dropped")
        XCTAssertFalse(notes.contains("notes.granola.ai"))
        XCTAssertEqual(pricing.actionItems, [
            .init(text: "Send the revised deck", owner: "Ana Petrović"),
            .init(text: "book the venue for the launch", owner: "Leo"),
            .init(text: "Draft the pricing FAQ"),
        ])

        // How the writer stores it: "Me" is the person's microphone, "Them"
        // nobody in particular, and the actions are already in the notes.
        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: pricing))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["me", "them 1", "them", "them 1"])
        XCTAssertEqual(transcript.speakerAliases, ["them 1": "Ana Petrović"])
        XCTAssertTrue(transcript.segments.allSatisfy { $0.timingPrecision == .coarse })
        XCTAssertEqual(ExternalMeetingWriter.notesMarkdown(for: pricing), notes + "\n")
    }

    func testUnlabeledDiarizedAndSpeakerTaggedTranscripts() throws {
        let meetings = try GranolaMeetingReader.read(try exportFile()).meetings
        XCTAssertEqual(meetings.count, 4)

        let hiring = meetings[1]
        XCTAssertEqual(hiring.sourceID, "00000000-0000-4000-8000-0000000000ab", "UUIDs are lowercased")
        XCTAssertEqual(hiring.startedAt, Date(timeIntervalSince1970: 1_792_918_800), "a database-style date is read too")
        XCTAssertEqual(hiring.notes, "Typed only", "typed notes stand alone without a summary")
        XCTAssertEqual(hiring.lines.map(\.speaker), [nil, nil, nil])
        XCTAssertEqual(hiring.lines.map(\.text), ["Hello there.", "and then she said: we ship on Friday", "Great, thanks."],
                       "a colon in speech is not a speaker")
        XCTAssertEqual(hiring.participants, [])
        XCTAssertEqual(hiring.actionItems, [])

        let mobile = meetings[2]
        XCTAssertEqual(mobile.title, "Granola meeting")
        XCTAssertEqual(mobile.lines.map(\.speaker), ["Speaker A", "Speaker B", "Speaker A"],
                       "a mid-line \"Speaker B:\" starts a new turn, as in Granola's own copy")
        XCTAssertEqual(mobile.lines.map(\.text), ["Hi.", "Hello there.", "Bye."])
        XCTAssertEqual(mobile.participants, [], "diarized voices aren't named people")
        XCTAssertEqual(mobile.actionItems, [.init(text: "Rebook the room")])

        let tagged = meetings[3]
        XCTAssertEqual(tagged.lines.map(\.speaker), ["Leo Marić (he/him)", "Me", "Board room"])
        XCTAssertEqual(tagged.lines.map(\.isMe), [false, true, false])
        XCTAssertEqual(tagged.participants, ["Leo Marić (he/him)"], "a room is not a participant")
        XCTAssertNil(tagged.notes)
        XCTAssertFalse(tagged.isEmpty)
        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: tagged))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them 1", "me", "them 2"])
    }

    func testZippedExportReadsThroughTheSharedScan() throws {
        let folder = try temporaryDirectory("granola-zip")
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try write(Fixture.exportCSV, to: content, "granola-export.csv")
        let zip = folder.appendingPathComponent("granola-export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let result = ExternalMeetingReaders.scan(.granola, urls: [zip])
        defer { result.cleanup() }
        XCTAssertEqual(result.scan.problems, [])
        XCTAssertEqual(result.scan.meetings.map(\.sourceID), [
            "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-0000000000ab",
            "00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000004",
        ])
    }

    func testSourceIDsAreStableAcrossReads() throws {
        let csv = try exportFile()
        let first = try GranolaMeetingReader.read(csv).meetings
        let second = try GranolaMeetingReader.read(csv).meetings
        XCTAssertEqual(first.map(\.sourceID), second.map(\.sourceID))
        XCTAssertEqual(first, second)

        let folder = try temporaryDirectory("granola-stable")
        let transcript = try write(Fixture.copiedTranscript, to: folder, "transcript.txt")
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(Fixture.localNoon(2026, 11, 10))],
                                              ofItemAtPath: transcript.path)
        let copyID = try GranolaMeetingReader.read(transcript).meetings.first?.sourceID
        XCTAssertEqual(copyID, ExternalImportText.stableID("granola-copy", "weekly sync", "2026-11-03"))
        XCTAssertEqual(try GranolaMeetingReader.read(transcript).meetings.first?.sourceID, copyID)
    }

    // MARK: Copies

    func testCopiedNoteAndTranscriptReadAloneAndPairUpInAFolder() throws {
        let folder = try temporaryDirectory("granola-copies")
        let notesURL = try write(Fixture.copiedNotes, to: folder, "Weekly sync notes.md")
        let transcriptURL = try write(Fixture.copiedTranscript, to: folder, "Weekly sync transcript.txt")
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(Fixture.localNoon(2026, 11, 10))],
                                              ofItemAtPath: transcriptURL.path)

        let note = try XCTUnwrap(GranolaMeetingReader.read(notesURL).meetings.first)
        XCTAssertEqual(note.sourceID, "00000000-0000-4000-8000-0000000000cc", "a /d/ link carries the document id")
        XCTAssertEqual(note.title, "Weekly sync")
        XCTAssertEqual(note.startedAt, Fixture.localNoon(2026, 11, 3))
        XCTAssertEqual(note.participants, ["Ana Petrović", "Leo Marić"])
        XCTAssertEqual(note.notes, "### Decisions\n\n- Ship on Thursday\n\n### Action Items\n\n- [ ] Leo to update the changelog")
        XCTAssertEqual(note.actionItems, [.init(text: "Leo to update the changelog")])
        XCTAssertEqual(note.lines, [])

        let transcript = try XCTUnwrap(GranolaMeetingReader.read(transcriptURL).meetings.first)
        XCTAssertEqual(transcript.title, "Weekly sync")
        XCTAssertEqual(transcript.startedAt, Fixture.localNoon(2026, 11, 3), "the year comes from when the file was saved")
        XCTAssertEqual(transcript.participants, ["Ana Petrović", "Leo Marić"])
        XCTAssertEqual(transcript.lines.map(\.speaker), ["Me", "Leo Marić", "Ana Petrović"])
        XCTAssertEqual(transcript.lines.map(\.isMe), [true, false, false])
        XCTAssertEqual(transcript.lines.map(\.text), ["Are we shipping Thursday?", "Yes, Thursday works.", "I'll tell support."])

        let merged = try GranolaMeetingReader.read(folder)
        XCTAssertEqual(merged.problems, [])
        XCTAssertEqual(merged.meetings.count, 1, "the note and its transcript are one meeting")
        let meeting = try XCTUnwrap(merged.meetings.first)
        XCTAssertEqual(meeting.sourceID, note.sourceID)
        XCTAssertEqual(meeting.notes, note.notes)
        XCTAssertEqual(meeting.lines, transcript.lines)
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marić"])
    }

    func testCopiedNoteWithoutItsLinkIsRecognizedByTheDateLine() throws {
        let url = try write(Fixture.copiedNotesWithoutLink, to: try temporaryDirectory("granola-nolink"), "standup.md")
        XCTAssertTrue(GranolaMeetingReader.recognizes(url))
        let meeting = try XCTUnwrap(GranolaMeetingReader.read(url).meetings.first)
        XCTAssertEqual(meeting.title, "Standup")
        XCTAssertEqual(meeting.startedAt, Fixture.localNoon(2026, 11, 4))
        XCTAssertEqual(meeting.sourceID, ExternalImportText.stableID("granola-copy", "standup", "2026-11-04"))
        XCTAssertEqual(meeting.notes, "- Nothing blocking")
    }

    // MARK: Recognizing and problems

    func testRecognizesOnlyGranolaFiles() throws {
        let folder = try temporaryDirectory("granola-recognize")
        XCTAssertTrue(GranolaMeetingReader.recognizes(try write(Fixture.exportCSV, to: folder, "export.csv")))
        XCTAssertTrue(GranolaMeetingReader.recognizes(try write(Fixture.copiedNotes, to: folder, "notes.md")))
        XCTAssertTrue(GranolaMeetingReader.recognizes(try write(Fixture.copiedTranscript, to: folder, "transcript.txt")))
        XCTAssertFalse(GranolaMeetingReader.recognizes(try write("id,title,created\n1,Standup,2026-01-01\n", to: folder, "other.csv")))
        XCTAssertFalse(GranolaMeetingReader.recognizes(try write("# Notes\n\nJust notes.\n", to: folder, "plain.md")))
        XCTAssertFalse(GranolaMeetingReader.recognizes(try write("not audio", to: folder, "audio.m4a")))
        XCTAssertFalse(GranolaMeetingReader.recognizes(try write("{}", to: folder, "cache-v6.json.enc")),
                       "Granola's encrypted cache is never read")
        XCTAssertEqual(GranolaMeetingReader.defaultLocations, [])
    }

    func testUnrecognizedFileAndFolderThrow() throws {
        let folder = try temporaryDirectory("granola-unrecognized")
        let other = try write("id,title\n1,Standup\n", to: folder, "other.csv")
        XCTAssertThrowsError(try GranolaMeetingReader.read(other)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.granola, "other.csv"))
        }
        XCTAssertThrowsError(try GranolaMeetingReader.read(folder)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.granola, folder.lastPathComponent))
        }
    }

    func testUnreadableFilesInAFolderAreProblemsAndTheRestIsRead() throws {
        let folder = try temporaryDirectory("granola-problems")
        try write(Fixture.exportCSV, to: folder, "export.csv")
        try write("Unrelated text.\n", to: folder, "readme.txt")
        let cut = try write(Fixture.header + "\n\"00000000-0000-4000-8000-000000000009\",\"\",\"Cut\",\"\",\"2026-10-27T10:00:00Z\",\"unfinished",
                            to: folder, "cut.csv")
        let locked = try write(Fixture.exportCSV, to: folder, "locked.csv")
        let canLock = getuid() != 0
        if canLock {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let scan = try GranolaMeetingReader.read(folder)
        let problemNames = scan.problems.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(problemNames, canLock ? [cut.lastPathComponent, locked.lastPathComponent] : [cut.lastPathComponent])
        XCTAssertTrue(scan.problems.first?.reason.contains("cut off") == true)
        XCTAssertFalse(scan.problems.contains { $0.reason.contains("unfinished") || $0.reason.contains("Cut") },
                       "reasons never quote what a file holds")
        XCTAssertEqual(scan.meetings.count, canLock ? 4 : 8)
        XCTAssertEqual(Set(scan.meetings.map(\.sourceID)).count, 4)
    }
}
