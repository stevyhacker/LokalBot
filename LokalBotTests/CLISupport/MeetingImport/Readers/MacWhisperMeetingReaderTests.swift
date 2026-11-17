import SQLite3
import XCTest
@testable import LokalBot

/// Every fixture here is synthetic: written as literals, zipped with ditto or
/// zip, or created with SQLite. No real MacWhisper data is used.
final class MacWhisperMeetingReaderTests: XCTestCase {
    private let fileManager = FileManager.default
    private let created = Date(timeIntervalSince1970: 1_789_984_800) // 2026-09-21T10:00:00Z

    // MARK: - .whisper documents

    func testWhisperDocumentRoundTrip() throws {
        let folder = try temporaryFolder("macwhisper-whisper")
        let document = folder.appendingPathComponent("Pricing review with Ana.whisper")
        let audio = fakeM4A()
        try makeWhisper(at: document, metadata: whisperMetadata(), audio: audio)
        let before = try Data(contentsOf: document)
        let filesBefore = listing(folder)

        let scan = try MacWhisperMeetingReader.read(document)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.source, .macWhisper)
        XCTAssertEqual(meeting.title, "Pricing review with Ana")
        XCTAssertEqual(meeting.startedAt, created, "dateCreated is seconds since 2001")
        XCTAssertEqual(meeting.duration, 11)
        XCTAssertEqual(meeting.participants, ["Ana", "Leo"], "placeholder labels name nobody")
        XCTAssertEqual(meeting.lines, [
            .init(start: 0, end: 4.2, speaker: "Ana", text: "Let's keep the Team plan at fifteen per seat."),
            .init(start: 4.5, end: 9, speaker: "Leo", text: "Billed annually, then."),
            .init(start: 9.1, end: 11, speaker: "Speaker 3", text: "Agreed."),
        ])
        XCTAssertTrue(meeting.lines.allSatisfy { !$0.isMe }, "MacWhisper doesn't mark the person's own lines")
        XCTAssertEqual(meeting.notes?.hasPrefix("## Summary"), true)
        XCTAssertEqual(meeting.actionItems, [.init(text: "Ana sends the new price sheet"),
                                             .init(text: "Leo updates the billing page")])
        XCTAssertEqual(meeting.origin, document)
        let recording = try XCTUnwrap(meeting.audioURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: recording.deletingLastPathComponent()) }
        XCTAssertEqual(recording.lastPathComponent, "Pricing review.m4a")
        XCTAssertEqual(try Data(contentsOf: recording), audio)
        XCTAssertFalse(recording.path.hasPrefix(folder.path), "unpacked outside the source folder")

        XCTAssertEqual(try Data(contentsOf: document), before, "the document is only read")
        XCTAssertEqual(listing(folder), filesBefore, "nothing is written beside it")

        let again = try MacWhisperMeetingReader.read(document)
        XCTAssertEqual(again.meetings.first?.sourceID, meeting.sourceID)
        XCTAssertEqual(again.meetings.first?.audioURL, recording, "the unpacked recording is reused")
    }

    func testWhisperDocumentWithoutExtensionStoredEntriesOrAudio() throws {
        let folder = try temporaryFolder("macwhisper-whisper-edges")

        // A WAV recording whose extension MacWhisper didn't keep, zipped inside a top folder.
        let wav = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8) + Data(count: 64)
        let noExtension = folder.appendingPathComponent("no-extension.whisper")
        try makeWhisper(at: noExtension, metadata: whisperMetadata(extension: nil), audio: wav, keepParent: true)
        let sniffed = try XCTUnwrap(MacWhisperMeetingReader.read(noExtension).meetings.first)
        let sniffedAudio = try XCTUnwrap(sniffed.audioURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: sniffedAudio.deletingLastPathComponent()) }
        XCTAssertEqual(sniffedAudio.pathExtension, "wav")
        XCTAssertEqual(sniffed.lines.count, 3)

        // Stored rather than deflated entries, as `zip -0` writes them.
        let stage = folder.appendingPathComponent("stored-stage", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: whisperMetadata()).write(to: stage.appendingPathComponent("metadata.json"))
        try fakeM4A().write(to: stage.appendingPathComponent("originalAudio"))
        let stored = folder.appendingPathComponent("stored.whisper")
        try run("/usr/bin/zip", ["-X", "-0", "-q", stored.path, "metadata.json", "originalAudio"], in: stage)
        let storedMeeting = try XCTUnwrap(MacWhisperMeetingReader.read(stored).meetings.first)
        let storedAudio = try XCTUnwrap(storedMeeting.audioURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: storedAudio.deletingLastPathComponent()) }
        XCTAssertEqual(storedMeeting.lines.count, 3)
        XCTAssertEqual(try Data(contentsOf: storedAudio), fakeM4A())

        // Saved without its media: the transcript alone, under the same id.
        let textOnly = folder.appendingPathComponent("text-only.whisper")
        try makeWhisper(at: textOnly, metadata: whisperMetadata(), audio: nil)
        let withoutAudio = try XCTUnwrap(MacWhisperMeetingReader.read(textOnly).meetings.first)
        XCTAssertNil(withoutAudio.audioURL)
        XCTAssertEqual(withoutAudio.sourceID, sniffed.sourceID, "the id comes from MacWhisper's metadata, not the file name")
    }

    func testUnpackedWhisperDocumentAndBrokenOne() throws {
        let folder = try temporaryFolder("macwhisper-unpacked")
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: whisperMetadata()).write(to: unpacked.appendingPathComponent("metadata.json"))
        try fakeM4A().write(to: unpacked.appendingPathComponent("originalAudio"))
        try write("2", to: unpacked.appendingPathComponent("version"))

        let scan = try MacWhisperMeetingReader.read(unpacked)
        XCTAssertEqual(scan.meetings.count, 1)
        let meeting = try XCTUnwrap(scan.meetings.first)
        let audio = try XCTUnwrap(meeting.audioURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        XCTAssertEqual(meeting.title, "Pricing review", "named after the media when there's no document name")
        XCTAssertEqual(audio.pathExtension, "m4a", "the extensionless originalAudio is copied with one")

        let broken = folder.appendingPathComponent("broken.whisper")
        try write("secret words, not a zip", to: broken)
        XCTAssertThrowsError(try MacWhisperMeetingReader.read(broken)) { error in
            guard case .unreadable(let name, let reason) = error as? ExternalImportError else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertEqual(name, "broken.whisper")
            XCTAssertFalse(reason.contains("secret"), "reasons never quote content")
        }
    }

    // MARK: - Exports

    func testSegmentsAndStructuredJSONExports() throws {
        let folder = try temporaryFolder("macwhisper-json")
        // Share › Segments › .json
        let segments = folder.appendingPathComponent("council.json")
        try write("""
            [
              { "timestamp" : "00:00-00:04", "text" : "Good evening everybody.", "speaker" : "Speaker 1" },
              { "text" : "Welcome to the meeting.", "speaker" : "Ana Petrović", "timestamp" : "59:58-01:00:04" }
            ]
            """, to: segments)
        let council = try XCTUnwrap(MacWhisperMeetingReader.read(segments).meetings.first)
        XCTAssertEqual(council.title, "council")
        XCTAssertEqual(council.lines.map(\.start), [0, 3_598])
        XCTAssertEqual(council.lines.map(\.end), [4, 3_604])
        XCTAssertEqual(council.participants, ["Ana Petrović"])

        // The structured export keeps milliseconds.
        let structured = folder.appendingPathComponent("structured.json")
        try write("""
            {"text": "Hello everyone.\\nWelcome.", "segments": [
              {"id": "6B29FC40-CA47-1067-B31D-00DD010662DA", "start": 0, "end": 1600, "text": "Hello everyone.",
               "speaker": "Speaker 1", "words": [{"text": "Hello", "start": 0, "end": 640}]},
              {"id": "7B29FC40-CA47-1067-B31D-00DD010662DA", "start": 1700, "end": 2500, "text": "Welcome."}
            ]}
            """, to: structured)
        XCTAssertEqual(try MacWhisperMeetingReader.read(structured).meetings.first?.lines, [
            .init(start: 0, end: 1.6, speaker: "Speaker 1", text: "Hello everyone."),
            .init(start: 1.7, end: 2.5, text: "Welcome."),
        ])
    }

    func testCSVExports() throws {
        let folder = try temporaryFolder("macwhisper-csv")
        let csv = folder.appendingPathComponent("pricing.csv")
        try write("00:00:00,000;00:00:04,200;\"Let's keep the Team plan; fifteen per seat.\";Ana\n"
            + "00:00:04,500;00:00:09,000;Billed annually.;Leo\n", to: csv)
        XCTAssertEqual(try MacWhisperMeetingReader.read(csv).meetings.first?.lines, [
            .init(start: 0, end: 4.2, speaker: "Ana", text: "Let's keep the Team plan; fifteen per seat."),
            .init(start: 4.5, end: 9, speaker: "Leo", text: "Billed annually."),
        ])

        let headed = folder.appendingPathComponent("headed.csv")
        try write("Start;End;Speaker;Transcript\n00:01;00:03;Ana;Short one.\n", to: headed)
        XCTAssertEqual(try MacWhisperMeetingReader.read(headed).meetings.first?.lines,
                       [.init(start: 1, end: 3, speaker: "Ana", text: "Short one.")])
    }

    func testTextMarkdownAndWordExports() throws {
        let folder = try temporaryFolder("macwhisper-text")

        // Grouped by speaker, as `--group people` writes it.
        let interview = folder.appendingPathComponent("interview.txt")
        try write("""
            Speaker 1
            So tell me how you got started with the project.

            Speaker 2
            It actually began as a weekend experiment. I never expected
            it to grow the way it did.

            Speaker 1
            And when did you realize it was becoming something bigger?
            """, to: interview)
        let talk = try XCTUnwrap(MacWhisperMeetingReader.read(interview).meetings.first)
        XCTAssertEqual(talk.lines.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(talk.lines[1].text, "It actually began as a weekend experiment. I never expected it to grow the way it did.")
        XCTAssertTrue(talk.lines.allSatisfy { $0.start == nil })
        XCTAssertEqual(talk.participants, [])

        let markdown = folder.appendingPathComponent("standup.md")
        try write("""
            # Monday standup

            **Ana**
            *00:00*
            Let's keep the Team plan at fifteen per seat.

            **Leo**
            *00:04*
            Billed annually, then. 10:30 works for me.
            """, to: markdown)
        let standup = try XCTUnwrap(MacWhisperMeetingReader.read(markdown).meetings.first)
        XCTAssertEqual(standup.title, "Monday standup")
        XCTAssertEqual(standup.lines, [
            .init(start: 0, speaker: "Ana", text: "Let's keep the Team plan at fifteen per seat."),
            .init(start: 4, speaker: "Leo", text: "Billed annually, then. 10:30 works for me."),
        ])

        let segments = folder.appendingPathComponent("segments.txt")
        try write("""
            [00:00:00.000 --> 00:00:04.200]  Ana: Let's keep the Team plan.
            [00:00:04.500 --> 00:00:09.000]  Leo: Billed annually.
            [00:00:09.100 --> 00:00:11.000]  Ana: Agreed.
            """, to: segments)
        XCTAssertEqual(try MacWhisperMeetingReader.read(segments).meetings.first?.lines, [
            .init(start: 0, end: 4.2, speaker: "Ana", text: "Let's keep the Team plan."),
            .init(start: 4.5, end: 9, speaker: "Leo", text: "Billed annually."),
            .init(start: 9.1, end: 11, speaker: "Ana", text: "Agreed."),
        ])

        // A time at the start of a sentence isn't a timestamp, and "Note:" isn't a speaker.
        let plain = folder.appendingPathComponent("plain.txt")
        try write("10:30 works for me. Note: bring the numbers.\n\nSecond paragraph here.", to: plain)
        XCTAssertEqual(try MacWhisperMeetingReader.read(plain).meetings.first?.lines, [
            .init(text: "10:30 works for me. Note: bring the numbers."), .init(text: "Second paragraph here."),
        ])

        let stage = folder.appendingPathComponent("docx-stage", isDirectory: true)
        try write(#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
                  to: stage.appendingPathComponent("[Content_Types].xml"))
        try write("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
            <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Ana</w:t></w:r></w:p>
            <w:p><w:r><w:t xml:space="preserve">Let's keep the </w:t></w:r><w:r><w:t>Team plan.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Leo</w:t></w:r></w:p>
            <w:p><w:r><w:t>Billed annually &amp; on time.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Ana</w:t></w:r></w:p>
            <w:p><w:r><w:t>Agreed.</w:t></w:r></w:p>
            </w:body></w:document>
            """, to: stage.appendingPathComponent("word/document.xml"))
        let docx = folder.appendingPathComponent("pricing-notes.docx")
        try ditto(stage, to: docx)
        let word = try XCTUnwrap(MacWhisperMeetingReader.read(docx).meetings.first)
        XCTAssertEqual(word.lines, [
            .init(speaker: "Ana", text: "Let's keep the Team plan."),
            .init(speaker: "Leo", text: "Billed annually & on time."),
            .init(speaker: "Ana", text: "Agreed."),
        ])
        XCTAssertEqual(word.participants, ["Ana", "Leo"])
    }

    func testRecognizesByNameAndHeader() throws {
        let folder = try temporaryFolder("macwhisper-recognizes")
        let accepted = ["a.whisper", "a.srt", "a.vtt", "a.txt", "a.md", "a.csv"]
        for name in accepted { try write("00:00 hello", to: folder.appendingPathComponent(name)) }
        try write(#"[{"timestamp": "00:00-00:01", "text": "Hi"}]"#, to: folder.appendingPathComponent("segments.json"))
        try write(#"{"foo": 1}"#, to: folder.appendingPathComponent("other.json"))
        let sqliteHeader = Data("SQLite format 3\u{0}".utf8) + Data(count: 84)
        try sqliteHeader.write(to: folder.appendingPathComponent("main.sqlite"))
        try sqliteHeader.write(to: folder.appendingPathComponent("other.sqlite"))
        try (Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 30)).write(to: folder.appendingPathComponent("a.docx"))
        try Data([0x00, 0x01, 0x02]).write(to: folder.appendingPathComponent("binary.txt"))
        try fakeM4A().write(to: folder.appendingPathComponent("a.m4a"))
        try write("x", to: folder.appendingPathComponent("a.pages"))

        for name in accepted + ["segments.json", "main.sqlite", "a.docx"] {
            XCTAssertTrue(MacWhisperMeetingReader.recognizes(folder.appendingPathComponent(name)), name)
        }
        for name in ["other.json", "other.sqlite", "binary.txt", "a.m4a", "a.pages", "main.sqlite-wal"] {
            XCTAssertFalse(MacWhisperMeetingReader.recognizes(folder.appendingPathComponent(name)), name)
        }

        let empty = try temporaryFolder("macwhisper-empty")
        try write("x", to: empty.appendingPathComponent("photo.png"))
        XCTAssertThrowsError(try MacWhisperMeetingReader.read(empty)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.macWhisper, empty.path))
        }
    }

    func testFolderReadsWhatItCanAndReportsUnreadableFiles() throws {
        let folder = try temporaryFolder("macwhisper-folder")
        try write("""
            1
            00:00:01,000 --> 00:00:03,500
            Ana: Let's keep the Team plan

            2
            00:00:06,000 --> 00:00:08,000
            Leo: Billed annually.
            """, to: folder.appendingPathComponent("standup.srt"))
        try write("WEBVTT\n\n00:00:01.000 --> 00:00:03.500\n<v Ana>Let's keep the Team plan\n\n"
            + "00:00:06.000 --> 00:00:08.000\n<v Leo>Billed annually.\n", to: folder.appendingPathComponent("standup.vtt"))
        try fakeM4A().write(to: folder.appendingPathComponent("standup.m4a"))
        try write("secret words, not a zip", to: folder.appendingPathComponent("nested/broken.whisper"))
        try write("First thought.\n\nSecond thought.", to: folder.appendingPathComponent("nested/notes.txt"))
        try write("x", to: folder.appendingPathComponent("photo.png"))
        let before = listing(folder)

        let scan = try MacWhisperMeetingReader.read(folder)

        XCTAssertEqual(scan.meetings.map(\.title), ["notes", "standup"])
        XCTAssertEqual(scan.problems.count, 1)
        XCTAssertTrue(scan.problems.first?.path.hasSuffix("/nested/broken.whisper") == true)
        XCTAssertFalse(scan.problems.first?.reason.contains("secret") ?? true, "reasons never quote content")
        let standup = scan.meetings[1]
        XCTAssertEqual(standup.origin.lastPathComponent, "standup.srt", "exports that share a name are one meeting")
        XCTAssertEqual(standup.audioURL?.lastPathComponent, "standup.m4a", "the recording beside the export comes along")
        XCTAssertEqual(standup.lines.map(\.speaker), ["Ana", "Leo"])
        XCTAssertNil(scan.meetings[0].audioURL)
        XCTAssertEqual(listing(folder), before, "the folder is only read")

        let again = try MacWhisperMeetingReader.read(folder)
        XCTAssertEqual(again.meetings.map(\.sourceID), scan.meetings.map(\.sourceID), "ids are stable across reads")
        let webVTT = try XCTUnwrap(MacWhisperMeetingReader.read(folder.appendingPathComponent("standup.vtt")).meetings.first)
        XCTAssertEqual(webVTT.sourceID, standup.sourceID, "the same transcript as WebVTT is the same meeting")
        XCTAssertEqual(webVTT.audioURL?.lastPathComponent, "standup.m4a")
    }

    func testScanOfAZippedExportFolderKeepsTheRecording() throws {
        let folder = try temporaryFolder("macwhisper-scan")
        let exports = folder.appendingPathComponent("MacWhisper exports", isDirectory: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        try makeWhisper(at: exports.appendingPathComponent("Pricing review.whisper"), metadata: whisperMetadata(), audio: fakeM4A())
        try write("1\n00:00:01,000 --> 00:00:02,000\nAna: Hello.\n", to: exports.appendingPathComponent("hello.srt"))
        let archive = folder.appendingPathComponent("exports.zip")
        try ditto(exports, to: archive, keepParent: true)

        let result = ExternalMeetingReaders.scan(.macWhisper, urls: [archive, archive])
        result.cleanup()

        XCTAssertEqual(result.scan.problems, [])
        XCTAssertEqual(result.scan.meetings.map(\.title).sorted(), ["Pricing review", "hello"], "the same archive twice is read once")
        let audio = result.scan.meetings.compactMap(\.audioURL)
        XCTAssertEqual(audio.count, 1)
        if let recording = audio.first {
            addTeardownBlock { try? FileManager.default.removeItem(at: recording.deletingLastPathComponent()) }
            XCTAssertTrue(fileManager.fileExists(atPath: recording.path), "the unpacked recording outlives the scan's own folders")
        }
    }

    // MARK: - MacWhisper's library

    func testLibraryOpenedImmutableLeavesNothingBehind() throws {
        let folder = try temporaryFolder("macwhisper-library")
        _ = try makeLibrary(in: folder, keepOpenInWAL: false)
        let database = folder.appendingPathComponent("main.sqlite")
        let before = listing(folder)
        let bytes = try Data(contentsOf: database)
        XCTAssertTrue(MacWhisperMeetingReader.recognizes(database))

        let scan = try MacWhisperMeetingReader.read(database)

        try assertLibrary(scan, folder: folder)
        XCTAssertEqual(listing(folder), before, "no -wal, -shm, or journal is created")
        XCTAssertEqual(try Data(contentsOf: database), bytes)
        XCTAssertEqual(try MacWhisperMeetingReader.read(database).meetings.map(\.sourceID), scan.meetings.map(\.sourceID))
        let fromFolder = try MacWhisperMeetingReader.read(folder)
        XCTAssertEqual(fromFolder.meetings.count, 4, "picking the folder reads the database and skips its media")
        XCTAssertEqual(fromFolder.problems, [])
    }

    func testLibraryWithChangesStillInTheWriteAheadLog() throws {
        let folder = try temporaryFolder("macwhisper-library-wal")
        let writer = try makeLibrary(in: folder, keepOpenInWAL: true)
        defer { sqlite3_close(writer) }
        let database = folder.appendingPathComponent("main.sqlite")
        let log = URL(fileURLWithPath: database.path + "-wal")
        XCTAssertGreaterThan((try log.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, 0,
                             "like MacWhisper, the fixture keeps its changes in the log")
        let mainBytes = try Data(contentsOf: database)
        let logBytes = try Data(contentsOf: log)
        let snapshotsBefore = try snapshotFolders()

        let scan = try MacWhisperMeetingReader.read(database)

        try assertLibrary(scan, folder: folder)
        XCTAssertEqual(try Data(contentsOf: database), mainBytes)
        XCTAssertEqual(try Data(contentsOf: log), logBytes)
        XCTAssertEqual(try snapshotFolders(), snapshotsBefore, "the private copy is removed")
    }

    func testAnotherAppsDatabaseIsRefusedWithoutQuotingIt() throws {
        let folder = try temporaryFolder("macwhisper-not-library")
        let other = folder.appendingPathComponent("other.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(other.path, &db), SQLITE_OK)
        try exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('secret');")
        sqlite3_close(db)
        XCTAssertThrowsError(try MacWhisperMeetingReader.read(other)) { error in
            guard case .unreadable(_, let reason) = error as? ExternalImportError else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertFalse(reason.contains("secret"))
        }
    }

    func testDefaultLocationAndHint() {
        XCTAssertEqual(MacWhisperMeetingReader.defaultLocations, ["~/Library/Application Support/MacWhisper/Database/main.sqlite"])
        XCTAssertTrue(MacWhisperMeetingReader.exportHint.contains(".whisper"))
        XCTAssertEqual(ObjectIdentifier(ExternalMeetingReaders.reader(for: .macWhisper)), ObjectIdentifier(MacWhisperMeetingReader.self))
    }

    private func assertLibrary(_ scan: ExternalImportScan, folder: URL, file: StaticString = #filePath,
                               line: UInt = #line) throws {
        XCTAssertEqual(scan.problems, [], file: file, line: line)
        let byID = Dictionary(uniqueKeysWithValues: scan.meetings.map { ($0.sourceID, $0) })
        XCTAssertEqual(Set(byID.keys), Set(["a1", "a2", "a6", "a7"].map { String(repeating: $0, count: 16) }),
                       "deleted, transient, and podcast sessions are skipped", file: file, line: line)

        let pricing = try XCTUnwrap(byID[String(repeating: "a1", count: 16)], file: file, line: line)
        XCTAssertEqual(pricing.title, "Pricing review", "the calendar title beats the app's placeholder", file: file, line: line)
        XCTAssertEqual(pricing.startedAt, utc("2026-09-21T10:00:00Z"), "recording stopped, minus its length", file: file, line: line)
        XCTAssertEqual(pricing.duration, 1_800, file: file, line: line)
        XCTAssertEqual(pricing.lines, [
            .init(start: 0, end: 4.2, speaker: "Ana", text: "Let's keep the Team plan at fifteen per seat."),
            .init(start: 4.5, end: 9, speaker: "Leo", text: "Billed annually, then."),
            .init(start: 9.1, end: 11, speaker: "Speaker 3", text: "Agreed."),
            .init(start: 11.5, end: 12, text: "Who else is here?"),
        ], file: file, line: line)
        XCTAssertEqual(pricing.participants, ["Ana", "Leo"], file: file, line: line)
        XCTAssertEqual(pricing.notes?.contains("Pricing stays"), true, file: file, line: line)
        XCTAssertEqual(pricing.actionItems, [.init(text: "Ana sends the new price sheet"),
                                             .init(text: "Leo updates the billing page")], file: file, line: line)
        XCTAssertNil(pricing.audioURL, "separate microphone and app tracks are no single recording", file: file, line: line)
        XCTAssertEqual(pricing.origin.lastPathComponent, "main.sqlite", file: file, line: line)

        let memo = try XCTUnwrap(byID[String(repeating: "a2", count: 16)], file: file, line: line)
        XCTAssertEqual(memo.title, "Idea for onboarding", file: file, line: line)
        XCTAssertEqual(memo.startedAt, utc("2026-09-22T08:00:00Z"), file: file, line: line)
        XCTAssertEqual(memo.audioURL, folder.appendingPathComponent("ExternalMedia/\(memoMedia)"), file: file, line: line)

        let interview = try XCTUnwrap(byID[String(repeating: "a6", count: 16)], file: file, line: line)
        XCTAssertEqual(interview.title, "Interview", file: file, line: line)
        XCTAssertEqual(interview.lines, [.init(text: "First paragraph."), .init(text: "Second paragraph.")],
                       "fullText when there are no lines", file: file, line: line)

        let sync = try XCTUnwrap(byID[String(repeating: "a7", count: 16)], file: file, line: line)
        XCTAssertEqual(sync.title, "Design sync", "the person's own title comes first", file: file, line: line)
        XCTAssertEqual(sync.startedAt, utc("2026-09-23T14:50:00Z"), file: file, line: line)
    }

    // MARK: - Fixtures

    private let meetingMedia = ["A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1_mic-audio_x.m4a",
                                "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1_app-audio_x.m4a"]
    private let memoMedia = "A2A2A2A2-A2A2-A2A2-A2A2-A2A2A2A2A2A2_mic-audio_memo.m4a"

    private func temporaryFolder(_ name: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }

    private func ditto(_ folder: URL, to archive: URL, keepParent: Bool = false) throws {
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr"] + (keepParent ? ["--keepParent"] : [])
            + [folder.path, archive.path])
    }

    private func listing(_ folder: URL) -> [String] {
        (fileManager.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
    }

    private func utc(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private func snapshotFolders() throws -> Set<String> {
        Set(try fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path)
            .filter { $0.hasPrefix("lokalbot-import-macwhisper-db-") })
    }

    /// Bytes that start like an AAC .m4a file.
    private func fakeM4A(_ count: Int = 4_000) -> Data {
        Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }

    /// `metadata.json` as MacWhisper writes it: milliseconds, speaker objects,
    /// and dates as seconds since 2001.
    private func whisperMetadata(extension ext: String? = "m4a") -> [String: Any] {
        let ana: [String: Any] = ["id": "6B29FC40-CA47-1067-B31D-00DD010662DA", "name": "Ana", "color": 1]
        let leo: [String: Any] = ["id": "7C29FC40-CA47-1067-B31D-00DD010662DB", "name": "Leo", "color": 2]
        let other: [String: Any] = ["id": "8D29FC40-CA47-1067-B31D-00DD010662DC", "name": "Speaker 3", "color": 3]
        var metadata: [String: Any] = [
            "originalMediaFilename": "Pricing review",
            "dateCreated": created.timeIntervalSinceReferenceDate,
            "dateUpdated": created.timeIntervalSinceReferenceDate + 90,
            "modelEngine": "whisperCPP",
            "modelQualityID": "ggml-model-whisper-large-v3-turbo",
            "modelLanguageID": "en",
            "detectedLanguageRaw": "en",
            "wasTranslatedToEnglish": false,
            "startTimeOffset": ["hours": 0, "minutes": 0, "seconds": 0, "milliseconds": 0],
            "speakers": [ana, leo, other],
            "tags": [] as [Any],
            "transcripts": [
                ["id": UUID().uuidString, "start": 0, "end": 4_200, "text": " Let's keep the Team plan at fifteen per seat.",
                 "speaker": ana, "favorited": false, "unEven": false],
                ["id": UUID().uuidString, "start": 4_500, "end": 9_000, "text": "Billed annually, then.",
                 "speaker": leo, "favorited": true, "unEven": false],
                ["id": UUID().uuidString, "start": 9_100, "end": 11_000, "text": "Agreed.",
                 "speaker": other, "favorited": false, "unEven": false],
                ["id": UUID().uuidString, "start": 11_000, "end": 11_000, "text": "   ", "favorited": false, "unEven": false],
            ],
            // Read when present; MacWhisper's library keeps its AI summary under this name.
            "aiSummary": "## Summary\n\nPricing stays at fifteen per seat.\n\n## Action items\n\n"
                + "- Ana sends the new price sheet\n- [ ] Leo updates the billing page",
        ]
        if let ext { metadata["originalMediaExtension"] = ext }
        return metadata
    }

    private func makeWhisper(at url: URL, metadata: [String: Any], audio: Data?, keepParent: Bool = false) throws {
        let stage = try temporaryFolder("whisper-stage").appendingPathComponent("doc", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: metadata).write(to: stage.appendingPathComponent("metadata.json"))
        try write("2", to: stage.appendingPathComponent("version"))
        if let audio { try audio.write(to: stage.appendingPathComponent("originalAudio")) }
        try ditto(stage, to: url, keepParent: keepParent)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        XCTAssertEqual(status, SQLITE_OK, message.map { String(cString: $0) } ?? "")
    }

    private func id(_ byte: String) -> String {
        "X'" + String(repeating: byte, count: 16) + "'"
    }

    /// MacWhisper's library as GRDB lays it out: UUID blobs, UTC dates as
    /// text, transcript lines in milliseconds. With `keepOpenInWAL`, the
    /// writer stays open and every change is still in the write-ahead log.
    private func makeLibrary(in folder: URL, keepOpenInWAL: Bool) throws -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("main.sqlite").path, &db), SQLITE_OK)
        if keepOpenInWAL { try exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        try exec(db, """
            CREATE TABLE session (id BLOB PRIMARY KEY NOT NULL, dateCreated DATETIME NOT NULL, dateUpdated DATETIME,
                dateDeleted DOUBLE, isTransient BOOLEAN NOT NULL DEFAULT 0, transcriptionDidSucceed BOOLEAN, userChosenTitle TEXT,
                aiTitle TEXT, aiSummary TEXT, fullText TEXT, textPreview TEXT, playbackDuration DOUBLE, originalFilename TEXT,
                recordedMeetingID BLOB, systemAudioRecordingID BLOB, voiceMemoID BLOB, podcastID BLOB, downloadMetadataID BLOB,
                isFromYoutube BOOLEAN NOT NULL DEFAULT 0);
            CREATE TABLE transcriptline (id BLOB PRIMARY KEY NOT NULL, sessionId BLOB NOT NULL, text TEXT NOT NULL,
                start INTEGER NOT NULL, "end" INTEGER NOT NULL, orderIndex INTEGER, speakerID BLOB, wordsJson TEXT);
            CREATE TABLE speaker (id BLOB PRIMARY KEY NOT NULL, name TEXT NOT NULL, isStub BOOLEAN);
            CREATE TABLE session_speaker (sessionID BLOB NOT NULL, speakerID BLOB NOT NULL);
            CREATE TABLE recordedmeeting (id BLOB PRIMARY KEY NOT NULL, date DATETIME, title TEXT, bundleIdentifier TEXT,
                appName TEXT, duration DOUBLE, dateCreated DATETIME, matchedCalendarTitle TEXT, dateDeleted DOUBLE);
            CREATE TABLE systemaudiorecording (id BLOB PRIMARY KEY NOT NULL, date DATETIME, title TEXT, duration DOUBLE,
                dateDeleted DOUBLE);
            CREATE TABLE voicememos (id BLOB PRIMARY KEY NOT NULL, title TEXT);
            CREATE TABLE podcast (id BLOB PRIMARY KEY NOT NULL, title TEXT);
            CREATE TABLE mediafile (id BLOB PRIMARY KEY NOT NULL, sessionId BLOB, filename TEXT);
            """)
        try exec(db, """
            INSERT INTO speaker VALUES (\(id("51")), 'Ana', 0), (\(id("52")), 'Leo', 0), (\(id("53")), 'Speaker 3', 1);
            INSERT INTO recordedmeeting (id, date, title, bundleIdentifier, appName, duration, matchedCalendarTitle)
                VALUES (\(id("01")), '2026-09-21 10:30:00.000', 'Meeting - Zoom', 'us.zoom.xos', 'Zoom', 1800, 'Pricing review');
            INSERT INTO systemaudiorecording (id, date, title, duration) VALUES (\(id("02")), '2026-09-23 15:00:00.000', 'Team call', 600);
            INSERT INTO voicememos VALUES (\(id("03")), 'Idea for onboarding');
            INSERT INTO podcast VALUES (\(id("04")), 'Episode 12');
            INSERT INTO session (id, dateCreated, recordedMeetingID, aiTitle, aiSummary, playbackDuration)
                VALUES (\(id("a1")), '2026-09-21 10:30:05.123', \(id("01")), 'Subject: Pricing' || char(10) || 'Participants: Ana, Leo',
                '## Summary' || char(10) || char(10) || 'Pricing stays at fifteen per seat.' || char(10) || char(10)
                || '**Action items**' || char(10) || '- Ana sends the new price sheet' || char(10)
                || '- [ ] Leo updates the billing page', 1799.5);
            INSERT INTO transcriptline VALUES
                (\(id("b2")), \(id("a1")), 'Billed annually, then.', 4500, 9000, 1, \(id("52")), NULL),
                (\(id("b1")), \(id("a1")), ' Let''s keep the Team plan at fifteen per seat.', 0, 4200, 0, \(id("51")), NULL),
                (\(id("b3")), \(id("a1")), 'Agreed.', 9100, 11000, 2, \(id("53")), NULL),
                (\(id("b4")), \(id("a1")), 'Who else is here?', 11500, 12000, 3, NULL, NULL);
            INSERT INTO mediafile VALUES (\(id("c1")), \(id("a1")), '\(meetingMedia[0])'), (\(id("c2")), \(id("a1")), '\(meetingMedia[1])');
            INSERT INTO session (id, dateCreated, voiceMemoID) VALUES (\(id("a2")), '2026-09-22 08:00:00.000', \(id("03")));
            INSERT INTO transcriptline VALUES (\(id("b5")), \(id("a2")), 'Start onboarding with a checklist.', 0, 3000, 0, NULL, NULL);
            INSERT INTO mediafile VALUES (\(id("c3")), \(id("a2")), '\(memoMedia)');
            INSERT INTO session (id, dateCreated, originalFilename, dateDeleted) VALUES (\(id("a3")), '2026-09-24 09:00:00', 'Deleted', 811111111.0);
            INSERT INTO transcriptline VALUES (\(id("b6")), \(id("a3")), 'Gone.', 0, 1000, 0, NULL, NULL);
            INSERT INTO session (id, dateCreated, originalFilename, isTransient) VALUES (\(id("a4")), '2026-09-24 09:05:00', 'Transient', 1);
            INSERT INTO transcriptline VALUES (\(id("b7")), \(id("a4")), 'Transient.', 0, 1000, 0, NULL, NULL);
            INSERT INTO session (id, dateCreated, podcastID) VALUES (\(id("a5")), '2026-09-24 09:10:00', \(id("04")));
            INSERT INTO transcriptline VALUES (\(id("b8")), \(id("a5")), 'Podcast talk.', 0, 1000, 0, NULL, NULL);
            INSERT INTO session (id, dateCreated, originalFilename, fullText) VALUES (\(id("a6")), '2026-09-25 12:00:00.000',
                'Interview', 'First paragraph.' || char(10) || char(10) || 'Second paragraph.');
            INSERT INTO session (id, dateCreated, systemAudioRecordingID, userChosenTitle)
                VALUES (\(id("a7")), '2026-09-23 15:00:02.000', \(id("02")), 'Design sync');
            INSERT INTO transcriptline VALUES (\(id("b9")), \(id("a7")), 'Ship the new icons.', 1000, 2500, 0, \(id("51")), NULL);
            """)
        let media = folder.appendingPathComponent("ExternalMedia", isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        for name in meetingMedia + [memoMedia] { try fakeM4A(100).write(to: media.appendingPathComponent(name)) }
        if keepOpenInWAL { return db }
        sqlite3_close(db)
        return nil
    }
}
