import XCTest
@testable import LokalBot

final class ExternalImportTextTests: XCTestCase {
    func testTimestamps() {
        XCTAssertEqual(ExternalImportText.timestamp("01:02:03,450"), 3_723.45)
        XCTAssertEqual(ExternalImportText.timestamp("01:02:03.450"), 3_723.45)
        XCTAssertEqual(ExternalImportText.timestamp("1:02:03"), 3_723)
        XCTAssertEqual(ExternalImportText.timestamp("02:03"), 123)
        XCTAssertEqual(ExternalImportText.timestamp(" 0:05 "), 5)
        XCTAssertNil(ExternalImportText.timestamp("2:61"))
        XCTAssertNil(ExternalImportText.timestamp("1.5:00"))
        XCTAssertNil(ExternalImportText.timestamp("Speaker 1"))
        XCTAssertNil(ExternalImportText.timestamp("12"))
    }

    func testDates() throws {
        XCTAssertEqual(ExternalImportText.date("2026-03-04T10:15:00Z"), Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertEqual(ExternalImportText.date("2026-03-04T10:15:00.250Z")?.timeIntervalSince1970 ?? 0,
                       1_772_619_300.25, accuracy: 0.001)
        XCTAssertEqual(ExternalImportText.date("2026-03-04T11:15:00+01:00"), Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertEqual(ExternalImportText.date("2026-03-04 10:15:00"), Date(timeIntervalSince1970: 1_772_619_300))
        XCTAssertNil(ExternalImportText.date("yesterday"))
    }

    func testStableIDsAreDeterministicAndPartSensitive() {
        let id = ExternalImportText.stableID("2026-03-04", "Standup")
        XCTAssertEqual(id.count, 32)
        XCTAssertEqual(id, ExternalImportText.stableID("2026-03-04", "Standup"))
        XCTAssertNotEqual(id, ExternalImportText.stableID("2026-03-04Standup"))
    }

    func testSpeakerSplitOnlyTakesNameLikePrefixes() {
        XCTAssertEqual(ExternalImportText.splitSpeaker("Ana Petrović: Let's ship it").speaker, "Ana Petrović")
        XCTAssertEqual(ExternalImportText.splitSpeaker("Ana Petrović: Let's ship it").text, "Let's ship it")
        XCTAssertNil(ExternalImportText.splitSpeaker("The plan is simple, really: ship").speaker)
        XCTAssertNil(ExternalImportText.splitSpeaker("10:30 works").speaker)
        XCTAssertNil(ExternalImportText.splitSpeaker("No colon here").speaker)
    }

    func testReadTextHandlesByteOrderMarksAndLineEndings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let utf8 = folder.appendingPathComponent("a.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("Ana:\r\nZdravo\r\n".utf8)).write(to: utf8)
        XCTAssertEqual(try ExternalImportText.readText(utf8), "Ana:\nZdravo\n")
        let utf16 = folder.appendingPathComponent("b.txt")
        try XCTUnwrap("Čao".data(using: .utf16)).write(to: utf16)
        XCTAssertEqual(try ExternalImportText.readText(utf16), "Čao")
    }

    func testSubRipWithNamePrefixesMergesATurn() {
        let lines = SubtitleTranscript.parse("""
            1
            00:00:01,000 --> 00:00:03,500
            Ana: Let's keep the Team plan

            2
            00:00:03,600 --> 00:00:05,000
            Ana: at fifteen per seat.

            3
            00:00:06,000 --> 00:00:08,000
            Leo: Billed annually.
            """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], .init(start: 1, end: 5, speaker: "Ana", text: "Let's keep the Team plan at fifteen per seat."))
        XCTAssertEqual(lines[1], .init(start: 6, end: 8, speaker: "Leo", text: "Billed annually."))
    }

    func testWebVTTVoiceTagsSettingsAndUnnamedCues() {
        let lines = SubtitleTranscript.parse("""
            WEBVTT

            NOTE written by a test

            cue-1
            00:00.000 --> 00:02.000 align:start
            <v Ana>Hello <b>everyone</b></v>

            00:00:02.500 --> 00:00:04.000
            <v.loud Leo>Hi!

            00:00:10.000 --> 00:00:12.000
            Just words, no speaker.
            """)
        XCTAssertEqual(lines.map(\.speaker), ["Ana", "Leo", nil])
        XCTAssertEqual(lines.map(\.text), ["Hello everyone", "Hi!", "Just words, no speaker."])
        XCTAssertEqual(lines.first?.end, 2)
    }
}

final class ExternalMeetingReadersTests: XCTestCase {
    func testExpandHandlesHomeRelativePaths() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ExternalMeetingReaders.expand("~", home: home).path, "/Users/someone")
        XCTAssertEqual(ExternalMeetingReaders.expand("~/Exports/a.zip", home: home).path, "/Users/someone/Exports/a.zip")
        XCTAssertEqual(ExternalMeetingReaders.expand("/tmp/x", home: home).path, "/tmp/x")
    }

    func testEverySourceHasAReaderForItself() {
        for source in ExternalMeetingSource.allCases {
            XCTAssertEqual(ExternalMeetingReaders.reader(for: source).source, source)
            XCTAssertFalse(source.exportHint.isEmpty)
            XCTAssertEqual(ExternalMeetingSource(rawValue: source.rawValue), source)
        }
    }

    func testScanReportsMissingPathsAndUnpacksZipArchives() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("missing.txt")
        let result = ExternalMeetingReaders.scan(.otter, urls: [missing])
        result.cleanup()
        XCTAssertEqual(result.scan.problems.map(\.path), [missing.path])

        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: content.appendingPathComponent("note.txt"))
        let zip = folder.appendingPathComponent("export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let unpacked = try ExternalImportArchive.unzip(zip)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        XCTAssertEqual(ExternalImportText.files(in: unpacked).map(\.lastPathComponent), ["note.txt"])
    }

    func testStagedRecordingFoldersAreCleanedUpButNothingElse() throws {
        let temporary = URL(fileURLWithPath: "/tmp/lokalbot-tests-\(UUID().uuidString)")
        func meeting(_ id: String, audio: String?) -> ExternalMeeting {
            ExternalMeeting(source: .macWhisper, sourceID: id, title: id,
                            audioURL: audio.map { temporary.appendingPathComponent($0) },
                            origin: URL(fileURLWithPath: "/tmp/x"))
        }
        let folders = ExternalMeetingReaders.stagedFolders(in: [
            meeting("a", audio: "lokalbot-import-macwhisper-1/a.m4a"),
            meeting("b", audio: "lokalbot-import-macwhisper-1/b.m4a"),
            meeting("c", audio: "lokalbot-import-zip/inner/c.m4a"),
            meeting("d", audio: "someone-else/d.m4a"),
            meeting("e", audio: nil),
        ], temporaryDirectory: temporary)
        XCTAssertEqual(folders.map(\.lastPathComponent), ["lokalbot-import-macwhisper-1"])
        XCTAssertTrue(ExternalMeetingReaders.stagedFolders(
            in: [ExternalMeeting(source: .zoom, sourceID: "z", title: "z",
                                 audioURL: URL(fileURLWithPath: "/Users/someone/Documents/Zoom/a.m4a"),
                                 origin: URL(fileURLWithPath: "/tmp/x"))],
            temporaryDirectory: temporary).isEmpty, "a source's own files are never cleaned up")
    }

    func testEmptyMeetingsAndRepeatedKeysAreRecognized() {
        let origin = URL(fileURLWithPath: "/tmp/x")
        let meetings = [
            ExternalMeeting(source: .otter, sourceID: "1", title: "A", notes: "n", origin: origin),
            ExternalMeeting(source: .otter, sourceID: "1", title: "A again", notes: "n", origin: origin),
            ExternalMeeting(source: .otter, sourceID: "2", title: "Empty", lines: [.init(text: "  ")], origin: origin),
        ]
        XCTAssertEqual(meetings.filter(\.isEmpty).map(\.sourceID), ["2"])
        XCTAssertEqual(Set(meetings.map(\.importKey)).count, 2)
    }
}

@MainActor
final class MeetingImportApprovalTests: XCTestCase {
    func testImportRequestsWaitForThePersonAndAreNotAskedTwice() throws {
        let approvals = SettingsApprovals()
        let subject = SettingsApprovals.Subject.meetingImport(.init(source: .otter, paths: ["/tmp/export"]))
        let first = try approvals.submit(subject, caller: "zsh", items: [], changes: [["newMeetings": 3]])
        let second = try approvals.submit(subject, caller: "zsh", items: [], changes: [["newMeetings": 3]])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.headline, "Importing meetings from Otter")
        XCTAssertEqual(first.state, .pending)
        approvals.deny(first.id)
        XCTAssertEqual(approvals.request(first.id)?.state, .denied)
    }

    func testSecretsAreNeverMatchedAgainstAWaitingRequest() throws {
        let approvals = SettingsApprovals()
        let subject = SettingsApprovals.Subject.secret(.openAICompatible, value: "sk-1")
        let first = try approvals.submit(subject, caller: "zsh", items: [], changes: [])
        let second = try approvals.submit(subject, caller: "zsh", items: [], changes: [])
        XCTAssertNotEqual(first.id, second.id)
    }
}
