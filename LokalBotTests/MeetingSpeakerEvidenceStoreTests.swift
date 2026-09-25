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

    func testEncryptedAuthenticatedChunksRecoverWithoutPersistingNamesInCleartext() async throws {
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        let interval = SpeakerActivityInterval(participantReference: "alex", displayName: "Alex Fixture",
            range: .init(start: 10, end: 15), uncertainty: 0.1, layoutEpoch: "grid")
        try await store.append([interval], meeting: meeting, generation: generation)
        let folder = meeting.folderURL(in: storage).appendingPathComponent("speaker-evidence")
        let ciphertext = try Data(contentsOf: folder.appendingPathComponent("chunk-0.sealed"))
        XCTAssertNil(ciphertext.range(of: Data("Alex Fixture".utf8)))
        let recovered = MeetingSpeakerEvidenceStore(root: root, key: key)
        let evidence = try await recovered.evidence(meeting: meeting, retentionDays: 14)
        XCTAssertEqual(evidence?.intervals.count, 1)
        XCTAssertEqual(evidence?.intervals.first?.range, interval.range)
        // Incomplete trailing record is discarded, never turned into a speaking interval.
        try ciphertext.prefix(12).write(to: folder.appendingPathComponent("chunk-1.sealed"))
        let partial = try await recovered.evidence(meeting: meeting, retentionDays: 14)
        XCTAssertEqual(partial?.intervals.count, 1)
    }

    func testFailureOnlyObservationSessionRetainsDiagnosticsAfterRestart() async throws {
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        var diagnostics = SpeakerObservationDiagnostics()
        diagnostics.record(.accessibilityPermission)
        diagnostics.record(.layoutUnavailable)
        try await store.recordDiagnostics(diagnostics, meeting: meeting, generation: generation)
        try await store.seal(meeting: meeting, generation: generation, failed: false)
        let reopened = MeetingSpeakerEvidenceStore(root: root, key: key)
        let evidence = try await reopened.evidence(meeting: meeting, retentionDays: 14)
        XCTAssertEqual(evidence?.intervals.count, 0)
        XCTAssertEqual(evidence?.diagnostics, diagnostics)
        let status = try await reopened.observationDiagnostics(meeting: meeting, retentionDays: 14)
        XCTAssertEqual(status, diagnostics)
        try await store.eraseEvidence(meeting: meeting)
        let deletedStatus = try await reopened.observationDiagnostics(meeting: meeting, retentionDays: 14)
        XCTAssertNil(deletedStatus)
        do {
            try await store.recordDiagnostics(diagnostics, meeting: meeting, generation: generation)
            XCTFail("Diagnostics resurrected deleted evidence")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testSilentParticipantNamesSurviveRestartButExpireWithEvidence() async throws {
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        let names = [MeetingParticipantName(name: "Jonathan", source: .ocr)]
        do {
            try await store.recordParticipants(names, meeting: meeting, generation: generation)
            XCTFail("Unverified source supplied participant names")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        try await store.verifyProvider(meeting: meeting, generation: generation)
        try await store.recordParticipants(names, meeting: meeting, generation: generation)
        try await store.seal(meeting: meeting, generation: generation, failed: false)
        let reopened = MeetingSpeakerEvidenceStore(root: root, key: key)
        let restored = try await reopened.participants(meeting: meeting, retentionDays: 14)
        XCTAssertEqual(restored, names)
        let evidence = try await reopened.evidence(meeting: meeting, retentionDays: 14)
        XCTAssertTrue(evidence?.intervals.isEmpty == true)
        let ciphertext = try Data(contentsOf: meeting.folderURL(in: storage).appendingPathComponent("speaker-evidence/session.sealed"))
        XCTAssertNil(ciphertext.range(of: Data("Jonathan".utf8)))
        try await store.eraseEvidence(meeting: meeting)
        let erased = try await reopened.participants(meeting: meeting, retentionDays: 14)
        XCTAssertTrue(erased.isEmpty)
        do {
            try await store.recordParticipants(names, meeting: meeting, generation: generation)
            XCTFail("Late roster resurrected erased evidence")
        } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
    }

    func testManualDecisionSurvivesRestartAndVisualEvidenceExpiry() async throws {
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
        let snapshot = try await store.matchingInput(meeting: meeting, retentionDays: 14)
        try await store.eraseEvidence(meeting: meeting)
        let afterDeletion = try await store.state(meeting: meeting)
        do {
            _ = try await store.commit(afterDeletion, meeting: meeting, expectedRevision: afterDeletion.revision,
                expectedEvidenceRevision: snapshot.1)
            XCTFail("An old matching task survived explicit evidence deletion")
        } catch MeetingSpeakerEvidenceStore.Failure.evidenceExpired {
            // Even a writer refreshed to the latest assignment revision cannot
            // reintroduce deleted evidence from its original snapshot.
        }
    }

    func testGenerationMismatchAndDeletionRejectLateEvidence() async throws {
        let generation = UUID()
        try await store.begin(.init(meetingID: meeting.id, generation: generation), meeting: meeting)
        do { try await store.append([], meeting: meeting, generation: UUID()); XCTFail("Wrong generation") } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
        try await store.revoke(meetingID: meeting.id, deletingMeeting: true)
        try storage.deleteMeeting(meeting)
        do { try await store.seal(meeting: meeting, generation: generation, failed: false); XCTFail("Resurrected source") } catch { XCTAssertTrue(error is MeetingSpeakerEvidenceStore.Failure) }
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
