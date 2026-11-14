import Foundation

/// Qwen3-ASR 1.7B on the bundled llama.cpp server (`LlamaServerRole.qwenASR`).
///
/// Benchmarks/transcribe/QwenLlamaCpp measured the ggml-org Q8_0 GGUF against
/// speech-swift's MLX 8-bit build on identical windows: AMI WER 17.76% vs
/// 17.80%, Serbian with `sr` and a vocabulary list 12.4% vs 13.4%, about 10–17%
/// slower, and a 2.3 GB server instead of up to 8.5 GB of MLX allocations.
///
/// llama-server's own `/v1/audio/transcriptions` is not used: it puts the
/// language in a user instruction, ignores the system turn and leaves the
/// `language X<asr_text>` prefix in the text. Each window goes to `/completion`
/// with speech-swift's prompt instead, token for token.
enum QwenLlamaASR {
    struct File: Sendable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    // Source: Hugging Face tree API at this revision (LFS oids).
    static let repository = "ggml-org/Qwen3-ASR-1.7B-GGUF"
    static let revision = "36a678687ba7d07a74ca70ccb0e36902e005fb80"
    static let model = File(
        name: "Qwen3-ASR-1.7B-Q8_0.gguf", bytes: 2_165_034_944,
        sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57")
    static let projector = File(
        name: "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf", bytes: 355_709_344,
        sha256: "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d")
    static var files: [File] { [model, projector] }

    /// llama.cpp randomizes its media marker per process unless this is set;
    /// the prompt must contain the server's marker exactly once.
    static let mediaMarker = "<__media__>"
    static let serverEnvironment = ["LLAMA_MEDIA_MARKER": mediaMarker]

    /// A 60 s merged window is about 750 audio tokens, plus at most 768
    /// generated tokens and the vocabulary context.
    static let contextTokens = 4_096
    /// The default 8 GiB host prompt cache grew the benchmark server to 14 GB.
    static let serverArguments = ["--parallel", "1", "--cache-ram", "256"]

    static func downloadURL(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
    }

    static func modelRoot(appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("qwen3-asr-models", isDirectory: true)
            .appendingPathComponent("gguf", isDirectory: true)
            .appendingPathComponent("Qwen3-ASR-1.7B-Q8_0", isDirectory: true)
    }

    static func url(for file: File, appSupport: URL) -> URL {
        modelRoot(appSupport: appSupport).appendingPathComponent(file.name)
    }

    /// speech-swift's Qwen3ASRModel prompt: system = context, user = audio
    /// (mtmd wraps the marker in <|audio_start|>/<|audio_end|>), assistant =
    /// optional "language X", then <asr_text>.
    static func prompt(language: String?, context: String?) -> String {
        "<|im_start|>system\n\(context ?? "")<|im_end|>\n<|im_start|>user\n\(mediaMarker)<|im_end|>\n"
            + "<|im_start|>assistant\n\(language.map { "language \($0)" } ?? "")<asr_text>"
    }

    static func completionURL(serverBaseURL: URL) -> URL {
        // `LlamaServer.baseURL` ends in /v1; /completion lives at the root.
        serverBaseURL.deletingLastPathComponent().appendingPathComponent("completion")
    }

    static func makeRequest(serverBaseURL: URL, authenticationToken: String, samples: [Float],
                            sampleRate: Int, language: String?, context: String?,
                            maxTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: completionURL(serverBaseURL: serverBaseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LocalLlamaServerAuthentication.apply(to: &request, token: authenticationToken)
        let body: [String: Any] = [
            "prompt": [
                "prompt_string": prompt(language: language, context: context),
                "multimodal_data": [floatWAV(samples, sampleRate: sampleRate).base64EncodedString()],
            ],
            // Greedy with no penalties, like speech-swift. llama.cpp has no
            // n-gram block; the app never enables speech-swift's either (merged
            // windows switch it off, and ≤15 s windows never reach it).
            "n_predict": maxTokens, "temperature": 0, "top_k": 1, "samplers": ["top_k"],
            "repeat_penalty": 1.0, "cache_prompt": false, "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Keeps what follows <asr_text> when the model emits it again after
    /// detecting the language itself, as speech-swift does.
    static func transcript(fromCompletion data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? String else {
            throw QwenASREngine.EngineError.transcriptionFailed("invalid response")
        }
        var text = content
        if let range = text.range(of: "<asr_text>", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono IEEE-float WAV, so the server hears the exact samples.
    static func floatWAV(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        return data
    }

    // MARK: - Download

    static func isDownloaded(appSupport: URL) -> Bool {
        files.allSatisfy { ModelFileValidator.looksLikeGGUF(url(for: $0, appSupport: appSupport)) }
    }

    /// Fetches both GGUFs through the shared download stack (mirrors, ranged
    /// parts, SHA-256 verification) and installs them atomically.
    static func prepareFiles(appSupport: URL, progress: ModelPreparationProgressHandler?) async throws -> (model: URL, projector: URL) {
        try FileManager.default.createDirectory(at: modelRoot(appSupport: appSupport),
                                                withIntermediateDirectories: true)
        for (file, status) in [(model, "Downloading Qwen3-ASR model..."),
                               (projector, "Downloading Qwen3-ASR audio encoder...")] {
            try await downloadIfNeeded(file, to: url(for: file, appSupport: appSupport),
                                       status: status, progress: progress)
        }
        removeLegacyMLXWeights(appSupport: appSupport)
        return (url(for: model, appSupport: appSupport), url(for: projector, appSupport: appSupport))
    }

    /// The MLX 8-bit weights this replaced (2.47 GB), once the GGUFs are in.
    static func legacyMLXDirectory(appSupport: URL) -> URL {
        QwenASREngine.hubStyleCacheDir(
            base: appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
            modelID: PinnedModelSnapshot.legacyQwenAccuracyRepository)
    }

    private static func removeLegacyMLXWeights(appSupport: URL) {
        let legacy = legacyMLXDirectory(appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
            lokalbotLog("qwen-asr removed the replaced MLX 1.7B weights")
        } catch {
            lokalbotLog("qwen-asr could not remove the replaced MLX 1.7B weights: \(error.localizedDescription)")
        }
    }

    private static func downloadIfNeeded(_ file: File, to destination: URL, status: String,
                                         progress: ModelPreparationProgressHandler?) async throws {
        if ModelFileValidator.looksLikeGGUF(destination),
           await DownloadIntegrity.verifiedExisting(
               at: destination, expectedBytes: file.bytes, expectedSHA256: file.sha256) {
            return
        }
        DownloadIntegrity.removeFileAndMarker(at: destination)
        report(.init(fractionCompleted: 0, status: status), to: progress)
        let stashed = try await ModelDownloadRouting.download(
            from: downloadURL(for: file), session: .shared,
            expectedSHA256: file.sha256, expectedBytes: file.bytes) { update in
            report(.init(fractionCompleted: update.fractionCompleted, status: status), to: progress)
        }
        do {
            guard ModelFileValidator.looksLikeGGUF(stashed) else {
                throw QwenASREngine.EngineError.notLoaded
            }
            try await DownloadIntegrity.verifyDownloaded(
                at: stashed, expectedBytes: file.bytes, expectedSHA256: file.sha256)
        } catch {
            DownloadFileRescuer.cleanup(stashed)
            throw error
        }
        try DownloadFileRescuer.install(stashed: stashed, to: destination)
        DownloadIntegrity.removeFileAndMarker(at: stashed)
        try DownloadIntegrity.markInstalled(
            at: destination, expectedBytes: file.bytes, expectedSHA256: file.sha256)
    }

    private static func report(_ update: ModelPreparationUpdate, to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }
}
