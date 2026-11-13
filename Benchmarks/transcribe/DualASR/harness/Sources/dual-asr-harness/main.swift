// Headless comparison of LokalBot's two multilingual transcribers on the same
// decode windows: Qwen3-ASR 1.7B (speech-swift 0.0.28, the app's
// word-attribution layout) and Whisper large-v3 turbo (WhisperKit 1.1.0, the
// app's pinned Core ML model). Both engines hear identical windows, so their
// outputs pair window by window for oracle and judge experiments.
//
// Usage: dual-asr-harness <jobs.json>
// Output: JSON lines appended to jobs.output; (condition, id) pairs already
// present are skipped, so runs are resumable.
import CoreML
import FluidAudio
import Foundation
import NaturalLanguage
import Qwen3ASR
import WhisperKit

let sampleRate = 16_000

struct Jobs: Decodable {
    var vadModel: String
    var output: String
    var qwenModelDir: String?
    var qwenModelId: String?
    var whisperModelFolder: String?
    var whisperTokenizerFolder: String?
    var items: [Item]
    var conditions: [Condition]
}

struct Item: Decodable {
    var id: String
    var wav: String
}

struct Condition: Decodable {
    var name: String
    /// "qwen" or "whisper".
    var engine: String
    /// nil = per-window auto-detection. Otherwise passed verbatim to the
    /// engine, except "vote" (the shipped vote-and-pin) and "vote-bcms"
    /// (vote-and-pin that also pins Croatian/Bosnian/Serbian votes to "sr").
    var language: String?
    /// Only items whose id starts with one of these prefixes.
    var prefixes: [String]?
}

struct Window: Encodable {
    var start: Double
    var end: Double
    var text: String
    /// Whisper only: duration-weighted mean token log-probability, the
    /// highest no-speech probability and compression ratio of its segments,
    /// and the language it decoded in.
    var avgLogprob: Double?
    var noSpeechProb: Double?
    var compressionRatio: Double?
    var detected: String?
}

struct Record: Encodable {
    var condition: String
    var id: String
    var engine: String
    var languageUsed: String
    var vote: String?
    var windows: [Window]
    var audioSeconds: Double
    var decodeSeconds: Double
}

func log(_ message: String) {
    FileHandle.standardError.write("[dual-asr] \(message)\n".data(using: .utf8)!)
}

// MARK: - Copied from LokalBot (SpeechActivitySpans.swift, QwenASREngine.swift, Transcript.swift, TranscriptLanguageVote.swift)

/// SpeechActivity.split: ≤15 s pieces of each VAD region.
func split(start: Double, end: Double, maxSegmentSeconds: Double) -> [(Double, Double)] {
    guard end > start else { return [] }
    let maxLength = max(maxSegmentSeconds, 1.0 / Double(sampleRate))
    var spans: [(Double, Double)] = []
    var cursor = start
    while cursor < end {
        let next = min(cursor + maxLength, end)
        spans.append((cursor, next))
        cursor = next
    }
    return spans
}

/// QwenASREngine.merged with the 1.7B word-attribution windows (≤60 s, gaps ≤5 s).
func merged(_ spans: [(Double, Double)], maxGap: Double = 5, maxLength: Double = 60) -> [(Double, Double)] {
    var windows: [(Double, Double)] = []
    for span in spans {
        if let last = windows.last, span.0 - last.1 <= maxGap, span.1 - last.0 <= maxLength {
            windows[windows.count - 1] = (last.0, span.1)
        } else {
            windows.append(span)
        }
    }
    return windows
}

func samplesForInference(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty, samples.count < 160 else { return samples }
    return samples + [Float](repeating: 0, count: 160 - samples.count)
}

func appMaxTokens(for sampleCount: Int) -> Int {
    min(768, max(128, Int(Double(sampleCount) / Double(sampleRate) * 18)))
}

func normalized(_ raw: String) -> String {
    let withoutControlTokens = raw.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: " ", options: .regularExpression)
    let collapsed = withoutControlTokens.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.rangeOfCharacter(from: .alphanumerics) == nil ? "" : collapsed
}

let qwenLanguages: Set<String> = [
    "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
    "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
]

func baseCode(_ language: String) -> String {
    String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
}

/// TranscriptLanguageVote.dominant: length-weighted vote over texts of three or more words.
func languageVote(_ texts: [String]) -> (code: String, share: Double)? {
    var weights: [String: Double] = [:]
    var total = 0.0
    for text in texts where text.split(whereSeparator: \.isWhitespace).count >= 3 {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= 0.5 else { continue }
        weights[baseCode(top.key.rawValue), default: 0] += Double(text.count)
        total += Double(text.count)
    }
    guard total > 0, let best = weights.max(by: { $0.value < $1.value }) else { return nil }
    return (best.key, best.value / total)
}

let bcms: Set<String> = ["hr", "bs", "sr"]

// MARK: - Windows

let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let outputURL = URL(fileURLWithPath: jobs.output)
var done = Set<String>()
if let existing = try? String(contentsOf: outputURL, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let condition = object["condition"] as? String, let id = object["id"] as? String {
            done.insert("\(condition)|\(id)")
        }
    }
}
if !FileManager.default.fileExists(atPath: outputURL.path) {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
}
let handle = try FileHandle(forWritingTo: outputURL)
handle.seekToEndOfFile()

let vadConfig = MLModelConfiguration()
vadConfig.computeUnits = VadConfig.default.computeUnits
let vad = VadManager(vadModel: try MLModel(contentsOf: URL(fileURLWithPath: jobs.vadModel), configuration: vadConfig))

var audioCache: [String: [Float]] = [:]
func audio(for item: Item) throws -> [Float] {
    if let cached = audioCache[item.wav] { return cached }
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: item.wav))
    audioCache[item.wav] = samples
    return samples
}

var windowCache: [String: [(Double, Double)]] = [:]
func windows(for item: Item, samples: [Float]) async throws -> [(Double, Double)] {
    if let cached = windowCache[item.wav] { return cached }
    var spans: [(Double, Double)] = []
    for segment in try await vad.segmentSpeech(samples) {
        guard segment.startTime.isFinite, segment.endTime.isFinite else { continue }
        let start = max(0, segment.startTime)
        guard segment.endTime > start else { continue }
        spans += split(start: start, end: segment.endTime, maxSegmentSeconds: 15)
    }
    let result = merged(spans)
    windowCache[item.wav] = result
    return result
}

func slice(_ audio: [Float], _ start: Double, _ end: Double) -> [Float] {
    let lower = max(0, min(audio.count, Int((start * Double(sampleRate)).rounded(.down))))
    let upper = max(lower, min(audio.count, Int((end * Double(sampleRate)).rounded(.up))))
    return Array(audio[lower..<upper])
}

// MARK: - Engines

var qwenModel: Qwen3ASRModel?
func qwen() async throws -> Qwen3ASRModel {
    if let qwenModel { return qwenModel }
    guard let dir = jobs.qwenModelDir, let id = jobs.qwenModelId else { throw HarnessError.missing("qwenModelDir") }
    let started = Date()
    let model = try await Qwen3ASRModel.fromPretrained(modelId: id, cacheDir: URL(fileURLWithPath: dir), offlineMode: true)
    log("qwen loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    qwenModel = model
    return model
}

var whisperPipe: WhisperKit?
func whisper() async throws -> WhisperKit {
    if let whisperPipe { return whisperPipe }
    guard let folder = jobs.whisperModelFolder, let tokenizer = jobs.whisperTokenizerFolder else {
        throw HarnessError.missing("whisperModelFolder")
    }
    let started = Date()
    let pipe = try await WhisperKit(WhisperKitConfig(
        model: "large-v3-v20240930", modelFolder: folder,
        tokenizerFolder: URL(fileURLWithPath: tokenizer), download: false))
    log("whisper loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    whisperPipe = pipe
    return pipe
}

enum HarnessError: Error { case missing(String) }

/// QwenASREngine.transcribeWindow with the 1.7B word-attribution options
/// (repetition blocking off).
func decodeQwen(_ window: [Float], language: String?) async throws -> Window {
    var options = Qwen3DecodingOptions(maxTokens: appMaxTokens(for: window.count), language: language, context: nil)
    options.longInputThresholdSeconds = .infinity
    let text = try await qwen().transcribe(audio: samplesForInference(window), sampleRate: sampleRate, options: options)
    return Window(start: 0, end: 0, text: normalized(text))
}

/// WhisperEngine.transcribe's options, applied to one window.
func decodeWhisper(_ window: [Float], language: String?) async throws -> Window {
    let options = DecodingOptions(language: language, detectLanguage: language == nil)
    let results = try await whisper().transcribe(audioArray: window, decodeOptions: options)
    let segments = results.flatMap(\.segments)
    let text = segments.map { normalized($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
    let weight = segments.reduce(0.0) { $0 + Double(max($1.end - $1.start, 0.01)) }
    let logprob = weight > 0
        ? segments.reduce(0.0) { $0 + Double($1.avgLogprob) * Double(max($1.end - $1.start, 0.01)) } / weight : nil
    return Window(start: 0, end: 0, text: text, avgLogprob: logprob,
                  noSpeechProb: segments.map { Double($0.noSpeechProb) }.max(),
                  compressionRatio: segments.map { Double($0.compressionRatio) }.max(),
                  detected: results.first?.language)
}

// MARK: - Run

for condition in jobs.conditions {
    let items = jobs.items.filter { item in
        condition.prefixes.map { $0.contains(where: { item.id.hasPrefix($0) }) } ?? true
    }
    var conditionAudio = 0.0, conditionDecode = 0.0
    for item in items where !done.contains("\(condition.name)|\(item.id)") {
        let samples = try audio(for: item)
        let spans = try await windows(for: item, samples: samples)
        let started = Date()
        func decodeAll(language: String?) async throws -> [Window] {
            var out: [Window] = []
            for (start, end) in spans {
                let window = slice(samples, start, end)
                guard !window.isEmpty else { continue }
                var decoded = condition.engine == "whisper"
                    ? try await decodeWhisper(window, language: language)
                    : try await decodeQwen(window, language: language)
                decoded.start = start
                decoded.end = end
                out.append(decoded)
            }
            return out
        }
        var language = condition.language
        var voteSummary: String?
        var decoded: [Window]
        if language == "vote" || language == "vote-bcms" {
            let auto = try await decodeAll(language: nil)
            let vote = languageVote(auto.map(\.text).filter { !$0.isEmpty })
            voteSummary = vote.map { "\($0.code)=\(String(format: "%.2f", $0.share))" } ?? "none"
            let mapped = vote.map { condition.language == "vote-bcms" && bcms.contains($0.code) ? "sr" : $0.code }
            if let vote, let mapped, vote.share >= 0.8, qwenLanguages.contains(mapped) || mapped == "sr" {
                language = mapped
                decoded = try await decodeAll(language: mapped)
            } else {
                language = nil
                decoded = auto
            }
        } else {
            decoded = try await decodeAll(language: language)
        }
        let decodeSeconds = Date().timeIntervalSince(started)
        let seconds = Double(samples.count) / Double(sampleRate)
        conditionAudio += seconds
        conditionDecode += decodeSeconds
        let record = Record(condition: condition.name, id: item.id, engine: condition.engine,
                            languageUsed: language ?? "auto", vote: voteSummary, windows: decoded,
                            audioSeconds: seconds, decodeSeconds: decodeSeconds)
        handle.write(try JSONEncoder().encode(record))
        handle.write("\n".data(using: .utf8)!)
        log("\(condition.name) \(item.id): \(spans.count) windows, language \(language ?? "auto")"
            + (voteSummary.map { " (vote \($0))" } ?? "") + ", \(String(format: "%.1f", decodeSeconds))s")
    }
    if conditionDecode > 0 {
        log("\(condition.name): \(String(format: "%.0f", conditionAudio))s audio, "
            + "\(String(format: "%.1f", conditionDecode))s decode, \(String(format: "%.1f", conditionAudio / conditionDecode))x")
    }
}
try handle.close()
