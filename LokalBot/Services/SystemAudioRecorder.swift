import AVFoundation
import Accelerate
import AppKit
import AudioToolbox
import CoreAudio

/// Records the audio *output* of one process (the meeting app) using
/// Core Audio process taps (macOS 14.4+) — the "Them" track.
///
/// Pipeline: PID → process AudioObject → CATapDescription → process tap
/// → private aggregate device containing the tap → IOProc → AAC `.m4a`.
/// Pattern follows Apple's "Capturing system audio with Core Audio taps"
/// and insidegui/AudioCap. Requires the "System Audio Recording" TCC
/// permission (NSAudioCaptureUsageDescription) and no App Sandbox.
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var previewTee: AudioPreviewTee?
    private var previewTeeURL: URL?
    private var tapFormat: AVAudioFormat?
    private var outputURL: URL?
    /// Accessed on the writer queue and preserved across process handoffs.
    private var timeline: RecordingAudioTimeline?
    /// Set before starting a tap, cleared only after the writer drains.
    var speakerAudioClock: RecordingAudioClock?
    private var framesWritten: AVAudioFramePosition = 0
    /// Frames delivered by the current tap only. Recovery padding deliberately
    /// does not advance this counter, so zero identifies a dead attachment.
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

    /// IOProc writes hop here so the Core Audio real-time thread never
    /// blocks on AAC encoding or filesystem I/O. Serial → ordered writes.
    private let ioQueue = DispatchQueue(label: "lokalbot.systemaudio.write",
                                        qos: .userInitiated)
    /// The tap callback borrows from this fixed pool with a non-blocking lock.
    /// It never allocates an AVAudioPCMBuffer or waits for the writer queue.
    private let bufferPoolLock = NSLock()
    private var bufferPool: [AVAudioPCMBuffer] = []
    private let dropLock = NSLock()

    /// Captured app's PID, so we can detect the process terminating and
    /// stop instead of silently recording a blank track.
    private var capturedPID: pid_t = 0
    private var terminationObserver: NSObjectProtocol?

    /// Fired on the main thread when the captured process exits before
    /// `stop()` was called (crash, user-quit, browser tab close).
    var onCapturedProcessTerminated: ((pid_t) -> Void)?

    struct CaptureHealth {
        let duration: TimeInterval
        let audibleDuration: TimeInterval
        let framesSinceAttach: AVAudioFramePosition
        let lastAudioWriteAt: Date?
        let lastAudibleWriteAt: Date?
        let capturedPID: pid_t
        let lastRMSLevel: Float
        let peakRMSLevel: Float
        let droppedBufferCount: Int
    }

    /// `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
    /// the live meeting transcript — best-effort, never fails the recording.
    func start(capturingPID pid: pid_t, writingTo url: URL, previewTee previewURL: URL? = nil,
               timeline: RecordingAudioTimeline? = nil) throws {
        // 1. Translate the PID to its Core Audio process object.
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: pid) else {
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
                peakRMSLevel = 0
            }
            dropLock.lock()
            droppedBufferCount = 0
            dropLock.unlock()
            try attachTap(processObject: processObject, writingTo: url)
        } catch {
            cleanup(closeFile: true)
            throw error
        }

        // Latch the PID only after a successful build so cleanup() on a
        // partial start doesn't leave a stale watcher running.
        installTerminationObserver(for: pid)
    }

    /// Switches the Core Audio process tap to a new PID while keeping the
    /// existing `system.m4a` writer open. Browser meetings often move output
    /// between helper processes; closing/reopening the file would discard the
    /// audio already captured before that handoff.
    func reattach(capturingPID pid: pid_t) throws {
        guard let outputURL else { throw RecorderError.processNotFound }
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: pid) else {
            throw RecorderError.processNotFound
        }
        teardownTap()
        ioQueue.sync {
            speakerAudioClock?.discontinuity()
            framesSinceAttach = 0
        }
        do {
            try attachTap(processObject: processObject, writingTo: outputURL)
            installTerminationObserver(for: pid)
        } catch {
            teardownTap()
            throw error
        }
    }

    func captureHealth() -> CaptureHealth {
        dropLock.lock()
        let dropped = droppedBufferCount
        dropLock.unlock()
        return ioQueue.sync {
            let duration = recordingSampleRate > 0
                ? Double(framesWritten) / recordingSampleRate
                : 0
            let audibleDuration = recordingSampleRate > 0
                ? Double(audibleFramesWritten) / recordingSampleRate
                : 0
            return CaptureHealth(duration: duration,
                                 audibleDuration: audibleDuration,
                                 framesSinceAttach: framesSinceAttach,
                                 lastAudioWriteAt: lastAudioWriteAt,
                                 lastAudibleWriteAt: lastAudibleWriteAt,
                                 capturedPID: capturedPID,
                                 lastRMSLevel: lastRMSLevel,
                                 peakRMSLevel: peakRMSLevel,
                                 droppedBufferCount: dropped)
        }
    }

    private func attachTap(processObject: AudioObjectID, writingTo url: URL) throws {
        // 2. Create a stereo-mixdown tap on that process only.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // user still hears the meeting
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else { throw RecorderError.coreAudio("CreateProcessTap", err) }

        // 3. Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.badTapFormat
        }

        if let existingFormat = tapFormat, !Self.formatsCompatible(existingFormat, format) {
            throw RecorderError.badTapFormat
        }
        tapFormat = format

        // 4. Private aggregate device that contains (auto-starts) the tap.
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LokalBot Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregateID)
        guard err == noErr else { throw RecorderError.coreAudio("CreateAggregateDevice", err) }

        // 5. Output file (PCM → AAC handled by AVAudioFile). Reattaches keep
        // this writer open so samples already captured remain in the same M4A.
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 96_000,
            ]
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
            previewTee = previewTeeURL.flatMap { AudioPreviewTee(url: $0, sourceFormat: format) }
            try prepareBufferPool(format: format)
            ioQueue.sync {
                recordingSampleRate = format.sampleRate
            }
        }

        // 6. IOProc: tap buffers arrive as the aggregate device's input.
        //    The Core Audio buffer list is only valid for the duration of
        //    this callback, and the AAC encoder must not run on the real-time
        //    audio thread — copy the samples, then hop to a serial queue.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, inputTime, _, _ in
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
                self.returnBuffer(copy)
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
                guard let fileRef = self.file else { return }
                do {
                    // The real-time callback only performs one bounded copy.
                    // RMS traversal, AAC encoding, preview conversion, and I/O
                    // all stay on this serial writer queue.
                    let timelineHostStart = self.timeline?.hostTimeOnTimeline(
                        bufferHostTime: bufferHostStart, callbackHostTime: callbackHostTime,
                        callbackInstant: capturedAt) ?? bufferHostStart
                    try self.appendTimelineSilence(before: timelineHostStart, file: fileRef, format: fmt)
                    let rmsLevel = Self.measureRMS(of: copy)
                    try fileRef.write(from: copy)
                    self.speakerAudioClock?.record(hostTime: sourceHostTime, valid: sourceHostValid,
                        startFrame: self.framesWritten, frames: Int64(copy.frameLength), sampleRate: fmt.sampleRate)
                    self.previewTee?.write(copy)
                    let now = Date()
                    self.framesWritten += AVAudioFramePosition(copy.frameLength)
                    self.framesSinceAttach += AVAudioFramePosition(copy.frameLength)
                    self.lastAudioWriteAt = now
                    self.lastRMSLevel = rmsLevel
                    self.peakRMSLevel = max(self.peakRMSLevel, rmsLevel)
                    if rmsLevel >= Self.audibleRMSThreshold {
                        self.audibleFramesWritten += AVAudioFramePosition(copy.frameLength)
                        self.lastAudibleWriteAt = now
                    }
                } catch {
                    NSLog("SystemAudioRecorder write failed: \(error.localizedDescription)")
                }
            }
        }
        guard err == noErr else { throw RecorderError.coreAudio("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw RecorderError.coreAudio("DeviceStart", err) }
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
        // Watch the captured process: if it dies mid-meeting, the tap goes
        // silent. Notify upstream so the meeting can end cleanly instead of
        // producing a `system.m4a` that's half audio, half blank.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.capturedPID else { return }
            self.onCapturedProcessTerminated?(app.processIdentifier)
        }
    }

    /// Stop the tap/aggregate without closing the file. Used for browser
    /// helper handoffs where the M4A should keep accumulating samples.
    private func teardownTap() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        // Drain any IOProc writes that were already dispatched before we
        // stopped, preserving sample order before a reattach or file close.
        ioQueue.sync {}

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// One canonical close path, used by both `stop()` and startup failures.
    /// Order matters: stop the IOProc (so no new buffers are dispatched), drain
    /// the write queue (so in-flight writes finish), release the file ref
    /// (flushes the AAC encoder), then dismantle Core Audio objects.
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
        bufferPoolLock.lock()
        bufferPool.removeAll(keepingCapacity: false)
        bufferPoolLock.unlock()
    }

    /// Commit missing meeting time only when a tap actually delivers a buffer.
    /// This includes initial late attachment, handoffs, and dropped callbacks;
    /// unsuccessful/dead reattachments cannot inflate capture health.
    private func appendTimelineSilence(before hostTime: Double, file: AVAudioFile,
                                       format: AVAudioFormat) throws {
        guard let timeline else { return }
        let frames = timeline.silenceFrames(before: hostTime, framesWritten: framesWritten,
                                            sampleRate: format.sampleRate)
        try AudioTimelinePadding.write(frames: frames, format: format) { silence in
            try file.write(from: silence)
            previewTee?.write(silence)
            framesWritten += Int64(silence.frameLength)
        }
    }

    private func noteDroppedBuffer() {
        // Capture-health accounting is best-effort. Never wait behind its reader
        // or emit a log from Core Audio's realtime callback.
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
        bufferPoolLock.lock()
        bufferPool = prepared
        bufferPoolLock.unlock()
    }

    /// Runs on Core Audio's real-time callback. `try()` makes saturation a
    /// dropped-buffer event instead of priority-inverting on a contended lock.
    private func borrowBuffer(frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frameLength <= Self.pooledBufferFrameCapacity,
              bufferPoolLock.try() else { return nil }
        defer { bufferPoolLock.unlock() }
        guard let buffer = bufferPool.popLast() else { return nil }
        buffer.frameLength = frameLength
        return buffer
    }

    private func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferPoolLock.lock()
        bufferPool.append(buffer)
        bufferPoolLock.unlock()
    }

    private static func formatsCompatible(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    /// Copies `source`'s samples into `destination` buffer-by-buffer via the
    /// `AudioBufferList` (layout-agnostic) and returns the RMS across all
    /// channels. `destination.frameLength` must already equal
    /// `source.frameLength` so its buffer byte sizes are final.
    ///
    /// Do NOT rewrite this as per-channel `memcpy`s over `floatChannelData`:
    /// the process tap delivers *interleaved* stereo, where the channel
    /// pointers overlap (`data`, `data+1`, stride 2). A contiguous
    /// `frameLength * 4`-byte copy per channel then moves only the first half
    /// of each buffer's frames and leaves the second half silent — chopping
    /// the track at sampleRate/frames Hz (93.75 Hz for 512-frame buffers),
    /// which plays back as a robotic buzz. Shipped twice; measured on real
    /// recordings as a 40× level drop in the back half of every 512 frames.
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

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        return copyBuffer(source, into: destination) ? destination : nil
    }

    private static func copyBuffer(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        copyBufferList(source.audioBufferList, into: destination)
    }

    private static func copyBufferList(
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

    private static func measureRMS(of buffer: AVAudioPCMBuffer) -> Float {
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
