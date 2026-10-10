import Foundation

/// The sherpa-onnx export of FunAudioLLM/Fun-ASR-Nano-2512. These files
/// remain owned by the user: validation never writes receipts or moves them.
struct FunASRNanoModel: Sendable {
    let directory: URL
    let encoder: URL
    let decoder: URL
    let embedding: URL
    let tokenizer: URL
    let externalData: URL?

    var weights: [URL] { [encoder, decoder, embedding] + (externalData.map { [$0] } ?? []) }

    static func load(directory path: String) throws -> Self {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { throw ValidationError.chooseDirectory }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ValidationError.chooseDirectory
        }
        func file(_ names: [String]) throws -> URL {
            for name in names {
                let url = root.appendingPathComponent(name)
                if usableFile(url) { return url }
            }
            throw ValidationError.missingFiles(names.joined(separator: " / "))
        }
        let encoder = try file(["encoder_adaptor.int8.onnx", "encoder_adaptor.onnx"])
        let embedding = try file(["embedding.int8.onnx", "embedding.onnx"])
        let decoder = try file(["llm.int8.onnx", "llm.fp16.onnx", "llm.fp32.onnx", "llm.onnx"])
        let externalData = decoder.lastPathComponent == "llm.fp32.onnx" ? try file(["llm.fp32.data"]) : nil
        for name in ["tokenizer.json", "vocab.json", "merges.txt"] {
            _ = try file(["Qwen3-0.6B/" + name])
        }
        return Self(directory: root, encoder: encoder, decoder: decoder, embedding: embedding,
                    tokenizer: root.appendingPathComponent("Qwen3-0.6B", isDirectory: true), externalData: externalData)
    }

    /// Lightweight readiness check; the runtime checks actual ONNX graphs
    /// during preparation. Support symlinks used by local model caches.
    private static func usableFile(_ url: URL) -> Bool {
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 128) else { return false }
        let text = String(decoding: prefix, as: UTF8.self).lowercased()
        return !text.hasPrefix("version https://git-lfs.github.com/spec/")
            && !text.hasPrefix("<!doctype html") && !text.hasPrefix("<html")
    }

    func arguments(language: String?) -> [String] {
        var args = [
            "--num-threads=4", "--provider=cpu",
            "--funasr-nano-encoder-adaptor=\(encoder.path)",
            "--funasr-nano-embedding=\(embedding.path)",
            "--funasr-nano-llm=\(decoder.path)",
            "--funasr-nano-tokenizer=\(tokenizer.path)",
            "--funasr-nano-max-new-tokens=512",
            "--funasr-nano-itn=true"
        ]
        // The runtime takes language names, not the app's ISO language codes.
        if let name = ["zh": "中文", "yue": "粤语", "en": "英文", "ja": "日文"][language ?? ""] {
            args.append("--funasr-nano-language=\(name)")
        }
        return args
    }

    enum ValidationError: LocalizedError {
        case chooseDirectory
        case missingFiles(String)

        var errorDescription: String? {
            switch self {
            case .chooseDirectory:
                "Choose an existing local Fun-ASR-Nano ONNX model folder in Models → Transcribe."
            case .missingFiles(let names):
                "Incomplete Fun-ASR-Nano ONNX folder: missing or unreadable \(names). Use the sherpa-onnx export, not the original PyTorch weights."
            }
        }
    }
}
