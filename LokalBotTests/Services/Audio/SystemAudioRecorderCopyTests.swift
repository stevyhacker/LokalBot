import AVFoundation
import XCTest
@testable import LokalBot

final class SystemAudioRecorderCopyTests: XCTestCase {

    private let frameCount: AVAudioFrameCount = 512

    private func makeFormat(interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 48_000,
                      channels: 2,
                      interleaved: interleaved)!
    }

    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        return buffer
    }

    private func forEachRawFloat(
        of buffer: AVAudioPCMBuffer,
        _ body: (_ bufferIndex: Int, _ floatIndex: Int, _ pointer: UnsafeMutablePointer<Float>) -> Void
    ) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (bufferIndex, audioBuffer) in list.enumerated() {
            guard let data = audioBuffer.mData else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for floatIndex in 0..<count {
                body(bufferIndex, floatIndex, floats + floatIndex)
            }
        }
    }

    private func fillDeterministicRamp(_ buffer: AVAudioPCMBuffer) {
        var value: Float = 0
        forEachRawFloat(of: buffer) { _, floatIndex, pointer in
            value += 1
            pointer.pointee = (floatIndex % 2 == 0 ? 1 : -1) * value / 4_096
        }
    }

    private func fill(_ buffer: AVAudioPCMBuffer, constant: Float) {
        forEachRawFloat(of: buffer) { _, _, pointer in
            pointer.pointee = constant
        }
    }

    private func zero(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list where audioBuffer.mData != nil {
            memset(audioBuffer.mData!, 0, Int(audioBuffer.mDataByteSize))
        }
    }

    private func referenceRMS(of buffer: AVAudioPCMBuffer) -> Float {
        var sumSquares = 0.0
        var count = 0
        forEachRawFloat(of: buffer) { _, _, pointer in
            sumSquares += Double(pointer.pointee) * Double(pointer.pointee)
            count += 1
        }
        return count == 0 ? 0 : Float((sumSquares / Double(count)).squareRoot())
    }

    private func sample(_ buffer: AVAudioPCMBuffer, frame: Int, channel: Int) -> Float {
        buffer.floatChannelData![channel][frame * buffer.stride]
    }

    private func assertLosslessCopy(interleaved: Bool,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let format = makeFormat(interleaved: interleaved)
        let source = makeBuffer(format: format, frames: frameCount)
        fillDeterministicRamp(source)
        let destination = makeBuffer(format: format, frames: frameCount)
        zero(destination)

        XCTAssertTrue(SystemAudioRecorder.copyBufferList(source.audioBufferList, into: destination),
                      file: file, line: line)
        let rms = SystemAudioRecorder.measureRMS(of: destination)

        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: destination.audioBufferList))
        XCTAssertEqual(sourceList.count, destinationList.count, file: file, line: line)
        let totalFloats = sourceList.reduce(0) { $0 + Int($1.mDataByteSize) / MemoryLayout<Float>.size }
        XCTAssertEqual(totalFloats, Int(frameCount) * Int(format.channelCount),
                       "pattern must cover every frame of every channel", file: file, line: line)
        for (index, (src, dst)) in zip(sourceList, destinationList).enumerated() {
            XCTAssertEqual(src.mDataByteSize, dst.mDataByteSize,
                           "AudioBuffer \(index) byte size", file: file, line: line)
            XCTAssertEqual(memcmp(src.mData!, dst.mData!, Int(src.mDataByteSize)), 0,
                           "AudioBuffer \(index) must match byte-for-byte after the copy",
                           file: file, line: line)
        }

        var lost: [String] = []
        for frame in Int(frameCount) / 2..<Int(frameCount) {
            for channel in 0..<Int(format.channelCount) {
                let expected = sample(source, frame: frame, channel: channel)
                XCTAssertNotEqual(expected, 0,
                                  "test pattern must be nonzero so silence is detectable",
                                  file: file, line: line)
                let actual = sample(destination, frame: frame, channel: channel)
                if actual != expected {
                    lost.append("frame \(frame) ch \(channel): expected \(expected), got \(actual)")
                }
            }
        }
        XCTAssertTrue(lost.isEmpty,
                      """
                      \(lost.count) back-half sample(s) corrupted — the 93.75 Hz \
                      robotic-buzz regression. First: \(lost.first ?? "")
                      """,
                      file: file, line: line)

        XCTAssertEqual(rms, referenceRMS(of: source), accuracy: 1e-4,
                       "RMS must be computed over every sample", file: file, line: line)
    }

    func testInterleavedStereoCopyPreservesEverySample() {
        assertLosslessCopy(interleaved: true)
    }

    func testDeinterleavedStereoCopyPreservesEverySample() {
        assertLosslessCopy(interleaved: false)
    }

    func testMicrophoneTapCopyPreservesInterleavedSamples() throws {
        try assertLosslessMicrophoneCopy(interleaved: true)
    }

    func testMicrophoneTapCopyPreservesPlanarSamples() throws {
        try assertLosslessMicrophoneCopy(interleaved: false)
    }

    func testMicrophoneBufferPoolIsBoundedAndReusesReturnedBuffer() throws {
        let format = makeFormat(interleaved: false)
        let source = makeBuffer(format: format, frames: frameCount)
        let pool = try XCTUnwrap(MicAudioBufferPool(
            format: format,
            bufferCount: 2,
            frameCapacity: frameCount))

        let first = try XCTUnwrap(pool.borrow(for: source))
        let second = try XCTUnwrap(pool.borrow(for: source))
        XCTAssertEqual(pool.availableBufferCount, 0)
        XCTAssertNil(pool.borrow(for: source))

        pool.returnBuffer(first)
        XCTAssertEqual(pool.availableBufferCount, 1)
        let reused = try XCTUnwrap(pool.borrow(for: source))
        XCTAssertTrue(reused === first)
        pool.returnBuffer(reused)
        pool.returnBuffer(second)
        XCTAssertEqual(pool.availableBufferCount, 2)
    }

    func testMicrophoneBufferPoolRejectsOversizedOrMismatchedInput() throws {
        let format = makeFormat(interleaved: false)
        let pool = try XCTUnwrap(MicAudioBufferPool(
            format: format,
            bufferCount: 1,
            frameCapacity: frameCount))
        let oversized = makeBuffer(format: format, frames: frameCount + 1)
        let mismatchedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false)!
        let mismatched = makeBuffer(format: mismatchedFormat, frames: frameCount)

        XCTAssertNil(pool.borrow(for: oversized))
        XCTAssertNil(pool.borrow(for: mismatched))
        XCTAssertEqual(pool.availableBufferCount, 1)
    }

    func testMicrophoneBufferPoolBrokerAdoptsNegotiatedTapFormat() throws {
        let staleFormat = makeFormat(interleaved: false)
        let negotiatedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false)!
        let source = makeBuffer(format: negotiatedFormat, frames: frameCount)
        let broker = MicAudioBufferPoolBroker(
            bufferCount: 2,
            frameCapacity: frameCount)
        XCTAssertTrue(broker.install(format: staleFormat))

        guard case .refreshNeeded(let requestedFormat) = broker.borrow(for: source) else {
            return XCTFail("A negotiated tap mismatch must request a replacement pool")
        }
        XCTAssertEqual(requestedFormat.sampleRate, 24_000)
        XCTAssertEqual(requestedFormat.channelCount, 1)
        guard case .unavailable = broker.borrow(for: source) else {
            return XCTFail("Only one off-thread refresh should be scheduled at a time")
        }

        XCTAssertTrue(broker.install(format: requestedFormat))
        guard case .borrowed(let buffer, let pool) = broker.borrow(for: source) else {
            return XCTFail("The negotiated format must become borrowable after refresh")
        }
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        pool.returnBuffer(buffer)
    }

    func testMicrophoneDropCounterNeverWaitsForContendedHealthLock() {
        let lock = NSLock()
        let counter = MicRealtimeDropCounter(lock: lock)
        lock.lock()
        XCTAssertFalse(counter.recordDrop())
        lock.unlock()

        XCTAssertEqual(counter.snapshot(), 0)
        XCTAssertTrue(counter.recordDrop())
        XCTAssertEqual(counter.snapshot(), 1)
        counter.reset()
        XCTAssertEqual(counter.snapshot(), 0)
    }

    func testFailedMicrophoneRecoveryCannotCreateSilencePlan() {
        var gate = AudioRecoverySilenceCommitGate()

        XCTAssertNil(gate.consumeAfterCapturedBuffer(forElapsed: 5))
        gate.stage()
        gate.cancel()

        XCTAssertFalse(gate.isPending)
        XCTAssertNil(gate.consumeAfterCapturedBuffer(forElapsed: 5))
    }

    func testRecoveredMicrophoneBufferCommitsGapExactlyOnce() throws {
        var gate = AudioRecoverySilenceCommitGate()
        gate.stage()

        let plan = try XCTUnwrap(gate.consumeAfterCapturedBuffer(forElapsed: 2.5))

        XCTAssertEqual(plan.duration, 2.5, accuracy: 0.000_001)
        XCTAssertFalse(gate.isPending)
        XCTAssertNil(gate.consumeAfterCapturedBuffer(forElapsed: 2.5))
    }

    func testRecoveredMicrophoneGapPreservesTheEntireOutage() throws {
        var gate = AudioRecoverySilenceCommitGate()
        gate.stage()

        let plan = try XCTUnwrap(gate.consumeAfterCapturedBuffer(forElapsed: 90))

        XCTAssertEqual(plan.duration, 90)
    }

    private func assertLosslessMicrophoneCopy(
        interleaved: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let format = makeFormat(interleaved: interleaved)
        let source = makeBuffer(format: format, frames: frameCount)
        fillDeterministicRamp(source)

        let pool = try XCTUnwrap(MicAudioBufferPool(
            format: format,
            bufferCount: 1,
            frameCapacity: frameCount), file: file, line: line)
        let destination = try XCTUnwrap(pool.borrow(for: source), file: file, line: line)
        XCTAssertTrue(MicRecorder.copyBuffer(source, into: destination), file: file, line: line)
        XCTAssertEqual(destination.frameLength, source.frameLength, file: file, line: line)
        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationList = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        XCTAssertEqual(destinationList.count, sourceList.count, file: file, line: line)
        for (src, dst) in zip(sourceList, destinationList) {
            XCTAssertEqual(dst.mDataByteSize, src.mDataByteSize, file: file, line: line)
            XCTAssertEqual(memcmp(src.mData!, dst.mData!, Int(src.mDataByteSize)), 0,
                           file: file, line: line)
        }
        pool.returnBuffer(destination)
    }

    func testRMSOfConstantHalfAmplitudeInterleaved() {
        let format = makeFormat(interleaved: true)
        let source = makeBuffer(format: format, frames: frameCount)
        fill(source, constant: 0.5)
        let destination = makeBuffer(format: format, frames: frameCount)

        let rms = SystemAudioRecorder.copyAndMeasureRMS(from: source, into: destination)

        XCTAssertEqual(rms, 0.5, accuracy: 1e-4)
    }

    func testRMSOfConstantHalfAmplitudeDeinterleaved() {
        let format = makeFormat(interleaved: false)
        let source = makeBuffer(format: format, frames: frameCount)
        fill(source, constant: 0.5)
        let destination = makeBuffer(format: format, frames: frameCount)

        let rms = SystemAudioRecorder.copyAndMeasureRMS(from: source, into: destination)

        XCTAssertEqual(rms, 0.5, accuracy: 1e-4)
    }

    func testZeroFrameBufferReturnsZeroRMS() {
        for interleaved in [true, false] {
            let format = makeFormat(interleaved: interleaved)
            let source = makeBuffer(format: format, frames: 0)
            let destination = makeBuffer(format: format, frames: 0)

            let rms = SystemAudioRecorder.copyAndMeasureRMS(from: source, into: destination)

            XCTAssertEqual(rms, 0,
                           "zero-frame buffer must yield RMS 0 (\(interleaved ? "interleaved" : "deinterleaved"))")
        }
    }
}
