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
    private let format: AVAudioFormat
    private let frameCapacity: AVAudioFrameCount
    private let ring: RealtimeBufferRing

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
        ring = RealtimeBufferRing(buffers: prepared)
    }

    func borrow(for source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength <= frameCapacity,
              isCompatible(with: source.format),
              let buffer = ring.borrow() else { return nil }
        buffer.frameLength = source.frameLength
        return buffer
    }

    func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        ring.giveBack(buffer)
    }

    var availableBufferCount: Int {
        ring.availableCount
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

struct MicRecoveryFlapDetector: Equatable {
    let limit: Int
    let window: TimeInterval
    private(set) var recoveries: [Date] = []

    init(limit: Int, window: TimeInterval) {
        self.limit = max(1, limit)
        self.window = window
    }

    static let dictation = MicRecoveryFlapDetector(limit: 3, window: 20)

    mutating func recordRecovery(at now: Date) -> Bool {
        recoveries = recoveries.filter { now.timeIntervalSince($0) < window } + [now]
        return recoveries.count > limit
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

final class MicRecorder {

    static var defaultInputFactory: () throws -> MicrophoneInput = { EngineMicrophoneInput() }
    static var dictationInputFactory: (_ preferredMicrophoneID: String) throws -> MicrophoneInput = { id in
        try CaptureSessionMicrophoneInput(device: DictationMicrophone.device(preferredID: id))
    }
    private let makeInput: () throws -> MicrophoneInput
    private let flapPolicy: MicRecoveryFlapDetector?
    private var flapDetector: MicRecoveryFlapDetector?
    private var input: MicrophoneInput
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var previewTee: AudioPreviewTee?
    private var writeFailure: String?
    private var recordingFormat: AVAudioFormat?
    private var timeline: RecordingAudioTimeline?
    private var recoverySilenceCommitGate = AudioRecoverySilenceCommitGate()
    private var isRecording = false
    private var reconfigurationTask: Task<Void, Never>?
    private let healthLock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    private var lastSignalAt: Date?
    private var lastAudioWriteInstant: ContinuousClock.Instant?
    private var captureStartedInstant: ContinuousClock.Instant?
    private var recoveryState: RecoveryState = .healthy
    private var configChangeObserver: NSObjectProtocol?
    private var deviceReconnectObserver: NSObjectProtocol?

    var speakerAudioClock: RecordingAudioClock?
    var soundMeter: RecordingSoundMeter?
    private let ioQueue: DispatchQueue

    init(writerQueue: DispatchQueue = DispatchQueue(label: "lokalbot.microphone.write", qos: .userInitiated),
         makeInput: @escaping () throws -> MicrophoneInput = MicRecorder.defaultInputFactory,
         flapPolicy: MicRecoveryFlapDetector? = nil) {
        ioQueue = writerQueue
        self.makeInput = makeInput
        self.flapPolicy = flapPolicy
        self.input = IdleMicrophoneInput()
    }
    private static let bufferPoolSize = 16
    private static let pooledBufferFrameCapacity: AVAudioFrameCount = 32_768
    private var bufferPoolBroker: MicAudioBufferPoolBroker?
    private var activeCaptureGraphID: UUID?
    private let dropCounter = MicRealtimeDropCounter()
    let levelMeter = AudioLevelMeter()
    var onFirstAudio: (() -> Void)?
    private var hasDeliveredFirstAudio = false

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

    enum RecoveryState: Equatable, Sendable {
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

    static let signalRMSThreshold: Float = 0.00003

    struct CaptureHealth: Sendable {
        let duration: TimeInterval
        let lastAudioWriteAt: Date?
        let lastSignalAt: Date?
        let isEngineRunning: Bool
        let droppedBufferCount: Int
        let recoveryState: RecoveryState
        var writeError: String?
    }

    static func requestPermission() async -> Bool {
#if LOKALBOT_TEST_HOOKS
        if TestHooks.backgroundAudioDirectory != nil { return true }
#endif
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, previewTee previewURL: URL? = nil,
               timeline: RecordingAudioTimeline? = nil) throws {
        reconfigurationTask?.cancel()
        reconfigurationTask = nil
        isRecording = false
        removeConfigurationChangeObserver()
        input.removeTap()
        input.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        input = try makeInput()
        let inputFormat = input.inputFormat
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

        var initialWriteFailure: String?
        let newFile: AVAudioFile?
        do { newFile = try Self.makeRecordingFile(at: url, recordingFormat: recordingFormat) } catch {
            newFile = nil
            initialWriteFailure = error.localizedDescription
        }
        let newPreviewTee = previewURL.flatMap {
            AudioPreviewTee(url: $0, sourceFormat: recordingFormat)
        }
        guard newFile != nil || newPreviewTee != nil else { throw CocoaError(.fileWriteUnknown) }
        ioQueue.sync {
            file = newFile
            self.recordingFormat = recordingFormat
            self.timeline = timeline
            previewTee = newPreviewTee
            writeFailure = initialWriteFailure
                ?? (previewURL != nil && newPreviewTee == nil ? "Recovery audio could not be opened" : nil)
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
        }
        updateRecoveryState(.healthy)
        resetCaptureHealth(sampleRate: recordingFormat.sampleRate)
        flapDetector = flapPolicy

        isRecording = true
        observeDeviceReconnections()
        if let live = input as? EngineMicrophoneInput { observeConfigurationChanges(for: live.engine) }
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
        input.removeTap()
        input.stop()
        ioQueue.sync {
            activeCaptureGraphID = nil
            drainConverter()
            converter = nil
            converterInputFormat = nil
            recoverySilenceCommitGate.cancel()
            recordingFormat = nil
            timeline = nil
            file = nil
            previewTee?.close()
            previewTee = nil
        }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
    }

    func captureHealth() -> CaptureHealth {
        let running = input.isRunning
        return ioQueue.sync { healthOnWriterQueue(isEngineRunning: running) }
    }

    @MainActor
    func captureHealthInBackground() async -> CaptureHealth {
        let running = input.isRunning
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.healthOnWriterQueue(isEngineRunning: running))
            }
        }
    }

    private func healthOnWriterQueue(isEngineRunning: Bool) -> CaptureHealth {
        healthLock.lock()
        let duration = recordingSampleRate > 0
            ? Double(framesWritten) / recordingSampleRate
            : 0
        let lastAudioWriteAt = self.lastAudioWriteAt
        let lastSignalAt = self.lastSignalAt
        let recoveryState = self.recoveryState
        healthLock.unlock()
        let droppedBufferCount = dropCounter.snapshot()
        let writeError = writeFailure ?? previewTee?.failureDescription
        return CaptureHealth(duration: duration,
                             lastAudioWriteAt: lastAudioWriteAt,
                             lastSignalAt: lastSignalAt,
                             isEngineRunning: isEngineRunning,
                             droppedBufferCount: droppedBufferCount,
                             recoveryState: recoveryState, writeError: writeError)
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

    func recoverCapture(reason: String) {
        scheduleReconfigurationRetry(lastError: reason)
    }

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

    private func rebuildCaptureGraph(recordingFormat: AVAudioFormat) throws {
        removeConfigurationChangeObserver()
        input.removeTap()
        input.stop()
        ioQueue.sync { activeCaptureGraphID = nil }
        bufferPoolBroker?.clear()
        bufferPoolBroker = nil
        drainAndResetConverter()
        ioQueue.sync {
            recoverySilenceCommitGate.cancel()
        }

        let replacement = try makeInput()
        input = replacement
        let inputFormat = replacement.inputFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }

        if let live = replacement as? EngineMicrophoneInput { observeConfigurationChanges(for: live.engine) }
        do {
            try installTapAndStart(inputFormat: inputFormat,
                                   recordingFormat: recordingFormat,
                                   shouldDrainExistingConverter: false,
                                   stageRecoverySilence: true)
        } catch {
            removeConfigurationChangeObserver()
            replacement.removeTap()
            replacement.stop()
            bufferPoolBroker?.clear()
            bufferPoolBroker = nil
            throw error
        }
    }

    private func installTapAndStart(
        inputFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat,
        shouldDrainExistingConverter: Bool = true,
        stageRecoverySilence: Bool = false
    ) throws {
        if shouldDrainExistingConverter {
            drainAndResetConverter()
        }
        let tapInput = input
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
        tapInput.installTap(bufferSize: 4096) { [weak self, broker] buffer, audioTime in
            guard let self else { return }
            let capturedAt = ContinuousClock.now
            let callbackHostTime = RecordingAudioClock.now
            let sourceHostTime = audioTime.hostTime
            let sourceHostValid = audioTime.isHostTimeValid
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
            try tapInput.start()
            guard tapInput.isRunning else { throw RecorderError.inputUnavailable }
        } catch {
            tapInput.removeTap()
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

    static func aacBitRate(forSampleRate sampleRate: Double) -> Int {
        switch sampleRate {
        case ..<12_000: 24_000
        case ..<22_050: 32_000
        default: 64_000
        }
    }

    static func aacBitRateLadder(forSampleRate sampleRate: Double) -> [Int] {
        let start = aacBitRate(forSampleRate: sampleRate)
        return [64_000, 48_000, 32_000, 24_000].filter { $0 <= start }
    }

    private func handleConfigurationChange(for changedEngine: AVAudioEngine) {
        guard isRecording, (input as? EngineMicrophoneInput)?.engine === changedEngine else { return }
        lokalbotLog("microphone configuration changed; rebuilding capture")
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
        if flapDetector?.recordRecovery(at: Date()) == true {
            let window = Int(flapDetector?.window ?? 0)
            lokalbotLog("microphone recovery stopped: input reconnected repeatedly within \(window)s")
            updateRecoveryState(.degraded(errorDescription:
                "The microphone kept disconnecting. If you use a Bluetooth headset, "
                    + "choose another input in System Settings → Sound."))
            return
        }
        lokalbotLog("microphone recovery started: \(initialError)")
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
                        lokalbotLog("microphone recovery succeeded on attempt \(attempt)")
                        self.reconfigurationTask = nil
                        self.updateRecoveryState(.healthy)
                        return ReconfigurationAttemptResult.recovered
                    } catch {
                        lokalbotLog(
                            "microphone recovery attempt \(attempt) failed: \(error.localizedDescription)")
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
                lokalbotLog(
                    "microphone recovery exhausted after \(Self.maximumReconfigurationAttempts) attempts: \(terminalError)")
            }
        }
    }

    private func drainAndResetConverter() {
        ioQueue.sync {
            drainConverter()
            converter = nil
            converterInputFormat = nil
        }
    }

    private func drainConverter() {
        guard let converter, let recordingFormat else { return }
        for _ in 0..<8 {
            guard let tail = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                              frameCapacity: 4096) else { return }
            var err: NSError?
            let status = converter.convert(to: tail, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if tail.frameLength > 0 {
                do { try writeSafely(tail) } catch {
                    NSLog("MicRecorder drain write failed: \(error.localizedDescription)")
                    return
                }
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
        let bufferDuration = buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate
            : 0
        let bufferStartedAt = capturedAt.advanced(by: .seconds(-bufferDuration))
        let timelineHostStart = timeline?.hostTimeOnTimeline(bufferHostTime: bufferHostStart,
            callbackHostTime: callbackHostTime, callbackInstant: capturedAt) ?? bufferHostStart
        guard let recordingFormat else {
            try writeSafely(buffer)
            noteWrittenAudio(buffer, endedAt: capturedAt, hostTime: hostTime, hostValid: hostValid)
            return
        }
        guard buffer.format != recordingFormat else {
            converter = nil
            converterInputFormat = nil
            try appendPendingRecoverySilence(
                until: bufferStartedAt,
                bufferHostStart: timelineHostStart,
                format: recordingFormat)
            try writeSafely(buffer)
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
                format: recordingFormat)
            try writeSafely(output)
            noteWrittenAudio(output, endedAt: capturedAt, hostTime: hostTime, hostValid: hostValid)
        }
    }

    private func writeSafely(_ buffer: AVAudioPCMBuffer, isPadding: Bool = false) throws {
        let result = AudioWriteSafety.write(recovery: { previewTee?.write(buffer, isPadding: isPadding) ?? false }, primary: {
            guard let file else { throw CocoaError(.fileWriteUnknown) }
            do { try file.write(from: buffer) } catch {
                self.file = nil
                throw error
            }
        })
        if let error = result.error { writeFailure = "Primary audio unavailable; using recovery audio. \(error)" }
        guard result.saved else {
            writeFailure = "No audio is being saved. Free disk space and restart recording."
            throw CocoaError(.fileWriteUnknown)
        }
    }

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
        lastSignalAt = nil
        lastAudioWriteInstant = nil
        captureStartedInstant = sampleRate > 0 ? now : nil
        recoveryState = .healthy
        healthLock.unlock()
        dropCounter.reset()
        levelMeter.reset()
        ioQueue.async { self.hasDeliveredFirstAudio = false }
    }

    private func updateRecoveryState(_ state: RecoveryState) {
        healthLock.lock()
        recoveryState = state
        healthLock.unlock()
    }

    private func appendPendingRecoverySilence(
        until now: ContinuousClock.Instant,
        bufferHostStart: Double,
        format: AVAudioFormat
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
            try writeSafely(silence, isPadding: true)
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
        let rms = AudioLevelMeter.rms(of: buffer)
        let now = Date()
        healthLock.lock()
        if recordingSampleRate <= 0 {
            recordingSampleRate = buffer.format.sampleRate
        }
        let startFrame = framesWritten
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        lastAudioWriteAt = now
        if rms >= Self.signalRMSThreshold { lastSignalAt = now }
        lastAudioWriteInstant = endedAt
        healthLock.unlock()
        speakerAudioClock?.record(hostTime: hostTime, valid: hostValid, startFrame: startFrame,
            frames: Int64(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        soundMeter?.record(rms: rms, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        levelMeter.record(AudioLevelMeter.normalized(rms: rms))
        if !hasDeliveredFirstAudio {
            hasDeliveredFirstAudio = true
            if let onFirstAudio { DispatchQueue.main.async(execute: onFirstAudio) }
        }
    }
}

private final class IdleMicrophoneInput: MicrophoneInput {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var isRunning: Bool { false }
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {}
    func removeTap() {}
    func start() throws { throw MicRecorder.RecorderError.inputUnavailable }
    func stop() {}
}
