import FluidAudio
import Foundation

/// Acoustic speaker clustering for microphone and system-audio tracks.
/// Clusters identify distinct voices within a track; confirmation and identity
/// evidence determine whether a voice belongs to the user or someone else.
///
/// Owns CoreML buffers off the main actor. Nemotron's mutable prediction buffers
/// are used synchronously here and a fresh diarizer resets speaker state per track.
actor NeuralDiarizationEngine {
    private var models: OfflineDiarizerModels?
    private var nemotron: Nemotron3Models?
    private let communityPreparation = AsyncSingleFlight()
    private let nemotronPreparation = AsyncSingleFlight()
    private let communityLoader: @Sendable () async throws -> OfflineDiarizerModels
    private let nemotronLoader: @Sendable () async throws -> Nemotron3Models

    init(
        communityLoader: @escaping @Sendable () async throws -> OfflineDiarizerModels = {
            try await OfflineDiarizerModels.load()
        },
        nemotronLoader: @escaping @Sendable () async throws -> Nemotron3Models = {
            let directory = try await NemotronDiarizationModels.prepare()
            return try await Nemotron3Models.load(config: .offline, directory: directory)
        }
    ) {
        self.communityLoader = communityLoader
        self.nemotronLoader = nemotronLoader
    }

    enum Failure: LocalizedError {
        case processing(DiarizationModel, String)
        var errorDescription: String? {
            switch self {
            case let .processing(model, reason):
                "\(model.displayName) speaker processing failed: \(reason). Retry, or choose another speaker model in Settings → Recording."
            }
        }
    }

    nonisolated private static func configuration(includeVoiceSamples: Bool) -> OfflineDiarizerConfig {
        // Start from `community-1` defaults, override the knobs that matter
        // for meeting recordings (short interjections, conservative cluster
        // merging, never collapse to one speaker).
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = 0.70     // preserve the existing app tuning
        clustering.warmStartFa = 0.07   // pyannote default; VBx precision

        var embedding = OfflineDiarizerConfig.Embedding.community
        embedding.minSegmentDurationSeconds = 0.3   // keep brief interjections

        var postProcessing = OfflineDiarizerConfig.PostProcessing.community
        postProcessing.minGapDurationSeconds = 0.05 // tolerate close turns

        var segmentation = OfflineDiarizerConfig.Segmentation.community
        segmentation.stepRatio = 0.15   // finer windows (slower but better recall)

        var config = OfflineDiarizerConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            postProcessing: postProcessing)
        config.exposeChunkEmbeddings = includeVoiceSamples
        return config
    }

    /// Coalesce recording-time prewarm and processing; failed loads remain retryable.
    func prepareModels(model: DiarizationModel, includeVoiceSamples: Bool) async throws {
        try Task.checkCancellation()
        do {
            if model == .nemotron3 {
                try await nemotronPreparation.run { try await self.loadNemotron() }
            }
            if model == .community1 || includeVoiceSamples {
                try await communityPreparation.run { try await self.loadCommunity() }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.processing(model, error.localizedDescription)
        }
    }

    private func loadCommunity() async throws {
        guard models == nil else { return }
        let id = "diarization:pyannote-community-1"
        await ModelRuntimeRegistry.shared.reserve(id: id, role: "Speaker diarization / voice samples",
            label: DiarizationModel.community1.displayName, estimatedBytes: ModelRuntimeRegistry.gibibytes(0.1))
        do {
            models = try await communityLoader()
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: id)
            throw error
        }
    }

    private func loadNemotron() async throws {
        guard nemotron == nil else { return }
        let id = "diarization:nemotron-3"
        await ModelRuntimeRegistry.shared.reserve(id: id, role: "Speaker diarization",
            label: DiarizationModel.nemotron3.displayName, estimatedBytes: ModelRuntimeRegistry.gibibytes(0.3))
        do {
            nemotron = try await nemotronLoader()
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: id)
            throw error
        }
    }

    /// Errors are surfaced to the retry UI, never saved as successful generic-speaker checkpoints.
    func diarizeDetailed(url: URL, model: DiarizationModel, includeVoiceSamples: Bool) async throws -> SpeakerDiarizationResult {
        try await prepareModels(model: model, includeVoiceSamples: includeVoiceSamples)
        do {
            let result: SpeakerDiarizationResult
            switch model {
            case .community1:
                result = try await communityResult(url: url, includeVoiceSamples: includeVoiceSamples)
            case .nemotron3:
                guard let nemotron else { throw TranscriptionEngineError.notLoaded }
                let audio = try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
                try Task.checkCancellation()
                let diarizer = Nemotron3Diarizer(config: .offline, models: nemotron)
                let output = try diarizer.processComplete(audio)
                try Task.checkCancellation()
                let segments = Self.nemotronSegments(probabilities: output.probabilities, frameCount: output.frameCount)
                // Nemotron slots are anonymous, not identity embeddings. Preserve the
                // existing 256-D voice space. AttributedTrackTranscriber maps these
                // samples by clean temporal coverage, never by a cross-model slot ID.
                let samples = includeVoiceSamples
                    ? try await communityResult(url: url, includeVoiceSamples: true).samples : []
                result = SpeakerDiarizationResult(segments: segments, samples: samples)
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.processing(model, error.localizedDescription)
        }
    }

    nonisolated static func nemotronSegments(probabilities: [Float], frameCount: Int) -> [DiarizedSegment] {
        Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount,
            threshold: 0.5, minDurationSeconds: 0.2).map {
            DiarizedSegment(start: TimeInterval($0.startSeconds), end: TimeInterval($0.endSeconds),
                            speakerId: "S\($0.speakerIndex)")
        }
    }

    private func communityResult(url: URL, includeVoiceSamples: Bool) async throws -> SpeakerDiarizationResult {
        guard let models else { throw TranscriptionEngineError.notLoaded }
        let manager = OfflineDiarizerManager(config: Self.configuration(includeVoiceSamples: includeVoiceSamples))
        manager.initialize(models: models)
        let result = try await manager.process(url)
        try Task.checkCancellation()
        let segments = result.segments.map {
            DiarizedSegment(start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), speakerId: $0.speakerId)
        }
        let samples = includeVoiceSamples ? (result.chunkEmbeddings ?? []).map {
            SpeakerVoiceSample(speaker: $0.speakerId,
                range: .init(start: $0.startTimeSeconds, end: $0.endTimeSeconds), vector: $0.embedding256)
        } : []
        return SpeakerDiarizationResult(segments: segments, samples: samples)
    }
}

/// FluidAudio's segment, distilled to what the pipeline actually uses (start,
/// end, raw speaker id like `"S1"`). Optional voice samples remain private.
struct DiarizedSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String
}

extension Array where Element == DiarizedSegment {
    /// Find the FluidAudio segment that overlaps `(start, end)` the most.
    /// Used when relabeling a transcript segment: pick the speaker that
    /// covered most of the spoken interval.
    func dominantSpeaker(coveringStart start: TimeInterval,
                         end: TimeInterval) -> String? {
        var best: (speaker: String, overlap: TimeInterval) = ("", 0)
        for segment in self {
            let overlap = Swift.min(segment.end, end) - Swift.max(segment.start, start)
            guard overlap > 0 else { continue }
            if overlap > best.overlap { best = (segment.speakerId, overlap) }
        }
        return best.overlap > 0 ? best.speaker : nil
    }
}

struct SpeakerDiarizationResult: Sendable {
    var segments: [DiarizedSegment]
    var samples: [SpeakerVoiceSample]
}
