import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation

struct Input: Codable { let id: String; let audio: String }
struct Segment: Codable { let start: Double; let end: Double; let speaker: String }
struct VoiceSample: Codable { let start: Double; let end: Double; let vector: [Float] }
struct Result: Codable {
    let id: String
    let variant: String
    let duration: Double
    let modelLoadSeconds: Double
    let processingSeconds: Double
    let audioLoadSeconds: Double
    let peakRSSBytes: Int64
    let segments: [Segment]
    let chunkSeconds: [Double]
    var voiceSamples: [VoiceSample]? = nil
}
func elapsed(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}
func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func peakRSS() -> Int64 {
    var r = rusage()
    getrusage(RUSAGE_SELF, &r)
    return Int64(r.ru_maxrss)
}

@main struct Bench {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            fatalError("Usage: DiarBench manifest.json model-directory variant output-directory [streaming]")
        }
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let modelsURL = URL(fileURLWithPath: args[2])
        let variant = args[3]
        let output = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let loadStart = tick()
        #if NEMOTRON
        guard let config = Nemotron3Config.preset(named: variant) else { fatalError("Unknown preset") }
        let units: MLComputeUnits = variant.contains("split") ? .cpuAndNeuralEngine : .all
        let models = try await Nemotron3Models.load(config: config, directory: modelsURL, computeUnits: units)
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        #else
        let models = try await OfflineDiarizerModels.load(from: modelsURL)
        var clustering = OfflineDiarizerConfig.Clustering.community
        var embedding = OfflineDiarizerConfig.Embedding.community
        var postProcessing = OfflineDiarizerConfig.PostProcessing.community
        var segmentation = OfflineDiarizerConfig.Segmentation.community
        if variant != "community-overlap" {
            clustering.threshold = 0.70
            clustering.warmStartFa = 0.07
            embedding.minSegmentDurationSeconds = 0.3
            postProcessing.minGapDurationSeconds = 0.05
            segmentation.stepRatio = 0.15
        }
        if variant == "community-overlap" || variant == "baseline-overlap" {
            postProcessing.exclusiveSegments = false
        }
        var config = OfflineDiarizerConfig(segmentation: segmentation, embedding: embedding,
            clustering: clustering, postProcessing: postProcessing)
        config.exposeChunkEmbeddings = args.contains("voices")
        #endif
        let loadSeconds = elapsed(loadStart)
        for input in inputs {
            let url = URL(fileURLWithPath: input.audio)
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let totalStart = tick()
            var audioSeconds = 0.0
            var chunks: [Double] = []
            let segments: [Segment]
            var voiceSamples: [VoiceSample]?
            #if NEMOTRON
            let samples = try AudioConverter(sampleRate: 16000).resampleAudioFile(url)
            audioSeconds = elapsed(totalStart)
            diarizer.reset()
            var probs: [Float] = []
            var frames = 0
            if args.count > 5 && args[5] == "streaming" {
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    let start = tick()
                    let results = try autoreleasepool {
                        diarizer.appendAudio(Array(samples[offset..<min(offset + 1600, samples.count)]))
                        return try diarizer.processBufferedAudio()
                    }
                    if !results.isEmpty { chunks.append(elapsed(start)) }
                    for result in results { probs.append(contentsOf: result.probabilities); frames += result.frameCount }
                }
                for result in try diarizer.finishStream() {
                    probs.append(contentsOf: result.probabilities); frames += result.frameCount
                }
            } else {
                (probs, frames) = try diarizer.processComplete(samples)
            }
            segments = Nemotron3Diarizer.segments(probabilities: probs, frameCount: frames).map {
                Segment(start: Double($0.startSeconds), end: Double($0.endSeconds), speaker: "S\($0.speakerIndex)")
            }
            #else
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let diarization = try await manager.process(url)
            voiceSamples = diarization.chunkEmbeddings?.map {
                VoiceSample(start: $0.startTimeSeconds, end: $0.endTimeSeconds, vector: $0.embedding256)
            }
            segments = diarization.segments.map {
                Segment(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
            }
            #endif
            let seconds = elapsed(totalStart)
            let result = Result(id: input.id, variant: variant, duration: duration, modelLoadSeconds: loadSeconds,
                processingSeconds: seconds, audioLoadSeconds: audioSeconds, peakRSSBytes: peakRSS(),
                segments: segments, chunkSeconds: chunks, voiceSamples: voiceSamples)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: output.appendingPathComponent(input.id + ".json"), options: .atomic)
            print("DONE \(variant) \(input.id) audio=\(duration)s processing=\(seconds)s speakers=\(Set(segments.map(\.speaker)).count) peakRSS=\(peakRSS())")
            fflush(stdout)
        }
    }
}
