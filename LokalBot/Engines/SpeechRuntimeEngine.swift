import AVFoundation
import Foundation

struct SpeechRuntimeEngine: TranscriptionEngine {
    typealias SpanProvider = (URL) async throws -> [SpeechSpan]

    static let modelID = "parakeet-ultra"
    static let shared = SpeechRuntimeEngine()

    enum Priority: String, Sendable {
        case interactive
        case batch
    }

    struct Status: Sendable, Equatable {
        let connected: Bool
        let modelReady: Bool
        let message: String
    }

    struct RuntimeToken: Decodable, Sendable {
        let text: String
        let startMilliseconds: Int

        enum CodingKeys: String, CodingKey {
            case text
            case startMilliseconds = "start_ms"
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let tokens: [RuntimeToken]?
        let audioMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case text
            case tokens
            case audioMilliseconds = "audio_ms"
        }
    }

    private struct ModelsResponse: Decodable {
        let models: [Model]

        struct Model: Decodable {
            let model: String
            let loaded: Bool?
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String?
    }

    private struct PostprocessResponse: Decodable {
        let text: String
    }

    private let baseURL: URL
    private let tokenURL: URL
    private let session: URLSession
    private let spanProvider: SpanProvider
    private let decoder = JSONDecoder()

    var displayName: String { "Speech Runtime — Parakeet Ultra" }
    var supportsStreaming: Bool { false }
    var checkpointIdentity: String { get throws { "speech-runtime:\(Self.modelID)" } }

    init() {
        self.init(
            baseURL: URL(string: "http://127.0.0.1:8477")!,
            tokenURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SpeechRuntime/token"),
            protocolClasses: nil,
            spanProvider: nil)
    }

    init(baseURL: URL, tokenURL: URL, protocolClasses: [AnyClass]?, spanProvider: SpanProvider? = nil) {
        self.baseURL = baseURL
        self.tokenURL = tokenURL
        self.spanProvider = spanProvider ?? { url in
            try await SpeechActivity.shared.spans(in: url, maxSegmentSeconds: 120)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func status() async -> Status {
        do {
            _ = try await request("GET", "/health", timeout: 5)
            let data = try await request("GET", "/v1/models", timeout: 5)
            let models = try decoder.decode(ModelsResponse.self, from: data).models
            guard let model = models.first(where: { $0.model == Self.modelID }) else {
                return Status(connected: true, modelReady: false,
                              message: "Speech Runtime is connected; Parakeet Ultra is unavailable.")
            }
            let ready = model.loaded == true
            return Status(connected: true, modelReady: ready,
                          message: ready ? "Parakeet Ultra is ready." : "Speech Runtime is connected; Parakeet Ultra is not loaded.")
        } catch {
            return Status(connected: false, modelReady: false, message: error.localizedDescription)
        }
    }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        reportProgress(.init(fractionCompleted: nil, status: "Checking Speech Runtime…"), to: progress)
        try Task.checkCancellation()
        let modelsData = try await request("GET", "/v1/models", timeout: 10)
        let models = try decoder.decode(ModelsResponse.self, from: modelsData).models
        guard let model = models.first(where: { $0.model == Self.modelID }) else {
            throw SpeechRuntimeError.modelUnavailable
        }
        if model.loaded != true {
            reportProgress(.init(fractionCompleted: nil, status: "Loading Parakeet Ultra…"), to: progress)
            let body = try JSONSerialization.data(withJSONObject: ["model": Self.modelID])
            _ = try await request("POST", "/v1/models/load", body: body,
                                  contentType: "application/json", timeout: 180)
        }
        try Task.checkCancellation()
        reportProgress(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private func reportProgress(_ update: ModelPreparationUpdate, to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: audio, language: language, prompt: nil, priority: .batch)
    }

    func transcribe(audio: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: audio, language: language, prompt: prompt, priority: .batch)
    }

    func transcribeForWordAttribution(audio: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        let transcript = try await transcribe(audio: audio, language: language, prompt: prompt, priority: .batch)
        return WordTimedTranscript(segments: transcript.segments.map { .init(segment: $0) },
                                  engine: transcript.engine, trackLanguage: language,
                                  allowsForcedAlignment: false)
    }

    func transcribe(audio: URL, language: String?, prompt: String?, priority: Priority) async throws -> Transcript {
        try Task.checkCancellation()
        try TranscriptionModelChoice.speechRuntime.validateLanguage(language)
        let reader = try SpanAudioReader(url: audio)
        guard reader.duration > 0 else { throw SpeechRuntimeError.emptyAudio }
        let spans = try await spanProvider(audio)
        var segments: [Transcript.Segment] = []
        for span in spans {
            try Task.checkCancellation()
            let samples = try reader.samples(from: span.start, to: span.end)
            guard !samples.isEmpty else { throw SpeechRuntimeError.emptyAudio }
            let wavURL = try Self.makeWAV(samples: samples)
            defer { try? FileManager.default.removeItem(at: wavURL) }
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/audio/transcriptions"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = Self.queryItems(priority: priority)
            let data = try await request("POST", "/v1/audio/transcriptions",
                                         contentType: "audio/wav", timeout: 600,
                                         url: components.url, uploadFile: wavURL)
            try Task.checkCancellation()
            let response = try decoder.decode(TranscriptionResponse.self, from: data)
            let cleanupData = try JSONSerialization.data(withJSONObject: ["text": response.text,
                                                                           "cleanup": true,
                                                                           "rules": [[String: String]]()])
            let processed = try await request("POST", "/v1/text/postprocess", body: cleanupData,
                                              contentType: "application/json", timeout: 30)
            try Task.checkCancellation()
            let cleanedText = try decoder.decode(PostprocessResponse.self, from: processed).text
            let chunkDuration = span.end - span.start
            let duration = min(response.audioMilliseconds.map { Double($0) / 1_000 } ?? chunkDuration, chunkDuration)
            segments += Self.segments(text: cleanedText, tokens: response.tokens ?? [], duration: duration,
                                      offset: span.start)
        }
        return Transcript(segments: segments, engine: "parakeet-ultra (Speech Runtime)")
    }

    static func segments(text: String, tokens: [RuntimeToken], duration: TimeInterval,
                         offset: TimeInterval = 0) -> [Transcript.Segment] {
        let normalized = Transcript.normalizedText(text)
        guard !normalized.isEmpty else { return [] }
        return [Transcript.Segment(start: max(offset, 0), end: max(offset, 0) + max(duration, 0), speaker: "speaker",
                                   text: normalized, confidence: nil, timingPrecision: .coarse)]
    }

    static func queryItems(priority: Priority) -> [URLQueryItem] {
        [URLQueryItem(name: "model", value: Self.modelID),
         URLQueryItem(name: "priority", value: priority.rawValue)]
    }

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         contentType: String? = nil, timeout: TimeInterval,
                         url overrideURL: URL? = nil, uploadFile: URL? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw SpeechRuntimeError.tokenUnavailable
        }
        var request = URLRequest(url: overrideURL ?? baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response): (Data, URLResponse)
            if let uploadFile {
                (data, response) = try await session.upload(for: request, fromFile: uploadFile)
            } else {
                (data, response) = try await session.data(for: request)
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SpeechRuntimeError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let detail = (try? decoder.decode(ErrorResponse.self, from: data).error) ?? "HTTP \(http.statusCode)"
                throw SpeechRuntimeError.server(detail)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as SpeechRuntimeError {
            throw error
        } catch {
            throw SpeechRuntimeError.unavailable(error.localizedDescription)
        }
    }

    private static func makeWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-runtime-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw SpeechRuntimeError.unavailable("Could not create temporary audio file.")
        }
        var handle: FileHandle?
        do {
            let output = try FileHandle(forWritingTo: url)
            handle = output
            output.write(Data(repeating: 0, count: 44))
            try Task.checkCancellation()
            var pcm = Data(capacity: samples.count * 2)
            for sample in samples {
                let clipped = max(-1, min(1, sample))
                var value = Int16((clipped * Float(Int16.max)).rounded()).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            output.write(pcm)
            let pcmBytes = try output.offset()
            guard pcmBytes > 44, pcmBytes - 8 <= UInt64(UInt32.max) else {
                throw SpeechRuntimeError.audioTooLarge
            }
            try output.seek(toOffset: 0)
            var header = Data("RIFF".utf8)
            header.appendLE(UInt32(pcmBytes - 8))
            header.append(Data("WAVEfmt ".utf8))
            header.appendLE(UInt32(16))
            header.appendLE(UInt16(1))
            header.appendLE(UInt16(1))
            header.appendLE(UInt32(16_000))
            header.appendLE(UInt32(32_000))
            header.appendLE(UInt16(2))
            header.appendLE(UInt16(16))
            header.append(Data("data".utf8))
            header.appendLE(UInt32(pcmBytes - 44))
            output.write(header)
            try output.close()
            handle = nil
            return url
        } catch {
            try? handle?.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum SpeechRuntimeError: LocalizedError {
    case tokenUnavailable
    case unavailable(String)
    case invalidResponse
    case server(String)
    case modelUnavailable
    case emptyAudio
    case audioTooLarge

    var errorDescription: String? {
        switch self {
        case .tokenUnavailable: "Speech Runtime token was not found. Start Speech Runtime.app first."
        case .unavailable(let reason): "Cannot reach Speech Runtime at 127.0.0.1:8477: \(reason)"
        case .invalidResponse: "Speech Runtime returned an invalid HTTP response."
        case .server(let message): "Speech Runtime: \(message)"
        case .modelUnavailable: "Speech Runtime does not provide Parakeet Ultra."
        case .emptyAudio: "Audio file is empty."
        case .audioTooLarge: "Audio exceeds the WAV size limit supported by Speech Runtime."
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
