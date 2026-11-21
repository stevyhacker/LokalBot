import AVFoundation
import Foundation

@main
struct AudioRecoveryCrashProbe {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let preview = folder.appendingPathComponent(AudioPreviewTee.micFileName)
        if mode == "write" {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let tee = AudioPreviewTee(url: preview, sourceFormat: format)!
            let primary = try AVAudioFile(forWriting: folder.appendingPathComponent("mic.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            for (frames, value) in [(32_000, Float(0.25)), (32_000, Float(0.5)), (5_000, Float(0.75))] {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                buffer.floatChannelData![0].initialize(repeating: value, count: frames)
                guard tee.write(buffer) else { throw CocoaError(.fileWriteUnknown) }
                try primary.write(from: buffer)
            }
            try Data("ready".utf8).write(to: folder.appendingPathComponent("ready"))
            withExtendedLifetime((tee, primary)) {
                while true { Thread.sleep(forTimeInterval: 1) }
            }
        } else {
            try FileManager.default.removeItem(at: preview)
            guard let recovered = try AudioRecoveryJournal.recover(previewURL: preview) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let reader = try AVAudioFile(forReading: recovered)
            let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4_096)!
            var frames = 0
            while reader.framePosition < reader.length {
                try reader.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                for index in 0..<Int(buffer.frameLength) {
                    let absolute = frames + index
                    let expected: Float = absolute < 32_000 ? 0.25 : absolute < 64_000 ? 0.5 : 0.75
                    guard abs(buffer.floatChannelData![0][index] - expected) < 0.0001 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                frames += Int(buffer.frameLength)
            }
            guard frames >= 64_000, frames <= 69_000,
                  AudioFileInspector.fullyDecodedDuration(at: recovered) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            MeetingAudioFiles.removeRedundantRecoveryFiles(in: folder)
            guard MeetingAudioFiles.readableURL(for: .mic, in: folder) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            print("SIGKILL recovery verified: \(frames) frames; both committed waveform intervals intact.")
        }
    }
}
