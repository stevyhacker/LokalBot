import Foundation

/// A speech-to-text server the user configures, speaking OpenAI's
/// `/audio/transcriptions` API: a cloud provider (OpenAI, Groq, OpenRouter)
/// or a whisper.cpp-style server on another device. Audio leaves the Mac only
/// for an origin approved for transcription; loopback needs no approval, and
/// plain HTTP is accepted only on the user's own network or tailnet.
struct RemoteTranscriptionConfiguration: Hashable, Sendable {
    var baseURL: String
    var model: String
    /// `AppSettings.approvedRemoteTranscriptionOrigins`. Separate from the
    /// Think approvals: approving a Think server never sends it audio.
    var approvedOrigins: [String]

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The request URL. A base such as `https://api.openai.com/v1` gets
    /// `/audio/transcriptions` appended; a URL that already names that
    /// endpoint, or whisper.cpp's default `/inference`, is used as is.
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

    /// The endpoint audio may be sent to now, or why not.
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

    /// Configured and allowed to receive audio. Readiness gates (automatic
    /// processing, the Models page) treat this as the model being "on disk".
    var isReady: Bool { (try? validatedEndpoint()) != nil }

    /// Where audio goes, for disclosures. Loopback reads as this Mac.
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

    /// Recorded in `transcript.json` and the crash-resume checkpoint. Never
    /// includes credentials.
    var transcriptEngine: String {
        let model = trimmedModel.isEmpty ? "server default" : trimmedModel
        return "\(model) (remote \(origin ?? "server"))"
    }
}

enum RemoteTranscriptionError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case insecure(String)
    case approvalRequired(String)
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

/// Transcribes through a `RemoteTranscriptionConfiguration`. Neighbouring
/// speech is packed into windows (`lineWindows`, or `attributionWindows`
/// before word attribution), and each window is uploaded as a 16 kHz WAV of at
/// most about 1 MB, so long meetings stay far below provider upload limits
/// (25 MB) and per-request timeouts (60 s upstream at OpenRouter). Speaker
/// turns are attributed after transcription with forced-aligned words, as for
/// Qwen3-ASR: cutting the audio at every turn sent each turn as its own
/// request, one after another, without the context around it.
/// Word-level timing is not requested because several providers reject it.
struct RemoteTranscriptionEngine: TranscriptionEngine, Sendable {
    /// How neighbouring VAD spans are packed into one request.
    struct Windowing: Equatable, Sendable {
        var maxSeconds: TimeInterval
        var maxGapSeconds: TimeInterval
    }

    /// Plain transcription (no speaker turns, or the speaker-region fallback):
    /// one request and one transcript line per window, short enough for the
    /// speaker-bleed filter to compare (`SpeakerBleedFilter`).
    static let lineWindows = Windowing(maxSeconds: 15, maxGapSeconds: 2)
    /// Before word attribution: longer windows give the model more context
    /// and need fewer requests; the aligner splits them at turns and pauses.
    static let attributionWindows = Windowing(maxSeconds: 30, maxGapSeconds: 3)
    /// OpenAI rejects audio shorter than 0.1 s, and such slivers hold no words.
    static let minimumSpanSamples = SpeechActivity.spanSampleRate / 10
    static let maximumConcurrentRequests = 3
    static let maximumAttempts = 3
    /// Idle time without a response byte. A slow CPU server can spend well
    /// over a minute on one 30-second span before it answers.
    static let requestTimeout: TimeInterval = 180
    static let sharedSession = InferenceURLSession.make(requestTimeout: requestTimeout, resourceTimeout: 600)

    let configuration: RemoteTranscriptionConfiguration
    /// Read once per transcription, off the main actor (Keychain).
    let apiKey: @Sendable () -> String
    var session: URLSession = RemoteTranscriptionEngine.sharedSession
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    var displayName: String { configuration.displayName }
    var supportsStreaming: Bool { false }
    var speakerAttribution: SpeakerAttributionStrategy { .alignedWords }
    var checkpointIdentity: String {
        "remote:\(configuration.endpoint?.absoluteString ?? configuration.baseURL)|\(configuration.trimmedModel)"
    }

    /// Nothing to download: ready means configured and approved. The model
    /// check sends the spoken sample to prove the server answers.
    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        _ = try configuration.validatedEndpoint()
        guard let progress else { return }
        Task { @MainActor in progress(.init(fractionCompleted: 1, status: "Ready")) }
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: nil)
    }

    func transcribe(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt, windowing: Self.lineWindows)
    }

    func transcribeForWordAttribution(audio url: URL, language: String?, prompt: String?) async throws -> Transcript {
        try await transcribe(audio: url, language: language, prompt: prompt, windowing: Self.attributionWindows)
    }

    /// VAD spans packed into request windows. A pause longer than the gap,
    /// or a window that would outgrow the limit, starts a new window.
    static func windows(in spans: [SpeechSpan], _ windowing: Windowing) -> [SpeechSpan] {
        QwenASREngine.merged(spans, maxGap: windowing.maxGapSeconds, maxLength: windowing.maxSeconds)
    }

    private func transcribe(audio url: URL, language: String?, prompt: String?,
                            windowing: Windowing) async throws -> Transcript {
        let endpoint = try configuration.validatedEndpoint()
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
                                  language: language, prompt: hint)
        }
        let elapsed = Date().timeIntervalSince(started)
        let duration = spans.last?.end ?? 0
        lokalbotLog(
            "remote-asr profile origin=\(configuration.origin ?? "?") speech=\(speech.count) requests=\(spans.count) "
                + "elapsed=\(String(format: "%.2fs", elapsed)) "
                + "rtfx=\(String(format: "%.1fx", elapsed > 0 ? duration / elapsed : 0))")
        return Transcript(segments: segments, engine: configuration.transcriptEngine)
    }

    /// Reads one span at a time, keeps at most `maximumConcurrent` uploads in
    /// flight, and stamps each returned text with its span's real start/end.
    static func segments(
        in url: URL,
        spans: [SpeechSpan],
        maximumConcurrent: Int,
        transcribe: @escaping @Sendable (Data) async throws -> String
    ) async throws -> [Transcript.Segment] {
        guard !spans.isEmpty else { return [] }
        let reader = try SpanAudioReader(url: url)
        var texts = [String](repeating: "", count: spans.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var running = 0
            for (index, span) in spans.enumerated() {
                try Task.checkCancellation()
                let samples = try reader.samples(from: span.start, to: span.end)
                guard samples.count >= minimumSpanSamples else { continue }
                let wav = OnnxTranscriptionEngine.wavData(samples)
                if running >= max(1, maximumConcurrent), let finished = try await group.next() {
                    texts[finished.0] = finished.1
                    running -= 1
                }
                group.addTask {
                    let text = try await transcribe(wav)
                    return (index, text)
                }
                running += 1
            }
            while let finished = try await group.next() {
                texts[finished.0] = finished.1
            }
        }
        return SpanTranscription.segments(pairing: spans, with: texts)
    }

    // MARK: - Request

    /// One span, retried on rate limits, server errors, and dropped
    /// connections. Internal so tests can drive it with a stub session.
    func upload(_ wav: Data, endpoint: URL, apiKey: String, model: String,
                language: String?, prompt: String?) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let request = Self.makeRequest(
                endpoint: endpoint, apiKey: apiKey, model: model,
                boundary: "lokalbot-\(UUID().uuidString)", wav: wav,
                language: language, prompt: prompt)
            let retryAfter: TimeInterval?
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RemoteTranscriptionError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) {
                    return try Self.transcriptText(from: data, response: http)
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

    /// Multipart form in OpenAI's shape. `response_format=json` is the one
    /// every provider and whisper.cpp accept; `model` is omitted when empty
    /// because single-model servers need none.
    static func makeRequest(endpoint: URL, apiKey: String, model: String, boundary: String,
                            wav: Data, language: String?, prompt: String?) -> URLRequest {
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
        fields.append(("response_format", "json"))
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

    private struct ResponseBody: Decodable {
        let text: String?
    }

    /// `{"text": …}` from OpenAI-style servers; a few self-hosted servers
    /// answer plain text instead.
    static func transcriptText(from data: Data, response: HTTPURLResponse) throws -> String {
        if let payload = try? JSONDecoder().decode(ResponseBody.self, from: data),
           let text = payload.text {
            return text
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("text/plain") {
            return String(decoding: data, as: UTF8.self)
        }
        throw RemoteTranscriptionError.invalidResponse
    }

    /// The server's own message (`{"error": {"message": …}}`,
    /// `{"error": "…"}`, or a short plain body), bounded for display.
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
