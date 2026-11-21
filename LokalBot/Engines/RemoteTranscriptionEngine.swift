import Foundation
import os

struct RemoteTranscriptionConfiguration: Hashable, Sendable {
    var baseURL: String
    var model: String
    var approvedOrigins: [String]

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var endpoint: URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var components = URLComponents(string: raw),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions"), !path.hasSuffix("/inference") {
            path += "/audio/transcriptions"
        }
        components.path = path
        guard let url = components.url, InferenceEndpointPolicy.origin(for: url) != nil else { return nil }
        return url
    }

    var origin: String? { endpoint.flatMap(InferenceEndpointPolicy.origin(for:)) }

    static let wordTimingModels: [String: Set<String>] = [
        "https://openrouter.ai": [
            "microsoft/mai-transcribe-2", "google/gemini-3.5-transcribe", "openai/whisper-large-v3-turbo",
        ],
    ]

    var requestsWordTimings: Bool {
        guard let origin else { return false }
        return Self.wordTimingModels[origin]?.contains(trimmedModel.lowercased()) == true
    }

    var wordTimingKey: String { "\(origin ?? baseURL)|\(trimmedModel.lowercased())" }

    func validatedEndpoint() throws -> URL {
        guard isConfigured else { throw RemoteTranscriptionError.notConfigured }
        guard let endpoint else { throw RemoteTranscriptionError.invalidURL }
        do {
            try InferenceEndpointPolicy.validate(
                endpoint, approvedOrigins: approvedOrigins, allowsPrivateNetworkHTTP: true)
        } catch InferenceEndpointPolicy.PolicyError.insecureRemoteEndpoint(let origin) {
            throw RemoteTranscriptionError.insecure(origin)
        } catch InferenceEndpointPolicy.PolicyError.remoteApprovalRequired(let origin) {
            throw RemoteTranscriptionError.approvalRequired(origin)
        } catch {
            throw RemoteTranscriptionError.invalidURL
        }
        return endpoint
    }

    var isReady: Bool { (try? validatedEndpoint()) != nil }

    var presentation: InferencePresentation {
        do {
            let endpoint = try validatedEndpoint()
            return InferenceEndpointPolicy.isLoopback(endpoint)
                ? .onDevice : .remote(host: endpoint.host ?? "transcription server")
        } catch {
            return .blocked(reason: error.localizedDescription)
        }
    }

    var displayName: String {
        let host = endpoint?.host ?? "not set up"
        return trimmedModel.isEmpty ? "Transcription server · \(host)" : "\(trimmedModel) · \(host)"
    }

    var transcriptEngine: String {
        let model = trimmedModel.isEmpty ? "server default" : trimmedModel
        return "\(model) (remote \(origin ?? "server"))"
    }
}

enum RemoteTranscriptionConsent {
    struct State: Equatable, Sendable {
        var serverSelected: Bool
        var approvedOrigins: [String]

        init(serverSelected: Bool, approvedOrigins: [String]) {
            self.serverSelected = serverSelected
            self.approvedOrigins = approvedOrigins
        }

        init(settings: AppSettings) {
            self.init(serverSelected: settings.transcriptionModel.isRemote,
                      approvedOrigins: settings.approvedRemoteTranscriptionOrigins)
        }
    }

    static var current: State? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    private static let state = OSAllocatedUnfairLock<State?>(initialState: nil)

    static func check(_ endpoint: URL, against state: State? = current) throws {
        guard let state, !InferenceEndpointPolicy.isLoopback(endpoint) else { return }
        guard state.serverSelected else { throw RemoteTranscriptionError.noLongerSelected }
        do {
            try InferenceEndpointPolicy.validate(
                endpoint, approvedOrigins: state.approvedOrigins, allowsPrivateNetworkHTTP: true)
        } catch {
            throw RemoteTranscriptionError.approvalRequired(
                InferenceEndpointPolicy.origin(for: endpoint) ?? endpoint.absoluteString)
        }
    }
}

enum RemoteTranscriptionError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case insecure(String)
    case approvalRequired(String)
    case noLongerSelected

    var isConsentWithdrawn: Bool {
        switch self {
        case .approvalRequired, .noLongerSelected: true
        default: false
        }
    }
    case rejected(status: Int, detail: String)
    case unreachable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Enter a transcription server URL under Settings → Models → Transcribe."
        case .invalidURL:
            "Use an http or https transcription server URL without a query or a user name."
        case .insecure(let origin):
            "Transcription server \(origin) is not encrypted. Use HTTPS, or a server on this Mac, your local network, or your tailnet."
        case .approvalRequired(let origin):
            "Allow sending audio to \(origin) under Settings → Models → Transcribe before transcribing with it."
        case .noLongerSelected:
            "The transcription server is no longer the selected Transcribe model, so no more audio was sent to it."
        case .rejected(let status, let detail):
            Self.rejection(status: status, detail: detail)
        case .unreachable(let detail):
            "Could not reach the transcription server: \(detail)"
        case .invalidResponse:
            "The transcription server did not return transcript text."
        }
    }

    private static func rejection(status: Int, detail: String) -> String {
        let summary = switch status {
        case 401, 403: "The transcription server rejected the API key (HTTP \(status))."
        case 404: "The transcription server has no transcription endpoint at this URL (HTTP 404). Check the server URL."
        case 413: "The transcription server refused the audio as too large (HTTP 413)."
        case 429: "The transcription server is rate limiting requests (HTTP 429). Try again later."
        default: "The transcription server returned HTTP \(status)."
        }
        return detail.isEmpty ? summary : "\(summary) \(detail)"
    }
}

struct RemoteTranscriptionEngine: TranscriptionEngine, Sendable {
    struct Windowing: Equatable, Sendable {
        var maxSeconds: TimeInterval
        var maxGapSeconds: TimeInterval
    }

    static let lineWindows = Windowing(maxSeconds: 15, maxGapSeconds: 2)
    static let attributionWindows = Windowing(maxSeconds: 30, maxGapSeconds: 3)
    static let minimumSpanSamples = SpeechActivity.spanSampleRate / 10
    static let maximumConcurrentRequests = 3
    static let maximumAttempts = 3
    static let requestTimeout: TimeInterval = 180
    static let sharedSession = InferenceURLSession.make(requestTimeout: requestTimeout, resourceTimeout: 600)

    let configuration: RemoteTranscriptionConfiguration
    let apiKey: @Sendable () -> String
    var session: URLSession = RemoteTranscriptionEngine.sharedSession
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var wordTimingRejections: WordTimingRejections = .shared
    var stillAllowed: @Sendable (URL) throws -> Void = { _ in }

    var displayName: String { configuration.displayName }
    var supportsStreaming: Bool { false }
    var speakerAttribution: SpeakerAttributionStrategy { .alignedWords }
    var providesWordTimings: Bool {
        configuration.requestsWordTimings && !wordTimingRejections.contains(configuration.wordTimingKey)
    }
    var checkpointIdentity: String {
        "remote:\(configuration.endpoint?.absoluteString ?? configuration.baseURL)|\(configuration.trimmedModel)"
    }

    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        _ = try configuration.validatedEndpoint()
        guard let progress else { return }
        Task { @MainActor in progress(.init(fractionCompleted: 1, status: "Ready")) }
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt,
                             windowing: Self.lineWindows, wordTimings: false).transcript
    }

    func transcribeForWordAttribution(audio url: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        try await transcribe(audio: url, language: language, prompt: prompt,
                             windowing: Self.attributionWindows, wordTimings: providesWordTimings)
    }

    static func windows(in spans: [SpeechSpan], _ windowing: Windowing) -> [SpeechSpan] {
        QwenASREngine.merged(spans, maxGap: windowing.maxGapSeconds, maxLength: windowing.maxSeconds)
    }

    private func transcribe(audio url: URL, language: String?, prompt: String?,
                            windowing: Windowing, wordTimings: Bool) async throws -> WordTimedTranscript {
        let endpoint = try configuration.validatedEndpoint()
        try stillAllowed(endpoint)
        let key = apiKey()
        let model = configuration.trimmedModel
        let hint = TranscriptionPrompt.normalized(prompt)
        let started = Date()
        let speech = try await SpeechActivity.shared.spans(in: url, maxSegmentSeconds: windowing.maxSeconds)
        let spans = Self.windows(in: speech, windowing)
        let segments = try await Self.segments(
            in: url, spans: spans, maximumConcurrent: Self.maximumConcurrentRequests
        ) { wav in
            try await self.upload(wav, endpoint: endpoint, apiKey: key, model: model,
                                  language: language, prompt: hint, wordTimings: wordTimings)
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "remote-asr profile origin=\(configuration.origin ?? "?") speech=\(speech.count) requests=\(spans.count) "
                + "word-timed=\(segments.filter { $0.words != nil }.count)/\(segments.count) "
                + "elapsed=\(String(format: "%.2fs", elapsed)) "
                + "rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return WordTimedTranscript(segments: segments, engine: configuration.transcriptEngine)
    }

    static func segments(
        in url: URL,
        spans: [SpeechSpan],
        maximumConcurrent: Int,
        transcribe: @escaping @Sendable (Data) async throws -> WindowTranscription
    ) async throws -> [WordTimedTranscript.Segment] {
        guard !spans.isEmpty else { return [] }
        let reader = try SpanAudioReader(url: url)
        var replies = [WindowTranscription?](repeating: nil, count: spans.count)
        try await withThrowingTaskGroup(of: (Int, WindowTranscription).self) { group in
            var running = 0
            for (index, span) in spans.enumerated() {
                try Task.checkCancellation()
                let samples = try reader.samples(from: span.start, to: span.end)
                guard samples.count >= minimumSpanSamples else { continue }
                let wav = OnnxTranscriptionEngine.wavData(samples)
                if running >= max(1, maximumConcurrent), let finished = try await group.next() {
                    replies[finished.0] = finished.1
                    running -= 1
                }
                group.addTask {
                    let reply = try await transcribe(wav)
                    return (index, reply)
                }
                running += 1
            }
            while let finished = try await group.next() {
                replies[finished.0] = finished.1
            }
        }
        return zip(spans, replies).compactMap { span, reply in
            guard let reply,
                  let segment = SpanTranscription.segments(pairing: [span], with: [reply.text]).first else { return nil }
            let words = reply.words.map { words in
                words.map { word in
                    AlignedWordTiming(text: word.text,
                                      start: min(span.end, span.start + word.start),
                                      end: min(span.end, span.start + word.end))
                }
            }
            return WordTimedTranscript.Segment(segment: segment, words: words)
        }
    }

    func upload(_ wav: Data, endpoint: URL, apiKey: String, model: String,
                language: String?, prompt: String?, wordTimings: Bool = false) async throws -> WindowTranscription {
        var attempt = 0
        var wordTimings = wordTimings && !wordTimingRejections.contains(configuration.wordTimingKey)
        var wordTimingsRejected = false
        while true {
            try Task.checkCancellation()
            try stillAllowed(endpoint)
            let request = Self.makeRequest(
                endpoint: endpoint, apiKey: apiKey, model: model,
                boundary: "lokalbot-\(UUID().uuidString)", wav: wav,
                language: language, prompt: prompt, wordTimings: wordTimings)
            let retryAfter: TimeInterval?
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RemoteTranscriptionError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) {
                    let reply = try Self.transcription(from: data, response: http)
                    if wordTimingsRejected {
                        wordTimingRejections.insert(configuration.wordTimingKey)
                    }
                    return reply
                }
                if wordTimings, http.statusCode == 400 {
                    lokalbotLog("remote-asr word timings refused (HTTP 400), asking for text only: "
                        + Self.errorDetail(from: data))
                    wordTimings = false
                    wordTimingsRejected = true
                    continue
                }
                attempt += 1
                guard Self.isRetryable(status: http.statusCode), attempt < Self.maximumAttempts else {
                    throw RemoteTranscriptionError.rejected(
                        status: http.statusCode, detail: Self.errorDetail(from: data))
                }
                retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                attempt += 1
                guard Self.isRetryable(error), attempt < Self.maximumAttempts else {
                    throw RemoteTranscriptionError.unreachable(error.localizedDescription)
                }
                retryAfter = nil
            }
            lokalbotLog("remote-asr retry attempt=\(attempt + 1)/\(Self.maximumAttempts)")
            try await sleep(RemoteRetryPolicy.backoff(attempt: attempt - 1, retryAfter: retryAfter))
        }
    }

    static func makeRequest(endpoint: URL, apiKey: String, model: String, boundary: String,
                            wav: Data, language: String?, prompt: String?,
                            wordTimings: Bool = false) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var fields: [(name: String, value: String)] = []
        if !model.isEmpty { fields.append(("model", model)) }
        if wordTimings {
            fields.append(("response_format", "verbose_json"))
            fields.append(("timestamp_granularities[]", "word"))
        } else {
            fields.append(("response_format", "json"))
        }
        fields.append(("temperature", "0"))
        if let language, !language.isEmpty { fields.append(("language", language)) }
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    struct WindowTranscription: Equatable, Sendable {
        var text: String
        var words: [AlignedWordTiming]?
    }

    private struct ResponseBody: Decodable {
        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }

        let text: String?
        let words: [Word]?
    }

    static func transcription(from data: Data, response: HTTPURLResponse) throws -> WindowTranscription {
        if let payload = try? JSONDecoder().decode(ResponseBody.self, from: data),
           let text = payload.text {
            return WindowTranscription(text: text, words: payload.words.flatMap(timedWords))
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("text/plain") {
            return WindowTranscription(text: String(decoding: data, as: UTF8.self))
        }
        throw RemoteTranscriptionError.invalidResponse
    }

    private static func timedWords(_ words: [ResponseBody.Word]) -> [AlignedWordTiming]? {
        var timed: [AlignedWordTiming] = []
        for word in words {
            let text = word.word?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            guard let start = word.start, let end = word.end, start.isFinite, end.isFinite,
                  start >= 0, end >= start else { return nil }
            timed.append(AlignedWordTiming(text: text, start: start, end: end))
        }
        return timed.isEmpty ? nil : timed
    }

    static func errorDetail(from data: Data) -> String {
        let message: String
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let text = error["message"] as? String {
                message = text
            } else if let text = (object["error"] as? String) ?? (object["message"] as? String)
                        ?? (object["detail"] as? String) {
                message = text
            } else {
                message = ""
            }
        } else {
            message = String(decoding: data.prefix(300), as: UTF8.self)
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    static func isRetryable(status: Int) -> Bool {
        [408, 425, 429, 500, 502, 503, 504].contains(status)
    }

    static func isRetryable(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
    }
}

final class WordTimingRejections: Sendable {
    static let shared = WordTimingRejections()

    private let keys = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func contains(_ key: String) -> Bool { keys.withLock { $0.contains(key) } }

    func insert(_ key: String) {
        let inserted = keys.withLock { $0.insert(key).inserted }
        if inserted { lokalbotLog("remote-asr word timings off for this server and model until relaunch") }
    }
}
