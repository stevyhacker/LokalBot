import Foundation

enum KokoroVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case heart = "af_heart"
    case bella = "af_bella"
    case sarah = "af_sarah"
    case sky = "af_sky"
    case adam = "am_adam"
    case puck = "am_puck"
    case emma = "bf_emma"
    case fable = "bm_fable"
    case george = "bm_george"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heart: "Heart"
        case .bella: "Bella"
        case .sarah: "Sarah"
        case .sky: "Sky"
        case .adam: "Adam"
        case .puck: "Puck"
        case .emma: "Emma"
        case .fable: "Fable"
        case .george: "George"
        }
    }

    var speakerID: Int {
        switch self {
        case .bella: 2
        case .heart: 3
        case .sarah: 9
        case .sky: 10
        case .adam: 11
        case .puck: 18
        case .emma: 21
        case .fable: 25
        case .george: 26
        }
    }
}

struct SpeechSynthesisRequest: Sendable {
    var text: String
    var voice: KokoroVoice
    var speed: Double
    var outputURL: URL?
}

enum SpeechTemporaryOutputCleanup {
    /// Releases playback first so a caller never unlinks the plaintext WAV
    /// while AVFoundation may still need it.
    static func cleanup(_ outputURL: URL?, afterPlaybackStops stopPlayback: () -> Void) {
        stopPlayback()
        guard let outputURL else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }
}

actor KokoroSpeechEngine {
    static let shared = KokoroSpeechEngine()
    private let preparation = AsyncSingleFlight()

    private static let executableName = "sherpa-onnx-offline-tts"
    private static let modelFolderName = "kokoro-multi-lang-v1_0"
    private static let archiveURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2"
    )!
    private static let archiveBytes: Int64 = 349_418_188
    private static let archiveSHA256 = "c133d26353d776da730870dac7da07dbfc9a5e3bc80cc5e8e83ab6e823be7046"

    nonisolated var displayName: String { "Kokoro 82M" }

    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        report(.init(fractionCompleted: nil, status: "Checking..."), to: progress)
        _ = try SherpaOnnxRuntime.installedRuntime(executableName: Self.executableName)
        if Self.isModelDownloaded {
            report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
            return
        }
        report(.init(fractionCompleted: nil, status: "Downloading Kokoro..."), to: progress)
        _ = try await preparedModelDir()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> URL {
        let text = SpeechTextSanitizer.plainText(fromMarkdown: request.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechError.emptyText }

        let runtime = try SherpaOnnxRuntime.installedRuntime(executableName: Self.executableName)
        let modelDir = try await preparedModelDir()
        let output = request.outputURL ?? Self.temporaryOutputURL()
        var completed = false
        defer {
            if !completed {
                SpeechTemporaryOutputCleanup.cleanup(output) {}
            }
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let config = try Self.modelConfig(in: modelDir)
        let speed = min(2.0, max(0.5, request.speed))
        let lengthScale = 1.0 / speed
        let args = [
            "--debug=0",
            "--kokoro-model=\(config.model.path)",
            "--kokoro-voices=\(config.voices.path)",
            "--kokoro-tokens=\(config.tokens.path)",
            "--kokoro-data-dir=\(config.dataDir.path)",
            "--kokoro-lexicon=\(config.lexicon)",
            "--num-threads=2",
            "--sid=\(request.voice.speakerID)",
            "--kokoro-length-scale=\(Self.formatScale(lengthScale))",
            "--output-filename=\(output.path)",
            text,
        ]

        try await Self.run(runtime: runtime, args: args, modelAt: config.model)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw SpeechError.missingOutput
        }
        try Task.checkCancellation()
        completed = true
        return output
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    private func preparedModelDir() async throws -> URL {
        let dir = Self.modelDir
        if Self.hasRequiredFiles(in: dir) { return dir }

        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.installModel(in: dir)
        }
        guard Self.hasRequiredFiles(in: dir) else { throw SpeechError.modelUnavailable }
        return dir
    }

    private func installModel(in dir: URL) async throws {
        if Self.hasRequiredFiles(in: dir) { return }

        try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: Self.archiveURL)
        let archive = Self.modelsRoot.appendingPathComponent("\(Self.modelFolderName).tar.bz2")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: tmp, to: archive)
        defer { DownloadIntegrity.removeFileAndMarker(at: archive) }

        do {
            try await DownloadIntegrity.verifyDownloaded(
                at: archive, expectedBytes: Self.archiveBytes,
                expectedSHA256: Self.archiveSHA256)
        } catch {
            DownloadIntegrity.removeFileAndMarker(at: archive)
            throw error
        }

        try ArchiveExtractor.extractBzip2Tar(archive, into: Self.modelsRoot)
        guard Self.hasRequiredFiles(in: dir) else { throw SpeechError.modelUnavailable }
    }

    nonisolated static var isModelDownloaded: Bool {
        hasRequiredFiles(in: modelDir)
    }

    nonisolated static func deleteModel() throws {
        try? FileManager.default.removeItem(
            at: modelsRoot.appendingPathComponent("\(modelFolderName).tar.bz2"))
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
    }

    private nonisolated static var modelsRoot: URL {
        AppDirectories.applicationSupport.appendingPathComponent("sherpa-models", isDirectory: true)
    }

    private nonisolated static var modelDir: URL {
        modelsRoot.appendingPathComponent(modelFolderName, isDirectory: true)
    }

    private nonisolated static func modelConfig(in dir: URL) throws -> ModelConfig {
        let config = ModelConfig(
            model: dir.appendingPathComponent("model.onnx"),
            voices: dir.appendingPathComponent("voices.bin"),
            tokens: dir.appendingPathComponent("tokens.txt"),
            dataDir: dir.appendingPathComponent("espeak-ng-data", isDirectory: true),
            lexicon: [
                dir.appendingPathComponent("lexicon-us-en.txt").path,
                dir.appendingPathComponent("lexicon-zh.txt").path,
            ].joined(separator: ","))
        guard hasRequiredFiles(in: dir) else { throw SpeechError.modelUnavailable }
        return config
    }

    private nonisolated static func hasRequiredFiles(in dir: URL) -> Bool {
        let paths = [
            dir.appendingPathComponent("model.onnx").path,
            dir.appendingPathComponent("voices.bin").path,
            dir.appendingPathComponent("tokens.txt").path,
            dir.appendingPathComponent("espeak-ng-data", isDirectory: true).path,
            dir.appendingPathComponent("lexicon-us-en.txt").path,
            dir.appendingPathComponent("lexicon-zh.txt").path,
        ]
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private nonisolated static func temporaryOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-speech-\(UUID().uuidString).wav")
    }

    private nonisolated static func formatScale(_ scale: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), scale)
    }

    private nonisolated static func run(runtime: (binary: URL, libDir: URL),
                                        args: [String], modelAt modelURL: URL) async throws {
        let cancellation = ProcessCancellationController()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()

                let runtimeID = "speech:kokoro:\(UUID().uuidString)"
                let estimatedBytes = ModelRuntimeRegistry.fileBytes(at: modelURL)
                await ModelRuntimeRegistry.shared.reserve(
                    id: runtimeID, role: "Speech synthesis", label: "Kokoro 82M",
                    estimatedBytes: estimatedBytes)

                let process = Process()
                process.executableURL = runtime.binary
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["DYLD_LIBRARY_PATH"] = runtime.libDir.path
                process.environment = env

                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
                    throw error
                }
                cancellation.track(process)
                defer { cancellation.clear(process) }

                let processUsage = SystemResourceSampler.processUsage(
                    for: process.processIdentifier)
                await ModelRuntimeRegistry.shared.register(
                    id: runtimeID,
                    role: "Speech synthesis",
                    label: "Kokoro 82M",
                    estimatedBytes: estimatedBytes,
                    processIdentifier: processUsage?.processIdentifier,
                    processStartTime: processUsage?.startTime
                )

                if Task.isCancelled {
                    cancellation.cancel()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
                try Task.checkCancellation()
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: stderr, as: UTF8.self)
                        + String(decoding: stdout, as: UTF8.self)
                    throw SpeechError.synthesisFailed(Int(process.terminationStatus), message)
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private struct ModelConfig {
        let model: URL
        let voices: URL
        let tokens: URL
        let dataDir: URL
        let lexicon: String
    }

    enum SpeechError: LocalizedError {
        case emptyText
        case modelUnavailable
        case missingOutput
        case synthesisFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "There is no text to read aloud."
            case .modelUnavailable:
                return "The Kokoro speech model could not be downloaded."
            case .missingOutput:
                return "Kokoro did not write an audio file."
            case .synthesisFailed(let code, let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Kokoro exited with code \(code)."
                    : "Kokoro exited with code \(code): \(trimmed)"
            }
        }
    }
}

private final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func track(_ process: Process) {
        var shouldTerminate = false
        lock.lock()
        if cancelled {
            shouldTerminate = true
        } else {
            self.process = process
        }
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        let active: Process?
        lock.lock()
        cancelled = true
        active = process
        lock.unlock()
        if active?.isRunning == true {
            active?.terminate()
        }
    }
}

enum SpeechTextSanitizer {
    static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown
        text = replace(pattern: #"(?s)```.*?```"#, in: text, with: " ")
        text = replace(pattern: #"`([^`]+)`"#, in: text, with: "$1")
        text = replace(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: text, with: "$1")
        text = replace(pattern: #"\[meeting:[^\]]+\]"#, in: text, with: " ")
        text = replace(pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, in: text, with: "")
        text = replace(pattern: #"(?m)^\s*[-*+]\s+"#, in: text, with: "")
        text = replace(pattern: #"(?m)^\s*\d+\.\s+"#, in: text, with: "")
        text = replace(pattern: #"[*_~>#]"#, in: text, with: "")
        text = replace(pattern: #"\s+"#, in: text, with: " ")
        return text
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
