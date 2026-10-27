import AVFoundation
import XCTest
@testable import LokalBot

final class MeetingImportServiceTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A stereo 44.1 kHz WAV, shaped like a phone or desktop recorder export.
    private func writeWAV(to url: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<Int(frames) {
                channels[channel][index] = 0.2 * sinf(Float(index) * 2 * .pi * 220 / 44_100)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }

    func testImportedFileBecomesASystemTrackMeetingDatedFromTheFile() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("ImportLibrary"))
        let source = try temporaryDirectory("ImportSource").appendingPathComponent("Design review.wav")
        try writeWAV(to: source, seconds: 2)
        let original = try Data(contentsOf: source)
        // A copied recording: modification still marks when it stopped, while
        // creation is when it was copied.
        let stopped = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: stopped.addingTimeInterval(86_400), .modificationDate: stopped],
            ofItemAtPath: source.path)

        let meeting = try await MeetingImportService.importRecording(
            from: source, storage: storage, now: Date(timeIntervalSince1970: 1_790_000_000))

        XCTAssertEqual(meeting.title, "Design review")
        XCTAssertEqual(meeting.appName, MeetingImportService.appName)
        XCTAssertEqual(meeting.importedFileNames, ["Design review.wav"])
        XCTAssertTrue(meeting.isImported)
        XCTAssertTrue(meeting.hasSystemTrack)
        let duration = try XCTUnwrap(meeting.recordedDuration)
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        XCTAssertEqual(meeting.startedAt.timeIntervalSince1970,
                       stopped.timeIntervalSince1970 - duration, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(meeting.endedAt).timeIntervalSince1970,
                       stopped.timeIntervalSince1970, accuracy: 0.001)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: meeting.startedAt)
        XCTAssertTrue(meeting.relativePath.hasPrefix(String(
            format: "meetings/%d/%02d/%02d-design-review",
            try XCTUnwrap(day.year), try XCTUnwrap(day.month), try XCTUnwrap(day.day))))

        // The pipeline transcribes whatever tracks the folder holds: the file
        // must arrive as the diarized system track with no microphone track.
        let folder = meeting.folderURL(in: storage)
        XCTAssertEqual(MeetingAudioFiles.transcribableURL(for: .system, in: folder),
                       MeetingAudioFiles.primaryURL(for: .system, in: folder))
        XCTAssertNil(MeetingAudioFiles.transcribableURL(for: .mic, in: folder))
        XCTAssertEqual(try Data(contentsOf: source), original, "the original file is only read")

        let loaded = try XCTUnwrap(storage.loadMeetings().first { $0.id == meeting.id })
        XCTAssertEqual(loaded.importedFileNames, ["Design review.wav"])
        XCTAssertNotNil(loaded.endedAt, "an imported meeting must never load as a live recording")
        XCTAssertTrue(loaded.hasSystemTrack)
    }

    func testUnreadableFileLeavesNoMeetingBehind() async throws {
        let root = try temporaryDirectory("ImportLibrary")
        let storage = StorageManager(rootURL: root)
        let source = try temporaryDirectory("ImportSource").appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: source)

        do {
            _ = try await MeetingImportService.importRecording(from: source, storage: storage)
            XCTFail("a file without readable audio must not import")
        } catch is MeetingImportService.ImportError {
        }
        XCTAssertTrue(storage.loadMeetings().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("meetings").path), [])
    }

    func testOnlyAudioAndVideoFilesAreImportable() throws {
        let folder = try temporaryDirectory("ImportTypes")
        for name in ["call.mp3", "call.m4a", "call.wav", "call.mp4", "call.mov"] {
            XCTAssertTrue(MeetingImportService.isImportable(folder.appendingPathComponent(name)), name)
        }
        for name in ["notes.txt", "slides.pdf", "photo.png"] {
            XCTAssertFalse(MeetingImportService.isImportable(folder.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(MeetingImportService.isImportable(try XCTUnwrap(URL(string: "https://example.com/call.mp3"))))
    }

    func testRecordingStartPrefersTheRecorderAndNeverEndsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let recorded = Date(timeIntervalSince1970: 1_780_000_000)
        func start(_ metadata: Date?, created: Date?, modified: Date?) -> Date {
            MeetingImportService.recordingStart(
                metadataDate: metadata, fileCreated: created, fileModified: modified, duration: 60, now: now)
        }

        XCTAssertEqual(start(recorded, created: now, modified: now), recorded,
                       "a recorder's own creation date names the start")
        XCTAssertEqual(start(nil, created: recorded, modified: recorded.addingTimeInterval(65)), recorded,
                       "an original file was created when recording began")
        XCTAssertEqual(start(nil, created: now.addingTimeInterval(-100), modified: recorded),
                       recorded.addingTimeInterval(-60), "a copy keeps the time recording stopped")
        XCTAssertEqual(start(Date(timeIntervalSince1970: 0), created: nil, modified: nil),
                       now.addingTimeInterval(-60), "an unset container date is not a recording date")
        XCTAssertEqual(start(now, created: nil, modified: nil), now.addingTimeInterval(-60))
        XCTAssertEqual(start(nil, created: nil, modified: nil), now.addingTimeInterval(-60))
    }

    func testFileNameBecomesTheTitle() {
        XCTAssertEqual(MeetingImportService.title(for: URL(fileURLWithPath: "/tmp/Team sync.m4a")), "Team sync")
        XCTAssertEqual(MeetingImportService.title(for: URL(fileURLWithPath: "/tmp/ .mp3")), "Imported recording")
    }

    /// The screen during an imported file's time span shows what the user was
    /// doing then, not that recording, so it must not reach the notes prompt.
    func testImportedMeetingsTakeNoScreenTitles() throws {
        let root = try temporaryDirectory("ImportScreenContext")
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let store = ActivityStore(databaseURL: root.appendingPathComponent("lokalbotv3.sqlite"))
        try store.insertScreenshot(ts: start.addingTimeInterval(60), path: "", app: "Keynote",
                                   windowTitle: "Q3 pricing.key", ocr: "", documentName: "Q3 pricing.key")
        var meeting = Meeting(id: UUID(), title: "Pricing review", appName: "zoom.us",
                              startedAt: start, endedAt: start.addingTimeInterval(1_800),
                              relativePath: "meetings/pricing")
        meeting.recordedDuration = 1_800
        var config = AppSettings()
        config.meetingNotesUseScreenTitles = true

        let recorded = ProcessingPipeline.meetingContextBlock(for: meeting, root: root, config: config)
        XCTAssertTrue(recorded?.contains("Q3 pricing.key") == true, "the fixture must reach a recorded meeting")

        meeting.importedFileNames = ["Pricing review.m4a"]
        XCTAssertNil(ProcessingPipeline.meetingContextBlock(for: meeting, root: root, config: config))
    }
}
