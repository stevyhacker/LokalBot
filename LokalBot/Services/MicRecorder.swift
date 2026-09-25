import AVFoundation

struct AudioRecoverySilencePlan: Equatable {
    let duration: TimeInterval
}

enum AudioRecoverySilencePlanner {
    static let minimumDuration: TimeInterval = 0.2
    static func plan(forElapsed elapsed: TimeInterval) -> AudioRecoverySilencePlan? {
        guard elapsed.isFinite, elapsed >= minimumDuration else { return nil }
        return AudioRecoverySilencePlan(duration: elapsed)
    }

    static func plan(forElapsed elapsed: Duration) -> AudioRecoverySilencePlan? {
        let components = elapsed.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return plan(forElapsed: seconds)
    }
}

/// Gates recovery-gap silence until a rebuilt capture graph delivers audio.
/// Starting an engine is not enough evidence: a graph can report success and
/// still never produce a buffer. Keeping this state separate also makes failed
/// retry behavior testable without requiring microphone hardware.
struct AudioRecoverySilenceCommitGate: Equatable {
    private(set) var isPending = false

    mutating func stage() {
        isPending = true
    }

    mutating func cancel() {
        isPending = false
    }

    mutating func consumeAfterCapturedBuffer(
        forElapsed elapsed: TimeInterval
    ) -> AudioRecoverySilencePlan? {
        guard isPending else { return nil }
        isPending = false
        return AudioRecoverySilencePlanner.plan(forElapsed: elapsed)
    }

    mutating func consumeAfterCapturedBuffer(
        forElapsed elapsed: Duration
    ) -> AudioRecoverySilencePlan? {
        guard isPending else { return nil }
        isPending = false
        return AudioRecoverySilencePlanner.plan(forElapsed: elapsed)
    }
}

final class MicAudioBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let frameCapacity: AVAudioFrameCount
    private var buffers: [AVAudioPCMBuffer]

    init?(
        format: AVAudioFormat,
        bufferCount: Int,
        frameCapacity: AVAudioFrameCount
    ) {
        guard bufferCount > 0, frameCapacity > 0 else { return nil }
        var prepared: [AVAudioPCMBuffer] = []
        prepared.reserveCapacity(bufferCount)
        for _ in 0..<bufferCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else { return nil }
            prepared.append(buffer)
        }
        self.format = format
        self.frameCapacity = frameCapacity
        buffers = prepared
    }

    func borrow(for source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength <= frameCapacity,
              isCompatible(with: source.format),
              lock.try() else { return nil }
        defer { lock.unlock() }
        guard let buffer = buffers.popLast() else { return nil }
        buffer.frameLength = source.frameLength
        return buffer
    }

    func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    var availableBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    func isCompatible(with candidate: AVAudioFormat) -> Bool {
        Self.formatsCompatible(candidate, format)
    }

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

/// Atomically routes real-time tap buffers to a pool matching the format Core
/// Audio actually negotiated. A `format: nil` tap is required during device
/// changes because `outputFormat(forBus:)` can be stale; this broker lets the
/// first mismatched callback request an off-thread pool rebuild instead of
/// silently dropping every subsequent buffer.
final class MicAudioBufferPoolBroker: @unchecked Sendable {
    enum BorrowResult {
        case borrowed(buffer: AVAudioPCMBuffer, pool: MicAudioBufferPool)
        case refreshNeeded(AVAudioFormat)
        case unavailable
    }

    private let lock = NSLock()
    private let bufferCount: Int
    private let frameCapacity: AVAudioFrameCount
    private var pool: MicAudioBufferPool?
    private var refreshPending = false

    init(bufferCount: Int, frameCapacity: AVAudioFrameCount) {
        self.bufferCount = bufferCount
        self.frameCapacity = frameCapacity
    }

    @discardableResult
    func install(format: AVAudioFormat) -> Bool {
        guard let replacement = MicAudioBufferPool(
            format: format,
            bufferCount: bufferCount,
            frameCapacity: frameCapacity
        ) else { return false }
        lock.lock()
        pool = replacement
        refreshPending = false
        lock.unlock()
        return true
    }

    func borrow(for source: AVAudioPCMBuffer) -> BorrowResult {
        guard lock.try() else { return .unavailable }
        guard let pool else {
            let shouldRefresh = !refreshPending
            refreshPending = true
            lock.unlock()
            return shouldRefresh ? .refreshNeeded(source.format) : .unavailable
        }
        guard pool.isCompatible(with: source.format) else {
            let shouldRefresh = !refreshPending
            refreshPending = true
            lock.unlock()
            return shouldRefresh ? .refreshNeeded(source.format) : .unavailable
        }
        lock.unlock()
        guard let buffer = pool.borrow(for: source) else { return .unavailable }
        return .borrowed(buffer: buffer, pool: pool)
    }

    func clear() {
        lock.lock()
        pool = nil
        refreshPending = false
        lock.unlock()
    }
}

final class MicRealtimeDropCounter: @unchecked Sendable {
    private let lock: NSLock
    private var count = 0

    init(lock: NSLock = NSLock()) {
        self.lock = lock
    }

    @discardableResult
    func recordDrop() -> Bool {
        guard lock.try() else { return false }
        count += 1
        lock.unlock()
        return true
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

/// Records the default input device (your voice). Meeting recordings use AAC
/// `.m4a`; short-lived dictation scratch files can use PCM `.caf` to avoid
/// AAC container startup failures on some devices.
/// This is the "Me" track — kept separate from system audio on purpose
/// so M2 gets speaker attribution for free (design doc §2.2).
final class MicRecorder {

    // Recreated per session — a reused engine can hold a stale graph after
    // device changes and then fails with kAudioDeviceUnsupportedFormat ('!dev').
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var previewTee: AudioPreviewTee?
    private var recordingFormat: AVAudioFormat?
    /// Accessed only on `ioQueue`. Nil for standalone dictation capture.
    private var timeline: RecordingAudioTimeline?
    /// Accessed only on `ioQueue`.
    private var recoverySilenceCommitGate = AudioRecoverySilenceCommitGate()
    private var isRecording = false
    private var reconfigurationTask: Task<Void, Never>?
    private let healthLock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    private var lastAudioWriteInstant: ContinuousClock.Instant?
    private var captureStartedInstant: ContinuousClock.Instant?
    private var recoveryState: RecoveryState = .healthy
    /// Observes `AVAudioEngineConfigurationChange` so we can rebuild the
    /// tap graph in place when the audio device changes mid-recording
    /// (AirPods plug/unplug, default-input switch, sample-rate renegotiation).
    /// Without this, the engine silently stops itself and `mic.m4a` truncates.
    private var configChangeObserver: NSObjectProtocol?
    private var deviceReconnectObserver: NSObjectProtocol?

    /// Audio taps run on a real-time Core Audio thread. Keep that callback to
    /// one bounded PCM copy, then serialize conversion, AAC encoding, preview
    /// resampling, and filesystem writes here.
    var speakerAudioClock: RecordingAudioClock?
    private let ioQueue = DispatchQueue(label: "lokalbot.microphone.write",
                                        qos: .userInitiated)
    private static let bufferPoolSize = 16
    private static let pooledBufferFrameCapacity: AVAudioFrameCount = 32_768
    private var bufferPoolBroker: MicAudioBufferPoolBroker?
    /// Accessed only on `ioQueue`. A per-install token prevents a late callback
    /// from an old input graph from mutating or writing into its replacement.
    private var activeCaptureGraphID: UUID?
    private let dropCounter = MicRealtimeDropCounter()

    enum RecorderError: LocalizedError {
        case inputUnavailable
        case unsupportedInputFormat
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .inputUnavailable:
                "Microphone is not available right now (no usable input device). Check the input selected in System Settings → Sound."
            case .unsupportedInputFormat:
                "Microphone input format is not supported by the recorder."
            case .conversionFailed(let message):
                "Microphone audio conversion failed: \(message)"
            }
        }
    }

    enum RecoveryState: Equatable {
        case healthy
        case recovering(attempt: Int)
        case degraded(errorDescription: String)
    }

    static let maximumReconfigurationAttempts = 4

    static func reconfigurationRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= maximumReconfigurationAttempts else { return nil }
        return min(Double(attempt), 5)
    }

    static func shouldRearmAfterDeviceEvent(isRecording: Bool, recovery: RecoveryState) -> Bool {
        guard isRecording else { return false }
        if case .degraded = recovery { return true }
        return false
    }

    struct CaptureHealth {
        let duration: TimeInterval
        let lastAudioWriteAt: Date?
        let isEngineRunning: Bool
        let droppedBufferCount: Int
        let recoveryState: RecoveryState
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
    /// the live meeting transcript — best-effort, never fails the recording.
    func start(writingTo url: URL, previewTee previewURL: URL? = nil,
               timeline: RecordingAudioTimeline? = nil) throws {
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        isRecording = false
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }
        let channelCount = min(inputFormat.channelCount, 2)
        let sampleRate = min(max(inputFormat.sampleRate, 8_000), 48_000)
        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: sampleRate,
                                                  channels: channelCount,
                                                  interleaved: false) else {
            throw RecorderError.unsupportedInputFormat
        }

        let newFile = try Self.makeRecordingFile(at: url, recordingFormat: recordingFormat)
        let newPreviewTee = previewURL.flatMap {
            AudioPreviewTee(url: $0, sourceFormat: recordingFormat)
        }
        ioQueue.sync {
            file = newFile
            self.recordingFormat = recordingFormat
            self.timeline = timeline
            previewTee = newPreviewTee
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
        }
        updateRecoveryState(.healthy)
        resetCaptureHealth(sampleRate: recordingFormat.sampleRate)

        isRecording = true
        observeDeviceReconnections()
        observeConfigurationChanges(for: engine)
        do {
            try installTapAndStart(inputFormat: inputFormat, recordingFormat: recordingFormat)
        } catch {
            isRecording = false
            removeDeviceReconnectObserver()
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
            removeConfigurationChangeObserver()
            ioQueue.sync {
                file = nil
                self.recordingFormat = nil
                self.timeline = nil
                converter = nil
                converterInputFormat = nil
                previewTee?.close()
                previewTee = nil
                recoverySilenceCommitGate.cancel()
            }
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            resetCaptureHealth(sampleRate: 0)
            throw error
        }
    }

    func stop() {
        isRecording = false
        removeDeviceReconnectObserver()
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        updateRecoveryState(.healthy)
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Draining the queue first preserves callback order. Then flush the
        // converter's tail before closing either output.
        ioQueue.sync {
            activeCaptureGraphID = nil
            drainConverter()
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
            recordingFormat = nil
            timeline = nil
            file = nil   // closes the file
            previewTee?.close()
            previewTee = nil
        }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
    }

    func captureHealth() -> CaptureHealth {
        healthLock.lock()
        let duration = recordingSampleRate > 0
            ? Double(framesWritten) / recordingSampleRate
            : 0
        let lastAudioWriteAt = self.lastAudioWriteAt
        let recoveryState = self.recoveryState
        healthLock.unlock()
        let droppedBufferCount = dropCounter.snapshot()
        return CaptureHealth(duration: duration,
                             lastAudioWriteAt: lastAudioWriteAt,
                             isEngineRunning: engine.isRunning,
                             droppedBufferCount: droppedBufferCount,
                             recoveryState: recoveryState)
    }

    func restartCapture() throws {
        guard isRecording, let recordingFormat else { return }
        do {
            try rebuildCaptureGraph(recordingFormat: recordingFormat)
            reconfigurationTask?.cancel()
            reconfigurationTask = nil
            updateRecoveryState(.healthy)
        } catch {
            scheduleReconfigurationRetry(lastError: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Engine setup

    /// This listener outlives failed engine graphs. Reconnecting an input
    /// rearms the bounded recovery owner even after its fast retries expired.
    private func observeDeviceReconnections() {
        removeDeviceReconnectObserver()
        deviceReconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio),
                  Self.shouldRearmAfterDeviceEvent(isRecording: self.isRecording,
                                                  recovery: self.captureHealth().recoveryState) else { return }
            self.scheduleReconfigurationRetry(lastError: "An audio input was reconnected.")
        }
    }

    private func removeDeviceReconnectObserver() {
        if let deviceReconnectObserver { NotificationCenter.default.removeObserver(deviceReconnectObserver) }
        deviceReconnectObserver = nil
    }

    /// Reconfiguration can leave `AVAudioEngine`'s input node pinned to the
    /// previous hardware rate. Reusing that graph makes every retry request the
    /// stale tap format. Build a completely new graph, while retaining the
    /// session's output file and recording format so capture can continue in
    /// the same artifact.
    private func rebuildCaptureGraph(recordingFormat: AVAudioFormat) throws {
        removeConfigurationChangeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        drainAndResetConverter()
        ioQueue.sync {
            recoverySilenceCommitGate.cancel()
        }

        let replacementEngine = AVAudioEngine()
        engine = replacementEngine
        let inputFormat = replacementEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }

        observeConfigurationChanges(for: replacementEngine)
        do {
            try installTapAndStart(inputFormat: inputFormat,
                                   recordingFormat: recordingFormat,
                                   shouldDrainExistingConverter: false,
                                   stageRecoverySilence: true)
        } catch {
            removeConfigurationChangeObserver()
            replacementEngine.inputNode.removeTap(onBus: 0)
            replacementEngine.stop()
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            throw error
        }
    }

    /// Builds the converter (only when input ≠ recording format), installs
    /// the tap, and starts the engine. Shared by `start()` and the
    /// configuration-change reinstall.
    private func installTapAndStart(
        inputFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat,
        shouldDrainExistingConverter: Bool = true,
        stageRecoverySilence: Bool = false
    ) throws {
        if shouldDrainExistingConverter {
            drainAndResetConverter()
        }
        let input = engine.inputNode
        let broker = MicAudioBufferPoolBroker(
            bufferCount: Self.bufferPoolSize,
            frameCapacity: Self.pooledBufferFrameCapacity)
        guard broker.install(format: inputFormat) else {
            throw RecorderError.unsupportedInputFormat
        }
        bufferPoolBroker?.clear()
        bufferPoolBroker = broker
        let captureGraphID = UUID()
        ioQueue.sync { activeCaptureGraphID = captureGraphID }
        // Let AVAudioEngine choose the current hardware format. During a live
        // device switch, `outputFormat(forBus:)` can briefly report a stale
        // client format while the input unit has already moved to the new
        // hardware rate, and passing that stale format makes installTap raise.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, broker] buffer, audioTime in
            guard let self else { return }
            let capturedAt = ContinuousClock.now
            let callbackHostTime = RecordingAudioClock.now
            let sourceHostTime = audioTime.hostTime
            let sourceHostValid = audioTime.isHostTimeValid
            // Capture the fallback on the callback, never after queue/encoder
            // delay. Invalid host anchors still fail closed for speaker proof.
            let bufferHostStart = sourceHostValid
                ? RecordingAudioClock.hostSeconds(sourceHostTime)
                : callbackHostTime - Double(buffer.frameLength) / buffer.format.sampleRate
            let copy: AVAudioPCMBuffer
            let pool: MicAudioBufferPool
            switch broker.borrow(for: buffer) {
            case .borrowed(let borrowedBuffer, let borrowedPool):
                copy = borrowedBuffer
                pool = borrowedPool
            case .refreshNeeded(let negotiatedFormat):
                self.ioQueue.async { [weak self] in
                    guard let self, self.activeCaptureGraphID == captureGraphID else { return }
                    if !broker.install(format: negotiatedFormat) {
                        broker.clear()
                        NSLog("MicRecorder could not allocate a pool for the negotiated input format")
                    }
                }
                self.noteDroppedBuffer()
                return
            case .unavailable:
                self.noteDroppedBuffer()
                return
            }
            guard Self.copyBuffer(buffer, into: copy) else {
                self.ioQueue.async { [pool] in pool.returnBuffer(copy) }
                self.noteDroppedBuffer()
                return
            }
            self.ioQueue.async { [weak self, pool] in
                defer { pool.returnBuffer(copy) }
                guard let self, self.activeCaptureGraphID == captureGraphID else { return }
                do {
                    try self.write(copy, capturedAt: capturedAt, hostTime: sourceHostTime,
                                   hostValid: sourceHostValid, bufferHostStart: bufferHostStart,
                                   callbackHostTime: callbackHostTime)
                } catch {
                    NSLog("MicRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
        if stageRecoverySilence {
            ioQueue.sync {
                recoverySilenceCommitGate.stage()
            }
        }
        do {
            engine.prepare()
            try engine.start()
            guard engine.isRunning else { throw RecorderError.inputUnavailable }
        } catch {
            input.removeTap(onBus: 0)
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            ioQueue.sync {
                if activeCaptureGraphID == captureGraphID {
                    activeCaptureGraphID = nil
                }
                converter = nil
                converterInputFormat = nil
                if stageRecoverySilence {
                    recoverySilenceCommitGate.cancel()
                }
            }
            throw error
        }
    }

    private func observeConfigurationChanges(for observedEngine: AVAudioEngine) {
        removeConfigurationChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: observedEngine,
            queue: .main
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            self?.handleConfigurationChange(for: changedEngine)
        }
    }

    private func removeConfigurationChangeObserver() {
        guard let configChangeObserver else { return }
        NotificationCenter.default.removeObserver(configChangeObserver)
        self.configChangeObserver = nil
    }

    /// Opens the capture file, stepping down the bitrate ladder if the encoder
    /// refuses. A rejected bitrate used to surface as "Could not start
    /// recording" with a raw Core Audio code, which told the user nothing and
    /// cost them the meeting.
    static func makeRecordingFile(at url: URL,
                                  recordingFormat: AVAudioFormat) throws -> AVAudioFile {
        var settings = fileSettings(for: url, recordingFormat: recordingFormat)
        guard settings[AVEncoderBitRateKey] != nil else {
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: recordingFormat.commonFormat,
                                   interleaved: recordingFormat.isInterleaved)
        }
        var lastError: Error?
        for bitRate in aacBitRateLadder(forSampleRate: recordingFormat.sampleRate) {
            settings[AVEncoderBitRateKey] = bitRate
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: recordingFormat.commonFormat,
                                           interleaved: recordingFormat.isInterleaved)
                if bitRate != aacBitRate(forSampleRate: recordingFormat.sampleRate) {
                    lokalbotLog(
                        "mic recording file fell back to \(bitRate) bit/s at "
                            + "\(Int(recordingFormat.sampleRate)) Hz")
                }
                return file
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RecorderError.unsupportedInputFormat
    }

    private static func fileSettings(for url: URL, recordingFormat: AVAudioFormat) -> [String: Any] {
        if url.pathExtension.lowercased() == "caf" {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: Int(recordingFormat.channelCount),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: !recordingFormat.isInterleaved,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(recordingFormat.channelCount),
            AVEncoderBitRateKey: aacBitRate(forSampleRate: recordingFormat.sampleRate),
        ]
    }

    /// AAC bitrates the encoder will accept, by sample rate.
    ///
    /// The rate is not ours to choose: it is whatever the input device runs at,
    /// and a Bluetooth headset in HFP mode runs at 16 kHz. A fixed 64 kbit/s is
    /// out of range there, so `AVAudioFile(forWriting:)` threw `!dat`
    /// (560226676) and the meeting did not record at all. Measured against the
    /// encoder, mono:
    ///
    ///     rate     64k  48k  32k  24k
    ///      8000     ✗    ✗    ✗    ✓
    ///     16000     ✗    ✓    ✓    ✓
    ///     22050     ✓    ✓    ✓    ✓
    ///     44100     ✓    ✓    ✓    ✗
    ///     48000     ✓    ✓    ✓    ✗
    ///
    /// So the constraint runs both ways and no single value covers the range.
    /// These tiers sit inside every accepted row, leaving headroom above the
    /// minimum rather than hugging the edge — speech at 16 kHz has nothing to
    /// gain from the last few kbit anyway.
    static func aacBitRate(forSampleRate sampleRate: Double) -> Int {
        switch sampleRate {
        case ..<12_000: 24_000
        case ..<22_050: 32_000
        default: 64_000
        }
    }

    /// Bitrates to try, best first, descending. The tiers above are measured,
    /// but only on the rates a Mac actually offers; a device that lands between
    /// them should still record at a lower bitrate rather than not at all.
    ///
    /// Strictly descending, because the failures are one-directional at each
    /// end: at 8 kHz everything above 24 kbit/s is refused, so retrying upwards
    /// would trade one rejection for another.
    static func aacBitRateLadder(forSampleRate sampleRate: Double) -> [Int] {
        let start = aacBitRate(forSampleRate: sampleRate)
        return [64_000, 48_000, 32_000, 24_000].filter { $0 <= start }
    }

    /// Posted asynchronously when the audio device changes. The engine has
    /// already stopped itself; remove the old tap and let the retry loop rebuild
    /// the graph after Core Audio has settled. Reinstalling immediately can hit
    /// AVAudioEngine's transient "config change pending" state.
    private func handleConfigurationChange(for changedEngine: AVAudioEngine) {
        guard isRecording, engine === changedEngine else { return }
        removeConfigurationChangeObserver()
        changedEngine.inputNode.removeTap(onBus: 0)
        changedEngine.stop()
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        scheduleReconfigurationRetry(lastError: "The audio input configuration changed.")
    }

    private enum ReconfigurationAttemptResult: Sendable {
        case recovered
        case retry(String)
        case stopped
    }

    private func scheduleReconfigurationRetry(lastError initialError: String) {
        guard isRecording else { return }
        guard reconfigurationTask == nil else { return }
        updateRecoveryState(.recovering(attempt: 0))
        reconfigurationTask = Task { [weak self] in
            var lastError = initialError
            for attempt in 1...Self.maximumReconfigurationAttempts {
                guard let delay = Self.reconfigurationRetryDelay(forAttempt: attempt) else { break }
                self?.updateRecoveryState(.recovering(attempt: attempt))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let result = await MainActor.run { [weak self] in
                    guard let self, self.isRecording else {
                        return ReconfigurationAttemptResult.stopped
                    }
                    guard let recordingFormat = self.recordingFormat else {
                        return ReconfigurationAttemptResult.stopped
                    }
                    do {
                        try self.rebuildCaptureGraph(recordingFormat: recordingFormat)
                        NSLog("MicRecorder reconfig retry succeeded")
                        self.reconfigurationTask = nil
                        self.updateRecoveryState(.healthy)
                        return ReconfigurationAttemptResult.recovered
                    } catch {
                        NSLog("MicRecorder reconfig retry failed: \(error.localizedDescription)")
                        return ReconfigurationAttemptResult.retry(error.localizedDescription)
                    }
                }
                switch result {
                case .recovered, .stopped:
                    return
                case .retry(let errorDescription):
                    lastError = errorDescription
                }
            }
            guard !Task.isCancelled else { return }
            let terminalError = lastError
            await MainActor.run { [weak self] in
                guard let self, self.isRecording else { return }
                self.reconfigurationTask = nil
                self.updateRecoveryState(.degraded(errorDescription: terminalError))
                NSLog(
                    "MicRecorder recovery exhausted after \(Self.maximumReconfigurationAttempts) attempts: \(terminalError)")
            }
        }
    }

    /// Flush the converter's internal buffer on stop. Without this, the tail
    /// (the last few hundred ms — more with resampling) is dropped because
    /// the streaming write loop only ever signals `.noDataNow`, never EOS.
    private func drainAndResetConverter() {
        ioQueue.sync {
            drainConverter()
            converter = nil
            converterInputFormat = nil
        }
    }

    private func drainConverter() {
        guard let converter, let recordingFormat, let file else { return }
        // Loop because the converter may need multiple output buffers to
        // emit everything it has buffered (especially with resampling).
        for _ in 0..<8 {
            guard let tail = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                              frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: tail, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if tail.frameLength > 0 {
                do { try file.write(from: tail) } catch {
                    NSLog("MicRecorder drain write failed: \(error.localizedDescription)")
                    return
                }
                previewTee?.write(tail)
                healthLock.lock()
                framesWritten += AVAudioFramePosition(tail.frameLength)
                healthLock.unlock()
                speakerAudioClock?.discontinuity()
            }
            if status == .endOfStream || status == .error || tail.frameLength == 0 {
                return
            }
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        capturedAt: ContinuousClock.Instant, hostTime: UInt64, hostValid: Bool,
        bufferHostStart: Double, callbackHostTime: Double
    ) throws {
        guard let file else { return }
        let bufferDuration = buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate
            : 0
        let bufferStartedAt = capturedAt.advanced(by: .seconds(-bufferDuration))
        let timelineHostStart = timeline?.hostTimeOnTimeline(bufferHostTime: bufferHostStart,
            callbackHostTime: callbackHostTime, callbackInstant: capturedAt) ?? bufferHostStart
        guard let recordingFormat else {
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer, endedAt: capturedAt, hostTime: hostTime, hostValid: hostValid)
            return
        }
        guard buffer.format != recordingFormat else {
            converter = nil
            converterInputFormat = nil
            try appendPendingRecoverySilence(
                until: bufferStartedAt,
                bufferHostStart: timelineHostStart,
                format: recordingFormat,
                file: file)
            try file.write(from: buffer)
            previewTee?.write(buffer)
            noteWrittenAudio(buffer, endedAt: capturedAt, hostTime: hostTime, hostValid: hostValid)
            return
        }
        if converter == nil || converterInputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: recordingFormat) else {
                throw RecorderError.unsupportedInputFormat
            }
            converter = newConverter
            converterInputFormat = buffer.format
        }
        guard let converter else { return }
        let sampleRateRatio = recordingFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                            frameCapacity: max(frameCapacity, 1)) else {
            throw RecorderError.unsupportedInputFormat
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw RecorderError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        if output.frameLength > 0 {
            try appendPendingRecoverySilence(
                until: bufferStartedAt,
                bufferHostStart: timelineHostStart,
                format: recordingFormat,
                file: file)
            try file.write(from: output)
            previewTee?.write(output)
            noteWrittenAudio(output, endedAt: capturedAt, hostTime: hostTime, hostValid: hostValid)
        }
    }

    /// Makes the tap buffer safe to retain after the callback returns. Copying
    /// through `AudioBufferList` handles both interleaved and planar layouts.
    static func copyBuffer(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        guard source.frameLength > 0,
              source.frameLength <= destination.frameCapacity else { return false }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for (src, dst) in zip(sourceBuffers, destinationBuffers) {
            guard src.mDataByteSize <= dst.mDataByteSize,
                  let srcData = src.mData,
                  let dstData = dst.mData
            else { return false }
            memcpy(dstData, srcData, Int(src.mDataByteSize))
        }
        return true
    }

    private func resetCaptureHealth(sampleRate: Double) {
        let now = ContinuousClock.now
        healthLock.lock()
        framesWritten = 0
        recordingSampleRate = sampleRate
        lastAudioWriteAt = nil
        lastAudioWriteInstant = nil
        captureStartedInstant = sampleRate > 0 ? now : nil
        recoveryState = .healthy
        healthLock.unlock()
        dropCounter.reset()
    }

    private func updateRecoveryState(_ state: RecoveryState) {
        healthLock.lock()
        recoveryState = state
        healthLock.unlock()
    }

    /// Preserve a recovery gap only after the rebuilt graph delivers a real
    /// buffer. Failed starts and nominally-running graphs that never capture
    /// audio therefore cannot inflate the file or its reported duration.
    /// Called only on `ioQueue` immediately before the recovered buffer write.
    private func appendPendingRecoverySilence(
        until now: ContinuousClock.Instant,
        bufferHostStart: Double,
        format: AVAudioFormat,
        file: AVAudioFile
    ) throws {
        healthLock.lock()
        let anchor = lastAudioWriteInstant ?? captureStartedInstant
        let written = framesWritten
        healthLock.unlock()
        let paddingFrames: Int64
        if let timeline {
            recoverySilenceCommitGate.cancel()
            paddingFrames = timeline.silenceFrames(before: bufferHostStart,
                framesWritten: written, sampleRate: format.sampleRate)
        } else if let anchor,
                  let plan = recoverySilenceCommitGate.consumeAfterCapturedBuffer(
                    forElapsed: anchor.duration(to: now)),
                  format.sampleRate > 0,
                  plan.duration * format.sampleRate < Double(Int64.max) {
            paddingFrames = Int64(plan.duration * format.sampleRate)
        } else {
            recoverySilenceCommitGate.cancel()
            return
        }
        try AudioTimelinePadding.write(frames: paddingFrames, format: format) { silence in
            try file.write(from: silence)
            previewTee?.write(silence)
            healthLock.lock()
            framesWritten += Int64(silence.frameLength)
            healthLock.unlock()
        }
    }

    private func noteDroppedBuffer() {
        dropCounter.recordDrop()
    }

    private func noteWrittenAudio(
        _ buffer: AVAudioPCMBuffer,
        endedAt: ContinuousClock.Instant, hostTime: UInt64, hostValid: Bool
    ) {
        guard buffer.frameLength > 0 else { return }
        healthLock.lock()
        if recordingSampleRate <= 0 {
            recordingSampleRate = buffer.format.sampleRate
        }
        let startFrame = framesWritten
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        lastAudioWriteAt = Date()
        lastAudioWriteInstant = endedAt
        healthLock.unlock()
        speakerAudioClock?.record(hostTime: hostTime, valid: hostValid, startFrame: startFrame,
            frames: Int64(buffer.frameLength), sampleRate: buffer.format.sampleRate)
    }
}
