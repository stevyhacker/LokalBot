import CryptoKit
import XCTest
@testable import LokalBot

@MainActor final class MeetingSpeakerIdentityServiceTests: XCTestCase {
    private var root: URL!
    private var storage: StorageManager!
    private var service: MeetingSpeakerIdentityService!
    private var settings: AppSettings!
    private var key: SymmetricKey!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-service-\(UUID())")
        storage = StorageManager(rootURL: root)
        settings = AppSettings()
        settings.identifySpeakersFromVisuals = true
        settings.rememberSpeakersOnMac = true
        key = SymmetricKey(size: .bits256)
        service = MeetingSpeakerIdentityService(storage: storage, settings: { [unowned self] in settings }, keyProvider: { [unowned self] in key })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(visual: Bool, participants: [MeetingParticipantName] = []) async throws -> (Meeting, URL, Transcript, [SpeakerAudioTurn], [SpeakerVoiceSample]) {
        let meeting = try storage.createMeetingFolder(title: "Staged rule fixture", appName: "Google Chrome")
        let audioURL = meeting.folderURL(in: storage).appendingPathComponent("fixture-audio.bin")
        // Digest fixture only. No synthetic vector/byte fixture is presented as
        // an audio-recognition accuracy test or a real provider capture.
        try Data("same audio content for digest and identity rules".utf8).write(to: audioURL)
        let turns: [SpeakerAudioTurn] = (0..<4).map { index in
            .init(speaker: "them", range: .init(start: Double(index * 20), end: Double(index * 20 + 10)))
        }
        let transcript = Transcript(segments: turns.map {
            .init(start: $0.range.start, end: $0.range.end, speaker: "them", text: "Synthetic speech turn.", confidence: nil)
        }, engine: "test")
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = turns.map { SpeakerVoiceSample(speaker: "them", range: $0.range, vector: vector) }
        let store = try service.store()
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        try await store.verifyProvider(meeting: meeting, generation: generation)
        try await store.recordParticipants(participants, meeting: meeting, generation: generation)
        if visual {
            try await store.append(turns.map { .init(participantReference: "alex", displayName: "Alex",
                range: $0.range, uncertainty: 0.1, layoutEpoch: "grid") }, meeting: meeting, generation: generation)
        }
        try await store.seal(meeting: meeting, generation: generation, failed: false)
        return (meeting, audioURL, transcript, turns, samples)
    }

    func testAutomaticNamingDoesNotTrainProfilesAndCorrectionSurvivesReprocessing() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(automatic.speakerAliases["them"], "Alex")
        XCTAssertEqual(automatic.segments, transcript.segments)
        let profiles = try await service.profiles()
        XCTAssertTrue(profiles.isEmpty)
        let state = try await service.state(for: meeting)
        let corrected = try await service.choose(.init(label: "them", name: "Sam", remember: false,
            expectedRevision: state.revision), meeting: meeting, transcript: automatic)
        XCTAssertEqual(corrected.speakerAliases["them"], "Sam")
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(again.speakerAliases["them"], "Sam")
        XCTAssertEqual(service.applyingLatestDecision(to: automatic, meetingID: meeting.id).speakerAliases["them"], "Sam")
    }

    func testCalendarEmailSuggestionRequiresConfirmationAndSurvivesReprocessingWithoutVisualEvidence() async throws {
        let (recording, audio, transcript, turns, samples) = try await fixture(visual: false)
        var meeting = recording
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "calendar-ana", name: nil, emailAddress: "ana@example.com"))
        meeting.calendarParticipantIdentities = [guest]
        settings.identifySpeakersFromVisuals = false
        settings.rememberSpeakersOnMac = false
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(automatic.speakerAliases.isEmpty)

        let chosen = try await service.choose(.init(label: "them", name: guest.suggestedSpeakerName,
            calendarIdentityID: guest.id, remember: false), meeting: meeting, transcript: automatic)
        XCTAssertEqual(chosen.speakerAliases["them"], "Ana")
        XCTAssertEqual(chosen.speakerCalendarIdentityIDs["them"], guest.id)
        XCTAssertFalse(chosen.markdown.contains("ana@example.com"))

        let reprocessed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(reprocessed.speakerAliases["them"], "Ana")
        XCTAssertEqual(reprocessed.speakerCalendarIdentityIDs["them"], guest.id)
        let profiles = try await service.profiles(managing: true)
        XCTAssertTrue(profiles.isEmpty)
    }

    func testOCRParticipantIsOnlyANameChoiceUntilTheUserSavesIt() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: false,
            participants: [.init(name: "Jonathan", source: .ocr)])
        let result = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("Jonathan"))
        let names = try await service.participants(for: meeting)
        XCTAssertEqual(names.map(\.name), ["Jonathan"])
        let chosen = try await service.choose(.init(label: "them", name: names[0].name, remember: false),
            meeting: meeting, transcript: result)
        XCTAssertEqual(chosen.speakerAliases["them"], "Jonathan")
        let profiles = try await service.profiles(managing: true)
        XCTAssertTrue(profiles.isEmpty)
        try await service.deleteEvidence(meeting: meeting)
        let remaining = try await service.participants(for: meeting)
        XCTAssertTrue(remaining.isEmpty)
        let state = try await service.state(for: meeting)
        XCTAssertEqual(state.assignments.first?.name, "Jonathan")
    }

    func testResetSuppressesReapplicationUntilExplicitResume() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let reset = try await service.choose(.init(label: "them", action: .reset), meeting: meeting, transcript: automatic)
        XCTAssertNil(reset.speakerAliases["them"])
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertNil(again.speakerAliases["them"])
        let resumed = try await service.choose(.init(label: "them", action: .resume), meeting: meeting, transcript: again)
        XCTAssertEqual(resumed.speakerAliases["them"], "Alex")
    }

    func testConfirmedProfileCanNameLaterMeetingWithoutVisualEvidence() async throws {
        let (first, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex", remember: true), meeting: first, transcript: automatic)
        let before = try await service.profiles()
        XCTAssertEqual(before.count, 1)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try await fixture(visual: false)
        settings.identifySpeakersFromVisuals = false
        let recognized = await service.process(transcript: secondTranscript, meeting: second,
            turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        XCTAssertEqual(recognized.speakerAliases["them"], "Alex")
        let result = try await service.state(for: second)
        XCTAssertEqual(result.assignments.first?.origin, .profileAutomatic)
        let after = try await service.profiles()
        XCTAssertEqual(after.first?.contributions.count, 1, "An automatic recognition must not reinforce its own profile")
        try await service.prepareDeletion(meeting: first)
        let revoked = try await service.profiles()
        XCTAssertTrue(revoked.isEmpty)
    }

    func testDisablingRememberingStopsMatchingInNewMeetings() async throws {
        let (first, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex", remember: true), meeting: first, transcript: automatic)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try await fixture(visual: false)
        settings.rememberSpeakersOnMac = false
        let result = await service.process(transcript: secondTranscript, meeting: second, turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let preserved = try await service.profiles(managing: true)
        XCTAssertEqual(preserved.count, 1)
    }

    func testPrivateEvidenceAndUnappliedCandidatesNeverEnterTranscriptEncoding() async throws {
        let (meeting, audio, transcript, turns, _) = try await fixture(visual: true)
        let result = await service.process(transcript: transcript, meeting: meeting, turns: Array(turns.prefix(1)), samples: [], audioURL: audio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for forbidden in ["Alex", "embedding", "participantReference", "profileID", "evidence", "suggestions"] {
            XCTAssertFalse(serialized.contains(forbidden))
        }
        XCTAssertFalse(result.summaryPromptMarkdown.contains("Alex"))
    }

    func testStaleTranscriptShapeCannotReceiveCachedOrdinalAliasesOrAUserCommand() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        _ = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        var changed = transcript
        changed.segments[0].speaker = "them 2"
        XCTAssertTrue(service.applyingLatestDecision(to: changed, meetingID: meeting.id).speakerAliases.isEmpty)
        do {
            _ = try await service.choose(.init(label: "them", name: "Sam"), meeting: meeting, transcript: changed)
            XCTFail("Accepted a name from a stale transcript")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testRetriedConfirmationIsIdempotentAndCannotCreateTwoProfiles() async throws {
        let (meeting, audio, transcript, turns, samples) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let before = try await service.state(for: meeting)
        let choice = MeetingSpeakerIdentityService.Choice(label: "them", name: "Alex", remember: true, expectedRevision: before.revision)
        _ = try await service.choose(choice, meeting: meeting, transcript: automatic)
        let confirmed = try await service.state(for: meeting)
        _ = try await service.choose(choice, meeting: meeting, transcript: automatic)
        let retried = try await service.state(for: meeting)
        let profiles = try await service.profiles()
        XCTAssertEqual(confirmed.revision, retried.revision)
        XCTAssertEqual(retried.decisions.count, 1)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.contributions.count, 1)
    }

    func testUserCanCorrectOneLabelAfterACleanSplitWithoutChangingTheOtherVoice() async throws {
        let (meeting, audio, transcript, turns, _) = try await fixture(visual: true)
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: [], audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: meeting, transcript: automatic)
        let splitTurns = turns.enumerated().map { index, turn in
            SpeakerAudioTurn(speaker: index < 2 ? "them 1" : "them 2", range: turn.range)
        }
        var splitTranscript = transcript
        for index in splitTranscript.segments.indices { splitTranscript.segments[index].speaker = splitTurns[index].speaker }
        let split = await service.process(transcript: splitTranscript, meeting: meeting, turns: splitTurns, samples: [], audioURL: audio)
        XCTAssertEqual(split.speakerAliases["them 1"], "Alex")
        XCTAssertEqual(split.speakerAliases["them 2"], "Alex")
        _ = try await service.choose(.init(label: "them 2", name: "Sam"), meeting: meeting, transcript: split)
        let retried = await service.process(transcript: splitTranscript, meeting: meeting, turns: splitTurns, samples: [], audioURL: audio)
        XCTAssertEqual(retried.speakerAliases["them 1"], "Alex")
        XCTAssertEqual(retried.speakerAliases["them 2"], "Sam")
    }

    func testMicrophoneDefaultAndExplicitOtherSurviveRestartAndLabelReorderingWithoutEnrollment() async throws {
        settings.identifySpeakersFromVisuals = false
        settings.rememberSpeakersOnMac = false
        let meeting = try storage.createMeetingFolder(title: "Two local voices", appName: "Manual")
        let audio = meeting.folderURL(in: storage).appendingPathComponent("mic.m4a")
        let writer = try WavWriter(url: audio, sampleRate: 16_000)
        try writer.append(Array(repeating: 0, count: 160_000))
        try writer.finish()
        let transcript = Transcript(segments: [
            .init(start: 1, end: 3, speaker: "local 1", text: "First local voice",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .diarization)),
            .init(start: 5, end: 7, speaker: "local 2", text: "Second local voice",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .diarization)),
        ], engine: "synthetic rule fixture")
        let turns = transcript.segments.map { SpeakerAudioTurn(speaker: $0.speaker,
            range: .init(start: $0.start, end: $0.end), source: .microphone) }
        var initial = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: [], audioURL: audio)
        XCTAssertTrue(initial.confirmedUserSpeakerIDs.isEmpty,
                      "A microphone track identifies an input, not a person")
        initial = try await service.choose(.init(label: "local 2", name: "Alex", action: .confirmOther),
                                           meeting: meeting, transcript: initial)
        let chosen = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser),
                                              meeting: meeting, transcript: initial)
        XCTAssertEqual(chosen.segments[0].resolvedAttribution.identity, .user)
        XCTAssertEqual(chosen.segments[1].resolvedAttribution.identity, .other)
        let restarted = MeetingSpeakerIdentityService(storage: storage, settings: { [unowned self] in settings },
            keyProvider: { [unowned self] in key })
        let recovered = try await restarted.recover(meeting: meeting, transcript: transcript)
        XCTAssertEqual(recovered.segments[0].resolvedAttribution.identity, .user)
        XCTAssertEqual(recovered.segments[1].resolvedAttribution.identity, .other)
        var reordered = transcript
        reordered.segments[0].speaker = "local 2"
        reordered.segments[1].speaker = "local 1"
        let nextTurns = reordered.segments.map { SpeakerAudioTurn(speaker: $0.speaker,
            range: .init(start: $0.start, end: $0.end), source: .microphone) }
        let reprocessed = await restarted.process(transcript: reordered, meeting: meeting, turns: nextTurns, samples: [], audioURL: audio)
        XCTAssertEqual(reprocessed.segments[0].resolvedAttribution.identity, .user)
        XCTAssertEqual(reprocessed.segments[1].resolvedAttribution.identity, .other)
        let profiles = try await restarted.profiles()
        XCTAssertTrue(profiles.isEmpty)
    }

    private func microphoneFixture() throws -> (Meeting, URL, Transcript, [SpeakerAudioTurn], [SpeakerVoiceSample]) {
        let meeting = try storage.createMeetingFolder(title: "Quiet reference rule fixture", appName: "Google Chrome")
        let folder = meeting.folderURL(in: storage)
        let audio = folder.appendingPathComponent("mic.m4a")
        for url in [audio, folder.appendingPathComponent("system.m4a")] {
            let writer = try WavWriter(url: url, sampleRate: 16_000)
            try writer.append([Float](repeating: 0, count: 40 * 16_000)); try writer.finish()
        }
        let clock = AudioClockSpan(hostStart: 100, hostEnd: 140, startFrame: 0, endFrame: 640_000, sampleRate: 16_000, generation: 1)
        try JSONEncoder().encode(RecordingAudioTiming(microphone: [clock], system: [clock]))
            .write(to: folder.appendingPathComponent(RecordingAudioTiming.fileName))
        let local: [Transcript.Segment] = (0..<3).map { index in
            let start = Double(index * 10 + 2)
            let end = start + 6
            let attribution = SpeakerAttribution(source: .microphone, identity: .unresolved, method: .diarization)
            return Transcript.Segment(start: start, end: end, speaker: "local 1", text: "Synthetic local turn", attribution: attribution)
        }
        let transcript = Transcript(segments: local + [
            .init(start: 35, end: 38, speaker: "them 1", text: "Synthetic remote turn",
                  attribution: .init(source: .system, identity: .other, method: .diarization))
        ], engine: "fixture", echoReport: .init(status: .disabled))
        let turns = transcript.segments.map { SpeakerAudioTurn(speaker: $0.speaker,
            range: .init(start: $0.start, end: $0.end), source: $0.resolvedAttribution.source) }
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = local.map { SpeakerVoiceSample(speaker: $0.speaker, range: .init(start: $0.start, end: $0.end), vector: vector, source: .microphone) }
        return (meeting, audio, transcript, turns, samples)
    }

    func testMicrophoneDefaultWithoutIdentificationOrDiarizationSupportsCorrectionAndReset() async throws {
        settings.identifySpeakersFromVisuals = false
        settings.rememberSpeakersOnMac = false
        let (meeting, audio, original, _, _) = try microphoneFixture()
        var transcript = original
        for index in transcript.segments.indices { transcript.segments[index].attribution?.method = .track }
        let initial = await service.process(transcript: transcript, meeting: meeting, turns: [], samples: [], audioURL: audio)
        XCTAssertEqual(initial.echoReport?.status, .disabled)
        XCTAssertTrue(initial.confirmedUserSpeakerIDs.isEmpty)
        XCTAssertEqual(initial.displaySpeaker(for: "local 1"), "Local 1")
        let corrected = try await service.choose(.init(label: "local 1", name: "Alex", action: .confirmOther),
                                                meeting: meeting, transcript: initial)
        XCTAssertTrue(corrected.confirmedUserSpeakerIDs.isEmpty)
        let reprocessed = await service.process(transcript: transcript, meeting: meeting, turns: [], samples: [], audioURL: audio)
        XCTAssertEqual(reprocessed.speakerRoster["local 1"]?.identity, .other)
        let reset = try await service.choose(.init(label: "local 1", action: .reset), meeting: meeting, transcript: reprocessed)
        XCTAssertTrue(reset.confirmedUserSpeakerIDs.isEmpty)
        XCTAssertEqual(reset.displaySpeaker(for: "local 1"), "Local 1")
        let profiles = try await service.profiles(managing: true)
        XCTAssertTrue(profiles.isEmpty)
    }

    func testEchoOffCanRememberAndSuggestAConfirmedLocalUserInTheNextMeeting() async throws {
        let (first, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        let state = try await service.state(for: first)
        XCTAssertEqual(state.voiceSamples.count, 3)
        XCTAssertEqual(state.microphoneSampleDiagnostics?["quietReference"], 3)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser, remember: true), meeting: first, transcript: initial)
        let profiles = try await service.profiles()
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.isLocalUser, true)

        let (second, nextAudio, nextTranscript, nextTurns, nextSamples) = try microphoneFixture()
        let proposed = await service.process(transcript: nextTranscript, meeting: second, turns: nextTurns, samples: nextSamples, audioURL: nextAudio)
        let suggested = try await service.state(for: second)
        XCTAssertEqual(suggested.suggestions["local 1"]?.first?.name, "Stevan")
        XCTAssertEqual(suggested.suggestions["local 1"]?.first?.tier, .suggested)
        XCTAssertTrue(proposed.confirmedUserSpeakerIDs.isEmpty,
                      "A suggested profile name does not confirm local ownership")
        XCTAssertEqual(proposed.displaySpeaker(for: "local 1"), "Local 1")
        let chosen = try await service.choose(.init(label: "local 1", name: "Stevan", profileID: profile.id), meeting: second, transcript: proposed)
        XCTAssertEqual(chosen.confirmedUserSpeakerIDs, ["local 1"])
        let remaining = try await service.profiles()
        XCTAssertEqual(remaining.first?.contributions.count, 1, "Choosing a name without Remember must not enroll again")
    }
}
