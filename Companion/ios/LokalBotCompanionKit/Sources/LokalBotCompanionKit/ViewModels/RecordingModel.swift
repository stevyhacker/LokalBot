import Foundation
import Observation

@MainActor
public protocol AudioCapture: AnyObject {
    var onEvent: ((AudioCaptureEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    var level: Float { get }

    func requestPermission() async -> Bool
    func start(url: URL) throws
    func resume() throws
    func stop() -> TimeInterval
}

public enum AudioCaptureEvent: Sendable, Equatable {
    case interrupted
    case resumed
    case failed
}

@MainActor @Observable
public final class RecordingModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        case interrupted
    }

    public private(set) var phase = Phase.idle
    public var isPresented = false
    public private(set) var microphoneDenied = false
    public var errorMessage: String?
    public var title = ""

    public var onInterrupted: () -> Void = {}
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

    private func stopAfterFailure() async {
        let message = errorMessage
        await stop()
        isPresented = message != nil
        errorMessage = message
    }
}
