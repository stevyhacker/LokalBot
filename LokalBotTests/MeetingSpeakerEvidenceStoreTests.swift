import CryptoKit
import XCTest
@testable import LokalBot

@MainActor final class MeetingSpeakerEvidenceStoreTests: XCTestCase {
    private var root: URL!
    private var storage: StorageManager!
    private var store: MeetingSpeakerEvidenceStore!
    private var meeting: Meeting!
    private var key: SymmetricKey!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-store-\(UUID())")
        storage = StorageManager(rootURL: root)
        meeting = try storage.createMeetingFolder(title: "Synthetic participants", appName: "Google Chrome")
        key = SymmetricKey(size: .bits256)
        store = MeetingSpeakerEvidenceStore(root: root, key: key)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testRetiredMeetObservationFilesAreRemovedWithoutLosingRecentVoiceSamples() async throws {
        var saved = MeetingSpeakerIdentityState(meetingID: meeting.id)
        saved.voiceSamples = enrollment().2
        _ = try await store.commit(saved, meeting: meeting, expectedRevision: 0)
        let folder = meeting.folderURL(in: storage).appendingPathComponent("speaker-evidence")
        for name in ["session.sealed", "chunk-0.sealed"] {
            try Data("retired Meet observation".utf8).write(to: folder.appendingPathComponent(name))
        }

        try await store.expire(meetings: [meeting], retentionDays: 14)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(remaining, ["identity.sealed"])
        let recent = try await store.state(meeting: meeting)
        XCTAssertEqual(recent.revision, 1)
        XCTAssertEqual(recent.voiceSamples.count, 3, "Recent microphone samples stay available for remembering")

        try await store.expire(meetings: [meeting], retentionDays: 0)
        let expired = try await store.state(meeting: meeting)
        XCTAssertTrue(expired.voiceSamples.isEmpty)
    }

    func testManualDecisionSurvivesRestartAndEvidenceExpiry() async throws {
        var saved = MeetingSpeakerIdentityState(meetingID: meeting.id)
        saved.audioRevision = "audio"
        let assignment = SpeakerIdentityAssignment(label: "them", name: "Alex", origin: .userConfirmed,
            audioRevision: "audio", anchors: [.init(start: 0, end: 20)])
        saved.assignments = [assignment]
        saved.acousticTimeline = [.init(speaker: "them", range: .init(start: 0, end: 300))]
        saved.decisions = [.init(speakerID: assignment.id, action: .assign, sourceRevision: "audio", name: "Alex")]
        _ = try await store.commit(saved, meeting: meeting, expectedRevision: 0)
        try await store.eraseEvidence(meeting: meeting)
        let reopened = MeetingSpeakerEvidenceStore(root: root, key: key)
        let after = try await reopened.state(meeting: meeting)
        XCTAssertEqual(after.assignments.first?.name, "Alex")
        XCTAssertEqual(after.assignments.first?.anchors, assignment.anchors)
        XCTAssertEqual(after.decisions.count, 1)
        XCTAssertTrue(after.suggestions.isEmpty)
        XCTAssertTrue(after.acousticTimeline?.isEmpty == true)
        XCTAssertTrue(after.timeline.isEmpty)
    }

    func testStaleAutomaticWriteCannotOverwriteCorrection() async throws {
        let old = try await store.state(meeting: meeting)
        var corrected = old
        corrected.assignments = [.init(label: "them", name: "Sam", origin: .userCorrected, audioRevision: "audio", anchors: [])]
        _ = try await store.commit(corrected, meeting: meeting, expectedRevision: 0)
        do {
            _ = try await store.commit(old, meeting: meeting, expectedRevision: 0)
            XCTFail("Accepted a stale writer")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        let current = try await store.state(meeting: meeting)
        XCTAssertEqual(current.assignments.first?.name, "Sam")
        let snapshot = try await store.state(meeting: meeting).evidenceRevision
        try await store.eraseEvidence(meeting: meeting)
        let afterDeletion = try await store.state(meeting: meeting)
        do {
            _ = try await store.commit(afterDeletion, meeting: meeting, expectedRevision: afterDeletion.revision,
                expectedEvidenceRevision: snapshot)
            XCTFail("An old matching task survived explicit evidence deletion")
        } catch MeetingSpeakerEvidenceStore.Failure.evidenceExpired {
            // Even a writer refreshed to the latest assignment revision cannot
            // reintroduce deleted evidence from its original snapshot.
        }
    }

    func testDeletedMeetingRejectsLateIdentityWrites() async throws {
        let saved = try await store.state(meeting: meeting)
        try await store.revoke(meetingID: meeting.id, deletingMeeting: true)
        try storage.deleteMeeting(meeting)
        do {
            _ = try await store.commit(saved, meeting: meeting, expectedRevision: saved.revision)
            XCTFail("Resurrected a deleted meeting")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.folderURL(in: storage).path))
    }

    func testWrongKeyOrReplayedJournalFailsClosedWithoutReplacingIt() async throws {
        var saved = MeetingSpeakerIdentityState(meetingID: meeting.id)
        saved.audioRevision = "audio"
        _ = try await store.commit(saved, meeting: meeting, expectedRevision: 0)
        let wrong = MeetingSpeakerEvidenceStore(root: root, key: SymmetricKey(size: .bits256))
        do { _ = try await wrong.state(meeting: meeting); XCTFail("Wrong key authenticated") } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        let other = try storage.createMeetingFolder(title: "Other", appName: "Google Chrome")
        let target = other.folderURL(in: storage).appendingPathComponent("speaker-evidence")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: meeting.folderURL(in: storage).appendingPathComponent("speaker-evidence/identity.sealed"),
            to: target.appendingPathComponent("identity.sealed"))
        do { _ = try await store.state(meeting: other); XCTFail("Cross-meeting replay authenticated") } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testProfilesRequireConfirmationAndForgetInvalidatesQueuedWork() async throws {
        let (assignment, decision, samples) = enrollment()
        do {
            _ = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
                samples: samples, profileID: nil, expectedDatabaseRevision: 0)
            XCTFail("Enrollment without durable confirmation")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        var saved = MeetingSpeakerIdentityState(meetingID: meeting.id)
        saved.assignments = [assignment]; saved.decisions = [decision]
        _ = try await store.commit(saved, meeting: meeting, expectedRevision: 0)
        let profile = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
            samples: samples, profileID: nil, expectedDatabaseRevision: 0)
        let beforeForget = try await store.profiles()
        XCTAssertEqual(beforeForget.profiles.count, 1)
        try await store.forgetProfile(profile)
        do {
            _ = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
                samples: samples, profileID: profile, expectedDatabaseRevision: beforeForget.revision)
            XCTFail("Stale enrollment resurrected a forgotten person")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        do {
            _ = try await store.commit(saved, meeting: meeting, expectedRevision: 1, expectedProfileRevision: beforeForget.revision)
            XCTFail("Recognition used a forgotten snapshot")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        let after = try await store.profiles()
        XCTAssertTrue(after.profiles.isEmpty)
        XCTAssertTrue(after.forgottenProfiles.contains(profile))
        do {
            _ = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
                samples: samples, profileID: nil, expectedDatabaseRevision: after.revision)
            XCTFail("Reused the old confirmation to create a replacement profile")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testDeletingLastEnrollmentSourceRemovesProfileButNotOtherMeetingsNames() async throws {
        let (assignment, decision, samples) = enrollment()
        var saved = MeetingSpeakerIdentityState(meetingID: meeting.id)
        saved.assignments = [assignment]; saved.decisions = [decision]
        _ = try await store.commit(saved, meeting: meeting, expectedRevision: 0)
        _ = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
            samples: samples, profileID: nil, expectedDatabaseRevision: 0)
        try await store.revoke(meetingID: meeting.id, speakerID: assignment.id)
        let database = try await store.profiles()
        XCTAssertTrue(database.profiles.isEmpty)
        let historical = try await store.state(meeting: meeting)
        XCTAssertEqual(historical.assignments.first?.name, "Alex")
    }

    private func enrollment() -> (SpeakerIdentityAssignment, SpeakerAliasDecision, [SpeakerVoiceSample]) {
        let assignment = SpeakerIdentityAssignment(label: "them", name: "Alex", origin: .userConfirmed,
            audioRevision: "audio", anchors: [.init(start: 0, end: 60)])
        let decision = SpeakerAliasDecision(speakerID: assignment.id, action: .assign, sourceRevision: "audio", name: "Alex")
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        let samples = (0..<3).map { SpeakerVoiceSample(speaker: "them",
            range: .init(start: Double($0 * 20), end: Double($0 * 20 + 10)), vector: vector) }
        return (assignment, decision, samples)
    }
}
