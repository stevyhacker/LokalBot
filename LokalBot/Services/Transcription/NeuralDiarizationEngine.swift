import FluidAudio
import Foundation
import CoreML

actor NeuralDiarizationEngine {
    private static let communityRuntimeID = "diarization:pyannote-community-1"
    private static let nemotronRuntimeID = "diarization:nemotron-3"

    private var models: OfflineDiarizerModels?
    private var nemotron: Nemotron3Models?
    private let communityPreparation = AsyncSingleFlight()
    private let nemotronPreparation = AsyncSingleFlight()
    private let communityLoader: @Sendable () async throws -> OfflineDiarizerModels
    private let nemotronLoader: @Sendable () async throws -> Nemotron3Models
    private var activeUses = 0
    private let idleSeconds: TimeInterval
    private lazy var idle = IdleTimer(seconds: idleSeconds) { [weak self] in await self?.unload() }

    init(
        idleSeconds: TimeInterval = 120,
        communityLoader: @escaping @Sendable () async throws -> OfflineDiarizerModels = {
            try await NeuralDiarizationEngine.loadPinnedCommunityModels()
        },
        nemotronLoader: @escaping @Sendable () async throws -> Nemotron3Models = {
            let directory = try await NemotronDiarizationModels.prepare()
            return try await Nemotron3Models.load(config: .offline, directory: directory)
        }
    ) {
        self.idleSeconds = idleSeconds
        self.communityLoader = communityLoader
        self.nemotronLoader = nemotronLoader
    }

    var hasLoadedModels: Bool { models != nil || nemotron != nil }

    nonisolated static var voiceModelInstalled: Bool {
        guard let snapshot = try? PinnedModelSnapshot.catalog("community") else { return false }
        let directory = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot
            .appendingPathComponent(Repo.diarizer.folderName)
        return snapshot.files.allSatisfy { file in
            let size = (try? directory.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map(Int64.init) == file.bytes
        }
    }

    private static func loadPinnedCommunityModels() async throws -> OfflineDiarizerModels {
        let directory = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot
            .appendingPathComponent(Repo.diarizer.folderName)
        try await PinnedModelSnapshot.catalog("community").prepare(in: directory)
        let started = Date()
        func load(_ name: String, units: MLComputeUnits = .all) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }
        let parameters = try Data(contentsOf: directory.appendingPathComponent("plda-parameters.json"))
        let root = try JSONSerialization.jsonObject(with: parameters) as? [String: Any]
        guard let tensors = root?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let data = Data(base64Encoded: base64), !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw PinnedModelSnapshot.SnapshotError.integrityFailure("plda-parameters.json")
        }
        let pldaPsi: [Double] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<UInt32>.size).map { offset in
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
            }
        }
        return try OfflineDiarizerModels(
            segmentationModel: load(ModelNames.OfflineDiarizer.segmentationPath),
            fbankModel: load(ModelNames.OfflineDiarizer.fbankPath, units: .cpuOnly),
            embeddingModel: load(ModelNames.OfflineDiarizer.embeddingPath),
            pldaRhoModel: load(ModelNames.OfflineDiarizer.pldaRhoPath),
            pldaPsi: pldaPsi, compilationDuration: Date().timeIntervalSince(started))
    }

    enum Failure: LocalizedError {
        case processing(DiarizationModel, String)
        var errorDescription: String? {
            switch self {
            case let .processing(model, reason):
                "\(model.displayName) speaker processing failed: \(reason). Retry, or choose another speaker model in Settings → Meetings."
            }
        }
    }

    nonisolated private static func configuration(includeVoiceSamples: Bool) -> OfflineDiarizerConfig {
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = 0.70
        clustering.warmStartFa = 0.07

        var embedding = OfflineDiarizerConfig.Embedding.community
        embedding.minSegmentDurationSeconds = 0.3

        var postProcessing = OfflineDiarizerConfig.PostProcessing.community
        postProcessing.minGapDurationSeconds = 0.05
        postProcessing.exclusiveSegments = true

        var segmentation = OfflineDiarizerConfig.Segmentation.community
        segmentation.stepRatio = 0.15

        var config = OfflineDiarizerConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            postProcessing: postProcessing)
        config.exposeChunkEmbeddings = includeVoiceSamples
        return config
    }

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
        let id = Self.communityRuntimeID
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
        let id = Self.nemotronRuntimeID
        await ModelRuntimeRegistry.shared.reserve(id: id, role: "Speaker diarization",
            label: DiarizationModel.nemotron3.displayName, estimatedBytes: ModelRuntimeRegistry.gibibytes(0.3))
        do {
            nemotron = try await nemotronLoader()
        } catch {
            await ModelRuntimeRegistry.shared.unregister(id: id)
            throw error
        }
    }

    private func finishUse() {
        activeUses -= 1
        guard activeUses == 0 else { return }
        Task { await idle.bump() }
    }

    private func unload() async {
        guard activeUses == 0, !(await communityPreparation.isRunning),
              !(await nemotronPreparation.isRunning), activeUses == 0 else { return }
        if models != nil {
            models = nil
            await ModelRuntimeRegistry.shared.unregister(id: Self.communityRuntimeID)
        }
        if nemotron != nil {
            nemotron = nil
            await ModelRuntimeRegistry.shared.unregister(id: Self.nemotronRuntimeID)
        }
    }

    func diarizeDetailed(url: URL, model: DiarizationModel, includeVoiceSamples: Bool) async throws -> SpeakerDiarizationResult {
        activeUses += 1
        defer { finishUse() }
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
        let result: DiarizationResult
        do { result = try await manager.process(url) } catch OfflineDiarizationError.noSpeechDetected {
            return SpeakerDiarizationResult(segments: [], samples: [])
        }
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

struct DiarizedSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String
}

extension Array where Element == DiarizedSegment {
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
