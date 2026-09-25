import AudioToolbox
import CryptoKit
import XCTest
@testable import LokalBot

final class RecordingSpeakerClockTests: XCTestCase {
    private func ticks(_ seconds: Double) -> UInt64 { AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000)) }
    private func write(_ clock: RecordingAudioClock, host: Double, frame: Int64, seconds: Int64 = 10, valid: Bool = true, rate: Double = 48_000) {
        clock.record(hostTime: ticks(host), valid: valid, startFrame: frame, frames: seconds * Int64(rate), sampleRate: rate)
    }
    func testStartupAndQueuedWriterUseSourceTimeNotMeetingWallTime() throws {
        let clock = RecordingAudioClock()
        write(clock, host: 123, frame: 0)
        let range = try XCTUnwrap(clock.map(hostStart: 125, hostEnd: 126))
        XCTAssertEqual(range.start, 2, accuracy: 0.000001)
        XCTAssertEqual(range.end, 3, accuracy: 0.000001)
        XCTAssertNil(clock.map(hostStart: 122, hostEnd: 124))
        XCTAssertNil(clock.map(hostStart: 132, hostEnd: 134))
    }
    func testDroppedBuffersDoNotCompressVisualTimeAcrossTheGap() throws {
        let clock = RecordingAudioClock()
        write(clock, host: 100, frame: 0)
        write(clock, host: 120, frame: 480_000)
        XCTAssertNil(clock.map(hostStart: 109, hostEnd: 121))
        XCTAssertEqual(try XCTUnwrap(clock.map(hostStart: 121, hostEnd: 122)).start, 11, accuracy: 0.00001)
    }
    func testRecoverySilenceAdvancesFilePositionWithoutCreatingCoverage() throws {
        let clock = RecordingAudioClock()
        write(clock, host: 100, frame: 0)
        clock.discontinuity()
        write(clock, host: 125, frame: 1_200_000)
        XCTAssertNil(clock.map(hostStart: 110, hostEnd: 125))
        XCTAssertEqual(try XCTUnwrap(clock.map(hostStart: 126, hostEnd: 127)).start, 26, accuracy: 0.00001)
    }
    func testInvalidTimestampsAndGenerationChangesBreakCoverage() {
        let clock = RecordingAudioClock()
        write(clock, host: 100, frame: 0)
        write(clock, host: 110, frame: 480_000, valid: false)
        write(clock, host: 120, frame: 960_000)
        XCTAssertNil(clock.map(hostStart: 109, hostEnd: 121))
        clock.invalidate()
        write(clock, host: 130, frame: 1_440_000)
        XCTAssertNil(clock.map(hostStart: 131, hostEnd: 132))
    }
    func testSampleRateChangeAndBackwardsClockNeverReuseAnOldMapping() {
        let clock = RecordingAudioClock()
        write(clock, host: 100, frame: 0)
        write(clock, host: 110, frame: 480_000, rate: 44_100)
        XCTAssertNil(clock.map(hostStart: 111, hostEnd: 112))
        write(clock, host: 90, frame: 960_000)
        XCTAssertNil(clock.map(hostStart: 101, hostEnd: 102))
        XCTAssertTrue(clock.snapshot().isEmpty)
        XCTAssertEqual(clock.archive().count, 1, "Offline file anchors survive live-clock invalidation")
        write(clock, host: 130, frame: 1_440_000)
        XCTAssertNotNil(clock.map(hostStart: 131, hostEnd: 132))
    }
}

final class SpeakerIdentityResolverTests: XCTestCase {
    private func assignment(_ label: String, name: String, start: Double, end: Double) -> SpeakerIdentityAssignment {
        .init(label: label, name: name, origin: .userConfirmed, audioRevision: "same-audio", anchors: [.init(start: start, end: end)])
    }
    func testRetranscriptionFollowsVoiceTurnsAfterOrdinalsSwap() {
        let previous = [assignment("them 1", name: "Alex", start: 10, end: 20), assignment("them 2", name: "Sam", start: 30, end: 40)]
        let new = [SpeakerAudioTurn(speaker: "them 2", range: .init(start: 10, end: 20)), .init(speaker: "them 1", range: .init(start: 30, end: 40))]
        let remapped = SpeakerIdentityResolver.remap(previous, turns: new, audioRevision: "same-audio")
        XCTAssertEqual(remapped.first { $0.label == "them 2" }?.name, "Alex")
        XCTAssertEqual(remapped.first { $0.label == "them 1" }?.name, "Sam")
        XCTAssertTrue(SpeakerIdentityResolver.remap(previous, turns: new, audioRevision: "new-audio").isEmpty)
    }
    func testCleanSplitRemembersPersonButMixedMergeAbstains() {
        let alex = assignment("them 1", name: "Alex", start: 0, end: 20)
        let split = [SpeakerAudioTurn(speaker: "them 2", range: .init(start: 0, end: 8)), .init(speaker: "them 3", range: .init(start: 12, end: 20))]
        let remapped = SpeakerIdentityResolver.remap([alex], turns: split, audioRevision: "same-audio")
        XCTAssertEqual(remapped.count, 2)
        XCTAssertTrue(remapped.allSatisfy { $0.id == alex.id && $0.name == "Alex" })
        let sam = assignment("them 2", name: "Sam", start: 20, end: 30)
        let merged = [SpeakerAudioTurn(speaker: "them", range: .init(start: 0, end: 30))]
        XCTAssertTrue(SpeakerIdentityResolver.remap([alex, sam], turns: merged, audioRevision: "same-audio").isEmpty)
    }
    func testSmallConflictingConfirmedVoiceStillBlocksAMergedIdentity() {
        let long = assignment("them 1", name: "Alex", start: 0, end: 98)
        let brief = assignment("them 2", name: "Sam", start: 98, end: 100)
        let merged = [SpeakerAudioTurn(speaker: "them", range: .init(start: 0, end: 100))]
        XCTAssertTrue(SpeakerIdentityResolver.remap([long, brief], turns: merged, audioRevision: "same-audio").isEmpty)
    }
    func testUserCorrectionAndSuppressionBeatAutomaticMatches() {
        var user = assignment("them", name: "Sam", start: 0, end: 20)
        let automatic = candidate(name: "Alex")
        XCTAssertTrue(SpeakerIdentityResolver.apply(candidates: [automatic], to: &user, profiles: []).isEmpty)
        XCTAssertEqual(user.name, "Sam")
        user.origin = .visualAutomatic
        user.name = nil
        user.suppressedNames = ["alex"]
        XCTAssertTrue(SpeakerIdentityResolver.apply(candidates: [automatic], to: &user, profiles: []).isEmpty)
        XCTAssertNil(user.name)
    }
    func testContradictionWithdrawsMachineNameWithoutSilentlySwapping() {
        var current = assignment("them", name: "Sam", start: 0, end: 20)
        current.origin = .visualAutomatic
        XCTAssertEqual(SpeakerIdentityResolver.apply(candidates: [candidate(name: "Alex")], to: &current, profiles: []).count, 1)
        XCTAssertNil(current.name)
    }
    func testVisualProfileConflictNeedsReviewWhileConfirmedNicknameAgrees() {
        let profile = SpeakerVoiceProfile(name: "Samuel", confirmedNames: ["Sam", "Samuel"], contributions: [])
        var voice = candidate(name: "Samuel")
        voice.source = .profile; voice.profileID = profile.id
        var current = assignment("them", name: "", start: 0, end: 20)
        current.name = nil; current.origin = .calendarAutomatic
        _ = SpeakerIdentityResolver.apply(candidates: [candidate(name: "Alex"), voice], to: &current, profiles: [profile])
        XCTAssertNil(current.name)
        _ = SpeakerIdentityResolver.apply(candidates: [candidate(name: "Sam"), voice], to: &current, profiles: [profile])
        XCTAssertEqual(current.name, "Sam")
        XCTAssertEqual(current.evidencePath, "combined")
        XCTAssertEqual(current.supportingMatches?.count, 2)
    }
    private func candidate(name: String) -> SpeakerNameMatch {
        .init(name: name, participantReference: name, tier: .automatic, source: .visual,
              supportSeconds: 30, independentTurns: 4, supportFraction: 1, contradictionSeconds: 0, evidence: [])
    }
}

final class SpeakerVoiceMatcherTests: XCTestCase {
    private func vector(_ axis: Int, noise: Float = 0) -> [Float] {
        var result = [Float](repeating: 0, count: 256)
        result[axis] = 1; result[255] = noise
        return result
    }
    private func samples(axis: Int) -> [SpeakerVoiceSample] {
        (0..<4).map { index in
            let start = Double(index * 20)
            let embedding = vector(axis, noise: Float(index) * 0.01)
            return SpeakerVoiceSample(speaker: "them", range: .init(start: start, end: start + 10), vector: embedding)
        }
    }
    private func profile(axis: Int) -> SpeakerVoiceProfile {
        .init(name: "Alex", confirmedNames: ["Alex"], contributions: [
            .init(meetingID: UUID(), audioRevision: "enrollment", speakerID: UUID(), decisionID: UUID(), confirmedAt: Date(), samples: samples(axis: axis))])
    }
    func testCompatibleIndependentQueryPassesRulesButIsNotAnAccuracyBenchmark() {
        let matches = SpeakerVoiceMatcher.matches(samples: samples(axis: 0), profiles: [profile(axis: 0)])
        XCTAssertEqual(matches.first?.tier, .automatic)
    }
    func testUnknownVoiceRejectedWithSingleSavedProfile() {
        XCTAssertTrue(SpeakerVoiceMatcher.matches(samples: samples(axis: 1), profiles: [profile(axis: 0)]).isEmpty)
    }
    func testConfusableProfilesCannotBothAutomaticallyWin() {
        XCTAssertTrue(SpeakerVoiceMatcher.matches(samples: samples(axis: 0), profiles: [profile(axis: 0), profile(axis: 0)])
            .allSatisfy { $0.tier == .suggested })
    }
    func testOverlappingChunksDoNotQualifyForEnrollment() {
        let one = samples(axis: 0)[0]
        let correlated = Array(repeating: one, count: 20)
        let eligible = SpeakerVoiceMatcher.eligible(correlated,
            turns: [.init(speaker: "them", range: .init(start: 0, end: 20))], speaker: "them")
        XCTAssertEqual(eligible.count, 1)
        XCTAssertFalse(SpeakerVoiceMatcher.canEnroll(eligible))
    }
    func testMixedClusterCorruptVectorsAndModelMismatchRejected() {
        var query = samples(axis: 0)
        let turns = query.map { SpeakerAudioTurn(speaker: "them", range: $0.range) }
        query[1].vector = vector(1)
        XCTAssertTrue(SpeakerVoiceMatcher.eligible(query, turns: turns, speaker: "them").isEmpty)
        XCTAssertNil(SpeakerVoiceMatcher.normalized([.nan]))
        XCTAssertNil(SpeakerVoiceMatcher.normalized([Float](repeating: 0, count: 256)))
        var incompatible = profile(axis: 0); incompatible.model = "another-vector-space"
        XCTAssertTrue(SpeakerVoiceMatcher.matches(samples: samples(axis: 0), profiles: [incompatible]).isEmpty)
    }
    func testOverlappingSpeakersDoNotEnrollMixedChunks() {
        let query = samples(axis: 0)
        let turns = query.flatMap { sample in
            [SpeakerAudioTurn(speaker: "them", range: sample.range), .init(speaker: "them 2", range: sample.range)]
        }
        XCTAssertTrue(SpeakerVoiceMatcher.eligible(query, turns: turns, speaker: "them").isEmpty)
    }
}
