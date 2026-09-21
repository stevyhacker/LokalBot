import CryptoKit
import Foundation

@MainActor
final class MeetingSpeakerIdentityService: ObservableObject {
    enum IdentityError: LocalizedError {
        case unseparatedAudio
        var errorDescription: String? {
            "This audio has not been separated into a reliable speaker. Reprocess transcription before confirming who spoke."
        }
    }
    @Published private(set) var notice: String?
    @Published private(set) var revision = 0
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let keyProvider: @MainActor () throws -> SymmetricKey
    private var cachedStore: MeetingSpeakerEvidenceStore?
    private var sealing: [UUID: Task<Void, Never>] = [:]
    private var deleted = Set<UUID>()
    private var retentionTask: Task<Void, Never>?
    private var latestStates: [UUID: MeetingSpeakerIdentityState] = [:]
    private var unverifiedProcessing = Set<UUID>()

    init(storage: StorageManager, settings: @escaping () -> AppSettings,
         keyProvider: @escaping @MainActor () throws -> SymmetricKey = { try KeychainSecrets.symmetricKey(account: "speaker-identity-key") }) {
        self.storage = storage
        self.settings = settings
        self.keyProvider = keyProvider
    }

    func store() throws -> MeetingSpeakerEvidenceStore {
        if let cachedStore { return cachedStore }
        let created = MeetingSpeakerEvidenceStore(root: storage.rootURL, key: try keyProvider())
        cachedStore = created
        return created
    }

    func finalize(meetingID: UUID, task: Task<Void, Never>) { sealing[meetingID] = task }

    func state(for meeting: Meeting) async throws -> MeetingSpeakerIdentityState {
        try await store().state(meeting: meeting)
    }

    func observationDiagnostics(for meeting: Meeting) async throws -> SpeakerObservationDiagnostics? {
        try await store().observationDiagnostics(meeting: meeting, retentionDays: settings().retentionDays)
    }

    func participants(for meeting: Meeting) async throws -> [MeetingParticipantName] {
        try await store().participants(meeting: meeting, retentionDays: settings().retentionDays)
    }

    nonisolated static func audioRevision(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func timeline(_ transcript: Transcript) -> [SpeakerAudioTurn] {
        transcript.segments.map { SpeakerAudioTurn(speaker: Transcript.canonicalSpeakerKey($0.speaker),
            range: .init(start: $0.start, end: $0.end), source: $0.resolvedAttribution.source == .unknown
                ? SpeakerAudioTurn.legacySource($0.speaker) : $0.resolvedAttribution.source) }
    }

    nonisolated static func recordingRevision(folder: URL, fallback: URL? = nil) throws -> String {
        let parts = try [MeetingAudioFiles.Track.mic, .system].compactMap { track -> String? in
            guard let url = MeetingAudioFiles.transcribableURL(for: track, in: folder) else { return nil }
            return "\(track.rawValue):\(try audioRevision(url: url))"
        }
        if parts.isEmpty, let fallback { return try audioRevision(url: fallback) }
        return parts.joined(separator: "|")
    }

    private func projection(_ state: MeetingSpeakerIdentityState, on transcript: Transcript) -> Transcript {
        var result = transcript
        let labels = Set(transcript.segments.map { Transcript.canonicalSpeakerKey($0.speaker) })
        for assignment in state.assignments where labels.contains(assignment.label) {
            result.setSpeakerAlias(assignment.name, for: assignment.label, calendarIdentityID: assignment.calendarIdentityID)
            if let isUser = assignment.isLocalUser {
                result.confirmSpeaker(assignment.label, isUser: isUser)
            } else if assignment.automaticDisabled {
                result.confirmSpeaker(assignment.label, isUser: nil)
            }
        }
        return result
    }

    private func rememberState(_ state: MeetingSpeakerIdentityState) {
        if state.revision >= (latestStates[state.meetingID]?.revision ?? -1) { latestStates[state.meetingID] = state }
    }

    nonisolated static func transcriptSignature(_ transcript: Transcript) -> String {
        let turns = transcript.segments.map { "\($0.start)|\($0.end)|\(Transcript.canonicalSpeakerKey($0.speaker))" }.joined(separator: "\n")
        return SHA256.hash(data: Data(turns.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Synchronous final projection immediately before the transcript write.
    /// An automatic task resumed after a human correction cannot overwrite it.
    func applyingLatestDecision(to transcript: Transcript, meetingID: UUID) -> Transcript {
        guard !unverifiedProcessing.contains(meetingID), let state = latestStates[meetingID],
              state.transcriptSignature == nil || state.transcriptSignature == Self.transcriptSignature(transcript) else { return transcript }
        return projection(state, on: transcript)
    }

    /// Recover an interrupted sidecar/transcript pair without applying a stale
    /// ordinal mapping to a different transcription.
    func recover(meeting: Meeting, transcript: Transcript) async throws -> Transcript {
        let saved = try await state(for: meeting)
        guard !saved.audioRevision.isEmpty else { return transcript }
        let folder = meeting.folderURL(in: storage)
        let currentAudio = try await Task.detached(priority: .utility) { try Self.recordingRevision(folder: folder) }.value
        guard currentAudio == saved.audioRevision else { return transcript }
        let currentTurns = timeline(transcript)
        let remapped = SpeakerIdentityResolver.remap(saved.assignments, turns: currentTurns, audioRevision: saved.audioRevision)
        var recovery = saved
        recovery.assignments = remapped
        return projection(recovery, on: transcript)
    }

    func process(transcript: Transcript, meeting: Meeting, turns: [SpeakerAudioTurn], samples: [SpeakerVoiceSample], audioURL: URL) async -> Transcript {
        unverifiedProcessing.insert(meeting.id)
        let config = settings()
        do {
            let store = try store()
            if sealing.removeValue(forKey: meeting.id) != nil {
                for _ in 0..<20 {
                    if await !store.isCollecting(meetingID: meeting.id) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let folder = meeting.folderURL(in: storage)
            let audioRevision = try await Task.detached(priority: .utility) { try Self.recordingRevision(folder: folder, fallback: audioURL) }.value
            let usableTurns = timeline(transcript)
            // ASR spans are not independent acoustic observations. Only the
            // supplied diarization turns may support automatic visual naming.
            let remoteTurns = turns.filter { $0.resolvedSource == .system }
            var (evidence, evidenceRevision) = try await store.matchingInput(meeting: meeting, retentionDays: config.retentionDays)
            var visual = config.identifySpeakersFromVisuals
                ? VisualSpeakerMatcher.matches(turns: remoteTurns, intervals: evidence?.intervals ?? []) : [:]
            var remembered = config.rememberSpeakersOnMac && settings().rememberSpeakersOnMac
            var database = remembered ? try await store.profiles() : SpeakerVoiceProfileDatabase()
            let microphoneSelection = remembered
                ? await SpeakerMicrophoneEvidence.select(samples: samples, transcript: transcript, turns: turns, folder: folder)
                : SpeakerMicrophoneEvidence.Selection()
            var compatibleSamples = microphoneSelection.samples
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard !deleted.contains(meeting.id) else { return transcript }
                let previous = try await store.state(meeting: meeting)
                var next = previous
                next.assignments = SpeakerIdentityResolver.remap(previous.assignments, turns: usableTurns, audioRevision: audioRevision)
                next.audioRevision = audioRevision
                next.transcriptSignature = Self.transcriptSignature(transcript)
                next.timeline = usableTurns
                next.acousticTimeline = turns
                next.providerVerified = evidence?.providerVerified == true || previous.providerVerified
                next.microphoneSampleDiagnostics = settings().rememberSpeakersOnMac ? microphoneSelection.counts : nil
                next.voiceSamples = settings().rememberSpeakersOnMac ? Set(usableTurns.map(\.speaker)).sorted().prefix(60).flatMap {
                    SpeakerVoiceMatcher.eligible(compatibleSamples.filter { sample in
                        sample.source == .microphone || next.providerVerified
                    }, turns: turns, speaker: $0)
                } : []
                next.suggestions = [:]
                next.analyzedAt = Date()
                // Legacy aliases have human authority, but only use their old
                // turns to carry them across retranscription.
                if previous.revision == 0,
                   let old = try? JSONDecoder().decode(Transcript.self, from: Data(contentsOf: meeting.folderURL(in: storage).appendingPathComponent("transcript.json"))) {
                    let legacy = Set(old.segments.map { Transcript.canonicalSpeakerKey($0.speaker) }).map { label in
                        SpeakerIdentityAssignment(label: label, name: old.speakerAliases[label], calendarIdentityID: old.speakerCalendarIdentityIDs[label],
                            origin: old.speakerAliases[label] == nil ? .calendarAutomatic : .legacy,
                            audioRevision: audioRevision, anchors: timeline(old).filter { $0.speaker == label }.map(\.range))
                    }
                    next.assignments += SpeakerIdentityResolver.remap(legacy, turns: usableTurns, audioRevision: audioRevision)
                }
                let fallback = SpeakerAutoNamer.applyingAliases(to: transcript, participants: meeting.resolvedCalendarParticipantIdentities)
                for (label, speakerTurns) in Dictionary(grouping: usableTurns, by: \.speaker) {
                    if !next.assignments.contains(where: { $0.label == label }) {
                        next.assignments.append(SpeakerIdentityAssignment(label: label, origin: .calendarAutomatic,
                            audioRevision: audioRevision, anchors: VisualSpeakerMatcher.union(speakerTurns.map(\.range))))
                    }
                    guard let index = next.assignments.firstIndex(where: { $0.label == label }) else { continue }
                    next.assignments[index].source = speakerTurns.first?.resolvedSource
                    var candidates = settings().identifySpeakersFromVisuals ? visual[label, default: []] : []
                    if remembered, settings().rememberSpeakersOnMac,
                       next.providerVerified || speakerTurns.first?.resolvedSource == .microphone {
                        let eligible = SpeakerVoiceMatcher.eligible(next.voiceSamples, turns: usableTurns, speaker: label)
                        candidates += SpeakerVoiceMatcher.matches(samples: eligible, profiles: database.profiles)
                    }
                    next.suggestions[label] = SpeakerIdentityResolver.apply(candidates: candidates, to: &next.assignments[index], profiles: database.profiles)
                    // Calendar is a fallback only; reliable disagreement is reviewable.
                    if next.assignments[index].name == nil, !next.assignments[index].origin.isProtected,
                       !next.assignments[index].automaticDisabled, candidates.isEmpty,
                       let name = fallback.speakerAliases[label],
                       !next.assignments[index].suppressedNames.contains(ParticipantObservation.nameKey(name)) {
                        next.assignments[index].name = name
                        next.assignments[index].calendarIdentityID = fallback.speakerCalendarIdentityIDs[label]
                        next.assignments[index].origin = .calendarAutomatic
                    }
                }
                // Preserve detached decisions for manual reassignment when a merge
                // prevents a safe remap. They cannot project onto a current label.
                let retainedIDs = Set(next.assignments.map(\.id))
                for (id, prior) in Dictionary(grouping: previous.assignments.filter { $0.origin.isProtected }, by: \.id)
                where !retainedIDs.contains(id) {
                    guard var item = prior.first else { continue }
                    item.anchors = VisualSpeakerMatcher.union(prior.flatMap(\.anchors))
                    item.label = "unresolved-" + item.id.uuidString
                    next.assignments.append(item)
                }
                do {
                    let committed = try await store.commit(next, meeting: meeting, expectedRevision: previous.revision,
                        expectedProfileRevision: remembered ? database.revision : nil, expectedEvidenceRevision: evidenceRevision)
                    // The pipeline reapplies this cache synchronously before writing.
                    rememberState(committed)
                    unverifiedProcessing.remove(meeting.id)
                    let microphoneReasons = (committed.microphoneSampleDiagnostics ?? [:]).sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                    lokalbotLog("speaker identity processed speakers=\(committed.assignments.count) "
                        + "named=\(committed.assignments.filter { $0.name != nil }.count) "
                        + "suggestions=\(committed.suggestions.values.reduce(0) { $0 + $1.count }) microphone=\(microphoneReasons)")
                    revision += 1
                    return applyingLatestDecision(to: transcript, meetingID: meeting.id)
                } catch MeetingSpeakerEvidenceStore.Failure.evidenceExpired {
                    // Keep durable human choices and historical aliases when a
                    // deletion races processing, but discard all pending evidence.
                    evidence = nil
                    visual = [:]
                    compatibleSamples = []
                    remembered = false
                    evidenceRevision = try await store.state(meeting: meeting).evidenceRevision
                    continue
                } catch MeetingSpeakerEvidenceStore.Failure.stale {
                    if remembered && settings().rememberSpeakersOnMac { database = try await store.profiles() }
                    continue
                }
            }
            notice = "Speaker names changed during processing. Reopen this meeting to review them."
        } catch {
            notice = "Speaker identification unavailable: \(error.localizedDescription)"
        }
        return transcript // Identity errors never fail audio transcription.
    }

    struct Choice {
        var id = UUID()
        var label: String
        var name: String?
        var calendarIdentityID: String?
        var action: SpeakerAliasDecision.Action = .assign
        var remember = false
        var profileID: UUID?
        var expectedRevision: Int?
    }

    func choose(_ choice: Choice, meeting: Meeting, transcript: Transcript) async throws -> Transcript {
        let store = try store()
        var current = try await store.state(meeting: meeting)
        if let signature = current.transcriptSignature, signature != Self.transcriptSignature(transcript) {
            throw MeetingSpeakerEvidenceStore.Failure.stale
        }
        if current.decisions.contains(where: { $0.id == choice.id }) {
            rememberState(current)
            return projection(current, on: transcript)
        }
        if let expected = choice.expectedRevision, expected != current.revision { throw MeetingSpeakerEvidenceStore.Failure.stale }
        current.transcriptSignature = Self.transcriptSignature(transcript)
        let label = Transcript.canonicalSpeakerKey(choice.label)
        if current.audioRevision.isEmpty {
            let folder = meeting.folderURL(in: storage)
            current.audioRevision = try await Task.detached(priority: .utility) { try Self.recordingRevision(folder: folder) }.value
        }
        if current.timeline.isEmpty { current.timeline = timeline(transcript) }
        let original = current.assignments.first { $0.label == label }
        var assignment = original ?? SpeakerIdentityAssignment(label: label, origin: .legacy,
            audioRevision: current.audioRevision, anchors: current.timeline.filter { $0.speaker == label }.map(\.range))
        assignment.source = current.timeline.first { $0.speaker == label }?.resolvedSource
        if choice.action.confirmsIdentity || (choice.action == .assign && choice.profileID != nil),
           !transcript.canConfirmSpeaker(label) {
            throw IdentityError.unseparatedAudio
        }
        let enrollmentSpeakerID = assignment.id
        let rejected = choice.action == .dismiss ? choice.name : assignment.name ?? transcript.speakerAliases[label]
        if let rejected, choice.action != .assign || choice.name != rejected {
            let key = ParticipantObservation.nameKey(rejected)
            if !assignment.suppressedNames.contains(key) { assignment.suppressedNames.append(key) }
        }
        switch choice.action {
        case .assign, .confirmUser, .confirmOther:
            assignment.name = choice.name.flatMap(ParticipantObservation.safeName)
            assignment.calendarIdentityID = choice.calendarIdentityID
            assignment.origin = original?.name == nil ? .userConfirmed : .userCorrected
            assignment.automaticDisabled = false
            if choice.action.confirmsIdentity {
                assignment.isLocalUser = choice.action == .confirmUser
                if assignment.name == nil { assignment.name = choice.action == .confirmUser ? "Me" : transcript.displaySpeaker(for: label) }
            } else if let profileID = choice.profileID {
                // Choosing a suggested profile is an explicit confirmation of
                // that person, including a previously confirmed local user.
                let profiles = try await store.profiles().profiles
                guard let profile = profiles.first(where: { $0.id == profileID }),
                      profile.confirmedNames.contains(where: {
                          ParticipantObservation.nameKey($0) == ParticipantObservation.nameKey(choice.name ?? "")
                      }) else { throw MeetingSpeakerEvidenceStore.Failure.stale }
                assignment.isLocalUser = profile.isLocalUser
            }
        case .reset, .undo:
            assignment.name = nil
            assignment.calendarIdentityID = nil
            assignment.origin = .userCorrected
            assignment.automaticDisabled = true
            assignment.isLocalUser = nil
        case .resume:
            assignment.automaticDisabled = false
            assignment.origin = .calendarAutomatic
            assignment.suppressedNames = []
        case .dismiss:
            if !assignment.origin.isProtected, choice.name == assignment.name {
                assignment.name = nil
                assignment.calendarIdentityID = nil
                assignment.match = nil
                assignment.supportingMatches = nil
            }
        }
        if choice.action != .dismiss {
            assignment.match = nil
            assignment.supportingMatches = nil
            assignment.profileID = nil
        }
        if current.assignments.contains(where: {
            $0.id == assignment.id && $0.label != label
                && ($0.name != assignment.name || $0.automaticDisabled != assignment.automaticDisabled
                    || $0.isLocalUser != assignment.isLocalUser)
        }) {
            // A human distinguished two labels previously inferred to be a
            // clean split. Preserve that distinction on subsequent remapping.
            assignment.id = UUID()
        }
        if choice.action == .resume {
            let evidence = try await store.evidence(meeting: meeting, retentionDays: settings().retentionDays)
            let acousticTurns = current.acousticTimeline ?? []
            let remoteTurns = acousticTurns.filter { $0.resolvedSource == .system }
            var candidates = settings().identifySpeakersFromVisuals
                ? VisualSpeakerMatcher.matches(turns: remoteTurns, intervals: evidence?.intervals ?? [])[label, default: []] : []
            let profiles = settings().rememberSpeakersOnMac ? try await store.profiles().profiles : []
            if settings().rememberSpeakersOnMac, current.providerVerified || assignment.source == .microphone {
                candidates += SpeakerVoiceMatcher.matches(samples: SpeakerVoiceMatcher.eligible(current.voiceSamples, turns: acousticTurns, speaker: label), profiles: profiles)
            }
            current.suggestions[label] = SpeakerIdentityResolver.apply(candidates: candidates, to: &assignment, profiles: profiles)
        }
        let decision = SpeakerAliasDecision(id: choice.id, speakerID: assignment.id, action: choice.action,
            sourceRevision: current.audioRevision, name: choice.name)
        // Revoke an old confirmation before recording a correction. A failure
        // leaves a visible pending state instead of training on the wrong person.
        if choice.action != .dismiss && FileManager.default.fileExists(atPath: storage.rootURL.appendingPathComponent("speaker-profiles/profiles.sealed").path) {
            try await store.revoke(meetingID: meeting.id, speakerID: enrollmentSpeakerID)
        }
        current.assignments.removeAll { $0.label == label }
        current.assignments.append(assignment)
        current.decisions.append(decision)
        current.suggestions[label] = current.suggestions[label]?.filter {
            !assignment.suppressedNames.contains(ParticipantObservation.nameKey($0.name))
        }
        let committed = try await store.commit(current, meeting: meeting, expectedRevision: current.revision)
        rememberState(committed)
        unverifiedProcessing.remove(meeting.id)
        notice = nil
        if choice.action == .assign || choice.action.confirmsIdentity,
           choice.remember, settings().rememberSpeakersOnMac,
           committed.providerVerified || assignment.source == .microphone {
            let samples = SpeakerVoiceMatcher.eligible(committed.voiceSamples, turns: committed.timeline, speaker: label)
            if SpeakerVoiceMatcher.canEnroll(samples) {
                do {
                    let database = try await store.profiles()
                    guard settings().rememberSpeakersOnMac else { return projection(committed, on: transcript) }
                    _ = try await store.enroll(meeting: meeting, assignment: assignment, decision: decision,
                        samples: samples, profileID: choice.profileID, expectedDatabaseRevision: database.revision)
                } catch { notice = "Meeting name saved. Voice profile update pending: \(error.localizedDescription)" }
            } else {
                notice = "Meeting name saved. Remembering this voice needs three separate clear turns totaling 15 seconds."
            }
        } else if choice.remember, choice.action == .assign {
            notice = "Meeting name saved. This recording does not have verified Meet voice material for remembering."
        }
        revision += 1
        // Another correction could arrive while enrollment was suspended.
        let latest = try await store.state(meeting: meeting)
        rememberState(latest)
        return applyingLatestDecision(to: transcript, meetingID: meeting.id)
    }

    func maintainRetention(meetings: @escaping @MainActor () -> [Meeting]) {
        guard retentionTask == nil else { return }
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.expire(meetings: meetings())
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    func expire(meetings: [Meeting]) async {
        guard meetings.contains(where: {
            FileManager.default.fileExists(atPath: $0.folderURL(in: storage).appendingPathComponent("speaker-evidence").path)
        }) else { return }
        do { try await store().expire(meetings: meetings, retentionDays: settings().retentionDays) } catch { notice = "Speaker evidence cleanup pending: \(error.localizedDescription)" }
    }

    func deleteEvidence(meeting: Meeting) async throws {
        try await store().eraseEvidence(meeting: meeting)
        revision += 1
    }

    func prepareDeletion(meeting: Meeting) async throws {
        deleted.insert(meeting.id)
        if cachedStore != nil || FileManager.default.fileExists(atPath: storage.rootURL.appendingPathComponent("speaker-profiles/profiles.sealed").path) {
            try await store().revoke(meetingID: meeting.id, deletingMeeting: true)
        }
    }

    func profiles(managing: Bool = false) async throws -> [SpeakerVoiceProfile] {
        guard managing || settings().rememberSpeakersOnMac else { return [] }
        return try await store().profiles().profiles
    }
    func forgetProfile(_ id: UUID?) async throws { try await store().forgetProfile(id); revision += 1 }
    func renameProfile(_ id: UUID, name: String) async throws { try await store().renameProfile(id, name: name); revision += 1 }
}
