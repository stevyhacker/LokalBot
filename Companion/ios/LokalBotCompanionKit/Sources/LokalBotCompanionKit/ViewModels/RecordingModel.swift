import Foundation
import Observation

/// What the recording screen needs from the device's microphone. The app's
/// implementation wraps `AVAudioRecorder`, writing ADTS AAC straight to `url`,
/// so whatever has been written stays readable if the app dies.
@MainActor
public protocol AudioCapture: AnyObject {
    var onEvent: ((AudioCaptureEvent) -> Void)? { get set }
    /// Seconds recorded so far, not counting interruptions.
    var currentTime: TimeInterval { get }
    /// Input level from 0 to 1.
    var level: Float { get }

    func requestPermission() async -> Bool
    func start(url: URL) throws
    /// Picks up after an interruption.
    func resume() throws
    /// Returns the seconds recorded. The file is complete afterwards.
    func stop() -> TimeInterval
}

public enum AudioCaptureEvent: Sendable, Equatable {
    /// A phone call or another app took the microphone; recording is paused.
    case interrupted
    case resumed
    /// The recorder can't go on. What it wrote is still good.
    case failed
}

/// One recording from the button to the queue: asks for the microphone, runs
/// the recorder, and hands the finished file to the store to send. It lives as
/// long as the app, so recording carries on whatever the screens do.
@MainActor @Observable
public final class RecordingModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        /// Paused by a call or another app; `resume()` carries on.
        case interrupted
    }

    public private(set) var phase = Phase.idle
    public var isPresented = false
    /// The microphone permission was refused, so Settings is the only way on.
    public private(set) var microphoneDenied = false
    public var errorMessage: String?
    public var title = ""

    /// A call or another app took the microphone. The app says so if nobody
    /// is looking, because recording may not carry on by itself.
    public var onInterrupted: () -> Void = {}
    /// The microphone is back and recording again.
    public var onResumed: () -> Void = {}

    private let session: CompanionSession
    private let capture: AudioCapture
    private var currentID: String?
    private var isStarting = false

    public init(session: CompanionSession, capture: AudioCapture) {
        self.session = session
        self.capture = capture
        capture.onEvent = { [weak self] event in self?.handle(event) }
    }

    public var isActive: Bool { phase != .idle }
    public var elapsed: TimeInterval { capture.currentTime }
    public var level: Float { capture.level }

    /// Opens the screen, recording at once unless the microphone is refused.
    public func begin() async {
        isPresented = true
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil
        microphoneDenied = false
        guard await capture.requestPermission() else {
            microphoneDenied = true
            return
        }
        do {
            let item = try await session.store.beginRecording(title: nil)
            do {
                try capture.start(url: URL(fileURLWithPath: item.filePath))
            } catch {
                try? await session.store.discardRecording(id: item.id)
                throw error
            }
            title = ""
            currentID = item.id
            phase = .recording
            await session.recordingsDidChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps the recording and sends it when the Mac can be reached.
    public func stop() async {
        guard let id = currentID else {
            isPresented = false
            return
        }
        let duration = capture.stop()
        currentID = nil
        phase = .idle
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { try? await session.store.setRecordingTitle(id: id, title: name) }
        do {
            _ = try await session.store.finishRecording(id: id, durationSeconds: duration)
            isPresented = false
            await session.recordingsDidChange()
            await session.uploadRecordings()
        } catch {
            errorMessage = error.localizedDescription
            await session.recordingsDidChange()
        }
    }

    public func discard() async {
        if let id = currentID {
            _ = capture.stop()
            currentID = nil
            phase = .idle
            await session.discardRecording(id: id)
        }
        isPresented = false
    }

    public func resume() {
        guard phase == .interrupted else { return }
        do {
            try capture.resume()
            phase = .recording
            onResumed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// There's no Mac to send to any more. What was recorded stays if the Mac
    /// removed this device, ready for when it pairs again, and removing the
    /// device from here has already erased it, which makes this a no-op.
    public func sessionModeChanged() {
        guard session.mode != .paired, let id = currentID else { return }
        let duration = capture.stop()
        currentID = nil
        phase = .idle
        isPresented = false
        Task {
            _ = try? await session.store.finishRecording(id: id, durationSeconds: duration)
            await session.recordingsDidChange()
        }
    }

    private func handle(_ event: AudioCaptureEvent) {
        guard currentID != nil else { return }
        switch event {
        case .interrupted:
            phase = .interrupted
            onInterrupted()
        case .resumed:
            phase = .recording
            onResumed()
        case .failed:
            errorMessage = "Recording stopped because the microphone stopped working. What was recorded is saved."
            Task { await stopAfterFailure() }
        }
    }

    /// Stays on the screen so the message is seen.
    private func stopAfterFailure() async {
        let message = errorMessage
        await stop()
        isPresented = message != nil
        errorMessage = message
    }
}
