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

    func testNamingACallVoiceRemembersItAndTheNameSurvivesReprocessing() async throws {
        let (meeting, audio, transcript, turns, samples) = try fixture()
        let processed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(processed.speakerAliases.isEmpty)
        XCTAssertEqual(processed.segments, transcript.segments)
        let state = try await service.state(for: meeting)
        XCTAssertEqual(state.voiceSamples.count, 4, "Call voice samples are kept for remembering")
        let corrected = try await service.choose(.init(label: "them", name: "Sam",
            expectedRevision: state.revision), meeting: meeting, transcript: processed)
        XCTAssertEqual(corrected.speakerAliases["them"], "Sam")
        XCTAssertNil(service.notice)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Sam"])
        XCTAssertNotNil(profiles.first?.contributions.first?.voiceprint)
        let again = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(again.speakerAliases["them"], "Sam")
        XCTAssertEqual(service.applyingLatestDecision(to: processed, meetingID: meeting.id).speakerAliases["them"], "Sam")
    }

    func testCalendarEmailSuggestionRequiresConfirmationAndSurvivesReprocessing() async throws {
        let (recording, audio, transcript, turns, samples) = try fixture()
        var meeting = recording
        let guest = try XCTUnwrap(CalendarParticipantIdentity(id: "calendar-ana", name: nil, emailAddress: "ana@example.com"))
        meeting.calendarParticipantIdentities = [guest]
        let automatic = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(automatic.speakerAliases.isEmpty)

        let chosen = try await service.choose(.init(label: "them", name: guest.suggestedSpeakerName,
            calendarIdentityID: guest.id), meeting: meeting, transcript: automatic)
        XCTAssertEqual(chosen.speakerAliases["them"], "Ana")
        XCTAssertEqual(chosen.speakerCalendarIdentityIDs["them"], guest.id)
        XCTAssertFalse(chosen.markdown.contains("ana@example.com"))

        let reprocessed = await service.process(transcript: transcript, meeting: meeting, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(reprocessed.speakerAliases["them"], "Ana")
        XCTAssertEqual(reprocessed.speakerCalendarIdentityIDs["them"], guest.id)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Ana"], "Confirming a calendar name remembers the voice")
    }

    func testRememberedCallVoiceNamesTheSpeakerInTheNextMeeting() async throws {
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
        XCTAssertEqual(result.speakerAliases["them"], "Alex")
        let state = try await service.state(for: second)
        XCTAssertEqual(state.assignments.first { $0.label == "them" }?.origin, .profileAutomatic)
        XCTAssertEqual(state.suggestions["them"]?.first?.tier, .automatic)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Alex"])
        XCTAssertEqual(profiles.first?.contributions.count, 1, "Automatic names never train profiles")
    }

    func testResetSuppressesSuggestionsUntilExplicitResume() async throws {
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try microphoneFixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser), meeting: first, transcript: initial)

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

    func testSampleMeetingVoicesAreNeverRememberedOrMatched() async throws {
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try fixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: first, transcript: initial)
        let (recorded, audio, transcript, turns, samples) = try fixture()
        var sample = recorded
        sample.sampleID = "synthetic-sample"
        let result = await service.process(transcript: transcript, meeting: sample, turns: turns, samples: samples, audioURL: audio)
        XCTAssertTrue(result.speakerAliases.isEmpty)
        let state = try await service.state(for: sample)
        XCTAssertTrue(state.voiceSamples.isEmpty)
        XCTAssertTrue(state.suggestions["them", default: []].isEmpty)
        _ = try await service.choose(.init(label: "them", name: "Sam"), meeting: sample, transcript: result)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Alex"])
    }

    func testPrivateEvidenceAndUnappliedCandidatesNeverEnterTranscriptEncoding() async throws {
        let (first, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser), meeting: first, transcript: initial)
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
            expectedRevision: before.revision)
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
        let profiles = try await service.profiles()
        XCTAssertTrue(profiles.isEmpty)
    }

    func testEchoOffCanRememberAndSuggestAConfirmedLocalUserInTheNextMeeting() async throws {
        let (first, audio, transcript, turns, samples) = try microphoneFixture()
        let initial = await service.process(transcript: transcript, meeting: first, turns: turns, samples: samples, audioURL: audio)
        let state = try await service.state(for: first)
        XCTAssertEqual(state.voiceSamples.count, 3)
        XCTAssertEqual(state.microphoneSampleDiagnostics?["quietReference"], 3)
        _ = try await service.choose(.init(label: "local 1", name: "Stevan", action: .confirmUser), meeting: first, transcript: initial)
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
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.contributions.count, 2, "Confirming the suggested person adds this meeting to their profile")
    }

    func testUndoingAnAutomaticNameKeepsItOffAfterReprocessing() async throws {
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try fixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: first, transcript: initial)
        let (second, audio, transcript, turns, samples) = try fixture()
        let automatic = await service.process(transcript: transcript, meeting: second, turns: turns, samples: samples, audioURL: audio)
        XCTAssertEqual(automatic.speakerAliases["them"], "Alex")
        let undone = try await service.choose(.init(label: "them", name: "Alex", action: .undo), meeting: second, transcript: automatic)
        XCTAssertNil(undone.speakerAliases["them"])
        let reprocessed = await service.process(transcript: transcript, meeting: second, turns: turns, samples: samples, audioURL: audio)
        XCTAssertNil(reprocessed.speakerAliases["them"])
    }

    func testCorrectingAnAutomaticNameRemembersTheCorrectPersonOnly() async throws {
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try fixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "them", name: "Alex"), meeting: first, transcript: initial)
        let (second, audio, transcript, turns, samples) = try fixture()
        let automatic = await service.process(transcript: transcript, meeting: second, turns: turns, samples: samples, audioURL: audio)
        let corrected = try await service.choose(.init(label: "them", name: "Sam"), meeting: second, transcript: automatic)
        XCTAssertEqual(corrected.speakerAliases["them"], "Sam")
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name).sorted(), ["Alex", "Sam"])
        XCTAssertEqual(profiles.first { $0.name == "Alex" }?.contributions.map(\.meetingID), [first.id])
    }

    func testNamingTheSamePersonAgainAddsToTheirProfileButADifferentVoiceGetsItsOwn() {
        func samples(axis: Int) -> [SpeakerVoiceSample] {
            var vector = [Float](repeating: 0, count: 256); vector[axis] = 1
            return (0..<4).map { SpeakerVoiceSample(speaker: "them", range: .init(start: Double($0 * 20), end: Double($0 * 20 + 10)),
                                                    vector: vector, source: .system) }
        }
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let alex = SpeakerVoiceProfile(name: "Alex", confirmedNames: ["Alex"], contributions: [
            .init(meetingID: UUID(), audioRevision: "a", speakerID: UUID(), decisionID: UUID(), confirmedAt: Date(),
                  samples: Array(samples(axis: 0).prefix(1)), voiceprint: vector)])
        XCTAssertEqual(MeetingSpeakerIdentityService.samePerson(named: "alex", samples: samples(axis: 0), profiles: [alex]), alex.id)
        XCTAssertNil(MeetingSpeakerIdentityService.samePerson(named: "Alex", samples: samples(axis: 1), profiles: [alex]))
        XCTAssertNil(MeetingSpeakerIdentityService.samePerson(named: "Sam", samples: samples(axis: 0), profiles: [alex]))
    }

    func testNamesGivenBeforeCallVoicesWereRememberedSuggestNamesInRecentMeetings() async throws {
        let store = try service.store()
        let (older, olderAudio, olderTranscript, olderTurns, olderSamples) = try callFixture()
        let processed = await service.process(transcript: olderTranscript, meeting: older, turns: olderTurns, samples: [], audioURL: olderAudio)
        let named = try await service.choose(.init(label: "them 1", name: "Hernan"), meeting: older, transcript: processed)
        let (recent, recentAudio, recentTranscript, recentTurns, recentSamples) = try callFixture()
        let unnamed = await service.process(transcript: recentTranscript, meeting: recent, turns: recentTurns, samples: [], audioURL: recentAudio)
        // Both were processed before call voices were kept.
        for meeting in [older, recent] {
            var saved = try await store.state(meeting: meeting)
            saved.callVoicesAnalyzed = nil
            _ = try await store.commit(saved, meeting: meeting, expectedRevision: saved.revision)
        }
        let before = try await service.profiles()
        XCTAssertTrue(before.isEmpty)

        let library = SavedLibrary(transcripts: [older.id: named, recent.id: unnamed],
                                   samples: [older.id: olderSamples, recent.id: recentSamples])
        await service.learnFromSavedMeetings([recent, older], recentSince: .distantPast, using: library.access)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Hernan"])
        // A saved transcript keeps its names, so its notes stay current; the
        // meeting offers the recognized name instead.
        let recentState = try await store.state(meeting: recent)
        XCTAssertNil(recentState.assignments.first { $0.label == "them 1" }?.name)
        let recognized = MeetingSpeakerIdentityService.recognizedSpeakers(in: recentState, transcript: unnamed)
        XCTAssertEqual(recognized.map(\.label), ["them 1"])
        XCTAssertEqual(recognized.first?.match.name, "Hernan")
        XCTAssertEqual(Set(library.analyzed), [older.id, recent.id])

        library.analyzed = []
        await service.learnFromSavedMeetings([recent, older], recentSince: .distantPast, using: library.access)
        XCTAssertTrue(library.analyzed.isEmpty, "Each saved meeting's call track is analyzed once")
    }

    func testRevisitingASavedMeetingKeepsTheNameTheUserGave() async throws {
        let store = try service.store()
        let (first, firstAudio, firstTranscript, firstTurns, firstSamples) = try callFixture()
        let initial = await service.process(transcript: firstTranscript, meeting: first, turns: firstTurns, samples: firstSamples, audioURL: firstAudio)
        _ = try await service.choose(.init(label: "them 1", name: "Hernan"), meeting: first, transcript: initial)
        let (second, audio, transcript, turns, samples) = try callFixture()
        let processed = await service.process(transcript: transcript, meeting: second, turns: turns, samples: [], audioURL: audio)
        let named = try await service.choose(.init(label: "them 1", name: "Nik"), meeting: second, transcript: processed)
        var saved = try await store.state(meeting: second)
        saved.callVoicesAnalyzed = nil
        _ = try await store.commit(saved, meeting: second, expectedRevision: saved.revision)

        let library = SavedLibrary(transcripts: [second.id: named], samples: [second.id: samples])
        await service.learnFromSavedMeetings([second], recentSince: .distantPast, using: library.access)
        let revisited = try await store.state(meeting: second)
        XCTAssertEqual(revisited.assignments.first { $0.label == "them 1" }?.name, "Nik",
                       "A voice that sounds like a remembered person never replaces a name the user gave")
        XCTAssertTrue(MeetingSpeakerIdentityService.recognizedSpeakers(in: revisited, transcript: named).isEmpty)
    }

    func testUnavailableVoiceModelLeavesSavedMeetingsForALaterPass() async throws {
        let store = try service.store()
        let (older, audio, transcript, turns, samples) = try callFixture()
        let processed = await service.process(transcript: transcript, meeting: older, turns: turns, samples: [], audioURL: audio)
        let named = try await service.choose(.init(label: "them 1", name: "Hernan"), meeting: older, transcript: processed)
        var saved = try await store.state(meeting: older)
        saved.callVoicesAnalyzed = nil
        _ = try await store.commit(saved, meeting: older, expectedRevision: saved.revision)

        let library = SavedLibrary(transcripts: [older.id: named], samples: [older.id: samples])
        library.unavailable = true
        await service.learnFromSavedMeetings([older], recentSince: .distantPast, using: library.access)
        let afterFailure = try await store.state(meeting: older)
        XCTAssertNil(afterFailure.callVoicesAnalyzed)
        library.unavailable = false
        await service.learnFromSavedMeetings([older], recentSince: .distantPast, using: library.access)
        let profiles = try await service.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Hernan"])
    }

    /// Saved transcripts and call-track analysis for `learnFromSavedMeetings`.
    @MainActor private final class SavedLibrary {
        struct Unavailable: Error {}
        let transcripts: [UUID: Transcript]
        let samples: [UUID: [SpeakerVoiceSample]]
        var analyzed: [UUID] = []
        var unavailable = false
        init(transcripts: [UUID: Transcript], samples: [UUID: [SpeakerVoiceSample]]) {
            self.transcripts = transcripts
            self.samples = samples
        }
        var access: MeetingSpeakerIdentityService.SavedMeetings {
            .init(transcript: { [unowned self] in transcripts[$0.id] },
                  callSamples: { [unowned self] meeting, _ in
                      if unavailable { throw Unavailable() }
                      analyzed.append(meeting.id)
                      return samples[meeting.id] ?? []
                  },
                  isBusy: { _ in false })
        }
    }

    /// One diarized call voice on a real (silent) system track.
    private func callFixture() throws -> (Meeting, URL, Transcript, [SpeakerAudioTurn], [SpeakerVoiceSample]) {
        let meeting = try storage.createMeetingFolder(title: "Call voice rule fixture", appName: "Google Chrome")
        let audio = meeting.folderURL(in: storage).appendingPathComponent("system.m4a")
        let writer = try WavWriter(url: audio, sampleRate: 16_000)
        try writer.append([Float](repeating: 0, count: 60 * 16_000)); try writer.finish()
        let segments: [Transcript.Segment] = (0..<4).map { index in
            let start = Double(index * 14 + 1)
            return .init(start: start, end: start + 10, speaker: "them 1", text: "Synthetic call turn",
                         attribution: .init(source: .system, identity: .other, method: .diarization))
        }
        let transcript = Transcript(segments: segments, engine: "fixture")
        let turns = segments.map { SpeakerAudioTurn(speaker: $0.speaker, range: .init(start: $0.start, end: $0.end), source: .system) }
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = turns.map { SpeakerVoiceSample(speaker: "them 1", range: $0.range, vector: vector, source: .system) }
        return (meeting, audio, transcript, turns, samples)
    }
}
