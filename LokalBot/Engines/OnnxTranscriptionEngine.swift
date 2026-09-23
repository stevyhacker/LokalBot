import AVFoundation
import Darwin
import FluidAudio
import Foundation

/// Transcription via the bundled sherpa-onnx ONNX runtime, invoked as a
/// subprocess (the same engine family Handy uses; mirrors the `LlamaServer`
/// subprocess pattern). Covers languages WhisperKit/FluidAudio handle poorly:
/// **SenseVoice** (Chinese / Japanese / Korean / Cantonese) and **GigaAM**
/// (Russian). The `sherpa-onnx-offline` binary + its onnxruntime dylibs ship in
/// the app bundle; the chosen model is downloaded on first use.
///
/// The track is split into VAD speech regions and decoded in a single batch
/// call (one model load), so each region carries the real start/end time of its
/// span — the same timestamp-exact approach as `CohereEngine` — and no model is
/// left resident afterwards.
actor OnnxTranscriptionEngine: TranscriptionEngine {

    enum Model: Sendable {
        case senseVoice
        case gigaamRussian

        var displayName: String {
            switch self {
            case .senseVoice: "SenseVoice (ONNX)"
            case .gigaamRussian: "GigaAM Russian (ONNX)"
            }
        }
        /// Tarball top-level directory == the model-zoo archive base name.
        var folderName: String {
            switch self {
            case .senseVoice: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
            case .gigaamRussian: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16"
            }
        }
        var archiveURL: URL {
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(folderName).tar.bz2")!
        }
        /// `--model-type` value, passed so the binary skips its load-twice probe.
        var modelType: String {
            switch self {
            case .senseVoice: "sense_voice"
            case .gigaamRussian: "nemo_ctc"
            }
        }
    }

    static let senseVoice = OnnxTranscriptionEngine(model: .senseVoice)
    static let gigaamRussian = OnnxTranscriptionEngine(model: .gigaamRussian)

    let model: Model
    private let preparation = AsyncSingleFlight()
    private init(model: Model) { self.model = model }

    nonisolated var displayName: String { model.displayName }
    nonisolated let supportsStreaming = false

    static let sampleRate = 16_000

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        let runtime = try SherpaOnnxRuntime.installedRuntime(executableName: "sherpa-onnx-offline")
        let modelDir = try await preparedModelDir()
        let modelFile = try Self.locateModel(in: modelDir)
        let tokens = modelDir.appendingPathComponent("tokens.txt")

        let work = try Self.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }

        // VAD speech regions give real per-utterance timing; fall back to the
        // whole track as a single region when VAD is unavailable.
        let spans = try await SpeechActivity.shared.spans(in: url, maxSegmentSeconds: nil)
        let reader = try SpanAudioReader(url: url)
        var regions: [(span: SpeechSpan, wav: URL)] = []
        for (index, span) in spans.enumerated() {
            let samples = try reader.samples(from: span.start, to: span.end)
            guard !samples.isEmpty else { continue }
            let wav = work.appendingPathComponent("\(index).wav")
            try Self.writeWav(samples, to: wav)
            regions.append((span, wav))
        }

        let started = Date()
        let texts = try await Self.transcribeBatch(
            runtime: runtime, modelFile: modelFile, tokens: tokens,
            model: model, language: language, wavs: regions.map(\.wav))
        let elapsed = Date().timeIntervalSince(started)
        let total = regions.last?.span.end ?? 0
        lokalbotLog(
            "onnx profile model=\(model.folderName) regions=\(regions.count) results=\(texts.count) elapsed=\(String(format: "%.2fs", elapsed)) rtfx=\(String(format: "%.1fx", elapsed > 0 ? total / elapsed : 0))")

        let segments = SpanTranscription.segments(pairing: regions.map(\.span), with: texts)
        return Transcript(segments: segments, engine: "\(model.folderName) (sherpa-onnx)")
    }

    /// Settings "Download" action: install the runtime + fetch the model.
    /// `URLSession.download` gives no granular fraction here, so we surface
    /// status text (the model row shows it).
    func prepare(progress: ModelPreparationProgressHandler? = nil) async throws {
        _ = try SherpaOnnxRuntime.installedRuntime(executableName: "sherpa-onnx-offline")
        report(.init(fractionCompleted: nil, status: "Downloading model..."), to: progress)
        _ = try await preparedModelDir()
        report(.init(fractionCompleted: 1, status: "Ready"), to: progress)
    }

    private nonisolated func report(_ update: ModelPreparationUpdate,
                                    to handler: ModelPreparationProgressHandler?) {
        guard let handler else { return }
        Task { @MainActor in handler(update) }
    }

    // MARK: - Model download / extract

    func preparedModelDir() async throws -> URL {
        let dir = Self.modelsRoot.appendingPathComponent(model.folderName, isDirectory: true)
        if (try? Self.locateModel(in: dir)) != nil { return dir }

        try await preparation.run { [weak self] in
            guard let self else { return }
            try await self.installModel(in: dir)
        }
        guard (try? Self.locateModel(in: dir)) != nil else { throw EngineError.modelUnavailable }
        return dir
    }

    private func installModel(in dir: URL) async throws {
        // A waiter may enter after the first caller finished but before it
        // observed the result; keep this operation idempotent as well.
        if (try? Self.locateModel(in: dir)) != nil { return }

        try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: model.archiveURL)
        let archive = Self.modelsRoot.appendingPathComponent("\(model.folderName).tar.bz2")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: tmp, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        try ArchiveExtractor.extractBzip2Tar(archive, into: Self.modelsRoot)
        guard (try? Self.locateModel(in: dir)) != nil else { throw EngineError.modelUnavailable }
    }

    // MARK: - Paths

    private static var appSupport: URL { AppDirectories.applicationSupport }
    private static var modelsRoot: URL {
        appSupport.appendingPathComponent("sherpa-models", isDirectory: true)
    }

    /// SenseVoice ships `model.int8.onnx`; NeMo-CTC tarballs ship `model.onnx`
    /// and/or `model.int8.onnx`. Prefer int8.
    private static func locateModel(in dir: URL) throws -> URL {
        for name in ["model.int8.onnx", "model.onnx"] {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw EngineError.modelUnavailable
    }

    private static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Subprocess

    private struct ResultLine: Decodable { let text: String }

    private static func transcribeBatch(runtime: (binary: URL, libDir: URL),
                                        modelFile: URL, tokens: URL, model: Model,
                                        language: String?, wavs: [URL]) async throws -> [String] {
        guard !wavs.isEmpty else { return [] }
        var args = [
            "--tokens=\(tokens.path)",
            "--num-threads=4",
            "--model-type=\(model.modelType)",
        ]
        switch model {
        case .senseVoice:
            args.append("--sense-voice-model=\(modelFile.path)")
            args.append("--sense-voice-use-itn=true")
            args.append("--sense-voice-language=\(Self.senseVoiceLanguage(language))")
        case .gigaamRussian:
            args.append("--nemo-ctc-model=\(modelFile.path)")
        }
        args.append(contentsOf: wavs.map(\.path))

        let binary = runtime.binary
        let libDir = runtime.libDir
        let processController = ONNXProcessController()
        let execution = Task.detached(priority: .userInitiated) { () throws -> String in
            let runtimeID = "transcription:onnx:\(model.modelType):\(UUID().uuidString)"
            let estimatedBytes = ModelRuntimeRegistry.fileBytes(at: modelFile)
            await ModelRuntimeRegistry.shared.reserve(
                id: runtimeID, role: "Transcribe", label: model.displayName,
                estimatedBytes: estimatedBytes)
            do {
                // Cancellation can arrive while the MainActor reservation call
                // is suspended. Keep every subsequent exit inside this cleanup
                // scope so a helper that never attaches cannot strand a row.
                try Task.checkCancellation()
                let process = Process()
                process.executableURL = binary
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["DYLD_LIBRARY_PATH"] = libDir.path
                process.environment = env
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice   // verbose logging — discard
                guard processController.attach(process) else { throw CancellationError() }
                defer { processController.detach(process) }
                try process.run()
                processController.processDidStart(process)
                let processUsage = SystemResourceSampler.processUsage(for: process.processIdentifier)
                await ModelRuntimeRegistry.shared.register(
                    id: runtimeID,
                    role: "Transcribe",
                    label: model.displayName,
                    estimatedBytes: estimatedBytes,
                    processIdentifier: processUsage?.processIdentifier,
                    processStartTime: processUsage?.startTime
                )
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try Task.checkCancellation()
                if processController.wasCancelled { throw CancellationError() }
                guard process.terminationStatus == 0 else {
                    throw EngineError.transcriptionFailed(Int(process.terminationStatus))
                }
                await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
                return String(decoding: data, as: UTF8.self)
            } catch {
                await ModelRuntimeRegistry.shared.unregister(id: runtimeID)
                throw error
            }
        }
        let stdout = try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            execution.cancel()
            processController.cancel()
        }
        return Self.parseTexts(stdout)
    }

    /// `sherpa-onnx-offline` prints one JSON object per wav, in input order, on
    /// stdout: `{"lang": …, "text": "…", "timestamps": […], …}`.
    private static func parseTexts(_ stdout: String) -> [String] {
        stdout.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.contains("\"text\""),
                  let data = trimmed.data(using: .utf8),
                  let result = try? JSONDecoder().decode(ResultLine.self, from: data)
            else { return nil }
            return result.text
        }
    }

    private static func senseVoiceLanguage(_ language: String?) -> String {
        switch language {
        case "zh", "en", "ja", "ko", "yue": return language!
        default: return "auto"
        }
    }

    // MARK: - WAV writer (16 kHz mono 16-bit PCM, what sherpa-onnx expects)

    static func writeWav(_ samples: [Float], to url: URL) throws {
        let rate = UInt32(sampleRate)
        let dataBytes = samples.count * 2
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var data = Data(capacity: 44 + dataBytes)
        data.append(Data("RIFF".utf8))
        data.append(le32(UInt32(36 + dataBytes)))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))                            // PCM fmt chunk size
        data.append(le16(1))                             // format = PCM
        data.append(le16(1))                             // channels = mono
        data.append(le32(rate))                          // sample rate
        data.append(le32(rate * 2))                      // byte rate
        data.append(le16(2))                             // block align
        data.append(le16(16))                            // bits per sample
        data.append(Data("data".utf8))
        data.append(le32(UInt32(dataBytes)))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(le16(UInt16(bitPattern: Int16(clamped * 32767))))
        }
        try data.write(to: url, options: .atomic)
    }

    enum EngineError: LocalizedError {
        case runtimeMissing
        case modelUnavailable
        case transcriptionFailed(Int)
        var errorDescription: String? {
            switch self {
            case .runtimeMissing: "The bundled sherpa-onnx runtime is missing from the app."
            case .modelUnavailable: "The transcription model could not be downloaded."
            case .transcriptionFailed(let code): "sherpa-onnx-offline exited with code \(code)."
            }
        }
    }
}

/// Bridges structured Swift cancellation to the blocking sherpa subprocess.
/// Cancellation sends SIGTERM immediately and escalates to SIGKILL only if the
/// helper ignores it, guaranteeing that `readDataToEndOfFile` eventually
/// unblocks and model memory is released.
private final class ONNXProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func processDidStart(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled && self.process === process
        lock.unlock()
        if shouldTerminate, process.isRunning { terminate(process) }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        terminate(process)
    }

    private func terminate(_ process: Process) {
        let pid = process.processIdentifier
        let processStartTime = SystemResourceSampler.processUsage(for: pid)?.startTime
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, let process else { return }
            self.killIfStillAttached(
                process, pid: pid, expectedStartTime: processStartTime)
        }
    }

    private func killIfStillAttached(
        _ process: Process,
        pid: pid_t,
        expectedStartTime: UInt64?
    ) {
        lock.lock()
        let isSameCancelledProcess = cancelled && self.process === process
        lock.unlock()
        guard isSameCancelledProcess,
              process.isRunning,
              process.processIdentifier == pid,
              let expectedStartTime,
              SystemResourceSampler.processUsage(for: pid)?.startTime == expectedStartTime
        else { return }
        kill(pid, SIGKILL)
    }
}
