import AVFoundation
import Accelerate
import AppKit
import AudioToolbox
import CoreAudio

final class SystemAudioRecorder {

    enum RecorderError: LocalizedError {
        case processNotFound
        case coreAudio(String, OSStatus)
        case badTapFormat

        var errorDescription: String? {
            switch self {
            case .processNotFound:
                "Could not locate the meeting app's audio process. The system audio tap requires macOS 14.4+."
            case .coreAudio(let stage, let code):
                "Core Audio \(stage) failed (\(code))."
            case .badTapFormat:
                "Core Audio tap returned an unsupported audio format."
            }
        }
    }

    static var defaultTapFactory: () -> SystemAudioTap = { CoreAudioProcessTap() }
    private let makeTap: () -> SystemAudioTap
    private var tap: SystemAudioTap?
    private var file: AVAudioFile?
    private var previewTee: AudioPreviewTee?
    private var writeFailure: String?
    private var previewTeeURL: URL?
    private var tapFormat: AVAudioFormat?
    private var outputURL: URL?
    private var timeline: RecordingAudioTimeline?
    var speakerAudioClock: RecordingAudioClock?
    var soundMeter: RecordingSoundMeter?
    private var framesWritten: AVAudioFramePosition = 0
    private var framesSinceAttach: AVAudioFramePosition = 0
    private var audibleFramesWritten: AVAudioFramePosition = 0
    private var recordingSampleRate: Double = 0
    private var lastAudioWriteAt: Date?
    private var lastAudibleWriteAt: Date?
    private var lastRMSLevel: Float = 0
    private var peakRMSLevel: Float = 0
    private var droppedBufferCount = 0
    private static let audibleRMSThreshold: Float = 0.0005
    private static let bufferPoolSize = 16
    private static let pooledBufferFrameCapacity: AVAudioFrameCount = 32_768

    private let ioQueue: DispatchQueue

    init(writerQueue: DispatchQueue = DispatchQueue(label: "lokalbot.systemaudio.write", qos: .userInitiated),
         makeTap: @escaping () -> SystemAudioTap = SystemAudioRecorder.defaultTapFactory) {
        ioQueue = writerQueue
        self.makeTap = makeTap
    }
    private var bufferRing: RealtimeBufferRing?
    private let dropLock = NSLock()

    private var capturedPID: pid_t = 0
    private var terminationObserver: NSObjectProtocol?

    var onCapturedProcessTerminated: ((pid_t) -> Void)?

    struct CaptureHealth: Sendable {
        let duration: TimeInterval
        let audibleDuration: TimeInterval
        let framesSinceAttach: AVAudioFramePosition
        let lastAudioWriteAt: Date?
        let lastAudibleWriteAt: Date?
        let capturedPID: pid_t
        let lastRMSLevel: Float
        let peakRMSLevel: Float
        let droppedBufferCount: Int
        var writeError: String?
    }

    func start(capturingPID pid: pid_t, writingTo url: URL, previewTee previewURL: URL? = nil,
               timeline: RecordingAudioTimeline? = nil) throws {
        let nextTap = makeTap()
        guard nextTap.resolves(processID: pid) else {
            throw RecorderError.processNotFound
        }

        do {
            outputURL = url
            previewTeeURL = previewURL
            let captureTimeline = timeline ?? RecordingAudioTimeline(originHostTime: RecordingAudioClock.now)
            ioQueue.sync {
                self.timeline = captureTimeline
                framesWritten = 0
                framesSinceAttach = 0
                audibleFramesWritten = 0
                recordingSampleRate = 0
                lastAudioWriteAt = nil
                lastAudibleWriteAt = nil
                lastRMSLevel = 0
                writeFailure = nil
                peakRMSLevel = 0
            }
            dropLock.lock()
            droppedBufferCount = 0
            dropLock.unlock()
            try attachTap(nextTap, processID: pid, writingTo: url)
        } catch {
            cleanup(closeFile: true)
            throw error
        }

        installTerminationObserver(for: pid)
    }

    func reattach(capturingPID pid: pid_t) throws {
        guard let outputURL else { throw RecorderError.processNotFound }
        let nextTap = makeTap()
        guard nextTap.resolves(processID: pid) else {
            throw RecorderError.processNotFound
        }
        teardownTap()
        ioQueue.sync {
            speakerAudioClock?.discontinuity()
            framesSinceAttach = 0
        }
        do {
            try attachTap(nextTap, processID: pid, writingTo: outputURL)
            installTerminationObserver(for: pid)
        } catch {
            teardownTap()
            throw error
        }
    }

    func captureHealth() -> CaptureHealth {
        let pid = capturedPID
        return ioQueue.sync { healthOnWriterQueue(capturedPID: pid) }
    }

    @MainActor
    func captureHealthInBackground() async -> CaptureHealth {
        let pid = capturedPID
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.healthOnWriterQueue(capturedPID: pid))
            }
        }
    }

    private func healthOnWriterQueue(capturedPID: pid_t) -> CaptureHealth {
        dropLock.lock()
        let dropped = droppedBufferCount
        dropLock.unlock()
        let duration = recordingSampleRate > 0 ? Double(framesWritten) / recordingSampleRate : 0
        let audibleDuration = recordingSampleRate > 0 ? Double(audibleFramesWritten) / recordingSampleRate : 0
        return CaptureHealth(duration: duration,
                             audibleDuration: audibleDuration,
                             framesSinceAttach: framesSinceAttach,
                             lastAudioWriteAt: lastAudioWriteAt,
                             lastAudibleWriteAt: lastAudibleWriteAt,
                             capturedPID: capturedPID,
                             lastRMSLevel: lastRMSLevel,
                             peakRMSLevel: peakRMSLevel,
                             droppedBufferCount: dropped,
                             writeError: writeFailure ?? previewTee?.failureDescription)
    }

    private func attachTap(_ nextTap: SystemAudioTap, processID: pid_t, writingTo url: URL) throws {
        tap = nextTap
        let format = try nextTap.attach(processID: processID)

        if let existingFormat = tapFormat, !Self.formatsCompatible(existingFormat, format) {
            throw RecorderError.badTapFormat
        }
        tapFormat = format

        if recordingSampleRate == 0 {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 96_000,
            ]
            do {
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            } catch { writeFailure = error.localizedDescription }
            previewTee = previewTeeURL.flatMap { AudioPreviewTee(url: $0, sourceFormat: format) }
            guard file != nil || previewTee != nil else { throw CocoaError(.fileWriteUnknown) }
            if previewTeeURL != nil, previewTee == nil { writeFailure = "Recovery audio could not be opened" }
            try prepareBufferPool(format: format)
            ioQueue.sync {
                recordingSampleRate = format.sampleRate
            }
        }

        try nextTap.start { [weak self] inInputData, inputTime in
            guard let self, let fmt = self.tapFormat,
                  fmt.commonFormat == .pcmFormatFloat32 else { return }
            let streamDescription = fmt.streamDescription
            guard streamDescription.pointee.mBytesPerFrame > 0 else { return }
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let firstBuffer = sourceBuffers.first else { return }
            let frameLength = AVAudioFrameCount(
                firstBuffer.mDataByteSize / streamDescription.pointee.mBytesPerFrame)
            guard frameLength > 0,
                  let copy = self.borrowBuffer(frameLength: frameLength) else {
                self.noteDroppedBuffer()
                return
            }
            guard Self.copyBufferList(inInputData, into: copy) else {
                self.ioQueue.async { self.returnBuffer(copy) }
                self.noteDroppedBuffer()
                return
            }
            let sourceHostTime = inputTime.pointee.mHostTime
            let sourceHostValid = inputTime.pointee.mFlags.contains(.hostTimeValid)
            let capturedAt = ContinuousClock.now
            let callbackHostTime = RecordingAudioClock.now
            let bufferHostStart = sourceHostValid
                ? RecordingAudioClock.hostSeconds(sourceHostTime)
                : callbackHostTime - Double(frameLength) / fmt.sampleRate
            self.ioQueue.async {
                defer { self.returnBuffer(copy) }
                do {
                    let timelineHostStart = self.timeline?.hostTimeOnTimeline(
                        bufferHostTime: bufferHostStart, callbackHostTime: callbackHostTime,
                        callbackInstant: capturedAt) ?? bufferHostStart
                    try self.appendTimelineSilence(before: timelineHostStart, format: fmt)
                    let rmsLevel = Self.measureRMS(of: copy)
                    try self.writeSafely(copy)
                    self.speakerAudioClock?.record(hostTime: sourceHostTime, valid: sourceHostValid,
                        startFrame: self.framesWritten, frames: Int64(copy.frameLength), sampleRate: fmt.sampleRate)
                    let now = Date()
                    self.framesWritten += AVAudioFramePosition(copy.frameLength)
                    self.framesSinceAttach += AVAudioFramePosition(copy.frameLength)
                    self.lastAudioWriteAt = now
                    self.lastRMSLevel = rmsLevel
                    self.peakRMSLevel = max(self.peakRMSLevel, rmsLevel)
                    self.soundMeter?.record(rms: rmsLevel, frames: Int(copy.frameLength),
                                            sampleRate: fmt.sampleRate)
                    if rmsLevel >= Self.audibleRMSThreshold {
                        self.audibleFramesWritten += AVAudioFramePosition(copy.frameLength)
                        self.lastAudibleWriteAt = now
                    }
                } catch {
                    NSLog("SystemAudioRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        cleanup(closeFile: true)
    }

    private func installTerminationObserver(for pid: pid_t) {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        capturedPID = pid
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.capturedPID else { return }
            self.onCapturedProcessTerminated?(app.processIdentifier)
        }
    }

    private func teardownTap() {
        tap?.stopDelivery()

        ioQueue.sync {}

        tap?.destroy()
        tap = nil
    }

    private func cleanup(closeFile: Bool) {
        teardownTap()
        guard closeFile else { return }
        file = nil
        previewTee?.close()
        previewTee = nil
        previewTeeURL = nil
        tapFormat = nil
        outputURL = nil
        capturedPID = 0
        ioQueue.sync {
            framesWritten = 0
            framesSinceAttach = 0
            audibleFramesWritten = 0
            recordingSampleRate = 0
            lastAudioWriteAt = nil
            timeline = nil
            lastAudibleWriteAt = nil
            lastRMSLevel = 0
            peakRMSLevel = 0
        }
        dropLock.lock()
        droppedBufferCount = 0
        dropLock.unlock()
        bufferRing = nil
    }

    private func appendTimelineSilence(before hostTime: Double,
                                       format: AVAudioFormat) throws {
        guard let timeline else { return }
        let frames = timeline.silenceFrames(before: hostTime, framesWritten: framesWritten,
                                            sampleRate: format.sampleRate)
        try AudioTimelinePadding.write(frames: frames, format: format) { silence in
            try writeSafely(silence, isPadding: true)
            framesWritten += Int64(silence.frameLength)
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

    private func noteDroppedBuffer() {
        guard dropLock.try() else { return }
        droppedBufferCount += 1
        dropLock.unlock()
    }

    private func prepareBufferPool(format: AVAudioFormat) throws {
        var prepared: [AVAudioPCMBuffer] = []
        prepared.reserveCapacity(Self.bufferPoolSize)
        for _ in 0..<Self.bufferPoolSize {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: Self.pooledBufferFrameCapacity
            ) else {
                throw RecorderError.badTapFormat
            }
            prepared.append(buffer)
        }
        bufferRing = RealtimeBufferRing(buffers: prepared)
    }

    private func borrowBuffer(frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frameLength <= Self.pooledBufferFrameCapacity,
              let buffer = bufferRing?.borrow() else { return nil }
        buffer.frameLength = frameLength
        return buffer
    }

    private func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferRing?.giveBack(buffer)
    }

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    static func copyAndMeasureRMS(from source: AVAudioPCMBuffer,
                                  into destination: AVAudioPCMBuffer) -> Float {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        var sumSquares: Double = 0
        var sampleCount = 0
        for (src, dst) in zip(sourceBuffers, destinationBuffers) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let bytes = Int(min(src.mDataByteSize, dst.mDataByteSize))
            memcpy(dstData, srcData, bytes)
            let samples = srcData.assumingMemoryBound(to: Float.self)
            let count = bytes / MemoryLayout<Float>.size
            var partial: Float = 0
            vDSP_svesq(samples, 1, &partial, vDSP_Length(count))
            sumSquares += Double(partial)
            sampleCount += count
        }
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }

    static func copyBufferList(
        _ source: UnsafePointer<AudioBufferList>,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            guard source.mDataByteSize <= destination.mDataByteSize,
                  let sourceData = source.mData,
                  let destinationData = destination.mData else { return false }
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
        }
        return true
    }

    static func measureRMS(of buffer: AVAudioPCMBuffer) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        var sumSquares: Double = 0
        var sampleCount = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            var partial: Float = 0
            vDSP_svesq(samples, 1, &partial, vDSP_Length(count))
            sumSquares += Double(partial)
            sampleCount += count
        }
        return sampleCount > 0 ? Float(sqrt(sumSquares / Double(sampleCount))) : 0
    }
}
