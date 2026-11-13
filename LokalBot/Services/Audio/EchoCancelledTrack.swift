import Foundation

/// Produces a copy of the microphone track with the remote side cancelled out,
/// for transcription only.
///
/// The original `mic.m4a` is never touched: it stays the recording the user can
/// play back, and this writes a 16 kHz mono sidecar that the ASR engines
/// consume (they resample to exactly that anyway). Working on the recorded
/// files rather than inside the capture path costs a codec generation — both
/// tracks are AAC by now — but it means meetings already in the library can be
/// cleaned by re-running transcription, which a capture-time canceller can
/// never do.
enum EchoCancelledTrack {

    struct Report: Equatable, Sendable {
        /// How far the microphone lagged the system track.
        var delaySeconds: TimeInterval
        /// Energy removed, in dB. Near zero means there was no echo to find —
        /// the expected outcome on headphones.
        var echoReturnLossDB: Double
        var processedSeconds: TimeInterval
        var acceptedSeconds: TimeInterval?
        var alignmentVerified = false
    }

    /// Streamed in windows so a long meeting never has both tracks resident:
    /// an hour of 16 kHz mono is 230 MB per track decoded whole.
    static let chunkSeconds: TimeInterval = 30

    /// Voice Isolation produced only 2.6-3.1 dB on the recordings used to
    /// validate this stage, while Standard mode produced at least 12.9 dB.
    /// Keep a deliberate gap between those ranges: a marginal result is more
    /// safely transcribed from the untouched microphone track.
    static let minimumAcceptedEchoReturnLossDB = 6.0

    enum StageError: Error {
        case noOverlap
    }

    /// Runs decode and DSP on a utility executor rather than the caller's
    /// actor. Cancelling the awaiting task also cancels the worker, whose
    /// cooperative checks remove any partial destination before returning.
    static func write(microphone: URL, reference: URL, to destination: URL,
                      timing: RecordingAudioTiming? = nil) async throws -> Report {
        let worker = Task.detached(priority: .utility) {
            try writeSynchronously(microphone: microphone,
                                   reference: reference,
                                   to: destination, timing: timing)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Fail open to the original microphone whenever the score is uncertain or
    /// falls in the known Voice Isolation degradation range.
    static func shouldUse(_ report: Report) -> Bool {
        report.echoReturnLossDB.isFinite
            && report.echoReturnLossDB >= minimumAcceptedEchoReturnLossDB
            && (report.acceptedSeconds ?? report.processedSeconds) > 0
    }

    private static func writeSynchronously(
        microphone: URL,
        reference: URL,
        to destination: URL, timing: RecordingAudioTiming?
    ) throws -> Report {
        do {
            return try writeFile(microphone: microphone,
                                 reference: reference,
                                 to: destination, timing: timing)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func writeFile(
        microphone: URL,
        reference: URL,
        to destination: URL, timing: RecordingAudioTiming?
    ) throws -> Report {
        try Task.checkCancellation()
        let rate = SpanAudioReader.sampleRate
        let microphoneDuration = try SpanAudioReader(url: microphone).duration
        let referenceDuration = try SpanAudioReader(url: reference).duration
        let overlapDuration = min(microphoneDuration, referenceDuration)
        guard overlapDuration > 1 else { throw StageError.noOverlap }

        let micReader = try SpanAudioReader(url: microphone)
        let writer = try WavWriter(url: destination, sampleRate: Int(rate))
        var position: TimeInterval = 0
        var processedSamples = 0
        var acceptedSeconds = 0.0
        var weightedReduction = 0.0
        var delays: [Double] = []
        var verified = timing != nil
        while position < microphoneDuration {
            try Task.checkCancellation()
            let end = min(position + chunkSeconds, microphoneDuration,
                          timing?.nextBoundary(after: position) ?? microphoneDuration)
            let mic = try micReader.samples(from: position, to: end)
            guard !mic.isEmpty else { break }
            let mapped = timing?.referenceRange(start: position, end: end)
            let range = mapped ?? SpeakerTurnAnchor(start: position, end: end)
            // A known capture gap is stronger evidence than an acoustic guess.
            // Older recordings can use local acoustic alignment, with uncertainty.
            var canAlign = timing == nil || mapped != nil
            let remote = canAlign ? try SpanAudioReader(url: reference).samples(from: range.start, to: range.end) : []
            // Do not stretch a missing tail or truncated reference over speech.
            if abs(Double(remote.count) - range.duration * rate) > 256 { canAlign = false }
            let referenceSamples = resampled(remote, count: mic.count)
            let estimate = EchoDelayEstimator.estimate(microphone: mic, reference: referenceSamples, sampleRate: rate)
            var output = mic
            if canAlign, !remote.isEmpty, estimate.isReliable {
                let shifted = mic.indices.map { index -> Float in
                    let source = index - estimate.samples
                    return referenceSamples.indices.contains(source) ? referenceSamples[source] : 0
                }
                var canceller = EchoCanceller()
                let candidate = try canceller.process(microphone: mic, reference: shifted)
                if canceller.echoReturnLossDB.isFinite,
                   canceller.echoReturnLossDB >= minimumAcceptedEchoReturnLossDB {
                    output = candidate
                    acceptedSeconds += end - position
                    weightedReduction += canceller.echoReturnLossDB * (end - position)
                    delays.append(position - range.start + Double(estimate.samples) / rate)
                } else { verified = false }
            } else { verified = false }
            try writer.append(output)
            processedSamples += output.count
            position = end
        }
        try Task.checkCancellation()
        try writer.finish()
        return Report(delaySeconds: delays.sorted().dropFirst(delays.count / 2).first ?? 0,
            echoReturnLossDB: acceptedSeconds > 0 ? weightedReduction / acceptedSeconds : 0,
            processedSeconds: Double(processedSamples) / rate,
            acceptedSeconds: acceptedSeconds, alignmentVerified: verified)
    }

    /// Correct the small measured clock-rate difference without holding either
    /// full recording in memory. Empty or missing reference remains silence.
    static func resampled(_ samples: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard samples.count > 1, count > 1 else { return Array(repeating: samples.first ?? 0, count: count) }
        return (0..<count).map { index in
            let position = Double(index) * Double(samples.count - 1) / Double(count - 1)
            let left = Int(position), right = min(left + 1, samples.count - 1)
            let fraction = Float(position - Double(left))
            return samples[left] * (1 - fraction) + samples[right] * fraction
        }
    }

}

/// Minimal streaming 16-bit PCM WAV writer. The header's two size fields are
/// only known at the end, so they are written as placeholders and patched on
/// `finish()` — which is what lets a 50-minute track be written without ever
/// holding it in memory.
final class WavWriter {
    private let handle: FileHandle
    private var bytesWritten = 0

    init(url: URL, sampleRate: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    func append(_ samples: [Float]) throws {
        var data = Data(capacity: samples.count * 2)
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    func finish() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(UInt32(36 + bytesWritten)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.le32(UInt32(bytesWritten)))
        try handle.close()
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: 44)
        data.append(Data("RIFF".utf8))
        data.append(le32(UInt32(36 + dataBytes)))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))                                 // PCM
        data.append(le16(1))                                 // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))            // byte rate
        data.append(le16(2))                                 // block align
        data.append(le16(16))                                // bits per sample
        data.append(Data("data".utf8))
        data.append(le32(UInt32(dataBytes)))
        return data
    }
}
