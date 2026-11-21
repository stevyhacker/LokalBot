import XCTest
@testable import LokalBot

final class OtterMeetingReaderTests: XCTestCase {
    private static let transcriptLines = [
        "Ana Petrović  0:00  ",
        "Let's keep the Team plan at fifteen per seat.",
        "",
        "Leo Marić  0:07  ",
        "Billed annually, then.",
        "",
        "Speaker 3  1:02:10  ",
        "I'll send the deck on Friday.",
        "",
        "Unknown Speaker  1:02:30  ",
        "Thanks, everyone.",
        "",
        "Transcribed by https://otter.ai",
    ]

    private static let txt = ([
        "Pricing review",
        "Wed, Mar 4, 2026 10:15AM • 1:05:00",
        "",
        "SUMMARY KEYWORDS",
        "pricing, team plan, annual billing",
        "",
        "SPEAKERS",
        "Ana Petrović, Leo Marić, Speaker 3",
        "",
        "OVERVIEW",
        "The team kept the Team plan at fifteen per seat and moved to annual billing.",
        "",
        "ACTION ITEMS",
        "• Send the pricing deck to finance (Leo Marić)",
        "• Update the billing page",
        "",
    ] + transcriptLines).joined(separator: "\n") + "\n"

    private static let srt = """
        1
        00:00:00,000 --> 00:00:03,500
        Ana Petrović: Let's keep the Team plan

        2
        00:00:03,600 --> 00:00:06,000
        at fifteen per seat.

        3
        00:00:07,000 --> 00:00:09,000
        Leo Marić: Billed annually, then.

        4
        01:02:10,000 --> 01:02:14,000
        Speaker 3: I'll send the deck on Friday.

        5
        01:02:30,000 --> 01:02:32,000
        Unknown Speaker: Thanks, everyone.

        """

    private static let docxParagraphs = [
        "Pricing review",
        "Wed, Mar 4, 2026 10:15AM • 1:05:00",
        "SUMMARY KEYWORDS",
        "pricing, team plan, annual billing",
        "SPEAKERS",
        "Ana Petrović, Leo Marić, Speaker 3",
        "Ana Petrović\t0:00",
        "Let's keep the Team plan at fifteen per seat.",
        "",
        "Leo Marić 0:07",
        "Billed annually, then.",
        "",
        "Speaker 3\t1:02:10",
        "I'll send the deck on Friday.",
        "",
        "Unknown Speaker\t1:02:30",
        "Thanks, everyone.",
        "",
        "Transcribed by https://otter.ai",
    ]

    private func expectedLines(srt: Bool = false) -> [ExternalMeeting.Line] {
        [
            .init(start: 0, end: srt ? 6 : nil, speaker: "Ana Petrović", text: "Let's keep the Team plan at fifteen per seat."),
            .init(start: 7, end: srt ? 9 : nil, speaker: "Leo Marić", text: "Billed annually, then."),
            .init(start: 3_730, end: srt ? 3_734 : nil, speaker: "Speaker 3", text: "I'll send the deck on Friday."),
            .init(start: 3_750, end: srt ? 3_752 : nil, speaker: nil, text: "Thanks, everyone."),
        ]
    }

    private func meetingStart() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 10, minute: 15)))
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otter-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try Data(text.utf8).write(to: url)
        return url
    }

    private func ditto(_ source: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeDocx(_ paragraphs: [String], at url: URL) throws {
        let source = try temporaryDirectory("docx-source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("word"), withIntermediateDirectories: true)
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """, to: source.appendingPathComponent("[Content_Types].xml"))
        let body = paragraphs.map { paragraph -> String in
            let runs = paragraph.components(separatedBy: "\t").map { part -> String in
                let escaped = part.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
            }
            return "<w:p><w:pPr><w:tabs><w:tab w:val=\"left\" w:pos=\"2880\"/></w:tabs></w:pPr>"
                + runs.joined(separator: "<w:r><w:tab/></w:r>") + "</w:p>"
        }.joined()
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr/></w:body></w:document>
            """, to: source.appendingPathComponent("word/document.xml"))
        try ditto(source, to: url)
    }

    private func readOne(_ text: String, name: String = "Call_otter_ai.txt") throws -> ExternalMeeting {
        let file = try write(text, to: try temporaryDirectory("layout").appendingPathComponent(name))
        let scan = try OtterMeetingReader.read(file)
        XCTAssertEqual(scan.meetings.count, 1)
        return try XCTUnwrap(scan.meetings.first)
    }

    func testTextExportWithRecordingRoundTrip() throws {
        let folder = try temporaryDirectory("roundtrip")
        let txt = try write(Self.txt, to: folder.appendingPathComponent("Pricing review_otter_ai.txt"))
        let mp3 = try write("not really audio", to: folder.appendingPathComponent("Pricing review.mp3"))

        let scan = try OtterMeetingReader.read(folder)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.source, .otter)
        XCTAssertEqual(meeting.title, "Pricing review")
        XCTAssertEqual(meeting.startedAt, try meetingStart())
        XCTAssertEqual(meeting.duration, 3_900)
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marić"], "Otter's numbered and unknown speakers name nobody")
        XCTAssertEqual(meeting.lines, expectedLines())
        XCTAssertTrue(meeting.lines.allSatisfy { !$0.isMe }, "Otter never says which microphone was the person's")
        XCTAssertEqual(meeting.notes, """
            ## Overview

            The team kept the Team plan at fifteen per seat and moved to annual billing.

            **Keywords:** pricing, team plan, annual billing
            """)
        XCTAssertEqual(meeting.actionItems, [
            .init(text: "Send the pricing deck to finance", owner: "Leo Marić"),
            .init(text: "Update the billing page"),
        ])
        XCTAssertEqual(meeting.audioURL?.standardizedFileURL, mp3.standardizedFileURL)
        XCTAssertEqual(meeting.origin.standardizedFileURL, txt.standardizedFileURL)
        XCTAssertEqual(meeting.sourceID.count, 32)

        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: meeting))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them 1", "them 2", "them 3", "them"])
        XCTAssertEqual(transcript.speakerAliases, ["them 1": "Ana Petrović", "them 2": "Leo Marić", "them 3": "Speaker 3"])
        XCTAssertEqual(transcript.engine, "import-otter")
        let notes = try XCTUnwrap(ExternalMeetingWriter.notesMarkdown(for: meeting))
        XCTAssertTrue(notes.hasSuffix("## Action items\n\n- [ ] Send the pricing deck to finance (Leo Marić)\n- [ ] Update the billing page\n"))
    }

    func testFileOrRecordingChosenAloneReadsTheirPair() throws {
        let folder = try temporaryDirectory("pair")
        let txt = try write(Self.txt, to: folder.appendingPathComponent("Pricing review_otter_ai.txt"))
        let mp3 = try write("not really audio", to: folder.appendingPathComponent("Pricing review.mp3"))
        let fromFolder = try XCTUnwrap(OtterMeetingReader.read(folder).meetings.first)

        let fromText = try XCTUnwrap(OtterMeetingReader.read(txt).meetings.first)
        XCTAssertEqual(fromText.audioURL?.standardizedFileURL, mp3.standardizedFileURL)
        XCTAssertEqual(fromText.sourceID, fromFolder.sourceID)
        let fromAudio = try XCTUnwrap(OtterMeetingReader.read(mp3).meetings.first)
        XCTAssertEqual(fromAudio.sourceID, fromFolder.sourceID, "choosing both files gives one meeting")
    }

    func testSameConversationAsSubRipAndWordGetsTheSameID() throws {
        let txtFolder = try temporaryDirectory("txt")
        try write(Self.txt, to: txtFolder.appendingPathComponent("Pricing review_otter_ai.txt"))
        let fromText = try XCTUnwrap(OtterMeetingReader.read(txtFolder).meetings.first)

        let srt = try write(Self.srt, to: try temporaryDirectory("srt").appendingPathComponent("Pricing review_otter_ai.srt"))
        let fromSRT = try XCTUnwrap(OtterMeetingReader.read(srt).meetings.first)
        XCTAssertEqual(fromSRT.lines, expectedLines(srt: true), "unnamed cues continue the turn before them")
        XCTAssertEqual(fromSRT.title, "Pricing review")
        XCTAssertEqual(fromSRT.duration, 3_752)
        XCTAssertEqual(fromSRT.participants, ["Ana Petrović", "Leo Marić"])
        XCTAssertEqual(fromSRT.sourceID, fromText.sourceID)

        let docxFolder = try temporaryDirectory("docx")
        let docx = docxFolder.appendingPathComponent("Pricing review_otter_ai.docx")
        try makeDocx(Self.docxParagraphs, at: docx)
        XCTAssertTrue(OtterMeetingReader.recognizes(docx))
        let scan = try OtterMeetingReader.read(docxFolder)
        XCTAssertEqual(scan.problems, [])
        let fromWord = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(fromWord.lines, expectedLines())
        XCTAssertEqual(fromWord.title, "Pricing review")
        XCTAssertEqual(fromWord.startedAt, try meetingStart())
        XCTAssertEqual(fromWord.notes, "**Keywords:** pricing, team plan, annual billing")
        XCTAssertEqual(fromWord.sourceID, fromText.sourceID)

        let bracketed = try temporaryDirectory("bracketed").appendingPathComponent("Notes [v2].docx")
        try FileManager.default.copyItem(at: docx, to: bracketed)
        XCTAssertEqual(try OtterMeetingReader.read(bracketed).meetings.first?.lines, expectedLines())
    }

    func testTextAndSubRipOfOneConversationAreOneMeeting() throws {
        let folder = try temporaryDirectory("both")
        try write(Self.txt, to: folder.appendingPathComponent("Pricing review_otter_ai.txt"))
        try write(Self.srt, to: folder.appendingPathComponent("Pricing review_otter_ai.srt"))
        try write("not really audio", to: folder.appendingPathComponent("Pricing review.mp3"))

        let scan = try OtterMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.count, 1)
        XCTAssertEqual(scan.meetings.first?.origin.pathExtension, "txt", "TXT turns are whole paragraphs")
        XCTAssertNotNil(scan.meetings.first?.audioURL)
    }

    func testBulkExportZipThroughScan() throws {
        let source = try temporaryDirectory("zip-source")
        try write(Self.txt, to: source.appendingPathComponent("Pricing review.txt"))
        try write(Self.transcriptLines.joined(separator: "\n").replacingOccurrences(of: "Team plan", with: "Pro plan"),
                  to: source.appendingPathComponent("Pricing review (1).txt"))
        let zip = try temporaryDirectory("zip").appendingPathComponent("otter-export.zip")
        try ditto(source, to: zip)
        let single = try write(Self.txt, to: try temporaryDirectory("single").appendingPathComponent("Pricing review_otter_ai.txt"))
        let singleID = try XCTUnwrap(OtterMeetingReader.read(single).meetings.first?.sourceID)

        let result = ExternalMeetingReaders.scan(.otter, urls: [zip])
        defer { result.cleanup() }

        XCTAssertEqual(result.scan.problems, [])
        XCTAssertEqual(result.scan.meetings.count, 2, "two conversations with one title stay two")
        XCTAssertTrue(result.scan.meetings.contains { $0.sourceID == singleID }, "a bulk export matches a single export")
        XCTAssertEqual(Set(result.scan.meetings.map(\.sourceID)).count, 2)
    }

    func testRecognizesOtterFilesOnly() throws {
        let folder = try temporaryDirectory("recognize")
        XCTAssertTrue(OtterMeetingReader.recognizes(try write("anything", to: folder.appendingPathComponent("Weekly sync_otter.ai.txt"))))
        XCTAssertTrue(OtterMeetingReader.recognizes(try write(Self.transcriptLines.dropLast().joined(separator: "\n"),
                                                              to: folder.appendingPathComponent("talk.txt"))), "turn headers")
        XCTAssertTrue(OtterMeetingReader.recognizes(try write("Hello there.\n\nGeneral Kenobi.\n\nTranscribed by https://otter.ai\n",
                                                              to: folder.appendingPathComponent("plain.txt"))), "closing line")
        XCTAssertTrue(OtterMeetingReader.recognizes(try write(Self.srt, to: folder.appendingPathComponent("talk.srt"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("Buy milk\nCall Ana at 10:30\n", to: folder.appendingPathComponent("list.txt"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("Agenda\nBreak  10:30\n\nLunch\n", to: folder.appendingPathComponent("agenda.txt"))),
                       "one header-like row without words under it")
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("no cues here", to: folder.appendingPathComponent("broken.srt"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("plain text", to: folder.appendingPathComponent("fake.docx"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("%PDF-1.7", to: folder.appendingPathComponent("Pricing review_otter_ai.pdf"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(try write("jpeg", to: folder.appendingPathComponent("photo.jpg"))))
        XCTAssertFalse(OtterMeetingReader.recognizes(folder.appendingPathComponent("missing.txt")))
    }

    func testUnreadableFileInFolderBecomesAProblemAndTheRestIsRead() throws {
        let folder = try temporaryDirectory("problems")
        try write(Self.transcriptLines.joined(separator: "\n"), to: folder.appendingPathComponent("Standup_otter_ai.txt"))
        let broken = try write("PK\u{3}\u{4}SECRET-CONTENT that is not a zip", to: folder.appendingPathComponent("Broken_otter_ai.docx"))
        let pdf = try write("%PDF-1.7 SECRET-CONTENT", to: folder.appendingPathComponent("Retro_otter_ai.pdf"))
        try write("Buy milk\n", to: folder.appendingPathComponent("list.txt"))

        let scan = try OtterMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.map(\.title), ["Standup"])
        XCTAssertEqual(scan.problems.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(),
                       [broken.lastPathComponent, pdf.lastPathComponent].sorted())
        XCTAssertTrue(scan.problems.allSatisfy { !$0.reason.contains("SECRET") }, "reasons never quote a file")
        XCTAssertThrowsError(try OtterMeetingReader.read(broken), "a broken file chosen alone throws") { error in
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        XCTAssertThrowsError(try OtterMeetingReader.read(pdf)) { error in
            XCTAssertTrue(error.localizedDescription.contains("TXT, DOCX, or SRT"))
        }
    }

    func testFolderWithoutOtterFilesThrows() throws {
        let folder = try temporaryDirectory("empty")
        try write("Buy milk\n", to: folder.appendingPathComponent("list.txt"))
        XCTAssertThrowsError(try OtterMeetingReader.read(folder)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.otter, folder.path))
        }
        XCTAssertTrue(OtterMeetingReader.defaultLocations.isEmpty, "Otter keeps nothing on this computer to read")
    }

    func testSourceIDIsStableAcrossReads() throws {
        let folder = try temporaryDirectory("stable")
        try write(Self.txt, to: folder.appendingPathComponent("Pricing review_otter_ai.txt"))
        let first = try XCTUnwrap(OtterMeetingReader.read(folder).meetings.first)
        let second = try XCTUnwrap(OtterMeetingReader.read(folder).meetings.first)
        XCTAssertEqual(first.sourceID, second.sourceID)

        let copy = try readOne(Self.transcriptLines.joined(separator: "\n"), name: "Q3 planning_otter_ai (2).txt")
        let original = try readOne(Self.transcriptLines.joined(separator: "\n"), name: "Q3 planning_otter_ai.txt")
        XCTAssertEqual(copy.title, "Q3 planning")
        XCTAssertEqual(copy.sourceID, original.sourceID, "a browser's copy number doesn't change the id")
        let renamed = try readOne(Self.transcriptLines.joined(separator: "\n"), name: "Q4 planning_otter_ai.txt")
        XCTAssertNotEqual(renamed.sourceID, original.sourceID)
    }

    func testLayoutsWithoutNamesOrTimesOrBoth() throws {
        let timesOnly = try readOne("0:00  \nHello there.\n\n0:05  \nGeneral Kenobi.\n\nTranscribed by https://otter.ai\n")
        XCTAssertEqual(timesOnly.lines, [.init(start: 0, text: "Hello there."), .init(start: 5, text: "General Kenobi.")])

        let namesOnly = try readOne("Ana Petrović  \nHello there.\n\nLeo Marić  \nGeneral Kenobi.\n")
        XCTAssertEqual(namesOnly.lines, [.init(speaker: "Ana Petrović", text: "Hello there."),
                                         .init(speaker: "Leo Marić", text: "General Kenobi.")])

        let paragraphs = try readOne("Hello there.\n\nGeneral Kenobi.\n\nTranscribed by https://otter.ai\n")
        XCTAssertEqual(paragraphs.lines, [.init(text: "Hello there."), .init(text: "General Kenobi.")])
    }

    func testVoiceNoteHeadersByteOrderMarkAndLineEndings() throws {
        let voiceNote = try readOne("Unknown 0:00\nHello.\n\nUnknown 0:09\nWe meet at 10:30\n\nTranscribed by https://otter.ai\n")
        XCTAssertEqual(voiceNote.lines, [.init(start: 0, text: "Hello."), .init(start: 9, text: "We meet at 10:30")],
                       "a line of words ending in a time stays words")
        XCTAssertEqual(voiceNote.participants, [])

        let windows = try readOne("\u{FEFF}David Tant  00:04\r\nGood evening.\r\n\r\nDavid Tant  75:12\r\nGoodnight.\r\n\r\nTranscribed by https://otter.ai\r\n")
        XCTAssertEqual(windows.lines, [.init(start: 4, speaker: "David Tant", text: "Good evening."),
                                       .init(start: 4_512, speaker: "David Tant", text: "Goodnight.")])

        let blankUnderHeader = try readOne("Ana Petrović  0:49\n\nOkay, that's a good point.\n\nLeo Marić  1:02\n\nSo\n")
        XCTAssertEqual(blankUnderHeader.lines.map(\.text), ["Okay, that's a good point.", "So"])
    }

    func testSummaryAfterTheTranscriptAndTitleLines() throws {
        let trailing = try readOne(Self.transcriptLines.dropLast().joined(separator: "\n")
            + "\n\nAction Items\n- [ ] Ship it (Ana Petrović)\n\nOutline\n• Pricing\n")
        XCTAssertEqual(trailing.lines, expectedLines())
        XCTAssertEqual(trailing.actionItems, [.init(text: "Ship it", owner: "Ana Petrović")])
        XCTAssertEqual(trailing.notes, "## Outline\n\n- Pricing")

        let titled = try readOne("Weekly sync\n\n" + Self.transcriptLines.joined(separator: "\n"), name: "renamed.txt")
        XCTAssertEqual(titled.title, "Weekly sync")
        XCTAssertNil(titled.startedAt, "no date line, no start")

        let yearless = try readOne("Standup\nFri, 9/18 3:26PM • 41:12\n\n" + Self.transcriptLines.joined(separator: "\n"))
        XCTAssertEqual(yearless.title, "Standup")
        XCTAssertNil(yearless.startedAt, "an old date line without a year gives no start")
        XCTAssertEqual(yearless.duration, 2_472)
        XCTAssertEqual(yearless.lines, expectedLines())
    }
}
