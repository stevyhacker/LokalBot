import Foundation

enum QwenLlamaASR {
    struct File: Sendable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    struct Weights: Sendable, Equatable {
        let repository: String
        let revision: String
        let model: File
        let projector: File
        let folderName: String
        let role: LlamaServerRole
        let legacyMLXRepository: String

        var files: [File] { [model, projector] }

        var totalBytes: Int64 { files.reduce(Int64(0)) { $0 + $1.bytes } }

        func downloadURL(for file: File) -> URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
        }

        func modelRoot(appSupport: URL) -> URL {
            appSupport
                .appendingPathComponent("qwen3-asr-models", isDirectory: true)
                .appendingPathComponent("gguf", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
        }

        func url(for file: File, appSupport: URL) -> URL {
            modelRoot(appSupport: appSupport).appendingPathComponent(file.name)
        }

        func isDownloaded(appSupport: URL) -> Bool {
            files.allSatisfy { ModelFileValidator.looksLikeGGUF(url(for: $0, appSupport: appSupport)) }
        }

        func missingBytes(appSupport: URL) -> Int64 {
            files.reduce(Int64(0)) { total, file in
                ModelFileValidator.looksLikeGGUF(url(for: file, appSupport: appSupport))
                    ? total : total + file.bytes
            }
        }

        func legacyMLXDirectory(appSupport: URL) -> URL {
            QwenASREngine.hubStyleCacheDir(
                base: appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
                modelID: legacyMLXRepository)
        }

        func makeServer(projector: URL) -> LlamaServer {
            LlamaServer(
                role: role, contextTokens: QwenLlamaASR.contextTokens,
                extraArgs: ["--mmproj", projector.path] + QwenLlamaASR.serverArguments,
                environment: QwenLlamaASR.serverEnvironment,
                runtimeAllowanceBytes: 768 * 1_048_576)
        }

        func prepareFiles(
            appSupport: URL,
            progress: ModelPreparationProgressHandler?
        ) async throws -> (model: URL, projector: URL) {
            try FileManager.default.createDirectory(at: modelRoot(appSupport: appSupport),
                                                    withIntermediateDirectories: true)
            for (file, status) in [(model, "Downloading Qwen3-ASR model..."),
                                   (projector, "Downloading Qwen3-ASR audio encoder...")] {
                try await QwenLlamaASR.downloadIfNeeded(file, from: downloadURL(for: file),
                                                        to: url(for: file, appSupport: appSupport),
                                                        status: status, progress: progress)
            }
            removeLegacyMLXWeights(appSupport: appSupport)
            return (url(for: model, appSupport: appSupport), url(for: projector, appSupport: appSupport))
        }

        func removeFiles(appSupport: URL, siblings: [Weights] = QwenLlamaASR.allWeights) throws {
            let remainingSiblings = siblings.filter {
                $0 != self && $0.folderName == folderName
                    && ModelFileValidator.looksLikeGGUF($0.url(for: $0.model, appSupport: appSupport))
            }
            let keptNames = Set(remainingSiblings.flatMap(\.files).map(\.name))
            for file in files where !keptNames.contains(file.name) {
                DownloadIntegrity.removeFileAndMarker(at: url(for: file, appSupport: appSupport))
            }
            let fileManager = FileManager.default
            if remainingSiblings.isEmpty {
                let root = modelRoot(appSupport: appSupport)
                if fileManager.fileExists(atPath: root.path) {
                    try fileManager.removeItem(at: root)
                }
                let legacy = legacyMLXDirectory(appSupport: appSupport)
                if fileManager.fileExists(atPath: legacy.path) {
                    try fileManager.removeItem(at: legacy)
                }
            }
        }

        private func removeLegacyMLXWeights(appSupport: URL) {
            let legacy = legacyMLXDirectory(appSupport: appSupport)
            guard FileManager.default.fileExists(atPath: legacy.path) else { return }
            do {
                try FileManager.default.removeItem(at: legacy)
                lokalbotLog("qwen-asr removed the replaced MLX weights repository=\(legacyMLXRepository)")
            } catch {
                lokalbotLog("qwen-asr could not remove the replaced MLX weights repository=\(legacyMLXRepository): \(error.localizedDescription)")
            }
        }
    }

    static let accuracyLokalBotV3 = Weights(
        repository: "stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF",
        revision: "33ca434ce773d56914f609cec80e843d085b5645",
        model: File(name: "Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf", bytes: 2_165_035_040,
                    sha256: "a3611b68d5065e3984d0cf8a93adaf7cfaf5f4a09b33da8d68914a7ae85aee19"),
        projector: File(name: "mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf", bytes: 355_709_376,
                        sha256: "0eb673620a73c412a0de2bb31a427ac5367f686e14db0922944023e44356c785"),
        folderName: "Qwen3-ASR-1.7B-Q8_0", role: .qwenASR,
        legacyMLXRepository: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")

    static let accuracy = Weights(
        repository: "ggml-org/Qwen3-ASR-1.7B-GGUF",
        revision: "36a678687ba7d07a74ca70ccb0e36902e005fb80",
        model: File(name: "Qwen3-ASR-1.7B-Q8_0.gguf", bytes: 2_165_034_944,
                    sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57"),
        projector: File(name: "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf", bytes: 355_709_344,
                        sha256: "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d"),
        folderName: "Qwen3-ASR-1.7B-Q8_0", role: .qwenASR,
        legacyMLXRepository: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")

    static let compactLokalBotV1 = Weights(
        repository: "stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF",
        revision: "4f9e435248343b208223ce33fa1a8b0b2f2e6bc6",
        model: File(name: "Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf", bytes: 804_749_344,
                    sha256: "c7493d2b337bb351f1c562337e7c9fdfef0195a26d4e91cfae805a6416066c3c"),
        projector: File(name: "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf", bytes: 214_392_480,
                        sha256: "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d"),
        folderName: "Qwen3-ASR-0.6B-Q8_0", role: .qwenASRCompact,
        legacyMLXRepository: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")

    static let compact = Weights(
        repository: "ggml-org/Qwen3-ASR-0.6B-GGUF",
        revision: "928ab958557df9aa2ef1c93e0e83c7ad0933fae2",
        model: File(name: "Qwen3-ASR-0.6B-Q8_0.gguf", bytes: 804_749_248,
                    sha256: "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971"),
        projector: File(name: "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf", bytes: 214_392_480,
                        sha256: "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d"),
        folderName: "Qwen3-ASR-0.6B-Q8_0", role: .qwenASRCompact,
        legacyMLXRepository: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")

    static let allWeights: [Weights] = [accuracyLokalBotV3, accuracy, compactLokalBotV1, compact]

    static let mediaMarker = "<__media__>"
    static let serverEnvironment = ["LLAMA_MEDIA_MARKER": mediaMarker]

    static let maxConcurrentWindows = 3
    static let contextTokens = 6_144
    static let serverArguments = [
        "--parallel", String(maxConcurrentWindows),
        "--ubatch-size", "2048",
        "--cache-ram", "0",
    ]

    static func prompt(language: String?, context: String?) -> String {
        "<|im_start|>system\n\(context ?? "")<|im_end|>\n<|im_start|>user\n\(mediaMarker)<|im_end|>\n"
            + "<|im_start|>assistant\n\(language.map { "language \($0)" } ?? "")<asr_text>"
    }

    static func completionURL(serverBaseURL: URL) -> URL {
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
            "n_predict": maxTokens, "temperature": 0, "top_k": 1, "samplers": ["top_k"],
            "repeat_penalty": 1.0, "cache_prompt": false, "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

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

    fileprivate static func downloadIfNeeded(_ file: File, from source: URL, to destination: URL, status: String,
                                             progress: ModelPreparationProgressHandler?) async throws {
        if ModelFileValidator.looksLikeGGUF(destination),
           await DownloadIntegrity.verifiedExisting(
               at: destination, expectedBytes: file.bytes, expectedSHA256: file.sha256) {
            return
        }
        DownloadIntegrity.removeFileAndMarker(at: destination)
        report(.init(fractionCompleted: 0, status: status), to: progress)
        let stashed = try await ModelDownloadRouting.download(
            from: source, session: .shared,
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
