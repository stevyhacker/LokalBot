import AVFoundation
import Foundation

enum AudioFileInspector {
    static let minimumTranscribableDuration: TimeInterval = 0.3

    static func duration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite ? duration : nil
    }

    static func isTranscribableAudio(at url: URL,
                                     minimumDuration: TimeInterval = minimumTranscribableDuration) -> Bool {
        guard let duration = duration(at: url) else { return false }
        return duration >= minimumDuration
    }

    /// Reading a container header alone cannot establish that the payload is
    /// complete. Recovery copies are retired only after decoding every frame.
    static func fullyDecodedDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { return nil }
        var frames: Int64 = 0
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { return nil }
                frames += Int64(buffer.frameLength)
            }
        } catch { return nil }
        guard frames == file.length else { return nil }
        return Double(frames) / file.processingFormat.sampleRate
    }
}
