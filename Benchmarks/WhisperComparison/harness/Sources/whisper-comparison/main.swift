import AVFoundation
import Foundation
import WhisperKit

struct Clip: Decodable {
    var id: String
    var wav: String
    var group: String
}

func audio(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// manifest, model folder, tokenizer folder, model name, output, label
let args = CommandLine.arguments
guard args.count == 7 else { fatalError("manifest modelFolder tokenizerFolder modelName output label") }
let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let started = Date()
let pipe = try await WhisperKit(WhisperKitConfig(
    model: args[4], modelFolder: args[2], tokenizerFolder: URL(fileURLWithPath: args[3]),
    verbose: false, logLevel: .none, download: false))
let loadSeconds = Date().timeIntervalSince(started)
let first = try audio(clips[0].wav)
_ = try await pipe.transcribe(audioArray: Array(first.prefix(80_000)),
                             decodeOptions: DecodingOptions(detectLanguage: true))
log("\(args[6]) loaded and warmed; load \(loadSeconds)s")
FileManager.default.createFile(atPath: args[5], contents: nil)
let output = try FileHandle(forWritingTo: URL(fileURLWithPath: args[5]))
for clip in clips {
    let samples = try audio(clip.wav)
    // Auto matches the app when language is unset; bs follows the previous
    // Serbian-meeting experiment. Keep them separate when reporting results.
    let languages: [String?] = clip.group == "bcms" ? [nil, "bs"] : [nil]
    for language in languages {
        let begin = Date()
        let results = try await pipe.transcribe(audioArray: samples,
            decodeOptions: DecodingOptions(language: language, detectLanguage: language == nil))
        let seconds = Date().timeIntervalSince(begin)
        let segments = results.flatMap(\.segments)
        let row: [String: Any] = [
            "model": args[6], "id": clip.id, "group": clip.group, "language": language ?? "auto",
            "detected": results.first?.language ?? "", "text": segments.map(\.text).joined(separator: " "),
            "audioSeconds": Double(samples.count) / 16_000, "decodeSeconds": seconds,
            "loadSeconds": loadSeconds,
            "segments": segments.map { ["start": Double($0.start), "end": Double($0.end)] }
        ]
        output.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        output.write(Data("\n".utf8))
        log("\(clip.id) \(language ?? "auto"): \(String(format: "%.3f", seconds))s")
    }
}
try output.close()
