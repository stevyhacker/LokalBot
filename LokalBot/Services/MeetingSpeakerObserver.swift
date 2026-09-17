import Foundation

/// Consecutive observations establish coverage. Never extend the last active
/// participant through source loss, overload, sleep, a layout change, or stop.
struct SpeakerObservationAccumulator {
    private var previous: (source: String, observation: ParticipantObservation)?
    mutating func gap() { previous = nil }
    mutating func consume(_ batch: MeetingSpeakerObservationBatch, clock: RecordingAudioClock) -> SpeakerActivityInterval? {
        let active = batch.observations.filter { $0.active && !$0.isSelf }
        guard batch.reason == nil, !batch.sourceKey.isEmpty, active.count == 1, let item = active.first,
              !item.muted, item.unique, ParticipantObservation.safeName(item.displayName) != nil else { gap(); return nil }
        defer { previous = (batch.sourceKey, item) }
        guard let last = previous, last.source == batch.sourceKey,
              last.observation.reference == item.reference, last.observation.layoutEpoch == item.layoutEpoch,
              item.hostStart > last.observation.hostEnd,
              item.hostEnd - last.observation.hostStart <= 0.85,
              let range = clock.map(hostStart: last.observation.hostEnd, hostEnd: item.hostStart) else { return nil }
        return SpeakerActivityInterval(participantReference: item.reference, displayName: item.displayName,
            range: range, uncertainty: 0.25 + max(item.hostEnd - item.hostStart, last.observation.hostEnd - last.observation.hostStart) / 2,
            layoutEpoch: item.layoutEpoch)
    }
}

@MainActor final class MeetingSpeakerObserver: ObservableObject {
    enum State: Equatable { case off, observing, paused(String), unavailable(String) }
    @Published private(set) var state: State = .off
    @Published var isPaused = false { didSet { coverageRevision += 1 } }
    private let identity: MeetingSpeakerIdentityService
    private let settings: () -> AppSettings
    private let capturePaused: () -> Bool
    private let providerFactory: @MainActor () -> any MeetingSpeakerObservationProvider
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var coverageRevision = 0
    private var rejectedGenerations = Set<UUID>()

    init(identity: MeetingSpeakerIdentityService, settings: @escaping () -> AppSettings,
         capturePaused: @escaping () -> Bool = { false },
         providerFactory: @escaping @MainActor () -> any MeetingSpeakerObservationProvider = { GoogleMeetSpeakerObservationProvider() }) {
        self.identity = identity
        self.settings = settings
        self.capturePaused = capturePaused
        self.providerFactory = providerFactory
    }

    func start(meeting: Meeting, clock: RecordingAudioClock, capturedBundleID: String) {
        stop()
        guard settings().identifySpeakersFromVisuals || settings().rememberSpeakersOnMac else { return }
        let token = UUID()
        generation = token
        isPaused = false
        let provider = providerFactory()
        task = Task { [weak self, identity] in
            guard let self else { return }
            guard generation == token, !Task.isCancelled,
                  settings().identifySpeakersFromVisuals || settings().rememberSpeakersOnMac else { return }
            var accumulator = SpeakerObservationAccumulator()
            var buffer: [SpeakerActivityInterval] = []
            var verified = false
            var failed = false
            var diagnostics = SpeakerObservationDiagnostics()
            var lastDiagnosticsWrite: ContinuousClock.Instant?
            var lastSavedIssue: SpeakerObservationIssue?
            do {
                let store = try identity.store()
                try await store.begin(.init(meetingID: meeting.id, generation: token), meeting: meeting)
                while !Task.isCancelled && generation == token {
                    let cycleStart = ContinuousClock.now
                    let config = settings()
                    guard config.identifySpeakersFromVisuals || config.rememberSpeakersOnMac else { break }
                    if isPaused || capturePaused() {
                        accumulator.gap()
                        state = .paused("Speaker observation paused")
                        diagnostics.record(.paused)
                        await provider.stop()
                    } else {
                        let coverage = coverageRevision
                        let batch = await provider.observe(config: config, expectedMeetingURL: meeting.meetingURL,
                            capturedBundleID: capturedBundleID, visual: config.identifySpeakersFromVisuals)
                        guard !Task.isCancelled, generation == token else { break }
                        // A setting change while capture was in flight revokes its result.
                        guard settings().identifySpeakersFromVisuals == config.identifySpeakersFromVisuals,
                              settings().rememberSpeakersOnMac == config.rememberSpeakersOnMac,
                              settings().excludedScreenDomains == config.excludedScreenDomains,
                              settings().excludedApps == config.excludedApps, coverage == coverageRevision, !isPaused, !capturePaused() else {
                            accumulator.gap(); diagnostics.record(.settingsChanged); continue
                        }
                        if !batch.sourceKey.isEmpty && !verified {
                            try await store.verifyProvider(meeting: meeting, generation: token)
                            verified = true
                        }
                        if let reason = batch.reason { state = .paused(reason) } else { state = .observing }
                        let interval = config.identifySpeakersFromVisuals ? accumulator.consume(batch, clock: clock) : nil
                        diagnostics.record(batch, interval: interval, visual: config.identifySpeakersFromVisuals)
                        if let interval {
                            if let last = buffer.last, last.participantReference == interval.participantReference,
                               last.layoutEpoch == interval.layoutEpoch, interval.range.start - last.range.end < 0.25 {
                                buffer[buffer.count - 1].range.end = interval.range.end
                                buffer[buffer.count - 1].uncertainty = max(last.uncertainty, interval.uncertainty)
                            } else { buffer.append(interval) }
                        }
                        if buffer.count >= 64 || (buffer.first.map { (buffer.last?.range.end ?? 0) - $0.range.start >= 30 } ?? false) {
                            try await store.append(buffer, meeting: meeting, generation: token, clockSpans: clock.snapshot())
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    // Persist failure-only sessions too. Throttle changes to
                    // avoid disk churn, and checkpoint unchanged counters every 30s.
                    let sinceWrite = lastDiagnosticsWrite?.duration(to: .now)
                    if sinceWrite == nil || sinceWrite! >= .seconds(30)
                        || (diagnostics.lastIssue != lastSavedIssue && sinceWrite! >= .seconds(5)) {
                        try await store.recordDiagnostics(diagnostics, meeting: meeting, generation: token)
                        lastDiagnosticsWrite = .now
                        lastSavedIssue = diagnostics.lastIssue
                    }
                    let elapsed = cycleStart.duration(to: .now)
                    if elapsed < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(500) - elapsed) }
                }
                // No positive evidence after cancellation. Only already mapped
                // intervals from this generation are flushed.
                try await store.append(buffer, meeting: meeting, generation: token, clockSpans: clock.snapshot())
                try await store.recordDiagnostics(diagnostics, meeting: meeting, generation: token)
                try await store.seal(meeting: meeting, generation: token, failed: rejectedGenerations.contains(token))
            } catch {
                failed = true
                diagnostics.record(.evidenceUnavailable)
                try? await identity.store().seal(meeting: meeting, generation: token, failed: true)
            }
            await provider.stop()
            let reasons = diagnostics.issues.keys.sorted().map { "\($0)=\(diagnostics.issues[$0, default: 0])" }.joined(separator: ",")
            lokalbotLog("speaker observation finished batches=\(diagnostics.observations) intervals=\(diagnostics.intervals) "
                + "coverage=\(Int(diagnostics.coveredSeconds))s failed=\(failed) usableEvidence=\(diagnostics.intervals > 0) reasons=\(reasons)")
            rejectedGenerations.remove(token)
            if generation == token {
                state = failed ? .unavailable("Speaker evidence unavailable; audio recording continues") : .off
            }
        }
        if let task { identity.finalize(meetingID: meeting.id, task: task) }
    }

    func stop() {
        generation = nil
        task?.cancel()
        task = nil
        state = .off
    }

    func rejectChangedAudioSource() {
        if let generation { rejectedGenerations.insert(generation) }
        stop()
        state = .unavailable("Meeting audio source changed; speaker identification stopped")
    }
}
