import Foundation

/// One session-owned attachment loop. A bounded fast retry burst becomes a
/// low-frequency wait, never a permanent microphone-only failure.
@MainActor
final class MeetingAudioRecovery {
    typealias Candidate = MeetingDetector.DetectedApp
    private(set) var recordingID: UUID?
    private(set) var attempts = 0
    private(set) var intent: Meeting.CaptureIntent?
    private var task: Task<Void, Never>?
    private var attach: ((Candidate) -> Bool)?

    static func retryDelay(attempt: Int) -> TimeInterval {
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]
        return delays.indices.contains(attempt) ? delays[attempt] : 30
    }

    func start(recordingID: UUID, intent: Meeting.CaptureIntent,
               find: @escaping (Meeting.CaptureIntent) -> Candidate?,
               attach: @escaping (Candidate) -> Bool,
               sleep: @escaping (TimeInterval) async throws -> Void = {
                   try await Task.sleep(for: .seconds($0))
               }) {
        cancel()
        guard intent.systemAudioRequested else { return }
        self.recordingID = recordingID
        attempts = 0
        self.intent = intent
        self.attach = attach
        task = Task { [weak self] in
            while let self, self.recordingID == recordingID, !Task.isCancelled {
                do { try await sleep(Self.retryDelay(attempt: self.attempts)) } catch { return }
                guard self.recordingID == recordingID, !Task.isCancelled,
                      let intent = self.intent else { return }
                self.attempts += 1
                if let candidate = find(intent), self.offer(candidate, recordingID: recordingID) { return }
            }
        }
    }

    /// Detector/device events can wake recovery immediately, including after
    /// the initial burst. A stale generation or a different call cannot attach.
    @discardableResult
    func offer(_ app: Candidate, recordingID: UUID) -> Bool {
        guard self.recordingID == recordingID,
              intent?.accepts(appBundleID: app.bundleID, meetingURL: app.meetingURL) == true,
              attach?(app) == true else { return false }
        cancel()
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        recordingID = nil
        intent = nil
        attach = nil
    }
}

struct RecordingHealthReport: Codable {
    static let fileName = "recording-health.json"
    struct Event: Codable {
        var seconds: TimeInterval
        var messages: [String]
    }
    var version = 1
    var lastVerifiedCallAt: Date?
    var completedAt: Date?
    var events: [Event] = []
    var microphoneDroppedBuffers = 0
    var systemDroppedBuffers = 0
    var attachmentAttempts = 0
    var hadMissingAudio: Bool?
    var hadWriteFailure: Bool?

    /// Drops below this are isolated callbacks (about 10–90 ms each) that no
    /// listener would notice. A single one flagged a complete 33-minute
    /// recording as "interrupted" on 2026-10-01.
    static let noticeableDroppedBuffers = 5

    static func dropsAreNoticeable(microphone: Int, system: Int) -> Bool {
        microphone >= noticeableDroppedBuffers || system >= noticeableDroppedBuffers
    }

    var hasCaptureIssues: Bool {
        hadMissingAudio == true || hadWriteFailure == true
            || Self.dropsAreNoticeable(microphone: microphoneDroppedBuffers, system: systemDroppedBuffers)
    }

    static func load(in folder: URL) -> Self? {
        (try? Data(contentsOf: folder.appendingPathComponent(fileName)))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    mutating func observe(_ messages: [String], seconds: TimeInterval) -> Bool {
        guard events.last?.messages != messages else { return false }
        // Keep the incident history bounded, preserving the first failure.
        if events.count >= 1_000 { events.remove(at: 1) }
        events.append(Event(seconds: max(0, seconds), messages: messages))
        return true
    }
}

/// When a live capture warning also becomes a macOS notification. The meeting
/// view shows every warning as it happens; a notification interrupts the call
/// itself, so it is kept for conditions that lasted long enough to matter.
/// On 2026-10-01 a 1.9-second accessibility hiccup and one dropped buffer each
/// raised "Recording needs attention" mid-meeting.
struct CaptureWarningNotifications {
    static let droppedBuffersWarning = "Audio buffers were dropped while saving. Some audio may be missing."
    static let callStatusUnavailableWarning = "Call status is unavailable. Recording continues; use Stop when finished."
    /// Audio that stops arriving must persist this long before it notifies.
    static let sustainedAudioWarningDelay: TimeInterval = 15

    private var firstSeen: [String: TimeInterval] = [:]
    private var notified: Set<String> = []

    /// Seconds a warning must persist before it notifies; nil never notifies.
    static func delay(for message: String) -> TimeInterval? {
        if message == droppedBuffersWarning { return nil }
        // The detector itself waits this long before it treats a lost call
        // as anything but a hiccup.
        if message == callStatusUnavailableWarning { return MeetingDetector.browserObservationGrace }
        if message.hasPrefix("Disk space is low") || message.contains("saving needs attention")
            || message.hasPrefix("Recording health could not be saved") {
            return 0
        }
        return sustainedAudioWarningDelay
    }

    /// Warnings due for a notification now, each at most once per recording.
    mutating func due(_ messages: [String], elapsed: TimeInterval) -> [String] {
        let current = Set(messages)
        firstSeen = firstSeen.filter { current.contains($0.key) }
        var due: [String] = []
        for message in messages {
            let since = firstSeen[message] ?? elapsed
            firstSeen[message] = since
            guard let delay = Self.delay(for: message), elapsed - since >= delay,
                  notified.insert(message).inserted else { continue }
            due.append(message)
        }
        return due
    }
}
