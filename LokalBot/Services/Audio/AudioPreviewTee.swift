import AVFoundation

/// Writes arbitrarily long timeline gaps with one bounded, reusable buffer.
/// Call only when real audio is ready to follow the gap, on the recorder's
/// writer queue. Account for each successful chunk so a failed disk write can
/// retry the remaining gap without duplicating silence already persisted.
enum AudioTimelinePadding {
    static func write(frames: Int64, format: AVAudioFormat,
                      consume: (AVAudioPCMBuffer) throws -> Void) throws {
        guard frames > 0 else { return }
        let capacity = AVAudioFrameCount(min(frames, 32_768))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CocoaError(.fileWriteUnknown)
        }
        silence.frameLength = capacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int64(capacity)))
            try consume(silence)
            remaining -= Int64(silence.frameLength)
        }
    }
}

/// Independent 16 kHz mono PCM recovery beside the AAC track (~230 MB/hour
/// per PCM copy). The growing CAF serves live transcription; closed checkpoints
/// survive a damaged/unfinalized container. Failures reach capture health, and
/// one sink failing cannot disable the other. Called only on the writer queue.
final class AudioPreviewTee {

    static let micFileName = "mic.live.caf"
    static let systemFileName = "system.live.caf"

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let teeFormat: AVAudioFormat
    private var journal: AudioRecoveryJournal?
    private var writeFailure: String?
    private var lastInputWasPadding = false
    var failureDescription: String? { writeFailure ?? journal?.failureDescription }

    init?(url: URL, sourceFormat: AVAudioFormat) {
        guard let teeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: teeFormat) else {
            return nil
        }
        self.teeFormat = teeFormat
        self.converter = converter
        do { journal = try AudioRecoveryJournal(previewURL: url, format: teeFormat) } catch {
            writeFailure = "Recovery checkpoints unavailable: \(error.localizedDescription)"
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: teeFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: teeFormat.commonFormat,
                                   interleaved: teeFormat.isInterleaved)
        } catch {
            NSLog("AudioPreviewTee setup failed: \(error.localizedDescription)")
            writeFailure = error.localizedDescription
            if journal == nil { return nil }
        }
    }

    /// Resample + downmix `buffer` (in the source format) into the tee file.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer, isPadding: Bool = false) -> Bool {
        guard let converter, buffer.frameLength > 0 else { return false }
        lastInputWasPadding = isPadding
        let ratio = teeFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: teeFormat, frameCapacity: capacity) else {
            writeFailure = "Recovery conversion buffer unavailable"
            self.converter = nil
            return false
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
        guard status != .error else {
            // Disable rather than spam the audio thread with retries.
            NSLog("AudioPreviewTee convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            writeFailure = conversionError?.localizedDescription ?? "PCM conversion failed"
            self.converter = nil
            return false
        }
        guard output.frameLength > 0 else { return true } // converter retained a short tail
        return writePCM(output, isPadding: isPadding)
    }

    private func writePCM(_ output: AVAudioPCMBuffer, isPadding: Bool) -> Bool {
        var saved = false
        if let journal {
            do { try journal.append(output, isPadding: isPadding); saved = true } catch { writeFailure = error.localizedDescription }
        }
        if let file {
            do { try file.write(from: output); saved = true } catch {
                writeFailure = error.localizedDescription
                self.file = nil // never resume this file with missing frames
            }
        }
        return saved
    }

    func close() {
        // Resampling can retain a short tail. Flush it before closing so a
        // finalized preview/recovery file keeps the primary track's timeline,
        // including the final speech after a long padded interval.
        if let converter {
            for _ in 0..<8 {
                guard let tail = AVAudioPCMBuffer(pcmFormat: teeFormat, frameCapacity: 4_096) else { break }
                var error: NSError?
                let status = converter.convert(to: tail, error: &error) { _, outputStatus in
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                if tail.frameLength > 0 {
                    if !writePCM(tail, isPadding: lastInputWasPadding) { break }
                }
                if status == .error || status == .endOfStream || tail.frameLength == 0 { break }
            }
        }
        file?.close()
        file = nil
        journal?.close()
        converter = nil
    }
}
