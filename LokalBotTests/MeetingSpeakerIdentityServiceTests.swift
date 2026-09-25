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
        settings.rememberSpeakersOnMac = true
        key = SymmetricKey(size: .bits256)
        service = MeetingSpeakerIdentityService(storage: storage, settings: { [unowned self] in settings }, keyProvider: { [unowned self] in key })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// One remote voice with remote voice samples.
    private func fixture() throws -> (Meeting, URL, Transcript, [SpeakerAudioTurn], [SpeakerVoiceSample]) {
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
        let samples = turns.map { SpeakerVoiceSample(speaker: "them", range: $0.range, vector: vector, source: .system) }
        return (meeting, audioURL, transcript, turns, samples)
    }

    func testRemoteVoiceIsNeverRememberedAndCorrectionSurvivesReprocessing() async throws {
        let (meeting, audio, transcript, turns, samples) = try fixture()
        let processed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(processed.speakerAliases.isEmpty)
        XCTAssertEqual(processed.segments, transcript.segments)
        let state = try await service.state(for: meeting)
        XCTAssertTrue(state.voiceSamples.isEmpty, "Remote voice samples are never retained")
        let corrected = try await service.choose(.init(label: "them", name: "Sam", remember: true,
            expectedRevision: state.revision), meeting: meeting, transcript: processed)
        XCTAssertEqual(corrected.speakerAliases["them"], "Sam")
        XCTAssertEqual(service.notice, "Meeting name saved. Only voices recorded by this Mac's microphone can be remembered.")
        let profiles = try await service.profiles(managing: true)
        XCTAssertTrue(profiles.isEmpty)
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(again.speakerAliases["them"], "Sam")
        XCTAssertEqual(service.applyingLatestDecision(to: processed, meetingID: meeting.id).speakerAliases["them"], "Sam")
    }

    func testCalendarEmailSuggestionRequiresConfirmationAndSurvivesReprocessing() async throws {
        let (recording, audio, transcript, turns, samples) = try fixture()
        var meeting = recording
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "calendar-ana", name: nil, emailAddress: "ana@example.com"))
        meeting.calendarParticipantIdentities = [guest]
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

    func testExistingRemoteProfileIsKeptButNeverSuggested() async throws {
        let (first, _, _, _, samples) = try fixture()
        let assignment = SpeakerIdentityAssignment(label: "them", name: "Alex", origin: .userConfirmed,
            audioRevision: "audio", anchors: [.init(start: 0, end: 80)], source: .system)
        let decision = SpeakerAliasDecision(speakerID: assignment.id, action: .assign, sourceRevision: "audio", name: "Alex")
        var saved = MeetingSpeakerIdentityState(meetingID: first.id)
        saved.assignments = [assignment]; saved.decisions = [decision]
        let store = try service.store()
        _ = try await store.commit(saved, meeting: first, expectedRevision: 0)
        _ = try await store.enroll(meeting: first, assignment: assignment, decision: decision,
            samples: Array(samples.prefix(3)), profileID: nil, expectedDatabaseRevision: 0)

        let (second, audio, transcript, turns, secondSamples) = try fixture()
        let result = await service.process(transcript: transcript, meeting: second, turns: turns, samples: secondSamples, audioURL: audio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let state = try await service.state(for: second)
        XCTAssertTrue(state.suggestions["them", default: []].isEmpty)
        let profiles = try await service.profiles(managing: true)
        XCTAssertEqual(profiles.map(\.name), ["Alex"])
    }

    func testResetSuppressesSuggestionsUntilExplicitResume() async throws {
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try microphoneFixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser, remember: true), meeting: first, transcript: initial)

        let (meeting, audio, transcript, turns, samples) = try microphoneFixture()
        let proposed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let suggested = try await service.state(for: meeting)
        XCTAssertEqual(suggested.suggestions["local 1"]?.first?.name, "Stevan")
        let reset = try await service.choose(.init(label: "local 1", action: .reset), meeting: meeting, transcript: proposed)
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let suppressed = try await service.state(for: meeting)
        XCTAssertTrue(suppressed.suggestions["local 1", default: []].isEmpty)
        XCTAssertNil(reset.speakerAliases["local 1"])
        _ = try await service.choose(.init(label: "local 1", action: .resume), meeting: meeting, transcript: again)
        let resumed = try await service.state(for: meeting)
        XCTAssertEqual(resumed.suggestions["local 1"]?.first?.name, "Stevan")
    }

    func testDisablingRememberingStopsMatchingInNewMeetings() async throws {
        let (first, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser, remember: true), meeting: first, transcript: initial)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try microphoneFixture()
        settings.rememberSpeakersOnMac = false
        _ = await service.process(transcript: secondTranscript, meeting: second, turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        let state = try await service.state(for: second)
        XCTAssertTrue(state.suggestions["local 1", default: []].isEmpty)
        XCTAssertTrue(state.voiceSamples.isEmpty)
        let preserved = try await service.profiles(managing: true)
        XCTAssertEqual(preserved.count, 1)
    }

    func testPrivateEvidenceAndUnappliedCandidatesNeverEnterTranscriptEncoding() async throws {
        let (first, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser, remember: true), meeting: first, transcript: initial)
        let (second, secondAudio, secondTranscript, secondTurns, secondSamples) = try microphoneFixture()
        let result = await service.process(transcript: secondTranscript, meeting: second, turns: secondTurns, samples: secondSamples, audioURL: secondAudio)
        let state = try await service.state(for: second)
        XCTAssertEqual(state.suggestions["local 1"]?.first?.name, "Stevan")
        let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for forbidden in ["Stevan", "embedding", "participantReference", "profileID", "evidence", "suggestions"] {
            XCTAssertFalse(serialized.contains(forbidden), forbidden)
        }
        XCTAssertFalse(result.summaryPromptMarkdown.contains("Stevan"))
    }

    func testStaleTranscriptShapeCannotReceiveCachedOrdinalAliasesOrAUserCommand() async throws {
        let (meeting, audio, transcript, turns, samples) = try fixture()
        let processed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: meeting, transcript: processed)
        var changed = transcript
        changed.segments[0].speaker = "them 2"
        XCTAssertTrue(service.applyingLatestDecision(to: changed, meetingID: meeting.id).speakerAliases.isEmpty)
        do {
            _ = try await service.choose(.init(label: "them", name: "Sam"), meeting: meeting, transcript: changed)
            XCTFail("Accepted a name from a stale transcript")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testRetriedConfirmationIsIdempotentAndCannotCreateTwoProfiles() async throws {
        let (meeting, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        let before = try await service.state(for: meeting)
        let choice = MeetingSpeakerIdentityService.Choice(label: "local 1", name: "Stevan", action: .confirmUser,
            remember: true, expectedRevision: before.revision)
        _ = try await service.choose(choice, meeting: meeting, transcript: initial)
        let confirmed = try await service.state(for: meeting)
        _ = try await service.choose(choice, meeting: meeting, transcript: initial)
        let retried = try await service.state(for: meeting)
        let profiles = try await service.profiles()
        XCTAssertEqual(confirmed.revision, retried.revision)
        XCTAssertEqual(retried.decisions.count, 1)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.contributions.count, 1)
    }

    func testUserCanCorrectOneLabelAfterACleanSplitWithoutChangingTheOtherVoice() async throws {
        let (meeting, audio, transcript, turns, _) = try fixture()
        let processed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: [], audioURL: audio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: meeting, transcript: processed)
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
        XCTAssertEqual(initial.confirmedUserSpeakerIDs, ["local 1", "local 2"])
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
        settings.rememberSpeakersOnMac = false
        let (meeting, audio, original, _, _) = try microphoneFixture()
        var transcript = original
        for index in transcript.segments.indices { transcript.segments[index].attribution?.method = .track }
        let initial = await service.process(transcript: transcript, meeting: meeting, turns: [], samples: [], audioURL: audio)
        XCTAssertEqual(initial.echoReport?.status, .disabled)
        XCTAssertEqual(initial.confirmedUserSpeakerIDs, ["local 1"])
        XCTAssertEqual(initial.displaySpeaker(for: "local 1"), "Me")
        let corrected = try await service.choose(.init(label: "local 1", name: "Alex", action: .confirmOther),
                                                meeting: meeting, transcript: initial)
        XCTAssertTrue(corrected.confirmedUserSpeakerIDs.isEmpty)
        let reprocessed = await service.process(transcript: transcript, meeting: meeting, turns: [], samples: [], audioURL: audio)
        XCTAssertEqual(reprocessed.speakerRoster["local 1"]?.identity, .other)
        let reset = try await service.choose(.init(label: "local 1", action: .reset), meeting: meeting, transcript: reprocessed)
        XCTAssertEqual(reset.confirmedUserSpeakerIDs, ["local 1"])
        XCTAssertEqual(reset.displaySpeaker(for: "local 1"), "Me")
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
        XCTAssertEqual(proposed.confirmedUserSpeakerIDs, ["local 1"], "The microphone defaults to the user independently of a suggested profile name")
        XCTAssertEqual(proposed.displaySpeaker(for: "local 1"), "Me")
        let chosen = try await service.choose(.init(label: "local 1", name: "Stevan", profileID: profile.id), meeting: second, transcript: proposed)
        XCTAssertEqual(chosen.confirmedUserSpeakerIDs, ["local 1"])
        let remaining = try await service.profiles()
        XCTAssertEqual(remaining.first?.contributions.count, 1, "Choosing a name without Remember must not enroll again")
    }
}
