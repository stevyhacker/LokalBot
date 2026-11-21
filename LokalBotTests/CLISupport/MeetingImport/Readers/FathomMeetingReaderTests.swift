import XCTest
@testable import LokalBot

private let shareToken = "SyntheticShareToken_0001"

private let copiedTranscript = """
    Pricing review - March 4
    VIEW RECORDING - 64 mins (1 min of highlights): https://fathom.video/share/\(shareToken)

    ---

      ACTION ITEM: Send the revised price sheet to Leo
     - WATCH: https://fathom.video/share/\(shareToken)?timestamp=0.0

    0:00 - Ana Petrović (Example Co)
      Let's keep the Team plan at fifteen per seat.
      BOOKMARK: Pricing - WATCH: https://fathom.video/share/\(shareToken)?timestamp=3.0  Billed annually.

    0:12 - Leo Marić (leo@example.com)
      HIGHLIGHT: Discount - WATCH: https://fathom.video/share/\(shareToken)?timestamp=12.0
        Then we drop the monthly discount.

        Agreed by everyone.


    1:02:03 - Ana Petrović (Example Co)
      Ship it Thursday.

    """

private let copiedSummary = """
    Pricing review - March 4
    VIEW RECORDING: https://fathom.video/share/\(shareToken)
    Meeting Purpose

    Settle the Team plan price.

    Key Takeaways

      - Team plan stays at fifteen per seat - WATCH (5 secs): https://fathom.video/share/\(shareToken)?timestamp=3.0
      - Monthly discount goes away

    Topics

    Pricing

      - Billed annually
          - Monthly billing costs more

    Next Steps

      - Ana:
          - Update the pricing page
      - Leo: Tell the sales team

    Action Items
      - Send the revised price sheet to Leo - WATCH (5 secs): https://fathom.video/share/\(shareToken)?timestamp=0.0

    """

private let expectedSummary = """
    ## Meeting Purpose

    Settle the Team plan price.

    ## Key Takeaways

      - Team plan stays at fifteen per seat
      - Monthly discount goes away

    ## Topics

    ### Pricing

      - Billed annually
          - Monthly billing costs more

    ## Next Steps

      - Ana:
          - Update the pricing page
      - Leo: Tell the sales team

    ## Action Items

      - Send the revised price sheet to Leo
    """

private let apiList = """
    {
      "limit": 10,
      "next_cursor": null,
      "items": [
        {
          "title": "Design sync",
          "meeting_title": "Design sync (calendar)",
          "meeting_type": null,
          "recording_id": 111,
          "url": "https://fathom.video/calls/111",
          "share_url": "https://fathom.video/share/SyntheticShareToken_0002",
          "created_at": "2026-03-05T10:01:30Z",
          "scheduled_start_time": "2026-03-05T09:00:00Z",
          "scheduled_end_time": "2026-03-05T10:00:00Z",
          "recording_start_time": "2026-03-05T09:01:12Z",
          "recording_end_time": "2026-03-05T09:31:12Z",
          "calendar_invitees_domains_type": "only_internal",
          "shared_with": "no_teams",
          "transcript_language": "en",
          "calendar_invitees": [
            {"name": "Mia Example", "email": "mia@example.com", "email_domain": "example.com", "is_external": false},
            {"name": null, "email": "guest@example.org", "email_domain": "example.org", "is_external": true}
          ],
          "recorded_by": {"name": "Mia Example", "email": "mia@example.com", "email_domain": "example.com", "team": null},
          "transcript": [
            {"speaker": {"display_name": "Mia Example", "matched_calendar_invitee_email": "mia@example.com"},
             "text": "Morning, let's look at the mockups.", "timestamp": "00:00:05"},
            {"speaker": {"display_name": "Noah Sample"}, "text": "The header feels heavy.", "timestamp": "00:01:10"}
          ],
          "default_summary": {
            "template_name": "general",
            "markdown_formatted": "## Summary\\n\\n[Lighter header agreed.](https://fathom.video/share/SyntheticShareToken_0002?tab=summary&timestamp=70.0)\\n"
          },
          "action_items": [
            {"description": "Send the new mockups", "user_generated": false, "completed": false,
             "recording_timestamp": "00:01:20", "recording_playback_url": "https://fathom.video/calls/111?timestamp=80",
             "assignee": {"name": "Noah Sample", "email": null, "team": null}},
            {"description": "Book the review room", "user_generated": true, "completed": true,
             "recording_timestamp": "00:02:00", "recording_playback_url": "https://fathom.video/calls/111?timestamp=120",
             "assignee": {"name": null, "email": null, "team": null}}
          ],
          "highlights": [
            {"type": "Decision", "summary": "Lighter header", "text": "Let's make the header lighter", "start_time": 70, "end_time": 75.5}
          ],
          "crm_matches": null
        },
        {
          "title": "Quick check-in",
          "recording_id": 222,
          "url": "https://fathom.video/xyz222",
          "share_url": "not a link",
          "created_at": "2026-03-06T08:00:00Z",
          "transcript": [
            {"speaker": {"display_name": "Noah Sample"}, "text": "All good here.", "timestamp": "00:00:01"}
          ]
        }
      ]
    }
    """

private let headerlessTranscript = "0:00 - Ana\n  Hello there.\n\n0:04 - Leo\n  Hi Ana.\n"

final class FathomMeetingReaderTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fathom-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in folder: URL, modified: Date? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func localDay(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private func assertSameFile(_ url: URL?, _ expected: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(url?.resolvingSymlinksInPath().path, expected.resolvingSymlinksInPath().path,
                       file: file, line: line)
    }

    func testCopiedTranscriptSummaryAndVideoOfOneCallBecomeOneMeeting() throws {
        let folder = try temporaryDirectory("roundtrip")
        let transcriptURL = try write(copiedTranscript, "Pricing review.txt", in: folder, modified: localDay(2026, 3, 10))
        try write(copiedSummary, "Pricing review summary.md", in: folder, modified: localDay(2026, 3, 10))
        let video = try write("synthetic video bytes", "Pricing review.mp4", in: folder)

        let scan = try FathomMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.source, .fathom)
        XCTAssertEqual(meeting.sourceID, shareToken, "the share link's token is Fathom's own id")
        XCTAssertEqual(meeting.title, "Pricing review")
        XCTAssertEqual(meeting.startedAt, try localDay(2026, 3, 4))
        XCTAssertEqual(meeting.duration, 3_840)
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marić"])
        XCTAssertEqual(meeting.lines, [
            .init(start: 0, speaker: "Ana Petrović", text: "Let's keep the Team plan at fifteen per seat. Billed annually."),
            .init(start: 12, speaker: "Leo Marić", text: "Then we drop the monthly discount. Agreed by everyone."),
            .init(start: 3_723, speaker: "Ana Petrović", text: "Ship it Thursday."),
        ], "marks are dropped, speech after a WATCH link and inside a highlight is kept")
        XCTAssertFalse(meeting.lines.contains(where: \.isMe))
        XCTAssertEqual(meeting.notes, expectedSummary)
        XCTAssertFalse(meeting.notes?.contains("fathom.video") ?? true)
        XCTAssertEqual(meeting.actionItems, [.init(text: "Send the revised price sheet to Leo")])
        assertSameFile(meeting.audioURL, video)
        assertSameFile(meeting.origin, transcriptURL)

        XCTAssertEqual(ExternalMeetingWriter.notesMarkdown(for: meeting), expectedSummary + "\n",
                       "the notes already list the action item, so it isn't repeated")
        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: meeting))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them 1", "them 2", "them 1"])
        XCTAssertEqual(transcript.speakerAliases, ["them 1": "Ana Petrović", "them 2": "Leo Marić"])
    }

    func testAPIListResponseReadsEveryMeeting() throws {
        let folder = try temporaryDirectory("api")
        let file = try write(apiList, "fathom-meetings.json", in: folder)

        let scan = try FathomMeetingReader.read(file)

        XCTAssertEqual(scan.meetings.count, 2)
        let design = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(design.sourceID, "SyntheticShareToken_0002")
        XCTAssertEqual(design.title, "Design sync")
        XCTAssertEqual(design.startedAt, ExternalImportText.date("2026-03-05T09:01:12Z"))
        XCTAssertEqual(design.duration, 1_800)
        XCTAssertEqual(design.participants, ["Mia Example", "Noah Sample"])
        XCTAssertEqual(design.lines, [
            .init(start: 5, speaker: "Mia Example", text: "Morning, let's look at the mockups."),
            .init(start: 70, speaker: "Noah Sample", text: "The header feels heavy."),
        ])
        XCTAssertEqual(design.notes, """
            ## Summary

            Lighter header agreed.

            ## Highlights

            - **Decision** at 1:10: Lighter header — “Let's make the header lighter”

            ## Action items

            - [ ] Send the new mockups (Noah Sample)
            - [x] Book the review room
            """)
        XCTAssertEqual(design.actionItems, [.init(text: "Send the new mockups", owner: "Noah Sample")],
                       "a done item stays in the notes, not among open actions")
        XCTAssertNil(design.audioURL)
        XCTAssertEqual(design.origin, file)

        let checkIn = scan.meetings[1]
        XCTAssertEqual(checkIn.sourceID, "recording-222", "no share link falls back to the recording id")
        XCTAssertEqual(checkIn.startedAt, ExternalImportText.date("2026-03-06T08:00:00Z"))
        XCTAssertNil(checkIn.duration)
        XCTAssertNil(checkIn.notes)
    }

    func testRecognizesFathomFilesOnly() throws {
        let folder = try temporaryDirectory("recognize")
        XCTAssertTrue(FathomMeetingReader.recognizes(try write(copiedTranscript, "t.txt", in: folder)))
        XCTAssertTrue(FathomMeetingReader.recognizes(try write(copiedSummary, "s.md", in: folder)))
        XCTAssertTrue(FathomMeetingReader.recognizes(try write(apiList, "m.json", in: folder)))
        XCTAssertTrue(FathomMeetingReader.recognizes(try write(
            #"{"transcript": [{"speaker": {"display_name": "A"}, "text": "Hi", "timestamp": "00:00:01"}]}"#,
            "only-transcript.json", in: folder)))
        XCTAssertTrue(FathomMeetingReader.recognizes(try write("bytes", "call.mp4", in: folder)))
        XCTAssertTrue(FathomMeetingReader.recognizes(try write(headerlessTranscript, "headerless.txt", in: folder)))

        XCTAssertFalse(FathomMeetingReader.recognizes(try write("Milk\nEggs\n10:30 - dentist\n", "shopping.txt", in: folder)))
        XCTAssertFalse(FathomMeetingReader.recognizes(try write(#"{"name": "settings", "theme": "dark"}"#, "settings.json", in: folder)))
        XCTAssertFalse(FathomMeetingReader.recognizes(try write(copiedTranscript, "t.docx", in: folder)))
        XCTAssertFalse(FathomMeetingReader.recognizes(try write("", "empty.txt", in: folder)))
        XCTAssertFalse(FathomMeetingReader.recognizes(folder.appendingPathComponent("missing.txt")))
        XCTAssertFalse(FathomMeetingReader.recognizes(folder.appendingPathComponent("missing.mp4")))
    }

    func testUnreadableFilesInAFolderAreProblemsAndTheRestIsRead() throws {
        let folder = try temporaryDirectory("problems")
        try write(copiedTranscript, "Pricing review.txt", in: folder)
        let broken = try write(#"{"recording_id": 9, "title": "SECRET-TITLE", "transcript": ["#, "broken.json", in: folder)
        try write(#"{"recording_id": [], "share_url": 5}"#, "odd.json", in: folder)
        try write("Milk\nEggs\n", "shopping.txt", in: folder)

        let scan = try FathomMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.map(\.sourceID), [shareToken])
        XCTAssertEqual(scan.problems.map(\.reason), ["it isn't valid JSON", "it holds no Fathom meeting"],
                       "a file that isn't Fathom's is skipped, not a problem")
        assertSameFile(scan.problems.first.map { URL(fileURLWithPath: $0.path) }, broken)
        XCTAssertFalse(scan.problems.contains { $0.reason.contains("SECRET") }, "reasons never quote a file")
    }

    func testSourceIDsAreStableAcrossReads() throws {
        let folder = try temporaryDirectory("stable")
        try write(copiedTranscript, "Pricing review.txt", in: folder)
        XCTAssertEqual(try FathomMeetingReader.read(folder).meetings, try FathomMeetingReader.read(folder).meetings)

        let headerless = try write(headerlessTranscript, "Standup notes.txt", in: try temporaryDirectory("headerless"))
        let first = try FathomMeetingReader.read(headerless).meetings
        XCTAssertEqual(first, try FathomMeetingReader.read(headerless).meetings)
        XCTAssertEqual(first.first?.sourceID.count, 32, "no share link, so a hash of what can't change")
        XCTAssertEqual(first.first?.title, "Standup notes")
        XCTAssertNil(first.first?.startedAt)

        let video = try write("bytes", "Loose call.mp4", in: try temporaryDirectory("video"))
        let once = try FathomMeetingReader.read(video).meetings
        XCTAssertEqual(once, try FathomMeetingReader.read(video).meetings)
        XCTAssertEqual(once.first?.title, "Loose call")
        XCTAssertEqual(once.first?.audioURL, video)
    }

    func testHeaderDayWithoutAYearIsPlacedBeforeTheFileWasSaved() throws {
        let folder = try temporaryDirectory("year")
        let late = try write(copiedTranscript.replacingOccurrences(of: "March 4", with: "December 30"), "late.txt",
                             in: folder, modified: localDay(2026, 1, 5))
        XCTAssertEqual(try FathomMeetingReader.read(late).meetings.first?.startedAt, try localDay(2025, 12, 30))
        let dated = try write(copiedTranscript.replacingOccurrences(of: "March 4", with: "March 4, 2024"), "dated.txt",
                              in: folder)
        XCTAssertEqual(try FathomMeetingReader.read(dated).meetings.first?.startedAt, try localDay(2024, 3, 4))
    }

    func testMarkdownSummaryDropsFathomLinksAndTakesNextStepOwners() throws {
        let markdown = """
            # 9:30 - Standup - June 11
            [**VIEW RECORDING - 48 mins (No highlights)**](https://fathom.video/share/SyntheticShareToken_0003)

            ---
            ## Meeting Purpose

            [Plan the week.](https://fathom.video/share/SyntheticShareToken_0003?tab=summary&timestamp=0.0 "PLAY @0:00")

            ## Next Steps

              - [**Ana:** Update the pricing page](https://fathom.video/share/SyntheticShareToken_0003?tab=summary&timestamp=71.0)
              - [**Leo:**](https://fathom.video/share/SyntheticShareToken_0003?tab=summary&timestamp=72.0)
                  - [Tell the sales team](https://fathom.video/share/SyntheticShareToken_0003?tab=summary&timestamp=72.0)
              - [Book a follow-up](https://fathom.video/share/SyntheticShareToken_0003?tab=summary&timestamp=73.0)
            """
        let file = try write(markdown, "standup.md", in: try temporaryDirectory("markdown"), modified: localDay(2026, 6, 20))

        let meetings = try FathomMeetingReader.read(file).meetings

        XCTAssertEqual(meetings.count, 1)
        let standup = try XCTUnwrap(meetings.first)
        XCTAssertEqual(standup.title, "9:30 - Standup", "a title starting with a time isn't a transcript turn")
        XCTAssertEqual(standup.sourceID, "SyntheticShareToken_0003")
        XCTAssertEqual(standup.startedAt, try localDay(2026, 6, 11))
        XCTAssertEqual(standup.duration, 2_880)
        XCTAssertEqual(standup.lines, [])
        XCTAssertEqual(standup.notes, """
            ## Meeting Purpose

            Plan the week.

            ## Next Steps

              - **Ana:** Update the pricing page
              - **Leo:**
                  - Tell the sales team
              - Book a follow-up
            """)
        XCTAssertEqual(standup.actionItems, [
            .init(text: "Update the pricing page", owner: "Ana"),
            .init(text: "Tell the sales team", owner: "Leo"),
            .init(text: "Book a follow-up"),
        ])
    }

    func testAPIJSONAndCopiedTranscriptOfOneCallJoinWithJSONFirst() throws {
        let folder = try temporaryDirectory("join")
        let json = try write("""
            {"title": "Pricing review", "recording_id": 333, "share_url": "https://fathom.video/share/\(shareToken)",
             "recording_start_time": "2026-03-04T14:00:00Z", "recording_end_time": "2026-03-04T15:04:00Z",
             "action_items": [{"description": "Send the revised price sheet to Leo", "completed": true,
                               "assignee": {"name": "Ana Petrović"}}]}
            """, "a-meeting.json", in: folder)
        try write(copiedTranscript, "b-transcript.txt", in: folder, modified: localDay(2026, 3, 10))

        let meetings = try FathomMeetingReader.read(folder).meetings

        XCTAssertEqual(meetings.count, 1)
        let meeting = try XCTUnwrap(meetings.first)
        XCTAssertEqual(meeting.startedAt, ExternalImportText.date("2026-03-04T14:00:00Z"), "the API's exact start wins")
        XCTAssertEqual(meeting.duration, 3_840)
        XCTAssertEqual(meeting.lines.count, 3, "the copied transcript fills what the JSON lacks")
        assertSameFile(meeting.origin, json)
        XCTAssertEqual(meeting.actionItems, [], "the transcript's mark doesn't reopen an item done in Fathom")
        XCTAssertEqual(meeting.notes, "## Action items\n\n- [x] Send the revised price sheet to Leo (Ana Petrović)")
    }

    func testVideoNamedLikeTwoCallsStaysOnItsOwn() throws {
        let folder = try temporaryDirectory("ambiguous")
        let weekly = copiedTranscript.replacingOccurrences(of: "Pricing review", with: "Weekly sync")
        try write(weekly, "one.txt", in: folder)
        try write(weekly.replacingOccurrences(of: shareToken, with: "SyntheticShareToken_0004"), "two.txt", in: folder)
        let video = try write("bytes", "Weekly sync.mp4", in: folder)

        let meetings = try FathomMeetingReader.read(folder).meetings

        XCTAssertEqual(meetings.count, 3)
        XCTAssertEqual(meetings.filter { $0.audioURL != nil }.map(\.title), ["Weekly sync"])
        assertSameFile(meetings.last?.audioURL, video)
        XCTAssertEqual(meetings.last?.lines, [])
    }

    func testZippedFolderReadsThroughScan() throws {
        let folder = try temporaryDirectory("zip")
        let export = folder.appendingPathComponent("Fathom calls", isDirectory: true)
        try write(copiedTranscript, "Pricing review.txt", in: export)
        try write("synthetic video bytes", "Pricing review.mp4", in: export)
        let zip = folder.appendingPathComponent("Fathom calls.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", export.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let result = ExternalMeetingReaders.scan(.fathom, urls: [zip])
        defer { result.cleanup() }

        XCTAssertEqual(result.scan.problems, [])
        XCTAssertEqual(result.scan.meetings.map(\.sourceID), [shareToken])
        let audio = try XCTUnwrap(result.scan.meetings.first?.audioURL)
        XCTAssertEqual(audio.lastPathComponent, "Pricing review.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testSingleFilesThatCantBeReadSaySo() throws {
        let folder = try temporaryDirectory("single")
        let notes = try write("Milk\nEggs\n", "shopping.txt", in: folder)
        XCTAssertThrowsError(try FathomMeetingReader.read(notes)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.fathom, "shopping.txt"))
        }
        let broken = try write(#"{"recording_id": 1, "#, "broken.json", in: folder)
        XCTAssertThrowsError(try FathomMeetingReader.read(broken)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unreadable("broken.json", "it isn't valid JSON"))
        }
        let empty = try temporaryDirectory("empty")
        XCTAssertThrowsError(try FathomMeetingReader.read(empty)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.fathom, empty.lastPathComponent))
        }
    }
}
