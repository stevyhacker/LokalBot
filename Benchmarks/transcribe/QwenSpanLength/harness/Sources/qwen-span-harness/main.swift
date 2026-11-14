// Headless replica of LokalBot's QwenASREngine span path (speech-swift 0.0.26,
// FluidAudio 0.17.1, aufklarer/Qwen3-ASR-1.7B-MLX-8bit) with the span layout,
// language hint, n-gram escalation and token cap exposed as experiment knobs.
//
// Usage: qwen-span-harness <jobs.json>
// Output: JSON lines appended to jobs.output; (condition, id) pairs already
// present are skipped, so runs are resumable.
//
// ASR_BACKEND=llama sends every decode window to a llama-server running
// Qwen3-ASR GGUF weights (LLAMA_URL, default http://127.0.0.1:8080) instead
// of speech-swift. Windows, language and context are identical; the window is
// posted as a 16 kHz float WAV with speech-swift's exact prompt layout.
import CoreML
import FluidAudio
import Foundation
import NaturalLanguage
import MLX
import Qwen3ASR

let sampleRate = 16_000

struct Jobs: Decodable {
    var modelDir: String
    var modelId: String
    var vadModel: String
    var output: String
    var items: [Item]
    var conditions: [Condition]
}

struct Item: Decodable {
    var id: String
    var wav: String
    /// True language code for `oracle` conditions (nil or "a+b" = no single oracle).
    var language: String?
    /// Named explicit layouts on the item's own timeline (seconds).
    var layouts: [String: [[Double]]]?
}

struct Layout: Decodable {
    /// vad: FluidAudio VAD regions (maxSpeechDuration = vadMax) then split(split).
    /// merge: vad regions merged across gaps <= gap into spans <= maxLen.
    /// whole: the whole item as one window.
    /// explicit: layouts[key] used as decode windows directly.
    /// regions: layouts[key] are diarization regions; each region is VAD-split
    ///          like AttributedTrackTranscriber -> QwenASREngine does.
    var kind: String
    var vadMax: Double?
    var split: Double?
    var gap: Double?
    var maxLen: Double?
    var key: String?
    /// Silero entry threshold (FluidAudio default 0.85; exit is 0.15 lower).
    var vadThreshold: Float?
    /// Padding added around each VAD region, seconds (FluidAudio default 0.1).
    var padding: Double?
}

struct Condition: Decodable {
    var name: String
    var layout: Layout
    /// nil = auto-detect (app's "auto"); otherwise passed verbatim as the app does.
    var language: String?
    /// "runtime" = speech-swift default (auto no-repeat-3gram above 15 s);
    /// "off" = long-input escalation disabled.
    var ngram: String
    /// nil = app formula min(768, max(128, seconds * 18)); otherwise fixed cap.
    var maxTokens: Int?
    /// Only items whose id starts with one of these prefixes.
    var prefixes: [String]?
    /// Vocabulary/context prompt, passed as Qwen3DecodingOptions.context like the app.
    var context: String?
}

struct Window: Encodable {
    var start: Double
    var end: Double
    var cap: Int
    var text: String
}

struct Record: Encodable {
    var backend: String
    var condition: String
    var id: String
    /// Language actually passed to Qwen ("auto" when none), and detection details.
    var languageUsed: String?
    var detected: String?
    var text: String
    var windows: [Window]
    var audioSeconds: Double
    var decodeSeconds: Double
}

// MARK: - Copied from LokalBot (SpeechActivitySpans.swift, QwenASREngine.swift)

func split(start: Double, end: Double, maxSegmentSeconds: Double?) -> [(Double, Double)] {
    guard end > start else { return [] }
    let minLength = 1.0 / Double(sampleRate)
    let maxLength = maxSegmentSeconds.map { max($0, minLength) } ?? (end - start)
    var spans: [(Double, Double)] = []
    var cursor = start
    while cursor < end {
        let next = min(cursor + maxLength, end)
        spans.append((cursor, next))
        cursor = next
    }
    return spans
}

func samplesForInference(_ samples: [Float]) -> [Float] {
    let minimumSamples = 160
    guard !samples.isEmpty, samples.count < minimumSamples else { return samples }
    return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
}

func appMaxTokens(for sampleCount: Int) -> Int {
    let seconds = Double(sampleCount) / Double(sampleRate)
    return min(768, max(128, Int(seconds * 18)))
}

/// SpanAudioReader.samples(from:to:): floor both frame positions.
func slice(_ audio: [Float], _ start: Double, _ end: Double) -> [Float] {
    let first = min(Int(max(0, start) * Double(sampleRate)), audio.count)
    let last = min(Int(max(0, end) * Double(sampleRate)), audio.count)
    guard last > first else { return [] }
    return Array(audio[first..<last])
}

/// Transcript.normalizedText: strip <|…|> control tokens, collapse whitespace,
/// and drop text with no alphanumerics.
func normalized(_ raw: String) -> String {
    let stripped = raw.replacingOccurrences(of: #"<\|[^>]*\|>"#, with: " ", options: .regularExpression)
    let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.rangeOfCharacter(from: .alphanumerics) == nil ? "" : collapsed
}

// MARK: - Layouts

var vadModelForThresholds: MLModel?
var vadManagers: [Float: VadManager] = [:]

/// One VadManager per entry threshold, sharing the loaded Core ML model.
func vadManager(_ fallback: VadManager, threshold: Float?) -> VadManager {
    guard let threshold, let model = vadModelForThresholds else { return fallback }
    if let cached = vadManagers[threshold] { return cached }
    let manager = VadManager(config: VadConfig(defaultThreshold: threshold), vadModel: model)
    vadManagers[threshold] = manager
    return manager
}

func vadRegions(_ vad: VadManager, _ audio: [Float], maxSpeech: Double,
                threshold: Float? = nil, padding: Double? = nil) async throws -> [(Double, Double)] {
    let config = VadSegmentationConfig(maxSpeechDuration: maxSpeech, speechPadding: padding ?? 0.1)
    let segments = try await vadManager(vad, threshold: threshold).segmentSpeech(audio, config: config)
    return segments.compactMap { segment in
        guard segment.startTime.isFinite, segment.endTime.isFinite else { return nil }
        let start = max(0, segment.startTime)
        return segment.endTime > start ? (start, segment.endTime) : nil
    }
}

func windows(for layout: Layout, item: Item, audio: [Float], vad: VadManager) async throws -> [(Double, Double)] {
    let duration = Double(audio.count) / Double(sampleRate)
    switch layout.kind {
    case "whole":
        return [(0, duration)]
    case "vad":
        let regions = try await vadRegions(vad, audio, maxSpeech: layout.vadMax ?? 14, threshold: layout.vadThreshold, padding: layout.padding)
        return regions.flatMap { split(start: $0.0, end: $0.1, maxSegmentSeconds: layout.split) }
    case "merge":
        let maxLen = layout.maxLen ?? 120
        let regions = try await vadRegions(vad, audio, maxSpeech: layout.vadMax ?? maxLen, threshold: layout.vadThreshold, padding: layout.padding)
        var out: [(Double, Double)] = []
        for region in regions {
            for piece in split(start: region.0, end: region.1, maxSegmentSeconds: maxLen) {
                if let last = out.last, piece.0 - last.1 <= (layout.gap ?? 5), piece.1 - last.0 <= maxLen {
                    out[out.count - 1].1 = piece.1
                } else {
                    out.append(piece)
                }
            }
        }
        return out
    case "explicit":
        return (item.layouts?[layout.key ?? ""] ?? []).map { ($0[0], $0[1]) }
    case "intersect":
        // Whole-item VAD windows clipped to each explicit region: region cuts
        // without restarting VAD at every region edge. With `gap`, clipped
        // pieces inside one region are merged across pauses <= gap up to maxLen.
        let track = try await vadRegions(vad, audio, maxSpeech: layout.vadMax ?? 14, threshold: layout.vadThreshold, padding: layout.padding)
            .flatMap { split(start: $0.0, end: $0.1, maxSegmentSeconds: layout.split ?? 15) }
        var out: [(Double, Double)] = []
        for region in item.layouts?[layout.key ?? ""] ?? [] {
            var pieces: [(Double, Double)] = []
            for window in track {
                let start = max(window.0, region[0]), end = min(window.1, region[1])
                guard end > start else { continue }
                if let gap = layout.gap, let last = pieces.last,
                   start - last.1 <= gap, end - last.0 <= (layout.maxLen ?? .infinity) {
                    pieces[pieces.count - 1].1 = end
                } else {
                    pieces.append((start, end))
                }
            }
            out += pieces
        }
        return out.sorted { $0.0 < $1.0 }
    case "regions":
        var out: [(Double, Double)] = []
        for region in item.layouts?[layout.key ?? ""] ?? [] {
            let regionAudio = slice(audio, region[0], region[1])
            guard !regionAudio.isEmpty else { continue }
            let spans = try await vadRegions(vad, regionAudio, maxSpeech: layout.vadMax ?? 14, threshold: layout.vadThreshold, padding: layout.padding)
                .flatMap { split(start: $0.0, end: $0.1, maxSegmentSeconds: layout.split ?? 15) }
            out += spans.map { (region[0] + $0.0, min(region[1], region[0] + $0.1)) }
        }
        return out
    default:
        fatalError("unknown layout \(layout.kind)")
    }
}

// MARK: - Language modes

/// Qwen3-ASR's 30 supported languages (model card), as ISO codes.
let qwenLanguages: Set<String> = ["zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi",
                                  "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu",
                                  "mk", "ro"]
let englishNames = ["de": "German", "ja": "Japanese", "ru": "Russian", "sr": "Serbian", "en": "English",
                    "fr": "French", "es": "Spanish", "zh": "Chinese"]

func baseCode(_ code: String) -> String {
    String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
}

/// Detect-once decision: the dominant language of probe text, pinned only when
/// confident and supported by Qwen; nil keeps per-window auto-detection.
func pinnedLanguage(for text: String, minimumConfidence: Double = 0.8) -> (String?, String) {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
    guard let top = hypotheses.first else { return (nil, "none") }
    let code = baseCode(top.key.rawValue)
    let summary = hypotheses.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: ",")
    guard top.value >= minimumConfidence, qwenLanguages.contains(code) else { return (nil, summary) }
    return (code, summary)
}

/// Length-weighted language vote over window texts (3+ words, confidence >= 0.5).
/// A whole-track string would be judged mostly by its opening words.
func languageVote(_ texts: [String]) -> (code: String, share: Double)? {
    var weights: [String: Double] = [:]
    var total = 0.0
    for text in texts where text.split(whereSeparator: { $0.isWhitespace }).count >= 3 {
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

// MARK: - llama.cpp backend

let environment = ProcessInfo.processInfo.environment
let backend = environment["ASR_BACKEND"] ?? "mlx"
let llamaURL = URL(string: (environment["LLAMA_URL"] ?? "http://127.0.0.1:8080") + "/completion")!
/// Must match the server's LLAMA_MEDIA_MARKER (llama.cpp randomizes it otherwise).
let mediaMarker = environment["LLAMA_MEDIA_MARKER"] ?? "<__media__>"

/// 16 kHz mono IEEE-float WAV, so llama.cpp hears the exact samples MLX gets.
func floatWAV(_ samples: [Float]) -> Data {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
    return data
}

/// speech-swift's Qwen3ASRModel prompt, token for token: system = context,
/// user = audio (mtmd adds <|audio_start|>/<|audio_end|> around the marker),
/// assistant = optional "language X" then <asr_text>.
func llamaPrompt(language: String?, context: String?) -> String {
    "<|im_start|>system\n\(context ?? "")<|im_end|>\n<|im_start|>user\n\(mediaMarker)<|im_end|>\n"
        + "<|im_start|>assistant\n\(language.map { "language \($0)" } ?? "")<asr_text>"
}

struct LlamaTimings { var promptMs = 0.0, predictedMs = 0.0, promptTokens = 0, predictedTokens = 0 }
var llamaTotals = LlamaTimings()

func llamaTranscribe(_ samples: [Float], language: String?, context: String?, maxTokens: Int) async throws -> String {
    var request = URLRequest(url: llamaURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 600
    let body: [String: Any] = [
        "prompt": ["prompt_string": llamaPrompt(language: language, context: context),
                   "multimodal_data": [floatWAV(samples).base64EncodedString()]],
        // Greedy, like speech-swift's default fast path (no penalties, no n-gram block).
        "n_predict": maxTokens, "temperature": 0, "top_k": 1, "samplers": ["top_k"],
        "repeat_penalty": 1.0, "cache_prompt": false, "stream": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = object["content"] as? String else {
        throw NSError(domain: "llama", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
    }
    if let t = object["timings"] as? [String: Any] {
        llamaTotals.promptMs += t["prompt_ms"] as? Double ?? 0
        llamaTotals.predictedMs += t["predicted_ms"] as? Double ?? 0
        llamaTotals.promptTokens += t["prompt_n"] as? Int ?? 0
        llamaTotals.predictedTokens += t["predicted_n"] as? Int ?? 0
    }
    // Same post-processing as speech-swift: keep what follows <asr_text> if the
    // model emitted it again (auto-detection), then trim spaces.
    var text = content
    if let range = text.range(of: "<asr_text>") { text = String(text[range.upperBound...]) }
    return text.trimmingCharacters(in: .whitespaces)
}

// MARK: - Main

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// `diarize <job.json>`: NeuralDiarizationEngine's Nemotron 3 path on whole
// recordings (offline preset, activity threshold 0.5, minimum 0.2 s).
struct DiarizeJob: Decodable {
    var modelDir: String
    var files: [String]
    var output: String
}

struct Turn: Encodable {
    var start: Double
    var end: Double
    var speaker: String
}

if CommandLine.arguments[1] == "diarize" {
    let job = try JSONDecoder().decode(
        DiarizeJob.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let models = try await Nemotron3Models.load(config: .offline, directory: URL(fileURLWithPath: job.modelDir))
    var turns: [String: [Turn]] = [:]
    for file in job.files {
        let started = Date()
        let audio = try AudioConverter(sampleRate: 16_000).resampleAudioFile(URL(fileURLWithPath: file))
        let diarizer = Nemotron3Diarizer(config: .offline, models: models)
        let output = try diarizer.processComplete(audio)
        turns[file] = Nemotron3Diarizer.segments(
            probabilities: output.probabilities, frameCount: output.frameCount,
            threshold: 0.5, minDurationSeconds: 0.2
        ).map { Turn(start: Double($0.startSeconds), end: Double($0.endSeconds), speaker: "S\($0.speakerIndex)") }
        log("\(URL(fileURLWithPath: file).lastPathComponent): \(turns[file]!.count) turns, "
            + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }
    try JSONEncoder().encode(turns).write(to: URL(fileURLWithPath: job.output))
    exit(0)
}

// `align <job.json>`: word timings for an existing condition's decode windows
// with speech-swift's Qwen3 forced aligner (transcribe first, attribute after).
struct AlignJob: Decodable {
    var modelId: String
    var modelDir: String
    var runs: String
    var condition: String
    var language: String
    var items: [Item]
    var output: String
}

struct AlignedRecord: Encodable {
    var id: String
    /// [surface, start, end] on the item's timeline, per decode window.
    var windows: [[[String]]]
    var seconds: Double
}

if CommandLine.arguments[1] == "align" {
    let job = try JSONDecoder().decode(
        AlignJob.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let aligner = try await Qwen3ForcedAligner.fromPretrained(
        modelId: job.modelId, cacheDir: URL(fileURLWithPath: job.modelDir), offlineMode: true)
    var windowsByID: [String: [(Double, Double, String)]] = [:]
    for line in try String(contentsOfFile: job.runs, encoding: .utf8).split(separator: "\n") {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["condition"] as? String == job.condition, let id = object["id"] as? String,
              let windows = object["windows"] as? [[String: Any]] else { continue }
        windowsByID[id] = windows.compactMap { window in
            guard let start = window["start"] as? Double, let end = window["end"] as? Double,
                  let text = window["text"] as? String, !text.isEmpty else { return nil }
            return (start, end, text)
        }
    }
    FileManager.default.createFile(atPath: job.output, contents: nil)
    let out = try FileHandle(forWritingTo: URL(fileURLWithPath: job.output))
    var total = 0.0
    for item in job.items {
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: item.wav))
        let started = Date()
        var aligned: [[[String]]] = []
        for (start, end, text) in windowsByID[item.id] ?? [] {
            let words = aligner.align(audio: samplesForInference(slice(samples, start, end)),
                                      text: text, sampleRate: sampleRate, language: job.language)
            aligned.append(words.map { [$0.text, String(start + Double($0.startTime)), String(start + Double($0.endTime))] })
        }
        let seconds = Date().timeIntervalSince(started)
        total += seconds
        out.write(try JSONEncoder().encode(AlignedRecord(id: item.id, windows: aligned, seconds: seconds)))
        out.write("\n".data(using: .utf8)!)
    }
    try out.close()
    log("aligned \(job.items.count) items in \(String(format: "%.1f", total))s")
    exit(0)
}

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

let loadStarted = Date()
// The llama backend never loads the MLX weights, so each process measures one runtime.
let model: Qwen3ASRModel? = backend == "llama" ? nil : try await Qwen3ASRModel.fromPretrained(
    modelId: jobs.modelId, cacheDir: URL(fileURLWithPath: jobs.modelDir), offlineMode: true)
let vadConfig = MLModelConfiguration()
vadConfig.computeUnits = VadConfig.default.computeUnits
let loadedVadModel = try MLModel(contentsOf: URL(fileURLWithPath: jobs.vadModel), configuration: vadConfig)
vadModelForThresholds = loadedVadModel
let vad = VadManager(vadModel: loadedVadModel)
log("backend \(backend): loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStarted)))s")

var audioCache: [String: [Float]] = [:]
func audio(for item: Item) throws -> [Float] {
    if let cached = audioCache[item.wav] { return cached }
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: item.wav))
    audioCache[item.wav] = samples
    return samples
}

// Warm-up (excluded from timing).
if let first = jobs.items.first {
    let warm = Array(try audio(for: first).prefix(sampleRate * 5))
    if let model {
        _ = model.transcribe(audio: warm, sampleRate: sampleRate, language: "en", maxTokens: 64, context: nil)
    } else {
        _ = try await llamaTranscribe(warm, language: "en", context: nil, maxTokens: 64)
    }
}
let runStarted = Date()

for condition in jobs.conditions {
    let items = jobs.items.filter { item in
        condition.prefixes.map { $0.contains(where: { item.id.hasPrefix($0) }) } ?? true
    }
    var conditionAudio = 0.0, conditionDecode = 0.0
    for item in items where !done.contains("\(condition.name)|\(item.id)") {
        let samples = try audio(for: item)
        let spans = try await windows(for: condition.layout, item: item, audio: samples, vad: vad)
        var parts: [String] = []
        var records: [Window] = []
        let started = Date()
        func decode(_ window: [Float], language: String?) async throws -> String {
            let cap = condition.maxTokens ?? appMaxTokens(for: window.count)
            guard let model else {
                // llama.cpp has no n-gram block; the conditions compared here never
                // trigger speech-swift's (ngram off, or windows <= 15 s).
                return try await llamaTranscribe(samplesForInference(window), language: language,
                                                 context: condition.context, maxTokens: cap)
            }
            if condition.ngram == "off" {
                return model.transcribe(
                    audio: samplesForInference(window), sampleRate: sampleRate,
                    options: Qwen3DecodingOptions(maxTokens: cap, language: language,
                                                  context: condition.context, longInputThresholdSeconds: .infinity))
            }
            return model.transcribe(
                audio: samplesForInference(window), sampleRate: sampleRate,
                language: language, maxTokens: cap, context: condition.context)
        }
        var language = condition.language
        var detected: String?
        switch condition.language {
        case "oracle":
            language = item.language.flatMap { $0.contains("+") ? nil : $0 }
        case "oracle-name":
            language = item.language.flatMap { $0.contains("+") ? nil : englishNames[$0] ?? $0 }
        case "detect":
            // Probe the longest windows (at least 30 s of audio) with auto-detection.
            var probe: [String] = []
            var probed = 0.0
            for (start, end) in spans.sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }) where probed < 30 {
                let window = slice(samples, start, end)
                guard !window.isEmpty else { continue }
                probe.append(normalized(try await decode(window, language: nil)))
                probed += end - start
            }
            let (pinned, summary) = pinnedLanguage(for: probe.joined(separator: " "))
            language = pinned
            detected = summary
        case "vote":
            // Decode with auto, vote the language over windows, and re-decode
            // pinned when one supported language holds >= 80% of the text.
            var texts: [String] = []
            for (start, end) in spans {
                let window = slice(samples, start, end)
                guard !window.isEmpty else { continue }
                let text = normalized(try await decode(window, language: nil))
                if !text.isEmpty { texts.append(text) }
            }
            let vote = languageVote(texts)
            detected = vote.map { "\($0.code)=\(String(format: "%.2f", $0.share))" } ?? "none"
            if let vote, vote.share >= 0.8, qwenLanguages.contains(vote.code) {
                language = vote.code
            } else {
                language = nil
            }
        default:
            break
        }
        for (start, end) in spans {
            let window = slice(samples, start, end)
            guard !window.isEmpty else { continue }
            let cap = condition.maxTokens ?? appMaxTokens(for: window.count)
            let raw = try await decode(window, language: language)
            let text = normalized(raw)
            records.append(Window(start: start, end: end, cap: cap, text: text))
            if !text.isEmpty { parts.append(text) }
        }
        let decode = Date().timeIntervalSince(started)
        let seconds = Double(samples.count) / Double(sampleRate)
        conditionAudio += seconds
        conditionDecode += decode
        let record = Record(backend: backend, condition: condition.name, id: item.id, languageUsed: language ?? "auto",
                            detected: detected, text: parts.joined(separator: " "),
                            windows: records, audioSeconds: seconds, decodeSeconds: decode)
        handle.write(try JSONEncoder().encode(record))
        handle.write("\n".data(using: .utf8)!)
    }
    if conditionDecode > 0 {
        log("\(condition.name): \(items.count) items, \(String(format: "%.0f", conditionAudio))s audio, "
            + "\(String(format: "%.1f", conditionDecode))s decode, \(String(format: "%.1f", conditionAudio / conditionDecode))x")
    }
}
try handle.close()
log("run wall \(String(format: "%.1f", Date().timeIntervalSince(runStarted)))s")
if model != nil {
    log("mlx peak memory \(String(format: "%.2f", Double(MLX.Memory.peakMemory) / 1_073_741_824)) GiB")
} else {
    log("llama prompt \(llamaTotals.promptTokens) tok \(String(format: "%.1f", llamaTotals.promptMs / 1000))s, "
        + "generated \(llamaTotals.predictedTokens) tok \(String(format: "%.1f", llamaTotals.predictedMs / 1000))s")
}
