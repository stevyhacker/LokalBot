import FluidAudio
import Foundation
import MLX
import Qwen3ASR

struct Item: Decodable {
    var id: String
    var pcm: String
    var language: String?
    var hints: String?
}
struct Jobs: Decodable {
    var engine: String
    var modelPath: String
    var modelID: String?
    var output: String
    var warmup: String
    var repeats: Int
    var items: [Item]
}
func samples(_ path: String) throws -> [Float] {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func seconds(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}
func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
FileManager.default.createFile(atPath: jobs.output, contents: nil)
let output = try FileHandle(forWritingTo: URL(fileURLWithPath: jobs.output))
func emit(_ value: [String: Any]) throws {
    output.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    output.write(Data([10]))
}

var qwen: Qwen3ASRModel?
var parakeet: AsrManager?
let start = DispatchTime.now().uptimeNanoseconds
if jobs.engine == "qwen" {
    qwen = try await Qwen3ASRModel.fromPretrained(modelId: jobs.modelID!, cacheDir: URL(fileURLWithPath: jobs.modelPath), offlineMode: true)
} else {
    let models = try AsrModels.loadLocal(from: URL(fileURLWithPath: jobs.modelPath), version: .ultra, encoderPrecision: .int8)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    parakeet = manager
}
try emit(["type": "load", "engine": jobs.engine, "seconds": seconds(start)])
func decode(_ pcm: [Float], _ item: Item) async throws -> [String: Any] {
    if let qwen {
        let options = Qwen3DecodingOptions(maxTokens: min(768, max(128, Int(Double(pcm.count) / 16000 * 18))),
                                          language: item.language, context: item.hints)
        let text = try qwen.transcribeCheckingCancellation(audio: pcm, sampleRate: 16000, options: options)
        return ["text": text]
    }
    var state = try TdtDecoderState()
    let result = try await parakeet!.transcribe(pcm, decoderState: &state, language: item.language.flatMap { Language(rawValue: $0) })
    return ["text": result.text, "words": (result.tokenTimings ?? []).map {
        ["word": $0.token, "start": $0.startTime, "end": $0.endTime] as [String: Any]
    }]
}
let warmup = try samples(jobs.warmup)
let warmStart = DispatchTime.now().uptimeNanoseconds
_ = try await decode(warmup, Item(id: "warmup", pcm: jobs.warmup))
try emit(["type": "warmup", "engine": jobs.engine, "seconds": seconds(warmStart)])
for repetition in 0..<jobs.repeats {
    // Reverse alternating passes to reduce systematic position effects.
    let items = repetition % 2 == 0 ? jobs.items : Array(jobs.items.reversed())
    for item in items {
        let pcm = try samples(item.pcm)
        let began = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await decode(pcm, item)
            let duration = seconds(began)
            try emit(["id": item.id, "engine": jobs.engine, "repeat": repetition,
                      "seconds": duration, "audioSeconds": Double(pcm.count) / 16000, "result": result])
            log("\(jobs.engine) \(repetition) \(item.id) \(String(format: "%.3f", duration))s")
        } catch {
            try emit(["id": item.id, "engine": jobs.engine, "repeat": repetition,
                      "seconds": seconds(began), "error": String(describing: error)])
            log("\(jobs.engine) \(item.id) ERROR \(error)")
        }
    }
}
if jobs.engine == "qwen" {
    try emit(["type": "memory", "mlxPeakBytes": Memory.peakMemory, "mlxActiveBytes": Memory.activeMemory])
}
try output.close()
