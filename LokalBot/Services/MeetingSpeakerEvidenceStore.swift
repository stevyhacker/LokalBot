import CryptoKit
import Foundation

/// One serial authority for evidence, assignment journals and profile mutations.
/// A durable decision is committed before its public transcript projection.
actor MeetingSpeakerEvidenceStore {
    enum Failure: LocalizedError {
        case stale, deleted, corrupt, tooLarge, evidenceExpired
        var errorDescription: String? {
            switch self {
            case .stale: "Speaker information changed. Reopen the speaker to review the current result."
            case .deleted: "This meeting or remembered person was removed."
            case .corrupt: "Local speaker information could not be authenticated."
            case .tooLarge: "Speaker evidence reached its storage limit."
            case .evidenceExpired: "Speaker evidence was deleted or expired while this result was being prepared."
            }
        }
    }
    private let root: URL
    private let key: SymmetricKey
    private var deleted = Set<UUID>()
    init(root: URL, key: SymmetricKey) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.key = key
    }

    private func evidenceFolder(_ meeting: Meeting) -> URL {
        root.appendingPathComponent(meeting.relativePath).appendingPathComponent("speaker-evidence", isDirectory: true)
    }
    private var profilesURL: URL { root.appendingPathComponent("speaker-profiles/profiles.sealed") }
    private func aad(_ url: URL) -> Data {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return Data(path.dropFirst(root.path.count).utf8)
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_024 * 1_024 else { throw Failure.tooLarge }
        // A locked/protected file is unavailable, not corrupt ciphertext.
        // Preserve the I/O failure so diagnostics distinguish it from a bad key.
        let data = try Data(contentsOf: url)
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let clear = try AES.GCM.open(box, using: key, authenticating: aad(url))
            return try JSONDecoder().decode(type, from: clear)
        } catch { throw Failure.corrupt }
    }
    @discardableResult private func write<T: Encodable>(_ value: T, at url: URL) throws -> Int {
        let clear = try JSONEncoder().encode(value)
        guard let data = try AES.GCM.seal(clear, using: key, authenticating: aad(url)).combined else { throw Failure.corrupt }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The payload is already authenticated AES-GCM ciphertext. Foundation's
        // file-protection option can create unreadable files on macOS when the
        // process has no Data Protection entitlement, so keep the atomic write
        // and enforce a user-only POSIX boundary instead.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data.count
    }
    private func checkMeeting(_ meeting: Meeting) throws {
        guard !deleted.contains(meeting.id),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(meeting.relativePath).appendingPathComponent("meta.json").path)
        else { throw Failure.deleted }
    }

    func state(meeting: Meeting) throws -> MeetingSpeakerIdentityState {
        try checkMeeting(meeting)
        let value = try read(MeetingSpeakerIdentityState.self, at: evidenceFolder(meeting).appendingPathComponent("identity.sealed"))
            ?? MeetingSpeakerIdentityState(meetingID: meeting.id)
        guard value.schemaVersion == 1, value.meetingID == meeting.id else { throw Failure.corrupt }
        return value
    }

    func commit(_ proposed: MeetingSpeakerIdentityState, meeting: Meeting, expectedRevision: Int,
                expectedProfileRevision: Int? = nil, expectedEvidenceRevision: Int? = nil) throws -> MeetingSpeakerIdentityState {
        let current = try state(meeting: meeting)
        if let expectedEvidenceRevision, current.evidenceRevision != expectedEvidenceRevision { throw Failure.evidenceExpired }
        guard current.revision == expectedRevision else { throw Failure.stale }
        if let expectedProfileRevision, try profiles().revision != expectedProfileRevision { throw Failure.stale }
        var next = proposed
        next.revision = current.revision + 1
        // Retain only bounded recent event metadata; assignments hold durable authority.
        next.decisions = Array(next.decisions.suffix(512))
        try write(next, at: evidenceFolder(meeting).appendingPathComponent("identity.sealed"))
        return next
    }

    /// Everything beside the identity journal is retired Google Meet speaker
    /// observation (participant names and speaking intervals).
    private func removeRetiredObservations(_ meeting: Meeting) throws {
        let folder = evidenceFolder(meeting)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where url.lastPathComponent != "identity.sealed" {
            try FileManager.default.removeItem(at: url)
        }
    }

    func eraseEvidence(meeting: Meeting) throws {
        try checkMeeting(meeting)
        try removeRetiredObservations(meeting)
        var saved = try state(meeting: meeting)
        saved.evidenceRevision += 1
        saved.suggestions = [:]
        saved.voiceSamples = []
        saved.microphoneSampleDiagnostics = nil
        saved.timeline = []
        saved.acousticTimeline = []
        // Durable applied names retain minimal turns, not the underlying matches.
        for index in saved.assignments.indices {
            saved.assignments[index].match = nil
            saved.assignments[index].supportingMatches = nil
        }
        _ = try commit(saved, meeting: meeting, expectedRevision: saved.revision)
    }

    func expire(meetings: [Meeting], retentionDays: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(max(0, retentionDays)) * 86_400)
        for meeting in meetings {
            let folder = evidenceFolder(meeting)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            if meeting.startedAt < cutoff {
                try eraseEvidence(meeting: meeting)
            } else {
                // Recent microphone voice samples stay available for remembering.
                try removeRetiredObservations(meeting)
            }
        }
    }

    func profiles() throws -> SpeakerVoiceProfileDatabase {
        let database = try read(SpeakerVoiceProfileDatabase.self, at: profilesURL) ?? SpeakerVoiceProfileDatabase()
        guard database.schemaVersion == 1 else { throw Failure.corrupt }
        return database
    }

    func enroll(meeting: Meeting, assignment: SpeakerIdentityAssignment, decision: SpeakerAliasDecision,
                samples: [SpeakerVoiceSample], profileID: UUID?, expectedDatabaseRevision: Int) throws -> UUID {
        try checkMeeting(meeting)
        var database = try profiles()
        if let existing = database.profiles.first(where: { profile in
            profile.contributions.contains { $0.decisionID == decision.id }
        }) { return existing.id }
        guard database.revision == expectedDatabaseRevision,
              !database.deletedMeetings.contains(meeting.id),
              !database.revokedDecisionIDs.contains(decision.id),
              assignment.origin.isProtected, decision.action == .assign || decision.action.confirmsIdentity,
              let name = assignment.name, SpeakerVoiceMatcher.canEnroll(samples) else { throw Failure.stale }
        let durable = try state(meeting: meeting)
        guard durable.decisions.last(where: { $0.speakerID == assignment.id })?.id == decision.id,
              durable.assignments.contains(where: { $0.id == assignment.id && $0.name == assignment.name && $0.origin.isProtected }) else { throw Failure.stale }
        let targetID = profileID ?? UUID()
        guard !database.forgottenProfiles.contains(targetID) else { throw Failure.deleted }
        let contribution = SpeakerVoiceProfile.Contribution(meetingID: meeting.id, audioRevision: assignment.audioRevision,
            speakerID: assignment.id, decisionID: decision.id, confirmedAt: decision.confirmedAt, samples: Array(samples.prefix(8)))
        if let index = database.profiles.firstIndex(where: { $0.id == targetID }) {
            guard database.profiles[index].model == SpeakerVoiceSample.fingerprint else { throw Failure.stale }
            let existingIdentity = database.profiles[index].isLocalUser
            if let existingIdentity, let confirmed = assignment.isLocalUser,
               existingIdentity != confirmed { throw Failure.stale }
            if let confirmed = assignment.isLocalUser { database.profiles[index].isLocalUser = confirmed }
            database.profiles[index].contributions.removeAll { $0.meetingID == meeting.id && $0.speakerID == assignment.id }
            database.profiles[index].contributions.append(contribution)
            database.profiles[index].contributions = Array(database.profiles[index].contributions.suffix(8))
            if !database.profiles[index].confirmedNames.contains(name) { database.profiles[index].confirmedNames.append(name) }
            database.profiles[index].revision += 1
        } else {
            guard profileID == nil else { throw Failure.deleted }
            guard database.profiles.count < 100 else { throw Failure.tooLarge }
            database.profiles.append(SpeakerVoiceProfile(id: targetID, name: name,
                isLocalUser: assignment.isLocalUser, confirmedNames: [name], contributions: [contribution]))
        }
        database.revision += 1
        try write(database, at: profilesURL)
        return targetID
    }

    func revoke(meetingID: UUID, speakerID: UUID? = nil, deletingMeeting: Bool = false) throws {
        var database = try profiles()
        if deletingMeeting { database.deletedMeetings.insert(meetingID); deleted.insert(meetingID) }
        for index in database.profiles.indices {
            let before = database.profiles[index].contributions.count
            database.revokedDecisionIDs.formUnion(database.profiles[index].contributions.filter {
                $0.meetingID == meetingID && (speakerID == nil || $0.speakerID == speakerID)
            }.map(\.decisionID))
            database.profiles[index].contributions.removeAll { $0.meetingID == meetingID && (speakerID == nil || $0.speakerID == speakerID) }
            if before != database.profiles[index].contributions.count { database.profiles[index].revision += 1 }
        }
        let empty = database.profiles.filter { $0.contributions.isEmpty }.map(\.id)
        database.profiles.removeAll { $0.contributions.isEmpty }
        database.forgottenProfiles.formUnion(empty)
        database.revision += 1
        try write(database, at: profilesURL)
    }

    func forgetProfile(_ id: UUID?) throws {
        var database = try profiles()
        let ids = id.map { [$0] } ?? database.profiles.map(\.id)
        database.revokedDecisionIDs.formUnion(database.profiles.filter { ids.contains($0.id) }.flatMap { $0.contributions.map(\.decisionID) })
        database.forgottenProfiles.formUnion(ids)
        database.profiles.removeAll { ids.contains($0.id) }
        database.revision += 1
        try write(database, at: profilesURL)
    }

    func renameProfile(_ id: UUID, name: String) throws {
        var database = try profiles()
        guard let name = ParticipantObservation.safeName(name), let index = database.profiles.firstIndex(where: { $0.id == id }) else { throw Failure.stale }
        database.profiles[index].name = name
        database.profiles[index].confirmedNames.append(name)
        database.profiles[index].revision += 1
        database.revision += 1
        try write(database, at: profilesURL)
    }
}
