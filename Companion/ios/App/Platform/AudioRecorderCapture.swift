import AVFoundation
import LokalBotCompanionKit
import os

/// The microphone, through `AVAudioRecorder`. The `.aac` extension makes it
/// write an ADTS stream, whose frames each carry a header, so the file is
/// readable however recording ends. It keeps recording with the screen locked
/// or the app in the background (the `audio` background mode).
@MainActor
final class AudioRecorderCapture: NSObject, AudioCapture {
    var onEvent: ((AudioCaptureEvent) -> Void)?

    private var recorder: AVAudioRecorder?
    private var observers: [NSObjectProtocol] = []

    /// Speech at this rate gives the same AAC quality the Mac records, at
    /// about 29 MB an hour.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        // -50 dB and below reads as silence.
        return max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else {
            try? session.setActive(false)
            throw RecorderError.wontStart
        }
        self.recorder = recorder
        observe(session)
    }

    func resume() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        guard recorder?.record() == true else { throw RecorderError.wontStart }
    }

    func stop() -> TimeInterval {
        let duration = currentTime
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:))
                MainActor.assumeIsolated { self?.interruption(type, shouldResume: options?.contains(.shouldResume) == true) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.failed) }
            },
        ]
    }

    /// The recorder pauses itself when interrupted. When it's allowed to, it
    /// carries on by itself; otherwise the person resumes from the screen.
    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            onEvent?(.interrupted)
        case .ended:
            if shouldResume, (try? resume()) != nil { onEvent?(.resumed) }
        default:
            break
        }
    }

    private enum RecorderError: LocalizedError {
        case wontStart

        var errorDescription: String? {
            "The microphone can't record right now. Another app may be using it."
        }
    }
}

extension AudioRecorderCapture: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Only `stop()` ends recording on purpose, and that clears the delegate.
        Task { @MainActor [weak self] in self?.onEvent?(.failed) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.onEvent?(.failed) }
    }
}
