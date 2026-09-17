import XCTest
@testable import LokalBot

final class AttributionSafetyTests: XCTestCase {
    private func transcript() -> Transcript {
        Transcript(segments: [
            .init(start: 0, end: 5, speaker: "local 1", text: "I will send the plan.",
                  attribution: .init(source: .microphone, identity: .user, method: .confirmation)),
            .init(start: 10, end: 15, speaker: "them 1", text: "I will send the report.",
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
            .init(start: 20, end: 25, speaker: "them 1", text: "Stevan, could you send the report?",
                  attribution: .init(source: .system, identity: .other, method: .diarization)),
            .init(start: 30, end: 35, speaker: "local 2", text: "I will send the invoice.",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .confirmation)),
        ], engine: "fixture", speakerAliases: ["local 1": "Stevan", "them 1": "Alice"])
    }

    private func action(transcript: Transcript, index: Int, ownerID: String, owner: String,
                        forUser: Bool, basis: String = "commitment", quote: String? = nil) throws -> MeetingOutcomes.ActionItem {
        let item: [String: Any] = ["text": "I will send the report.", "owner": owner, "for_user": forUser,
            "due": "", "importance": 4, "owner_speaker_id": ownerID, "ownership_basis": basis,
            "ownership_quote": quote ?? transcript.segments[index].text,
            "source_segment_ids": [transcript.segmentID(at: index)]]
        let data = try JSONSerialization.data(withJSONObject: ["action_items": [item], "decisions": [], "open_questions": []])
        let parsed = try XCTUnwrap(OutcomesExtractor.parseResult(String(decoding: data, as: UTF8.self),
            sourceSegments: transcript.segmentSourceMap, requireEvidence: true, speakerRoster: transcript.speakerRoster))
        return try XCTUnwrap(parsed.outcomes.actionItems.first)
    }

    func testRemoteFirstPersonKeepsItsOwnerThroughParserReloadIndexAndSummary() throws {
        let source = transcript()
        let parsed = try action(transcript: source, index: 1, ownerID: "them 1", owner: "Alice", forUser: false)
        let outcomes = MeetingOutcomes(actionItems: [parsed])
        let reloaded = try JSONDecoder().decode(MeetingOutcomes.self, from: JSONEncoder().encode(outcomes))
        XCTAssertEqual(reloaded, outcomes)
        XCTAssertEqual(reloaded.otherActionItems.first?.owner, "Alice")
        XCTAssertTrue(reloaded.userActionItems.isEmpty)
        let rendered = MeetingSummaryOutcomeSynchronizer.synchronize("## TL;DR\nAlice discussed the report.",
            outcomes: reloaded, template: .meeting)
        XCTAssertTrue(rendered.contains("### Me\nNone"))
        XCTAssertTrue(rendered.contains("Alice: I will send the report."))
    }

    func testRemoteExplicitRequestForConfirmedUserRemainsARequest() throws {
        let item = try action(transcript: transcript(), index: 2, ownerID: "local 1", owner: "Me", forUser: true, basis: "request")
        XCTAssertTrue(item.isForUser)
        XCTAssertEqual(item.attribution?.basis, .request)
        XCTAssertTrue(item.displayText.hasPrefix("Requested: "))
    }

    func testKnownUserCommitmentSurvivesEvidenceValidation() throws {
        let item = try action(transcript: transcript(), index: 0, ownerID: "local 1", owner: "Me", forUser: true)
        XCTAssertTrue(item.isForUser)
        XCTAssertEqual(item.attribution?.speakerID, "local 1")
    }

    func testExplicitlyUnresolvedLocalVoiceAndWrongSpeakerCannotBecomeUser() throws {
        for id in ["local 1", "local 2"] {
            let item = try action(transcript: transcript(), index: 3, ownerID: id, owner: "Me", forUser: true)
            XCTAssertTrue(item.ownershipIsUnclear)
            XCTAssertFalse(item.isForUser)
        }
    }

    func testConflictingOwnerFlagIsUnresolvedEvenWithValidCitation() throws {
        let item = try action(transcript: transcript(), index: 1, ownerID: "them 1", owner: "Alice", forUser: true)
        XCTAssertTrue(item.ownershipIsUnclear)
        XCTAssertNil(item.owner)
    }

    func testPersistedConflictingOwnershipMetadataFailsClosed() throws {
        var original = try action(transcript: transcript(), index: 0, ownerID: "local 1", owner: "Me", forUser: true)
        original.isForUser = false
        let reopened = try JSONDecoder().decode(MeetingOutcomes.ActionItem.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(reopened.isForUser)
        XCTAssertTrue(reopened.ownershipIsUnclear)
        XCTAssertNil(reopened.owner)
        let constructed = MeetingOutcomes.ActionItem(text: "I will send the plan", owner: "Me", isForUser: false,
            attribution: .init(resolution: .user, speakerID: "local 1", basis: .commitment))
        XCTAssertTrue(constructed.ownershipIsUnclear)
    }

    func testPronounRequestAndThirdPartyMentionCannotProveUserOwnership() throws {
        var source = transcript()
        source.segments[2].text = "Could you send the report?"
        XCTAssertTrue(try action(transcript: source, index: 2, ownerID: "local 1", owner: "Me", forUser: true, basis: "request").ownershipIsUnclear)
        source.segments[0].text = "Alice will send the report."
        XCTAssertTrue(try action(transcript: source, index: 0, ownerID: "local 1", owner: "Me", forUser: true).ownershipIsUnclear)
    }

    func testAliasSpelledMeDoesNotChangeRemoteIdentity() throws {
        var source = transcript()
        source.setSpeakerAlias("Me", for: "them 1")
        let item = try action(transcript: source, index: 1, ownerID: "them 1", owner: "Me", forUser: false)
        XCTAssertFalse(item.isForUser)
        XCTAssertEqual(item.attribution?.resolution, .other)
        let reopened = try JSONDecoder().decode(MeetingOutcomes.ActionItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(reopened, item)
    }

    func testMicrophoneDefaultIsCorrectableWithoutDiarizationButNotForOverlappingVoices() {
        var source = transcript()
        source.segments += [
            .init(start: 40, end: 42, speaker: "local", text: "Unclassified speech",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .track)),
            .init(start: 43, end: 45, speaker: "local unclear", text: "Overlapping speech",
                  attribution: .init(source: .microphone, identity: .unresolved, method: .overlappingSpeech)),
        ]
        source.confirmSpeaker("local 2", isUser: true)
        source.confirmSpeaker("local", isUser: false)
        source.confirmSpeaker("local unclear", isUser: true)
        XCTAssertEqual(source.segments[3].resolvedAttribution.identity, .user)
        XCTAssertEqual(source.segments[4].resolvedAttribution.identity, .other)
        XCTAssertEqual(source.segments[5].resolvedAttribution.identity, .unresolved)
        XCTAssertEqual(source.segments[1].resolvedAttribution.identity, .other)
    }

    func testLegacyMicrophoneIsAnAssumptionSeparateFromTextConfidence() {
        let segment = Transcript.Segment(start: 0, end: 3, speaker: "me", text: "I will do it", confidence: 1)
        XCTAssertEqual(segment.resolvedAttribution.identity, .unresolved)
        XCTAssertEqual(segment.resolvedAttribution.method, .legacy)
    }

    func testAudioRegionsPreserveGapsOverlapAndActualBoundaries() {
        let regions = AttributedTrackTranscriber.regions(duration: 8, turns: [
            .init(start: 1, end: 4, speakerId: "A"), .init(start: 3, end: 6, speakerId: "B"),
        ], source: .microphone)
        XCTAssertEqual(regions.map(\.start), [0, 1, 3, 4, 6])
        XCTAssertEqual(regions.map(\.end), [1, 3, 4, 6, 8])
        XCTAssertEqual(regions.map(\.speaker), ["local", "local 1", "local unclear", "local 2", "local"])
        XCTAssertEqual(regions[2].attribution.method, .overlappingSpeech)
        XCTAssertEqual(regions.map(\.attribution.identity), [.unresolved, .unresolved, .unresolved, .unresolved, .unresolved])
    }

    func testRecordingClockAlignmentHandlesStartupOffsetAndRejectsGaps() throws {
        let mic = AudioClockSpan(hostStart: 100, hostEnd: 130, startFrame: 0, endFrame: 480_000, sampleRate: 16_000, generation: 1)
        let remote = AudioClockSpan(hostStart: 99, hostEnd: 129, startFrame: 0, endFrame: 480_000, sampleRate: 16_000, generation: 1)
        let timing = RecordingAudioTiming(microphone: [mic], system: [remote])
        let aligned = try XCTUnwrap(timing.referenceRange(start: 2, end: 5))
        XCTAssertEqual(aligned.start, 3, accuracy: 0.0001)
        XCTAssertEqual(aligned.end, 6, accuracy: 0.0001)
        XCTAssertNil(timing.referenceRange(start: 28, end: 30))
        var fragmented = timing
        fragmented.system[0].hostEnd = 103
        fragmented.system[0].endFrame = 64_000
        XCTAssertNil(fragmented.referenceRange(start: 2, end: 6))
    }

    func testASRChunksCannotManufactureIndependentAcousticTurns() {
        let source = Transcript(segments: (0..<4).map { index in
            .init(start: Double(index * 10), end: Double(index * 10 + 10), speaker: "them 1", text: "A sentence",
                attribution: .init(source: .system, identity: .other, method: .diarization))
        }, engine: "fixture")
        let turns = AttributedTrackTranscriber.turns([.init(start: 0, end: 40, speakerId: "A")],
            transcript: source, source: .system)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.range.duration, 40)
        XCTAssertTrue(AttributedTrackTranscriber.turns([], transcript: source, source: .system).isEmpty)
    }

    func testMeasuredClockDriftIsMappedAndExcessiveRateChangesAreRejected() throws {
        let mic = AudioClockSpan(hostStart: 0, hostEnd: 1_000.1, startFrame: 0, endFrame: 16_000_000, sampleRate: 16_000, generation: 1)
        let remote = AudioClockSpan(hostStart: 0, hostEnd: 1_100, startFrame: 0, endFrame: 17_600_000, sampleRate: 16_000, generation: 1)
        var timing = RecordingAudioTiming(microphone: [mic], system: [remote])
        XCTAssertEqual(try XCTUnwrap(timing.referenceRange(start: 900, end: 930)).start, 900.09, accuracy: 0.001)
        timing.microphone[0].hostEnd = 1_100
        XCTAssertNil(timing.referenceRange(start: 900, end: 930))
    }

    func testMicrophoneProfileMatchesStaySuggestionsAndCannotUseSystemExemplars() {
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = (0..<3).map { SpeakerVoiceSample(speaker: "local 1", range: .init(start: Double($0 * 10), end: Double($0 * 10 + 6)), vector: vector, source: .microphone) }
        let contribution = SpeakerVoiceProfile.Contribution(meetingID: UUID(), audioRevision: "audio", speakerID: UUID(), decisionID: UUID(), confirmedAt: Date(), samples: samples)
        var profile = SpeakerVoiceProfile(name: "Stevan", isLocalUser: true, confirmedNames: ["Stevan"], contributions: [contribution])
        XCTAssertEqual(SpeakerVoiceMatcher.matches(samples: samples, profiles: [profile]).first?.tier, .suggested)
        profile.contributions[0].samples = samples.map { var sample = $0; sample.source = .system; return sample }
        XCTAssertTrue(SpeakerVoiceMatcher.matches(samples: samples, profiles: [profile]).isEmpty)
    }

    func testSummaryUsesValidatedSpeakerEvenWhenParaphraseContainsFirstPerson() throws {
        let source = transcript()
        let claim = SummaryClaimEvidence.Claim(section: "TL;DR", text: "I will send the report.", speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        let validated = try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([claim]), transcript: source)
        let summary = SummaryClaimEvidence.render(validated, transcript: source, template: .meeting)
        XCTAssertTrue(summary.contains("**Alice:** I will send the report."))
        XCTAssertFalse(summary.contains("**You:**"))
        var wrong = claim; wrong.speakerID = "local 1"
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([wrong]), transcript: source))
        wrong = claim; wrong.quote = "I will change the owner."
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([wrong]), transcript: source))
    }

    func testSummaryClaimCannotCiteOutsideItsChunk() throws {
        let source = transcript()
        let claim = SummaryClaimEvidence.Claim(section: "Key points", text: "Will send the report.", speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([claim]), transcript: source, allowedIDs: [source.segmentID(at: 0)]))
        XCTAssertTrue(source.summaryPromptTurns().allSatisfy { !$0.sourceID.isEmpty })
    }

    func testCompactSummaryCitationsResolveToStableIDsWithTheSameSpeakerAndScopeChecks() throws {
        let source = transcript()
        let claim = SummaryClaimEvidence.Claim(section: "TL;DR", text: "Will send the report.",
            speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        let prompt = try SummaryClaimEvidence.encodeForPrompt([claim], transcript: source)
        XCTAssertTrue(prompt.contains("\"s2\""))
        XCTAssertFalse(prompt.contains(claim.segmentID))
        XCTAssertEqual(try SummaryClaimEvidence.decode(prompt, transcript: source, allowedIDs: [claim.segmentID]), [claim])
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(prompt, transcript: source, allowedIDs: [source.segmentID(at: 0)])) { error in
            XCTAssertEqual((error as? SummaryClaimEvidence.ValidationError)?.reason, .sourceOutsidePart)
        }
        var wrongSpeaker = claim
        wrongSpeaker.segmentID = "s2"
        wrongSpeaker.speakerID = "local 1"
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([wrongSpeaker]), transcript: source)) { error in
            XCTAssertEqual((error as? SummaryClaimEvidence.ValidationError)?.reason, .speakerMismatch)
        }
        var unknown = claim
        unknown.segmentID = "s9999"
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([unknown]), transcript: source)) { error in
            XCTAssertEqual((error as? SummaryClaimEvidence.ValidationError)?.reason, .unknownSource)
        }
    }

    func testSummaryValidationIdentifiesFailingClaimWithoutLeakingItsContent() throws {
        let source = transcript()
        let valid = SummaryClaimEvidence.Claim(section: "TL;DR", text: "Will send the report.",
            speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        var wrong = valid
        wrong.quote = "private invented supporting quote"
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([valid, wrong]), transcript: source)) { error in
            let failure = error as? SummaryClaimEvidence.ValidationError
            XCTAssertEqual(failure?.reason, .quoteMismatch)
            XCTAssertEqual(failure?.claimNumber, 2)
            XCTAssertTrue(error.localizedDescription.contains("Summary claim 2"))
            XCTAssertFalse(error.localizedDescription.contains("private invented"))
            XCTAssertFalse(error.localizedDescription.contains("LLM server error"))
        }
    }

    func testTranslatedSummaryTextStillRequiresAnOriginalLanguageQuote() throws {
        let source = transcript()
        let claim = SummaryClaimEvidence.Claim(section: "TL;DR", text: "Wird den Bericht senden.",
            speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        XCTAssertEqual(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([claim]), transcript: source), [claim])
        var translatedQuote = claim
        translatedQuote.quote = "Ich werde den Bericht senden."
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([translatedQuote]), transcript: source)) { error in
            XCTAssertEqual((error as? SummaryClaimEvidence.ValidationError)?.reason, .quoteMismatch)
        }
    }

    func testFreeformSummaryPreservesSupportedTopicHeadings() throws {
        let source = transcript()
        let claim = SummaryClaimEvidence.Claim(section: "Report delivery", text: "Will send the report.",
            speakerID: "them 1", segmentID: source.segmentID(at: 1), quote: "I will send the report.")
        let claims = try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([claim]), transcript: source, template: .freeform)
        XCTAssertTrue(SummaryClaimEvidence.render(claims, transcript: source, template: .freeform).contains("## Report delivery"))
        XCTAssertThrowsError(try SummaryClaimEvidence.decode(SummaryClaimEvidence.encode([claim]), transcript: source, template: .meeting))
    }

    func testAmbiguousRepairKeepsEditsForReviewWithoutMovingCompletion() {
        let citation = OutcomeSourceCitation(segmentID: "source", start: 0, end: 10, speaker: "Alice", excerpt: "Send the report")
        let old = MeetingOutcomes.ActionItem(id: "old", text: "Send the report", owner: "Alice", citations: [citation])
        let previous = MeetingOutcomes(actionItems: [old])
        let next = MeetingOutcomes(actionItems: [
            .init(id: "new-1", text: "Send the report", owner: "Alice", citations: [citation]),
            .init(id: "new-2", text: "Send the report", owner: "Bob", citations: [citation]),
        ])
        var state = MeetingOutcomeState()
        state.actions[old.id] = .init(status: .done, dueOverride: "Friday", userEdited: true)
        let repaired = MeetingOutcomeStore.reconcileState(state, from: previous, to: next)
        XCTAssertTrue(repaired.actions.isEmpty)
        XCTAssertEqual(repaired.unmatchedActions?[old.id]?.status, .done)
        XCTAssertEqual(repaired.unmatchedActions?[old.id]?.dueOverride, "Friday")
    }

    func testCorrectionInvalidatesDerivedArtifactsButPreservesPreviousResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = transcript()
        try JSONEncoder().encode(source).write(to: folder.appendingPathComponent("transcript.json"))
        try Data("Previous summary".utf8).write(to: folder.appendingPathComponent("summary.md"))
        try MeetingOutcomes(actionItems: [.init(text: "Send report", owner: "Me")]).write(to: folder)
        try MeetingAttributionArtifacts.invalidate(in: folder)
        XCTAssertTrue(MeetingAttributionArtifacts.needsRefresh(in: folder))
        XCTAssertNil(MeetingOutcomes.load(from: folder))
        XCTAssertNotNil(MeetingAttributionArtifacts.previous(in: folder))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("summary.previous.md"), encoding: .utf8), "Previous summary")
        var changed = source; changed.confirmSpeaker("local 2", isUser: true)
        XCTAssertThrowsError(try MeetingAttributionArtifacts.requireCurrent(changed, in: folder))
        XCTAssertNoThrow(try MeetingAttributionArtifacts.requireCurrent(source, in: folder))
    }

    func testExactTextWithoutWaveformEvidencePreservesWordsButMarksUncertainty() {
        let text = "we will send the final report"
        let source = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: text, timingPrecision: .span),
            .init(start: 0, end: 5, speaker: "them", text: text, timingPrecision: .span),
        ], engine: "fixture")
        let result = SpeakerBleedFilter.filter(source)
        XCTAssertEqual(result.removedSegments, 0)
        XCTAssertEqual(result.transcript.segments.map(\.text), [text, text])
        XCTAssertEqual(result.transcript.segments[0].resolvedAttribution.identity, .unresolved)
        XCTAssertEqual(result.transcript.segments[0].resolvedAttribution.method, .suspectedEcho)
        XCTAssertFalse(result.transcript.canConfirmSpeaker("me"))
        XCTAssertEqual(result.acousticCandidateIndices, [0])
    }

    func testMicrophoneDefaultStillAllowsProvenEchoRemovalButExplicitConfirmationWins() {
        let text = "we will send the final report"
        var source = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "local 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .microphone, identity: .user, method: .diarization)),
            .init(start: 0, end: 5, speaker: "them 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .system, identity: .other, method: .diarization))
        ], engine: "fixture")
        let filtered = SpeakerBleedFilter.filter(source, acousticallyVerifiedIndices: [0])
        XCTAssertEqual(filtered.removedSegments, 1)
        XCTAssertEqual(filtered.transcript.segments.map(\.speaker), ["them 1"])
        source.confirmSpeaker("local 1", isUser: true)
        let confirmed = SpeakerBleedFilter.filter(source, acousticallyVerifiedIndices: [0])
        XCTAssertEqual(confirmed.removedSegments, 0)
        XCTAssertEqual(confirmed.transcript.segments, source.segments)
        XCTAssertTrue(confirmed.acousticCandidateIndices.isEmpty)
    }

    func testDefaultMicrophoneEchoReachesTheWaveformCheckThroughTheProductionPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var state: UInt64 = 23
        let audio: [Float] = (0..<32_000).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int64(bitPattern: state) % 10_000) / 10_000 * Float(0.2 + 0.15 * sin(Double(index) / 900))
        }
        for track in [MeetingAudioFiles.Track.mic, .system] {
            let writer = try WavWriter(url: MeetingAudioFiles.recoveryURL(for: track, in: folder), sampleRate: 16_000)
            try writer.append(track == .mic ? audio.map { $0 * 0.5 } : audio)
            try writer.finish()
        }
        let text = "we will send the final report"
        var source = Transcript(segments: [
            .init(start: 0, end: 2, speaker: "local 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .microphone, identity: .user, method: .diarization)),
            .init(start: 0, end: 2, speaker: "them 1", text: text, timingPrecision: .span,
                  attribution: .init(source: .system, identity: .other, method: .diarization))
        ], engine: "fixture")
        let verified = try await EchoWaveformEvidence.verified(in: source, folder: folder)
        XCTAssertEqual(verified, [0])
        XCTAssertEqual(SpeakerBleedFilter.filter(source, acousticallyVerifiedIndices: verified).transcript.segments.map(\.speaker), ["them 1"])

        source.confirmSpeaker("local 1", isUser: true)
        let confirmed = try await EchoWaveformEvidence.verified(in: source, folder: folder)
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testUnconfirmedMicrophoneCannotBecomeUserAcrossEchoModesAndPersistence() throws {
        for status: TranscriptEchoReport.Status in [.disabled, .uncertain, .failed, .noReference, .applied] {
            for method: SpeakerAttribution.Method in [.track, .diarization, .legacy] {
                let original = Transcript(segments: [
                    .init(start: 0, end: 5, speaker: "local 1", text: "I will send the report.",
                          attribution: .init(source: .microphone, identity: .user, method: method))
                ], engine: "fixture", echoReport: .init(status: status))
                let source = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(original))
                XCTAssertTrue(source.confirmedUserSpeakerIDs.isEmpty)
                XCTAssertFalse(source.summaryPromptMarkdown.contains("identity=user"))
                XCTAssertTrue(try action(transcript: source, index: 0, ownerID: "local 1", owner: "Me", forUser: true).ownershipIsUnclear)
            }
        }
    }

    func testMicrophoneDefaultPreservesCorrectionsOverlapAndEchoEvidence() throws {
        for method: SpeakerAttribution.Method in [.overlappingSpeech, .suspectedEcho, .confirmation] {
            let original = Transcript(segments: [
                .init(start: 0, end: 5, speaker: "local 1", text: "I will send the report.",
                      attribution: .init(source: .microphone, identity: .unresolved, method: method))
            ], engine: "fixture")
            let source = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(original))
            XCTAssertTrue(source.confirmedUserSpeakerIDs.isEmpty)
            XCTAssertTrue(try action(transcript: source, index: 0, ownerID: "local 1", owner: "Me", forUser: true).ownershipIsUnclear)
        }
        var corrected = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "I will send the report.")
        ], engine: "fixture")
        corrected.confirmSpeaker("me", isUser: false)
        let reopened = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(corrected))
        XCTAssertEqual(reopened.speakerRoster["me"]?.identity, .other)
        XCTAssertEqual(reopened.displaySpeaker(for: "me"), "Local speaker")
    }

    func testWaveformConfirmationRejectsDifferentSpeechAndMissingReference() {
        var state: UInt64 = 23
        let reference: [Float] = (0..<32_000).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let noise = Float(Int64(bitPattern: state) % 10_000) / 10_000
            return noise * Float(0.2 + 0.15 * sin(Double(index) / 900))
        }
        XCTAssertTrue(EchoWaveformEvidence.nearIdentical(microphone: reference.map { $0 * 0.5 }, reference: reference))
        XCTAssertFalse(EchoWaveformEvidence.nearIdentical(microphone: Array(reference.reversed()), reference: reference))
        XCTAssertFalse(EchoWaveformEvidence.nearIdentical(microphone: reference, reference: []))
    }
}
