import AVFoundation
import XCTest
@testable import LokalBot

final class MeetingSelectionExtractServiceTests: XCTestCase {
    func testExtractSlicesAudioTranscriptNotesAndScreenContextWithoutMutatingSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(rootURL: root)
        let startedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let relative = try storage.reserveMeetingFolder(title: "Two Meetings", startedAt: startedAt)
        var source = Meeting(
            id: UUID(),
            title: "Two Meetings",
            appName: "Zoom",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(6),
            relativePath: relative,
            hasSystemTrack: true
        )
        source.recordedDuration = 6
        source.participantNameHints = ["Alex Rivera"]
        try storage.saveMeta(source)

        let sourceFolder = source.folderURL(in: storage)
        try writeTone(to: sourceFolder.appendingPathComponent("mic.m4a"), frequency: 440, duration: 6)
        try writeTone(to: sourceFolder.appendingPathComponent("system.m4a"), frequency: 660, duration: 6)

        let sourceTranscript = Transcript(
            segments: [
                .init(start: 0.2, end: 1.0, speaker: "me", text: "First meeting wrap up"),
                .init(start: 2.5, end: 4.5, speaker: "them 1", text: "Second meeting kickoff"),
                .init(start: 5.2, end: 5.8, speaker: "them 2", text: "Trailing chatter"),
            ],
            engine: "test",
            speakerAliases: ["me": "Me", "them 1": "Alex Rivera", "them 2": "Unused Speaker"],
            speakerCalendarIdentityIDs: ["them 1": "alex-id", "them 2": "unused-id"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sourceTranscript).write(
            to: sourceFolder.appendingPathComponent("transcript.json"), options: .atomic)
        try MeetingNotes.writeChecked("Action: follow up with Alex.", to: sourceFolder)

        let dbURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let store = ActivityStore(databaseURL: dbURL)
        try store.insertScreenshot(
            ts: startedAt.addingTimeInterval(0.5),
            path: "",
            app: "Keynote",
            windowTitle: "First Deck",
            ocr: "",
            meetingID: source.id.uuidString)
        try store.insertScreenshot(
            ts: startedAt.addingTimeInterval(3.0),
            path: "",
            app: "Xcode",
            windowTitle: "Second Meeting Doc",
            ocr: "",
            meetingID: source.id.uuidString)

        let extracted = try await MeetingSelectionExtractService.extract(
            from: source,
            range: .init(start: 2.0, end: 5.0),
            storage: storage)

        XCTAssertEqual(extracted.title, "Two Meetings (0:02–0:05)")
        XCTAssertEqual(extracted.displayTitle, "Two Meetings (0:02–0:05)")
        XCTAssertEqual(extracted.extractedFromMeetingID, source.id)
        XCTAssertEqual(extracted.startedAt.timeIntervalSince1970, startedAt.addingTimeInterval(2.0).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(extracted.recordedDuration), 3.0, accuracy: 0.2)
        XCTAssertTrue(extracted.hasSystemTrack)

        let destFolder = extracted.folderURL(in: storage)
        let micDuration = try XCTUnwrap(AudioFileInspector.duration(at: destFolder.appendingPathComponent("mic.m4a")))
        let systemDuration = try XCTUnwrap(AudioFileInspector.duration(at: destFolder.appendingPathComponent("system.m4a")))
        XCTAssertEqual(micDuration, 3.0, accuracy: 0.25)
        XCTAssertEqual(systemDuration, 3.0, accuracy: 0.25)

        let slicedData = try Data(contentsOf: destFolder.appendingPathComponent("transcript.json"))
        let slicedTranscript = try JSONDecoder().decode(Transcript.self, from: slicedData)
        XCTAssertEqual(slicedTranscript.segments.count, 1)
        XCTAssertEqual(slicedTranscript.segments[0].text, "Second meeting kickoff")
        XCTAssertEqual(slicedTranscript.segments[0].start, 0.5, accuracy: 0.01)
        XCTAssertEqual(slicedTranscript.segments[0].end, 2.5, accuracy: 0.01)
        XCTAssertEqual(slicedTranscript.speakerAliases, ["them 1": "Alex Rivera"])
        XCTAssertEqual(slicedTranscript.speakerCalendarIdentityIDs, ["them 1": "alex-id"])

        XCTAssertEqual(MeetingNotes.load(from: destFolder), "Action: follow up with Alex.")

        let shots = store.screenshots(
            forMeeting: extracted.id,
            additionalMeetingID: extracted.extractedFromMeetingID,
            from: extracted.startedAt.addingTimeInterval(-0.2),
            to: try XCTUnwrap(extracted.endedAt).addingTimeInterval(0.2))
        XCTAssertEqual(shots.map(\.windowTitle), ["Second Meeting Doc"])

        let reloadedSource = storage.loadMeetings().first(where: { $0.id == source.id })
        XCTAssertEqual(reloadedSource?.title, "Two Meetings")
        XCTAssertEqual(try XCTUnwrap(reloadedSource?.recordedDuration), 6.0, accuracy: 0.01)
    }

    private func writeTone(
        to url: URL,
        frequency: Double,
        duration: TimeInterval,
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1
    ) throws {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let samples = channelData[channel]
            for index in 0..<Int(frameCount) {
                samples[index] = Float(sin(2 * .pi * frequency * Double(index) / sampleRate) * 0.25)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
            ])
        try file.write(from: buffer)
    }
}
