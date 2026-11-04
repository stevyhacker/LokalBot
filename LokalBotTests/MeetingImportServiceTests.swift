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

    /// An ADTS AAC stream, the way the phone apps write recordings: the file
    /// type follows the `.aac` extension.
    private func writeADTS(to url: URL, seconds: Double, silentAfter: Double? = nil) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        var noise = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) {
            if let silentAfter {
                // Noise costs the encoder far more bytes than silence does.
                samples[index] = Double(index) / 44_100 < silentAfter ? Float.random(in: -0.4...0.4, using: &noise) : 0
            } else {
                samples[index] = 0.2 * sinf(Float(index) * 2 * .pi * 220 / 44_100)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        try file.write(from: buffer)
    }

    private func deviceOrigin(id: UUID = UUID(), startedAt: Date?) -> MeetingImportService.DeviceOrigin {
        .init(id: id, title: "Site visit", startedAt: startedAt, deviceName: "Stevan's iPad")
    }

    func testDeviceRecordingBecomesAMicrophoneMeetingWithTheDevicesIdAndTime() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("DeviceLibrary"))
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 2)
        let bytes = try Data(contentsOf: source)
        XCTAssertEqual(bytes[0], 0xFF, "ADTS frames start with a sync word")
        XCTAssertEqual(bytes[1] & 0xF0, 0xF0, "ADTS frames start with a sync word")
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_780_000_000)

        let meeting = try await MeetingImportService.importDeviceRecording(
            from: source, origin: deviceOrigin(id: id, startedAt: started), storage: storage,
            now: started.addingTimeInterval(3_600))

        XCTAssertEqual(meeting.id, id)
        XCTAssertEqual(meeting.title, "Site visit")
        XCTAssertEqual(meeting.appName, "Stevan's iPad")
        XCTAssertEqual(meeting.startedAt, started)
        XCTAssertTrue(meeting.isImported, "the person wasn't at this Mac, so no screen context")
        XCTAssertFalse(meeting.hasSystemTrack)
        XCTAssertEqual(try XCTUnwrap(meeting.recordedDuration), 2, accuracy: 0.2)
        let folder = meeting.folderURL(in: storage)
        XCTAssertNotNil(MeetingAudioFiles.transcribableURL(for: .mic, in: folder))
        XCTAssertNil(MeetingAudioFiles.transcribableURL(for: .system, in: folder))
        XCTAssertEqual(try Data(contentsOf: source), bytes, "the host owns the file; it is only read")
        let saved = try XCTUnwrap(storage.loadMeetings().first { $0.id == id })
        XCTAssertEqual(saved.title, "Site visit")
    }

    func testRecordingCutOffByACrashStillImports() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("DeviceLibrary"))
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 4)
        // A killed recorder stops mid-frame.
        let whole = try Data(contentsOf: source)
        try whole.prefix(whole.count / 2 + 7).write(to: source)

        let meeting = try await MeetingImportService.importDeviceRecording(
            from: source, origin: deviceOrigin(startedAt: nil), storage: storage)

        XCTAssertEqual(try XCTUnwrap(meeting.recordedDuration), 2, accuracy: 0.5)
    }

    func testARecordingThatStartsLoudAndGoesQuietImportsWhole() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("DeviceLibrary"))
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 120, silentAfter: 5)

        let meeting = try await MeetingImportService.importDeviceRecording(
            from: source, origin: deviceOrigin(startedAt: nil), storage: storage)

        // The phone deletes its copy after this, so all of it has to be here.
        XCTAssertEqual(try XCTUnwrap(meeting.recordedDuration), 120, accuracy: 0.5)
    }

    func testADTSLengthComesFromCountingFrames() throws {
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 30, silentAfter: 2)
        XCTAssertEqual(try XCTUnwrap(MeetingImportService.adtsDuration(of: source)), 30, accuracy: 0.1)

        let whole = try Data(contentsOf: source)
        try whole.prefix(whole.count / 2 + 3).write(to: source)
        XCTAssertLessThan(try XCTUnwrap(MeetingImportService.adtsDuration(of: source)), 30)

        try Data("not a stream at all".utf8).write(to: source)
        XCTAssertNil(MeetingImportService.adtsDuration(of: source))
    }

    func testALongTitleInAnyAlphabetStillMakesAFolder() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("DeviceLibrary"))
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 2)
        let title = String(repeating: "会議の記録", count: 40)
        let meeting = try await MeetingImportService.importDeviceRecording(
            from: source, origin: .init(id: UUID(), title: title, startedAt: nil, deviceName: "iPad"), storage: storage)
        XCTAssertEqual(meeting.title, title)
        XCTAssertLessThanOrEqual(meeting.folderURL(in: storage).lastPathComponent.utf8.count, 255)
    }

    func testDeviceRecordingWithAClockAheadStillEndsInThePast() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("DeviceLibrary"))
        let source = try temporaryDirectory("DeviceSource").appendingPathComponent("upload.aac")
        try writeADTS(to: source, seconds: 2)
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let meeting = try await MeetingImportService.importDeviceRecording(
            from: source, origin: deviceOrigin(startedAt: now.addingTimeInterval(600)), storage: storage, now: now)

        XCTAssertLessThanOrEqual(try XCTUnwrap(meeting.endedAt), now.addingTimeInterval(0.001))
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
