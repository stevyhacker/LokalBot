import XCTest
@testable import LokalBot

final class FirefliesMeetingReaderTests: XCTestCase {
    static let apiTranscript = """
        {"data": {"transcript": {
          "id": "01JABCDEF0123456789XYZ",
          "title": "Pricing review",
          "date": 1772619300000,
          "dateString": "2026-03-04T10:15:00.000Z",
          "duration": 31.5,
          "transcript_url": "https://app.fireflies.ai/view/Pricing-review::01JABCDEF0123456789XYZ",
          "organizer_email": "ana@example.com",
          "participants": ["ana@example.com,leo@example.com", "mia@example.com"],
          "meeting_attendees": [
            {"displayName": "Ana Petrović", "email": "ana@example.com", "phoneNumber": null},
            {"displayName": null, "email": "leo@example.com"}
          ],
          "speakers": [{"id": 0, "name": "Ana Petrović"}, {"id": 1, "name": "Leo"}],
          "sentences": [
            {"index": 0, "speaker_name": "Ana Petrović", "speaker_id": 0, "text": "Let's keep the Team plan.",
             "raw_text": "lets keep the team plan", "start_time": 0.5, "end_time": 2.4},
            {"index": 1, "speaker_name": "Ana Petrović", "speaker_id": 0, "text": "At fifteen per seat.",
             "raw_text": "at fifteen per seat", "start_time": 2.6, "end_time": 4.0},
            {"index": 2, "speaker_name": "Leo", "speaker_id": 1, "text": "Billed annually.",
             "start_time": 5.0, "end_time": 6.2},
            {"index": 3, "speaker_name": null, "speaker_id": 1, "text": "I'll draft the email.",
             "start_time": 1880.0, "end_time": 1885.5}
          ],
          "summary": {
            "overview": "The team kept the Team plan price.",
            "shorthand_bullet": "💰 **Pricing** (00:00 - 00:06)\\n- Team plan stays at fifteen per seat",
            "action_items": "**Leo**\\nDraft the pricing email (31:20)\\n\\n**Ana Petrović**\\nUpdate the pricing page (00:04)\\n",
            "keywords": ["pricing", "Team plan"],
            "outline": null
          }
        }}}
        """

    static let subtitles = """
        1
        00:00:01,000 --> 00:00:03,000
        Mia: The mockups are ready.

        2
        00:00:03,200 --> 00:00:05,000
        Mia: Two screens left.

        3
        00:00:06,000 --> 00:00:08,500
        Leo: Ship them Friday.
        """

    static let markdownSummary = """
        # Design sync

        ## Overview
        The team reviewed the new mockups.

        ## Action Items
        **Mia**
        - Ship the mockups (00:06)

        Powered by Fireflies.ai
        """

    static let markdownTranscript = """
        # Roadmap planning

        Date: Mar 4, 2026 10:15 AM
        Participants: Ana Petrović, Leo

        ## Transcript

        **Ana Petrović** (00:00:05): We start with the roadmap.
        Leo - 00:12
        Sounds good.
        Second paragraph continues.

        [00:00:30] Ana Petrović: Then hiring.

        View in Fireflies: https://app.fireflies.ai/view/Roadmap-planning::01JROADMAP0001
        """

    static let csvTranscript = """
        "Speaker","Start Time","End Time","Sentence"\r
        "Ana Petrović","00:00:01","00:00:03","Hello, everyone."\r
        "Leo","00:00:04","00:00:06","He said ""ship it"", so we ship."\r

        """

    private func temporaryFolder(_ name: String = "fireflies") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func meeting(titled title: String, in scan: ExternalImportScan) throws -> ExternalMeeting {
        try XCTUnwrap(scan.meetings.first { $0.title == title }, "no meeting titled \(title)")
    }

    func testAPITranscriptWithSummaryAndAudioRoundTrip() throws {
        let folder = try temporaryFolder()
        try write(Self.apiTranscript, "Pricing review transcript.json", in: folder)
        let audio = folder.appendingPathComponent("Pricing review audio.mp3")
        try Data([0x49, 0x44, 0x33, 0x04, 0x00]).write(to: audio)

        let scan = try FirefliesMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.source, .fireflies)
        XCTAssertEqual(meeting.sourceID, "01JABCDEF0123456789XYZ")
        XCTAssertEqual(meeting.title, "Pricing review")
        XCTAssertEqual(meeting.startedAt, Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertEqual(meeting.duration ?? 0, 1_890, accuracy: 0.001, "the API counts minutes")
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo", "leo@example.com", "mia@example.com"])
        XCTAssertEqual(meeting.lines, [
            .init(start: 0.5, end: 4.0, speaker: "Ana Petrović", text: "Let's keep the Team plan. At fifteen per seat."),
            .init(start: 5.0, end: 6.2, speaker: "Leo", text: "Billed annually."),
            .init(start: 1_880, end: 1_885.5, speaker: "Leo", text: "I'll draft the email."),
        ])
        XCTAssertFalse(meeting.lines.contains(where: \.isMe), "Fireflies never says which line was the person's microphone")
        let notes = try XCTUnwrap(meeting.notes)
        XCTAssertTrue(notes.hasPrefix("## Overview\n\nThe team kept the Team plan price."))
        XCTAssertTrue(notes.contains("## Notes\n\n💰 **Pricing** (00:00 - 00:06)\n- Team plan stays at fifteen per seat"))
        XCTAssertTrue(notes.hasSuffix("**Keywords:** pricing, Team plan"))
        XCTAssertFalse(notes.contains("Draft the pricing email"), "action items are listed by the writer, once")
        XCTAssertEqual(meeting.actionItems, [
            .init(text: "Draft the pricing email", owner: "Leo"),
            .init(text: "Update the pricing page", owner: "Ana Petrović"),
        ])
        XCTAssertEqual(meeting.audioURL?.lastPathComponent, "Pricing review audio.mp3")
        XCTAssertEqual(meeting.origin.lastPathComponent, "Pricing review transcript.json")
    }

    func testSubtitlesAndMarkdownSummaryOfOneMeetingAreMerged() throws {
        let folder = try temporaryFolder()
        try write(Self.subtitles, "Design sync.srt", in: folder)
        try write(Self.markdownSummary, "Design sync - summary.md", in: folder)

        let scan = try FirefliesMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try meeting(titled: "Design sync", in: scan)
        XCTAssertNil(meeting.startedAt)
        XCTAssertEqual(meeting.lines, [
            .init(start: 1, end: 5, speaker: "Mia", text: "The mockups are ready. Two screens left."),
            .init(start: 6, end: 8.5, speaker: "Leo", text: "Ship them Friday."),
        ])
        XCTAssertEqual(meeting.participants, ["Mia", "Leo"])
        XCTAssertEqual(meeting.notes, """
            ## Overview
            The team reviewed the new mockups.

            ## Action Items
            **Mia**
            - Ship the mockups (00:06)
            """)
        XCTAssertEqual(meeting.actionItems, [.init(text: "Ship the mockups", owner: "Mia")])
        XCTAssertNil(meeting.audioURL)
    }

    func testMarkdownTranscriptLayoutsAndHeaderDetails() throws {
        let folder = try temporaryFolder()
        let file = try write(Self.markdownTranscript, "Roadmap.md", in: folder)

        let scan = try FirefliesMeetingReader.read(file)

        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.sourceID, "01JROADMAP0001", "the link back to Fireflies carries its id")
        XCTAssertEqual(meeting.title, "Roadmap planning")
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo"])
        let start = try XCTUnwrap(meeting.startedAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 3, 4, 10, 15])
        XCTAssertEqual(meeting.lines, [
            .init(start: 5, speaker: "Ana Petrović", text: "We start with the roadmap."),
            .init(start: 12, speaker: "Leo", text: "Sounds good. Second paragraph continues."),
            .init(start: 30, speaker: "Ana Petrović", text: "Then hiring."),
        ])
        XCTAssertNil(meeting.notes, "the branding line and header details aren't notes")
    }

    func testCSVTranscriptKeepsQuotedCommasAndQuotes() throws {
        let folder = try temporaryFolder()
        try write(Self.csvTranscript, "Retro.csv", in: folder)

        let scan = try FirefliesMeetingReader.read(folder)

        let meeting = try meeting(titled: "Retro", in: scan)
        XCTAssertEqual(meeting.lines, [
            .init(start: 1, end: 3, speaker: "Ana Petrović", text: "Hello, everyone."),
            .init(start: 4, end: 6, speaker: "Leo", text: "He said \"ship it\", so we ship."),
        ])
    }

    func testRecognizesFirefliesFilesOnly() throws {
        let folder = try temporaryFolder()
        let recognized = [
            try write(Self.apiTranscript, "a.json", in: folder),
            try write(#"[{"speaker": "Ana", "text": "Hello", "startTime": 1.5}]"#, "b.json", in: folder),
            try write(Self.subtitles, "c.srt", in: folder),
            try write(Self.csvTranscript, "d.csv", in: folder),
            try write(Self.markdownTranscript, "e.md", in: folder),
            try write(Self.markdownSummary, "f.md", in: folder),
        ]
        for url in recognized {
            XCTAssertTrue(FirefliesMeetingReader.recognizes(url), url.lastPathComponent)
        }
        let rejected = [
            try write(#"{"name": "app", "version": "1.0.0"}"#, "package.json", in: folder),
            try write("Milk\nEggs\nBread\n", "groceries.txt", in: folder),
            try write("Name,Amount\nRent,1200\n", "budget.csv", in: folder),
            try write("1\nno timing here\n", "broken.srt", in: folder),
            try write("%PDF-1.7", "Pricing review.pdf", in: folder),
            try write("ID3", "Pricing review.mp3", in: folder),
        ]
        for url in rejected {
            XCTAssertFalse(FirefliesMeetingReader.recognizes(url), url.lastPathComponent)
        }
    }

    func testFolderWithAnUnreadableFileStillReadsTheRest() throws {
        let folder = try temporaryFolder()
        try write(Self.subtitles, "Standup.srt", in: folder)
        let broken = try write(#"{"sentences": [{"text": "Secret plans"#, "Broken transcript.json", in: folder)
        try write("Milk\nEggs\n", "groceries.txt", in: folder)

        let scan = try FirefliesMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.map(\.title), ["Standup"])
        XCTAssertEqual(scan.problems.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
                       [broken.resolvingSymlinksInPath().path])
        XCTAssertEqual(scan.problems.first?.reason, "it isn't valid JSON")
        XCTAssertFalse(scan.problems.contains { $0.reason.contains("Secret") }, "reasons never quote the file")
    }

    func testSourceIDsAreStableAcrossReadsAndCopies() throws {
        let first = try temporaryFolder()
        let second = try temporaryFolder()
        for folder in [first, second] {
            try write(Self.subtitles, "Design sync.srt", in: folder)
            try write(Self.apiTranscript, "Pricing review.json", in: folder)
        }
        let ids = { (folder: URL) throws -> [String] in
            try FirefliesMeetingReader.read(folder).meetings.map(\.sourceID).sorted()
        }
        let firstIDs = try ids(first)
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(firstIDs, try ids(first))
        XCTAssertEqual(firstIDs, try ids(second))
        XCTAssertTrue(firstIDs.contains("01JABCDEF0123456789XYZ"))
        XCTAssertTrue(firstIDs.contains { $0.count == 32 }, "a meeting without an id gets a stable hash")
    }

    func testSentenceArrayWithMillisecondTimesAndSpeakerIDs() throws {
        let folder = try temporaryFolder()
        let file = try write("""
            [
              {"speaker_id": 0, "speaker": "Ana", "text": "Hello there.", "startTime": 1200, "endTime": 2400},
              {"speaker_id": 3, "text": "Hi, who's this?", "startTime": 95000, "endTime": 97500},
              {"speaker": "Ana", "text": "It's Ana.", "startTime": 98000, "endTime": 99000}
            ]
            """, "Intro call.json", in: folder)

        let meeting = try XCTUnwrap(try FirefliesMeetingReader.read(file).meetings.first)

        XCTAssertEqual(meeting.title, "Intro call")
        XCTAssertEqual(meeting.lines, [
            .init(start: 1.2, end: 2.4, speaker: "Ana", text: "Hello there."),
            .init(start: 95, end: 97.5, speaker: "Speaker 3", text: "Hi, who's this?"),
            .init(start: 98, end: 99, speaker: "Ana", text: "It's Ana."),
        ])
        XCTAssertEqual(meeting.participants, ["Ana"], "unnamed speakers aren't participants")
    }

    func testSummaryDownloadWithReadableKeysAndListedActions() throws {
        let folder = try temporaryFolder()
        let file = try write("""
            {"Title": "Budget", "Date": "2026-05-01T09:00:00Z", "Overview": "We set the Q3 budget.",
             "Action Items": ["- Send the budget to finance (02:10)", {"text": "Book the offsite", "assignee": "Unassigned"}],
             "Keywords": "budget, finance"}
            """, "Budget summary.json", in: folder)

        let meeting = try XCTUnwrap(try FirefliesMeetingReader.read(file).meetings.first)

        XCTAssertEqual(meeting.title, "Budget")
        XCTAssertEqual(meeting.startedAt, ExternalImportText.date("2026-05-01T09:00:00Z"))
        XCTAssertEqual(meeting.notes, "## Overview\n\nWe set the Q3 budget.\n\n**Keywords:** budget, finance")
        XCTAssertEqual(meeting.actionItems, [.init(text: "Send the budget to finance"), .init(text: "Book the offsite")])
        XCTAssertTrue(meeting.lines.isEmpty)
        XCTAssertEqual(meeting.sourceID, ExternalImportText.stableID("fireflies", "1777626000", "budget"))
    }

    func testAccountExportMetadataTakesInFilesNamedByIDOrTitle() throws {
        let folder = try temporaryFolder()
        try write("""
            [{"id": "COLLECTIONID0001", "title": "Board call", "date": 1772619300000, "duration": 20},
             {"id": "COLLECTIONID0002", "title": "Hiring sync", "dateString": "2026-03-05T09:00:00Z"}]
            """, "meetings.json", in: folder)
        try write("Ana: Welcome, everyone.\nLeo: Thanks.\nAna: First item.\n", "Board call.txt", in: folder)
        try write("Overview\nWe agreed to hire two engineers.\n\nAction Items\n- Post the job ad\n",
                  "COLLECTIONID0002_summary.txt", in: folder)
        try Data([0x49, 0x44, 0x33]).write(to: folder.appendingPathComponent("Board call.mp3"))

        let scan = try FirefliesMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.map(\.sourceID), ["COLLECTIONID0001", "COLLECTIONID0002"])
        let board = try meeting(titled: "Board call", in: scan)
        XCTAssertEqual(board.startedAt, Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertEqual(board.duration, 1_200)
        XCTAssertEqual(board.lines.map(\.speaker), ["Ana", "Leo", "Ana"])
        XCTAssertEqual(board.audioURL?.lastPathComponent, "Board call.mp3")
        let hiring = try meeting(titled: "Hiring sync", in: scan)
        XCTAssertEqual(hiring.notes, "Overview\nWe agreed to hire two engineers.\n\nAction Items\n- Post the job ad")
        XCTAssertEqual(hiring.actionItems, [.init(text: "Post the job ad")])
    }

    func testZippedDownloadsAreReadThroughTheScan() throws {
        let folder = try temporaryFolder()
        let content = folder.appendingPathComponent("Fireflies export/Pricing review", isDirectory: true)
        try write(Self.apiTranscript, "transcript.json", in: content)
        try Data([0x49, 0x44, 0x33]).write(to: content.appendingPathComponent("audio.mp3"))
        let zip = folder.appendingPathComponent("fireflies-export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", folder.appendingPathComponent("Fireflies export").path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let result = ExternalMeetingReaders.scan(.fireflies, urls: [zip])
        defer { result.cleanup() }

        XCTAssertEqual(result.scan.problems, [])
        let meeting = try XCTUnwrap(result.scan.meetings.first)
        XCTAssertEqual(result.scan.meetings.count, 1)
        XCTAssertEqual(meeting.sourceID, "01JABCDEF0123456789XYZ")
        XCTAssertEqual(meeting.audioURL?.lastPathComponent, "audio.mp3", "a meeting's own folder keeps its recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.audioURL?.path ?? ""))
    }

    func testFilesChosenOnTheirOwn() throws {
        let folder = try temporaryFolder()
        let pdf = try write("%PDF-1.7", "Pricing review.pdf", in: folder)
        XCTAssertThrowsError(try FirefliesMeetingReader.read(pdf))
        let empty = try write(#"{"title": "Nothing here", "date": "2026-03-04"}"#, "empty.json", in: folder)
        XCTAssertThrowsError(try FirefliesMeetingReader.read(empty))
        XCTAssertThrowsError(try FirefliesMeetingReader.read(folder.appendingPathComponent("missing.json")))

        let audio = folder.appendingPathComponent("Weekly sync - audio.mp3")
        try Data([0x49, 0x44, 0x33]).write(to: audio)
        let recording = try XCTUnwrap(try FirefliesMeetingReader.read(audio).meetings.first)
        XCTAssertEqual(recording.title, "Weekly sync")
        XCTAssertEqual(recording.audioURL, audio)
        XCTAssertFalse(recording.isEmpty)
    }

    func testAFolderWithNothingFromFirefliesIsUnrecognized() throws {
        let folder = try temporaryFolder()
        try write("Milk\nEggs\n", "groceries.txt", in: folder)
        XCTAssertThrowsError(try FirefliesMeetingReader.read(folder)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.fireflies, folder.path))
        }
        XCTAssertTrue(FirefliesMeetingReader.defaultLocations.isEmpty)
        XCTAssertFalse(FirefliesMeetingReader.exportHint.isEmpty)
    }
}
