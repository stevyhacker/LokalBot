import XCTest
@testable import LokalBot

final class ZoomMeetingReaderTests: XCTestCase {
    private static let namedTranscript = """
        WEBVTT

        1
        00:00:01.200 --> 00:00:04.800
        Ana Petrović: Let's keep the Team plan at fifteen per seat.

        2
        00:00:05.100 --> 00:00:07.900
        Leo Marković: Billed annually, then.

        3
        00:00:08.000 --> 00:00:10.500
        Unknown Speaker: Sorry, I joined late.

        4
        00:00:11.000 --> 00:00:14.250
        Ana Petrović: I'll send the summary by Friday.
        """

    private static let unnamedTranscript = """
        WEBVTT

        1
        00:00:00.500 --> 00:00:03.000
        We should ship the beta on Thursday.

        2
        00:00:03.500 --> 00:00:06.000
        Thursday works if QA signs off.
        """

    private static let namedCaptions = """
        WEBVTT

        1
        00:00:00.500 --> 00:00:03.000
        Mia: We should ship the beta on Thursday.

        2
        00:00:03.500 --> 00:00:06.000
        Noor: Thursday works if QA signs off.
        """

    private static let chat = """
        10:16:02 From Ana Petrović to Everyone:
        \tSlides are in the shared folder
        """

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(_ base: URL, _ components: String...) -> URL {
        components.reduce(base) { $0.appendingPathComponent($1) }
    }

    private func write(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeMedia(_ url: URL) throws {
        try writeData(Data("synthetic media".utf8), to: url)
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    func testComputerRecordingFolderRoundTrip() throws {
        let root = file(try temporaryDirectory("zoom-local"), "Zoom")
        let folder = file(root, "2026-03-04 10.15.00 Pricing review 81234567890")
        try writeMedia(file(folder, "audio_only.m4a"))
        try writeMedia(file(folder, "zoom_0.mp4"))
        try write("#EXTM3U\nzoom_0.mp4\n", to: file(folder, "playback.m3u"))
        try write(Self.chat, to: file(folder, "chat.txt"))
        try writeMedia(file(folder, "Audio Record", "audioAnaPetrovic11234567.m4a"))
        try write(Self.namedTranscript, to: file(folder, "GMT20260304-091500.vtt"))
        let personalRoom = file(root, "2026-03-05 16.00.00 Ana Petrović's Personal Meeting Room 4155550123")
        try writeMedia(file(personalRoom, "video98796876.mp4"))
        try write(Self.chat, to: file(personalRoom, "meeting_saved_chat.txt"))

        let scan = try ZoomMeetingReader.read(root)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.map(\.title), ["Pricing review", "Ana Petrović's Personal Meeting Room"])
        let meeting = try XCTUnwrap(scan.meetings.first)
        XCTAssertEqual(meeting.source, .zoom)
        XCTAssertEqual(meeting.startedAt, localDate(2026, 3, 4, 10, 15))
        XCTAssertEqual(meeting.audioURL?.lastPathComponent, "audio_only.m4a", "the audio-only file, not the video or a participant track")
        XCTAssertEqual(meeting.origin.lastPathComponent, folder.lastPathComponent)
        XCTAssertEqual(meeting.lines.map(\.speaker), ["Ana Petrović", "Leo Marković", nil, "Ana Petrović"])
        XCTAssertEqual(meeting.lines.map(\.start), [1.2, 5.1, 8, 11])
        XCTAssertEqual(meeting.lines.map(\.end), [4.8, 7.9, 10.5, 14.25])
        XCTAssertEqual(meeting.lines.first?.text, "Let's keep the Team plan at fifteen per seat.")
        XCTAssertFalse(meeting.lines.contains { $0.isMe }, "Zoom never says which voice was the person's own")
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marković"])
        XCTAssertEqual(meeting.duration, 14.25)
        XCTAssertNil(meeting.notes, "a recording carries no notes")
        XCTAssertEqual(meeting.actionItems, [])
        XCTAssertFalse(meeting.lines.contains { $0.text.contains("Slides") }, "chat is never a transcript")

        let room = scan.meetings[1]
        XCTAssertEqual(room.startedAt, localDate(2026, 3, 5, 16, 0))
        XCTAssertEqual(room.audioURL?.lastPathComponent, "video98796876.mp4", "the video when there's no audio-only file")
        XCTAssertEqual(room.lines, [])
        XCTAssertEqual(room.participants, [])
    }

    func testCloudDownloadsGroupByStampAndPreferTheNamedTranscript() throws {
        let downloads = try temporaryDirectory("zoom-cloud")
        let first = "GMT20260304-091500_Recording"
        try writeMedia(file(downloads, "\(first).m4a"))
        try writeMedia(file(downloads, "\(first)_1920x1080.mp4"))
        try writeMedia(file(downloads, "\(first)_gallery_1920x1080.mp4"))
        try write(Self.namedTranscript, to: file(downloads, "\(first).transcript.vtt"))
        try write(Self.unnamedTranscript, to: file(downloads, "\(first).cc.vtt"))
        try write(Self.chat, to: file(downloads, "\(first)newChat.txt"))
        let second = "GMT20260311-140000_Recording"
        try writeMedia(file(downloads, "\(second)_as_1920x1080.mp4"))
        try writeMedia(file(downloads, "\(second)_1920x1080.mp4"))
        try write(Self.unnamedTranscript, to: file(downloads, "\(second).transcript.vtt"))
        try write(Self.namedCaptions, to: file(downloads, "\(second).cc.vtt"))
        try writeMedia(file(downloads, "holiday.m4a"))
        try write("Quarterly numbers", to: file(downloads, "report.txt"))

        let scan = try ZoomMeetingReader.read(downloads)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.count, 2)
        let meeting = scan.meetings[0]
        XCTAssertEqual(meeting.title, "Zoom meeting")
        XCTAssertEqual(meeting.startedAt, ExternalImportText.date("2026-03-04T09:15:00Z"), "the GMT stamp is UTC")
        XCTAssertEqual(meeting.audioURL?.lastPathComponent, "\(first).m4a")
        XCTAssertEqual(meeting.origin.lastPathComponent, "\(first).m4a")
        XCTAssertEqual(meeting.lines.map(\.speaker), ["Ana Petrović", "Leo Marković", nil, "Ana Petrović"])
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marković"], "Unknown Speaker is nobody")
        XCTAssertFalse(meeting.lines.contains { $0.text.contains("Slides") })

        let later = scan.meetings[1]
        XCTAssertEqual(later.startedAt, ExternalImportText.date("2026-03-11T14:00:00Z"))
        XCTAssertEqual(later.audioURL?.lastPathComponent, "\(second)_1920x1080.mp4", "speaker view, not the screen share alone")
        XCTAssertEqual(later.lines.map(\.speaker), ["Mia", "Noor"], "captions that name speakers beat a transcript that doesn't")
        XCTAssertEqual(later.lines.map(\.start), [0.5, 3.5])
        XCTAssertFalse(scan.meetings.contains { $0.audioURL?.lastPathComponent == "holiday.m4a" })
    }

    func testRecognizesZoomFilesAndFolders() throws {
        let base = try temporaryDirectory("zoom-recognize")
        let root = file(base, "Zoom")
        let folder = file(root, "2026-03-04 10.15.00 Pricing review")
        let recordingFiles = ["audio_only.m4a", "audio_only_1.m4a", "audio98796876.m4a", "zoom_0.mp4", "video98796876.mp4",
                              "chat.txt", "meeting_saved_closed_caption.txt", "double_click_to_convert_01.zoom", "renamed.m4a"]
        for name in recordingFiles { try writeMedia(file(folder, name)) }
        try writeMedia(file(folder, "playback.m3u"))
        let downloads = file(base, "Downloads")
        let cloudFiles = ["GMT20260304-091500_Recording.m4a", "GMT20260304-091500_Recording_1920x1080.mp4",
                          "GMT20260304-091500_Recording.transcript.vtt", "GMT20260304-091500_Recording.cc.vtt",
                          "GMT20260304-091500_RecordingnewChat.txt", "Weekly sync.vtt"]
        for name in cloudFiles { try writeMedia(file(downloads, name)) }
        let other = file(base, "Other")
        let otherFiles = ["holiday.m4a", "movie.mp4", "notes.txt", "report.pdf"]
        for name in otherFiles { try writeMedia(file(other, name)) }
        let empty = file(base, "Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        for name in recordingFiles { XCTAssertTrue(ZoomMeetingReader.recognizes(file(folder, name)), name) }
        for name in cloudFiles { XCTAssertTrue(ZoomMeetingReader.recognizes(file(downloads, name)), name) }
        XCTAssertTrue(ZoomMeetingReader.recognizes(folder))
        XCTAssertTrue(ZoomMeetingReader.recognizes(root))
        XCTAssertTrue(ZoomMeetingReader.recognizes(downloads))

        for name in otherFiles { XCTAssertFalse(ZoomMeetingReader.recognizes(file(other, name)), name) }
        XCTAssertFalse(ZoomMeetingReader.recognizes(file(folder, "playback.m3u")))
        XCTAssertFalse(ZoomMeetingReader.recognizes(other))
        XCTAssertFalse(ZoomMeetingReader.recognizes(empty))
        XCTAssertFalse(ZoomMeetingReader.recognizes(file(base, "missing", "audio_only.m4a")))
    }

    func testUnreadableFilesAreProblemsAndTheRestStillReads() throws {
        let root = try temporaryDirectory("zoom-problems")
        let good = file(root, "2026-03-04 10.15.00 Good")
        try writeMedia(file(good, "audio_only.m4a"))
        try write(Self.namedTranscript, to: file(good, "closed_caption.vtt"))
        let brokenTranscript = file(root, "2026-03-05 11.00.00 Broken transcript")
        try writeMedia(file(brokenTranscript, "audio_only.m4a"))
        try writeData(Data([0x00, 0x9F, 0x92, 0x96, 0xFF, 0x00, 0x01, 0xC3]), to: file(brokenTranscript, "broken.vtt"))
        let onlyJunk = file(root, "2026-03-06 12.00.00 Only junk")
        try write("Shopping list: eggs, milk", to: file(onlyJunk, "notes.vtt"))
        let notConverted = file(root, "2026-03-07 13.00.00 Not converted")
        try writeMedia(file(notConverted, "double_click_to_convert_01.zoom"))
        try writeMedia(file(notConverted, "double_click_to_convert_02.zoom"))
        let chatOnly = file(root, "2026-03-08 14.00.00 Chat only")
        try write(Self.chat, to: file(chatOnly, "meeting_saved_chat.txt"))
        let emptyAudio = file(root, "2026-03-09 15.00.00 Empty audio")
        try writeData(Data(), to: file(emptyAudio, "audio_only.m4a"))

        let scan = try ZoomMeetingReader.read(root)

        XCTAssertEqual(scan.meetings.map(\.title), ["Good", "Broken transcript"])
        XCTAssertEqual(scan.meetings[0].lines.count, 4)
        XCTAssertEqual(scan.meetings[1].lines, [], "LokalBot transcribes the recording instead")
        XCTAssertEqual(scan.meetings[1].audioURL?.lastPathComponent, "audio_only.m4a")
        XCTAssertEqual(scan.problems.map { fileName($0.path) },
                       ["broken.vtt", "notes.vtt", notConverted.lastPathComponent, "audio_only.m4a"],
                       "a chat-only folder isn't a problem, just nothing to import")
        XCTAssertTrue(scan.problems[2].reason.contains("converted"))
        for problem in scan.problems {
            XCTAssertFalse(problem.reason.contains("eggs"), "problems never quote what a file says")
            XCTAssertFalse(problem.reason.contains("Slides"))
        }
    }

    func testSourceIDsStayTheSameAcrossReadsAndChoices() throws {
        let root = try temporaryDirectory("zoom-ids")
        let folder = file(root, "2026-03-04 10.15.00 Pricing review")
        try writeMedia(file(folder, "audio_only.m4a"))
        let localTranscript = file(folder, "closed_caption.vtt")
        try write(Self.namedTranscript, to: localTranscript)
        let cloudAudio = file(root, "Downloads", "GMT20260304-091500_Recording.m4a")
        let cloudTranscript = file(root, "Downloads", "GMT20260304-091500_Recording.transcript.vtt")
        try writeMedia(cloudAudio)
        try write(Self.namedTranscript, to: cloudTranscript)

        let first = try ZoomMeetingReader.read(root)
        let second = try ZoomMeetingReader.read(root)

        XCTAssertEqual(first.meetings.count, 2)
        XCTAssertEqual(first.meetings.map(\.sourceID), second.meetings.map(\.sourceID))
        XCTAssertEqual(Set(first.meetings.map(\.sourceID)).count, 2)
        XCTAssertEqual(first.meetings[0].sourceID.count, 32)

        let fromOneFile = try XCTUnwrap(ZoomMeetingReader.read(localTranscript).meetings.first)
        XCTAssertEqual(fromOneFile.sourceID, first.meetings[0].sourceID, "one file reads its whole recording")
        XCTAssertEqual(fromOneFile.audioURL?.lastPathComponent, "audio_only.m4a")

        let chosen = ExternalMeetingReaders.scan(.zoom, urls: [cloudAudio, cloudTranscript])
        chosen.cleanup()
        XCTAssertEqual(chosen.scan.meetings.count, 1, "the audio and its transcript are one meeting")
        let cloud = try XCTUnwrap(chosen.scan.meetings.first)
        XCTAssertEqual(cloud.sourceID, first.meetings[1].sourceID)
        XCTAssertEqual(cloud.audioURL?.lastPathComponent, cloudAudio.lastPathComponent)
        XCTAssertEqual(cloud.lines.count, 4)
    }

    func testSavedCaptionsWithoutARecording() throws {
        let root = try temporaryDirectory("zoom-captions")
        let crit = file(root, "2026-03-12 16.00.00 Design crit")
        try write("""
            [Ana Petrović] 16:00:05
            Shall we start with the onboarding flow?

            [Leo Marković] 16:00:12
            Yes. The second screen still feels slow.
            It loads the whole catalog.
            """, to: file(crit, "meeting_saved_closed_caption.txt"))
        try write("16:00:05 Shall we start with the onboarding flow?\n", to: file(crit, "closed_caption.txt"))
        try write(Self.chat, to: file(crit, "meeting_saved_chat.txt"))
        let retro = file(root, "2026-03-13 10.00.00 Retro")
        try write("10:00:30 Thanks for joining.\n10:01:00 Let's look at last sprint.\n",
                  to: file(retro, "closed_caption.txt"))
        let standup = file(root, "2026-03-14 09.00.00 Standup")
        try writeMedia(file(standup, "audio_only.m4a"))
        try write("[Mia] 09:00:03\nMorning.\n", to: file(standup, "meeting_saved_closed_caption.txt"))

        let scan = try ZoomMeetingReader.read(root)

        XCTAssertEqual(scan.problems, [])
        XCTAssertEqual(scan.meetings.map(\.title), ["Design crit", "Retro", "Standup"])
        let meeting = scan.meetings[0]
        XCTAssertNil(meeting.audioURL)
        XCTAssertEqual(meeting.lines, [
            .init(start: 5, speaker: "Ana Petrović", text: "Shall we start with the onboarding flow?"),
            .init(start: 12, speaker: "Leo Marković", text: "Yes. The second screen still feels slow. It loads the whole catalog."),
        ])
        XCTAssertEqual(meeting.participants, ["Ana Petrović", "Leo Marković"])
        XCTAssertEqual(scan.meetings[1].lines, [
            .init(start: 30, text: "Thanks for joining."),
            .init(start: 60, text: "Let's look at last sprint."),
        ])
        XCTAssertEqual(scan.meetings[2].lines, [], "a recording is transcribed by LokalBot rather than from saved captions")
        XCTAssertEqual(scan.meetings[2].audioURL?.lastPathComponent, "audio_only.m4a")
    }

    func testLooseTranscriptsRenamedAndUntitledFolders() throws {
        let root = try temporaryDirectory("zoom-loose")
        try writeMedia(file(root, "2026-03-06 09.00.00", "audio_only.m4a"))
        let renamed = file(root, "Kickoff with Acme")
        try writeMedia(file(renamed, "audio_only.m4a"))
        try writeMedia(file(renamed, "zoom_0.mp4"))
        try write(Self.chat, to: file(renamed, "chat.txt"))
        try write(Self.namedTranscript, to: file(root, "Weekly_sync.transcript.vtt"))

        let scan = try ZoomMeetingReader.read(root)

        XCTAssertEqual(scan.meetings.map(\.title), ["Zoom meeting", "Kickoff with Acme", "Weekly sync"])
        XCTAssertEqual(scan.meetings[0].startedAt, localDate(2026, 3, 6, 9, 0))
        XCTAssertNil(scan.meetings[1].startedAt)
        XCTAssertEqual(scan.meetings[1].audioURL?.lastPathComponent, "audio_only.m4a")
        let loose = scan.meetings[2]
        XCTAssertNil(loose.startedAt)
        XCTAssertNil(loose.audioURL)
        XCTAssertEqual(loose.lines.count, 4)
        XCTAssertEqual(try ZoomMeetingReader.read(file(root, "Weekly_sync.transcript.vtt")).meetings.first?.sourceID,
                       loose.sourceID)

        let unrelated = file(root, "Notes")
        try write("Agenda", to: file(unrelated, "agenda.txt"))
        try writeMedia(file(unrelated, "holiday.m4a"))
        XCTAssertThrowsError(try ZoomMeetingReader.read(unrelated)) { error in
            XCTAssertEqual(error as? ExternalImportError, .unrecognized(.zoom, "Notes"))
        }
    }

    func testZippedRecordingFolderReadsLikeTheFolder() throws {
        let staging = try temporaryDirectory("zoom-zip")
        let folder = file(staging, "2026-03-04 10.15.00 Pricing review")
        try writeMedia(file(folder, "audio_only.m4a"))
        try write(Self.namedTranscript, to: file(folder, "closed_caption.vtt"))
        let zip = file(staging, "recording.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let result = ExternalMeetingReaders.scan(.zoom, urls: [zip])
        XCTAssertEqual(result.scan.problems, [])
        XCTAssertEqual(result.scan.meetings.count, 1)
        let meeting = try XCTUnwrap(result.scan.meetings.first)
        XCTAssertEqual(meeting.title, "Pricing review")
        XCTAssertEqual(meeting.sourceID, try ZoomMeetingReader.read(folder).meetings.first?.sourceID)
        let audio = try XCTUnwrap(meeting.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        result.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
}
