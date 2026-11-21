import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

protocol MicrophoneInput: AnyObject {
    var inputFormat: AVAudioFormat { get }
    var isRunning: Bool { get }
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func start() throws
    func stop()
}

final class EngineMicrophoneInput: MicrophoneInput {
    let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var isRunning: Bool { engine.isRunning }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}

#if LOKALBOT_TEST_HOOKS
final class FileMicrophoneInput: MicrophoneInput {
    private let file: AVAudioFile
    private let speed: Double
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-microphone")
    private var timer: DispatchSourceTimer?
    private var block: AVAudioNodeTapBlock?
    private var bufferSize: AVAudioFrameCount = 4_096

    init(url: URL, speed: Double = 1) throws {
        file = try AVAudioFile(forReading: url)
        self.speed = max(0.1, speed)
    }

    var inputFormat: AVAudioFormat { file.processingFormat }
    var isRunning: Bool { timer != nil }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        queue.sync {
            self.bufferSize = bufferSize
            self.block = block
        }
    }

    func removeTap() { queue.sync { block = nil } }

    func start() throws {
        let interval = Double(bufferSize) / file.processingFormat.sampleRate / speed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.deliver() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func deliver() {
        guard let block,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferSize) else { return }
        do {
            try file.read(into: buffer, frameCount: bufferSize)
        } catch {
            buffer.frameLength = 0
        }
        if buffer.frameLength == 0 {
            buffer.frameLength = bufferSize
            for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
        }
        block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }
}
#endif

protocol SystemAudioTap: AnyObject {
    func resolves(processID: pid_t) -> Bool
    func attach(processID: pid_t) throws -> AVAudioFormat
    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws
    func stopDelivery()
    func destroy()
}

final class CoreAudioProcessTap: SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func resolves(processID: pid_t) -> Bool {
        CoreAudioUtils.translatePIDToProcessObject(pid: processID) != nil
    }

    func attach(processID: pid_t) throws -> AVAudioFormat {
        guard let processObject = CoreAudioUtils.translatePIDToProcessObject(pid: processID) else {
            throw SystemAudioRecorder.RecorderError.processNotFound
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else { throw SystemAudioRecorder.RecorderError.coreAudio("CreateProcessTap", err) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioRecorder.RecorderError.badTapFormat
        }

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
        guard err == noErr else { throw SystemAudioRecorder.RecorderError.coreAudio("CreateAggregateDevice", err) }
        return format
    }

    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, inputTime, _, _ in
            deliver(inInputData, inputTime)
        }
        guard err == noErr else { throw SystemAudioRecorder.RecorderError.coreAudio("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw SystemAudioRecorder.RecorderError.coreAudio("DeviceStart", err) }
    }

    func stopDelivery() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
    }

    func destroy() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

#if LOKALBOT_TEST_HOOKS
final class FileSystemAudioTap: SystemAudioTap {
    static let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let speed: Double
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-system-audio")
    private var timer: DispatchSourceTimer?
    private var fileEnded = false
    private let frames: AVAudioFrameCount = 4_096

    init(url: URL, speed: Double = 1) throws {
        file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: Self.tapFormat) else {
            throw SystemAudioRecorder.RecorderError.badTapFormat
        }
        self.converter = converter
        self.speed = max(0.1, speed)
    }

    func resolves(processID: pid_t) -> Bool { true }

    func attach(processID: pid_t) throws -> AVAudioFormat { Self.tapFormat }

    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        let interval = Double(frames) / Self.tapFormat.sampleRate / speed
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.nextBuffer() else { return }
            var time = AudioTimeStamp()
            time.mHostTime = mach_absolute_time()
            time.mFlags = .hostTimeValid
            withUnsafePointer(to: &time) { deliver(buffer.audioBufferList, $0) }
        }
        timer.resume()
        self.timer = timer
    }

    func stopDelivery() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    func destroy() {}

    private func nextBuffer() -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.tapFormat, frameCapacity: frames) else { return nil }
        if !fileEnded {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [file] count, inputStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                      (try? file.read(into: input, frameCount: count)) != nil, input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .endOfStream || status == .error { fileEnded = true }
        }
        if output.frameLength == 0 {
            output.frameLength = frames
            for channel in UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
        }
        return output
    }
}
#endif
