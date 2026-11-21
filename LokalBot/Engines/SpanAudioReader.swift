import AVFoundation
import Foundation

final class SpanAudioReader {
    static let sampleRate = 16_000.0

    enum ReaderError: Error {
        case formatUnavailable
        case bufferAllocationFailed
    }

    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat

    var duration: TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
            channels: 1, interleaved: false) else {
            throw ReaderError.formatUnavailable
        }
        outputFormat = format
    }

    func samples(from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        let firstFrame = min(AVAudioFramePosition(max(0, start) * sourceRate), file.length)
        let lastFrame = min(AVAudioFramePosition(max(0, end) * sourceRate), file.length)
        guard lastFrame > firstFrame else { return [] }

        file.framePosition = firstFrame
        let frameCount = AVAudioFrameCount(lastFrame - firstFrame)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw ReaderError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer, frameCount: frameCount)

        if sourceFormat.sampleRate == outputFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return Self.floats(of: sourceBuffer)
        }
        return try Self.convert(sourceBuffer, to: outputFormat)
    }

    private static func convert(
        _ source: AVAudioPCMBuffer, to outputFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter = AVAudioConverter(from: source.format, to: outputFormat) else {
            throw ReaderError.formatUnavailable
        }
        converter.primeMethod = .none
        var fed = false
        let input: AVAudioConverterInputBlock = { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let maximumFrames = Int(ceil(Double(source.frameLength) * ratio))
        var result: [Float] = []
        result.reserveCapacity(maximumFrames)
        while true {
            guard let chunk = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 8_192) else {
                throw ReaderError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError, withInputFrom: input)
            if let conversionError { throw conversionError }
            result.append(contentsOf: Self.floats(of: chunk).prefix(maximumFrames - result.count))
            if status == .endOfStream || status == .error || chunk.frameLength == 0 { break }
        }
        return result
    }

    private static func floats(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
