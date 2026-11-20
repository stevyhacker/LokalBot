import AVFoundation
import XCTest
@testable import LokalBot

final class ExternalMeetingWriterTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sample(_ source: ExternalMeetingSource = .otter, id: String = "conv-1",
                        lines: [ExternalMeeting.Line] = [], notes: String? = nil,
                        actions: [ExternalMeeting.ActionItem] = []) -> ExternalMeeting {
        ExternalMeeting(
            source: source, sourceID: id, title: "  Pricing   review ",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), duration: 1_800,
            participants: ["Ana", " ", "Leo"], lines: lines, notes: notes, actionItems: actions,
            origin: URL(fileURLWithPath: "/tmp/exports/pricing-review.txt"))
    }

    func testTextOnlyMeetingWritesTranscriptNotesAndImportSource() async throws {
        let root = try temporaryDirectory("external-writer")
        let storage = StorageManager(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let external = sample(lines: [
            .init(start: 0, end: 4, speaker: "Ana", text: "Let's keep the Team plan at fifteen."),
            .init(start: 4, end: 9, speaker: "Leo", text: "Billed annually, then."),
        ], notes: "## Summary\n\nPricing stays.")

        let result = try await ExternalMeetingWriter.write(external, storage: storage, now: now)

        XCTAssertFalse(result.needsTranscription)
        let meeting = result.meeting
        XCTAssertEqual(meeting.id, ExternalMeetingWriter.meetingID(for: external))
        XCTAssertEqual(meeting.title, "Pricing review")
        XCTAssertEqual(meeting.appName, "Otter")
        XCTAssertEqual(meeting.startedAt, external.startedAt)
        XCTAssertEqual(meeting.endedAt, external.startedAt?.addingTimeInterval(1_800))
        XCTAssertEqual(meeting.importSource, .init(app: "otter", id: "conv-1", importedAt: now))
        XCTAssertEqual(meeting.importedFileNames, ["pricing-review.txt"])
        XCTAssertTrue(meeting.isImported, "imported meetings take no screen context")
        XCTAssertEqual(meeting.participantNameHints, ["Ana", "Leo"])

        let folder = meeting.folderURL(in: storage)
        let saved = storage.loadMeetings().first { $0.id == meeting.id }
        XCTAssertEqual(saved?.importSource?.key, "otter/conv-1")
        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(transcript.speakerAliases, ["them 1": "Ana", "them 2": "Leo"])
        XCTAssertEqual(transcript.engine, "import-otter")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
        let summary = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertEqual(summary, "## Summary\n\nPricing stays.\n")
        let kept = try String(contentsOf: folder.appendingPathComponent(ExternalMeetingWriter.importedNotesFileName),
                              encoding: .utf8)
        XCTAssertEqual(kept, summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
    }

    func testNotesOnlyMeetingHasNoTranscriptAndNeedsNoTranscription() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("external-notes"))
        let result = try await ExternalMeetingWriter.write(
            sample(.granola, notes: "Decided to ship Thursday."), storage: storage,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let folder = result.meeting.folderURL(in: storage)
        XCTAssertFalse(result.needsTranscription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertNil(MissingTranscription.reason(for: result.meeting, folder: folder),
                     "a meeting without audio is never queued for transcription")
    }

    func testMicrophoneLinesAreMeAndUnnamedLinesAreThem() throws {
        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: sample(lines: [
            .init(start: 0, end: 2, speaker: "Stevan", text: "Morning.", isMe: true),
            .init(start: 2, end: 4, speaker: "ana", text: "Hi."),
            .init(start: 4, end: 6, speaker: "Ana", text: "Same person, other case."),
            .init(start: 6, end: 8, text: "Nobody named."),
            .init(start: 8, end: 9, speaker: "Ana", text: "   "),
        ])))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["me", "them 1", "them 1", "them"])
        XCTAssertEqual(transcript.speakerAliases, ["them 1": "ana"])
        XCTAssertEqual(transcript.segments.map(\.timingPrecision), [.span, .span, .span, .span])
    }

    func testUntimedLinesAreLaidOutAtSpeakingPaceAndMarkedCoarse() throws {
        let transcript = try XCTUnwrap(ExternalMeetingWriter.transcript(for: sample(lines: [
            .init(speaker: "Ana", text: "one two three four five six seven eight nine ten"),
            .init(speaker: "Leo", text: "Yes."),
            .init(start: 30, speaker: "Ana", text: "Back on the clock."),
        ])))
        let segments = transcript.segments
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].start, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, 30, accuracy: 0.001, "an untimed line ends where the next timed one starts")
        XCTAssertEqual(segments[2].start, 30)
        XCTAssertEqual(segments.map(\.timingPrecision), [.coarse, .coarse, .span])
        XCTAssertTrue(segments.allSatisfy { $0.end >= $0.start })
    }

    func testActionItemsFollowTheNotesUnlessAlreadyListed() {
        let notes = ExternalMeetingWriter.notesMarkdown(for: sample(
            notes: "Leo will send the deck.",
            actions: [.init(text: "Leo will send the deck."), .init(text: "Book the venue", owner: "Ana"),
                      .init(text: "  ")]))
        XCTAssertEqual(notes, "Leo will send the deck.\n\n## Action items\n\n- [ ] Book the venue (Ana)\n")
        XCTAssertNil(ExternalMeetingWriter.notesMarkdown(for: sample()))
        XCTAssertEqual(ExternalMeetingWriter.notesMarkdown(for: sample(actions: [.init(text: "Ship it")])),
                       "## Action items\n\n- [ ] Ship it\n")
    }

    func testIDsAreStablePerSourceMeetingAndDistinctAcrossSources() {
        let first = ExternalMeetingWriter.meetingID(for: sample(.otter, id: "a"))
        XCTAssertEqual(first, ExternalMeetingWriter.meetingID(for: sample(.otter, id: "a")))
        XCTAssertNotEqual(first, ExternalMeetingWriter.meetingID(for: sample(.otter, id: "b")))
        XCTAssertNotEqual(first, ExternalMeetingWriter.meetingID(for: sample(.fireflies, id: "a")))
    }

    func testPlanSkipsMeetingsAlreadyImportedByKeyOrID() {
        let kept = sample(.otter, id: "kept", notes: "n")
        let byKey = sample(.otter, id: "by-key", notes: "n")
        let byID = sample(.otter, id: "by-id", notes: "n")
        var recording = sample(.zoom, id: "audio")
        recording.audioURL = URL(fileURLWithPath: "/tmp/audio.m4a")
        let plan = ExternalImportPlan(
            source: .otter, paths: ["/tmp/exports"],
            scan: ExternalImportScan(meetings: [kept, byKey, byID, recording]),
            importedKeys: [byKey.importKey], libraryIDs: [ExternalMeetingWriter.meetingID(for: byID)])
        XCTAssertEqual(plan.found, 4)
        XCTAssertEqual(plan.newMeetings, 2)
        XCTAssertEqual(plan.alreadyImported, 2)
        XCTAssertEqual(plan.toTranscribe, 1)
        XCTAssertEqual(plan.json["newMeetings"]?.intValue, 2)
        XCTAssertNil(plan.json["meetings"], "the plan carries counts, never contents")
    }

    func testVoiceMemosRecordingsGoOnTheMicrophoneTrack() async throws {
        let folder = try temporaryDirectory("external-voice-memo")
        let audio = folder.appendingPathComponent("Standup.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * 4)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { samples[index] = 0.2 * sinf(Float(index) * 2 * .pi * 220 / 16_000) }
        try {
            let file = try AVAudioFile(forWriting: audio, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            try file.write(from: buffer)
        }()

        var memo = sample(.voiceMemos, id: "memo-1")
        memo.audioURL = audio
        let storage = StorageManager(rootURL: try temporaryDirectory("external-voice-library"))
        let result = try await ExternalMeetingWriter.write(memo, storage: storage,
                                                           now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(result.needsTranscription)
        XCTAssertFalse(result.meeting.hasSystemTrack)
        let meetingFolder = result.meeting.folderURL(in: storage)
        XCTAssertNotNil(MeetingAudioFiles.readableURL(for: .mic, in: meetingFolder))
        XCTAssertNil(MeetingAudioFiles.readableURL(for: .system, in: meetingFolder))
        XCTAssertEqual(result.meeting.importSource?.key, "voice-memos/memo-1")
        XCTAssertEqual(ExternalMeetingWriter.recordingTrack(for: .zoom), .system)
    }

    func testSummaryMessageExplainsAnEmptyImport() {
        var summary = ExternalImportSummary(source: .otter)
        summary.alreadyImported = 3
        XCTAssertEqual(summary.message, "Everything in this Otter export is already in your library.")
        summary.imported = [UUID()]
        XCTAssertNil(summary.message)
    }
}
