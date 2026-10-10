import Foundation

/// Immutable per-selection paths prevent a folder change from redirecting an
/// already-running meeting. Only the bundled runtime is executed.
actor FunASRNanoEngine: TranscriptionEngine {
    nonisolated let displayName = "Fun-ASR-Nano-2512"
    nonisolated let supportsStreaming = false
    let directory: String
    static let maxSegmentSeconds: Double = 20

    init(directory: String) { self.directory = directory }

    func prepare(progress: ModelPreparationProgressHandler?) async throws {
        let model = try FunASRNanoModel.load(directory: directory)
        let runtime = try SherpaOnnxRuntime.installedRuntime(executableName: "sherpa-onnx-offline")
        await progress?(.init(fractionCompleted: nil, status: "Checking local model…"))
        let work = try OnnxTranscriptionEngine.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let wav = work.appendingPathComponent("check.wav")
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0, count: 8_000), to: wav)
        // Loading a short synthetic input catches incompatible/corrupt graphs
        // before the selection replaces the current working model.
        _ = try await OnnxTranscriptionEngine.runBatch(
            runtime: runtime, arguments: model.arguments(language: nil), weights: model.weights,
            modelID: "fun-asr-nano-2512", label: displayName, wavs: [wav], requireAllResults: true)
        try Task.checkCancellation()
        await progress?(.init(fractionCompleted: 1, status: "Ready"))
    }

    func transcribe(audio url: URL, language: String?) async throws -> Transcript {
        let model = try FunASRNanoModel.load(directory: directory)
        let runtime = try SherpaOnnxRuntime.installedRuntime(executableName: "sherpa-onnx-offline")
        let work = try OnnxTranscriptionEngine.makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let spans = try await SpeechActivity.shared.spans(in: url, maxSegmentSeconds: Self.maxSegmentSeconds)
        let reader = try SpanAudioReader(url: url)
        var regions: [(span: SpeechSpan, wav: URL)] = []
        for (index, span) in spans.enumerated() {
            try Task.checkCancellation()
            let samples = try reader.samples(from: span.start, to: span.end)
            guard !samples.isEmpty else { continue }
            let wav = work.appendingPathComponent("\(index).wav")
            try OnnxTranscriptionEngine.writeWav(samples, to: wav)
            regions.append((span, wav))
        }
        let texts = try await OnnxTranscriptionEngine.runBatch(
            runtime: runtime, arguments: model.arguments(language: language), weights: model.weights,
            modelID: "fun-asr-nano-2512", label: displayName, wavs: regions.map(\.wav), requireAllResults: true)
        return Transcript(segments: SpanTranscription.segments(pairing: regions.map(\.span), with: texts),
                          engine: "Fun-ASR-Nano-2512 (sherpa-onnx)")
    }
}
