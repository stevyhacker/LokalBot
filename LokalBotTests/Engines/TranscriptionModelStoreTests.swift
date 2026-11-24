import XCTest
import FluidAudio
@testable import LokalBot

final class TranscriptionModelStoreTests: XCTestCase {
    func testRemovedGraniteTurboSelectionDecodesAsParakeetV2() throws {
        for raw in ["granite-speech-5-turbo", "Granite Speech 5 fast (English)"] {
            let data = try JSONEncoder().encode([raw])
            XCTAssertEqual(try JSONDecoder().decode([TranscriptionModelChoice].self, from: data), [.parakeetV2], raw)
        }
        XCTAssertFalse(TranscriptionModelChoice.allCases.map(\.rawValue).contains("granite-speech-5-turbo"))
        XCTAssertThrowsError(try JSONDecoder().decode([TranscriptionModelChoice].self,
                                                      from: Data(#"["no-such-model"]"#.utf8)))
    }

    func testRetiredModelFoldersAreRemovedByExactPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-retired-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let turbo = root.appendingPathComponent("granite-turbo/5.0-470m", isDirectory: true)
        let kept = root.appendingPathComponent("granite-speech", isDirectory: true)
        for folder in [turbo, kept] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        }
        let removed = TranscriptionModelStore.removeRetiredModels(appSupport: root)
        XCTAssertEqual(removed.map(\.lastPathComponent), ["granite-turbo"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("granite-turbo").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("model.safetensors").path))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("granite-turbo"), withDestinationURL: kept)
        XCTAssertEqual(TranscriptionModelStore.removeRetiredModels(appSupport: root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("model.safetensors").path))
    }

    func testSpeech5RequiresItsOwnCompleteCacheAndDeletionPreserves41() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeGraniteModel(in: environment)
        let configuration = GraniteSpeechModelConfiguration.speech5
        let model = GraniteSpeechEngine.modelURL(configuration: configuration, appSupport: environment.appSupport)
        let projector = GraniteSpeechEngine.projectorURL(configuration: configuration, appSupport: environment.appSupport)

        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.graniteSpeech5, environment: environment))
        try writeGGUF(model)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.graniteSpeech5, environment: environment))
        try writeGGUF(projector)
        XCTAssertTrue(TranscriptionModelStore.downloadedChoices(environment: environment).contains("granite-speech-5.0-2b"))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.graniteSpeech, environment: environment))

        try TranscriptionModelStore.delete(.graniteSpeech5, environment: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projector.path))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.graniteSpeech, environment: environment))
    }

    func testDeletingGranite41LeavesSpeech5Downloaded() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeGraniteModel(in: environment)
        try writeGGUF(GraniteSpeechEngine.modelURL(configuration: .speech5, appSupport: environment.appSupport))
        try writeGGUF(GraniteSpeechEngine.projectorURL(configuration: .speech5, appSupport: environment.appSupport))

        try TranscriptionModelStore.delete(.graniteSpeech, environment: environment)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.graniteSpeech, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.graniteSpeech5, environment: environment))
    }

    func testDownloadedChoicesReadDiskCaches() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFluidAudioParakeetV3(in: environment)
        for file in QwenLlamaASR.compact.files {
            try writeGGUF(QwenLlamaASR.compact.url(for: file, appSupport: environment.appSupport))
        }
        try writeGraniteModel(in: environment)
        try writeWhisperModel(in: environment)
        try writeFluidAudioCohere(in: environment)
        try writeOnnxModel(
            folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
            in: environment)

        let downloaded = TranscriptionModelStore.downloadedChoices(environment: environment)

        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.parakeetV3.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.qwenASR06B.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.graniteSpeech.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.whisperLarge.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.cohere.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.gigaamRussian.id))
        XCTAssertFalse(downloaded.contains(TranscriptionModelChoice.parakeetV2.id))
        XCTAssertFalse(downloaded.contains(TranscriptionModelChoice.senseVoice.id))
    }

    func testInterruptedParakeetDownloadIsNotDownloaded() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFluidAudioParakeetV3(in: environment)
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.parakeetV3, environment: environment))

        let directory = environment.fluidAudioModelsRoot.appendingPathComponent(Repo.parakeetV3.folderName)
        let encoder = directory.appendingPathComponent(
            ModelNames.ASR.requiredModelsV3(precision: .int8V2).first { $0.hasPrefix("Encoder") }!)
        try writeEmptyFile(encoder.appendingPathComponent("weights/weight.bin.partial"))
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.parakeetV3, environment: environment))

        try FileManager.default.removeItem(at: encoder)
        try writeEmptyFile(encoder)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.parakeetV3, environment: environment))
    }

    func testDeleteRemovesOnlySelectedTranscriptionCache() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        for weights in [QwenLlamaASR.accuracy, QwenLlamaASR.compact] {
            for file in weights.files {
                try writeGGUF(weights.url(for: file, appSupport: environment.appSupport))
            }
        }

        try TranscriptionModelStore.delete(.qwenASR06B, environment: environment)

        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.qwenASR06B, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.qwenASR17B, environment: environment))
    }

    func testQwenTiersAreTheirGGUFPairsAndDeletionAlsoRemovesTheOldMLXWeights() throws {
        for (choice, weights) in [(TranscriptionModelChoice.qwenASR17BLokalBotV3, QwenLlamaASR.accuracyLokalBotV3),
                                  (.qwenASR17B, QwenLlamaASR.accuracy),
                                  (.qwenASR06BLokalBotV1, QwenLlamaASR.compactLokalBotV1),
                                  (.qwenASR06B, QwenLlamaASR.compact)] {
            let (root, environment) = try makeEnvironment()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeQwenModel(modelID: weights.legacyMLXRepository, in: environment)
            XCTAssertFalse(TranscriptionModelStore.isDownloaded(choice, environment: environment))

            try writeGGUF(weights.url(for: weights.model, appSupport: environment.appSupport))
            XCTAssertFalse(TranscriptionModelStore.isDownloaded(choice, environment: environment),
                           "the audio projector is required too")
            try writeGGUF(weights.url(for: weights.projector, appSupport: environment.appSupport))
            XCTAssertTrue(TranscriptionModelStore.isDownloaded(choice, environment: environment))

            try TranscriptionModelStore.delete(choice, environment: environment)
            XCTAssertFalse(TranscriptionModelStore.isDownloaded(choice, environment: environment))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: weights.legacyMLXDirectory(appSupport: environment.appSupport).path))
        }
    }

    func testDeletingOneQwenVariantKeepsItsSiblingAndSharedProjector() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        for weights in QwenLlamaASR.allWeights {
            for file in weights.files {
                try writeGGUF(weights.url(for: file, appSupport: environment.appSupport))
            }
        }

        try TranscriptionModelStore.delete(.qwenASR17B, environment: environment)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.qwenASR17B, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.qwenASR17BLokalBotV3, environment: environment))

        try TranscriptionModelStore.delete(.qwenASR06B, environment: environment)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.qwenASR06B, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.qwenASR06BLokalBotV1, environment: environment))
    }

    func testUltraRequiresItsOwnCompleteCacheAndDeletionPreservesV3() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFluidAudioParakeetV3(in: environment)
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.parakeetUltra, environment: environment))

        let directory = environment.fluidAudioModelsRoot.appendingPathComponent(Repo.parakeetUltra.folderName)
        for fileName in ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile])
        where fileName != ModelNames.ASR.encoderFile {
            try writeFluidAudioComponent(directory.appendingPathComponent(fileName))
        }
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.parakeetUltra, environment: environment))
        try writeFluidAudioComponent(directory.appendingPathComponent(ModelNames.ASR.encoderFile))
        XCTAssertTrue(TranscriptionModelStore.downloadedChoices(environment: environment).contains("parakeet-ultra"))

        try TranscriptionModelStore.delete(.parakeetUltra, environment: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.parakeetUltra, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.parakeetV3, environment: environment))
    }

    func testLegacyWhisperCacheCountsOnlyAfterMigrationToApplicationSupport() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = try XCTUnwrap(environment.legacyWhisperKitRepoRoot)
        let legacyModel = try writeWhisperModel(in: legacyRoot)

        XCTAssertFalse(TranscriptionModelStore.isDownloaded(
            .whisperLarge,
            environment: environment))

        try TranscriptionModelStore.migrateLegacyWhisperKitModels(environment: environment)

        let migrated = environment.whisperKitRepoRoot.appendingPathComponent(
            legacyModel.lastPathComponent,
            isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrated.appendingPathComponent("config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyModel.path))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(
            .whisperLarge,
            environment: environment))
    }

    func testWhisperMigrationDoesNotReplaceACompleteDestination() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = try XCTUnwrap(environment.legacyWhisperKitRepoRoot)
        let legacyModel = try writeWhisperModel(in: legacyRoot)
        let destination = try writeWhisperModel(in: environment.whisperKitRepoRoot)
        let marker = destination.appendingPathComponent("keep-me")
        try writeEmptyFile(marker)

        try TranscriptionModelStore.migrateLegacyWhisperKitModels(environment: environment)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacyModel.appendingPathComponent("config.json").path))
    }

    func testWhisperMigrationSkipsTheLegacyCacheOnceApplicationSupportHasAModel() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = try XCTUnwrap(environment.legacyWhisperKitRepoRoot)
        let otherLegacyModel = legacyRoot
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        for fileName in ["config.json", "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try writeEmptyFile(otherLegacyModel.appendingPathComponent(fileName))
        }
        try writeWhisperModel(in: environment.whisperKitRepoRoot)

        try TranscriptionModelStore.migrateLegacyWhisperKitModels(environment: environment)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: otherLegacyModel.appendingPathComponent("config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.whisperKitRepoRoot
            .appendingPathComponent(otherLegacyModel.lastPathComponent).path))
    }

    func testCustomGraniteQuantizationUsesItsConfiguredFiles() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeGraniteQ8Configuration()

        try writeGGUF(GraniteSpeechEngine.modelURL(
            configuration: configuration,
            appSupport: environment.appSupport))
        try writeGGUF(GraniteSpeechEngine.projectorURL(
            configuration: configuration,
            appSupport: environment.appSupport))

        XCTAssertTrue(TranscriptionModelStore.isDownloaded(
            .graniteSpeech,
            environment: environment,
            graniteConfiguration: configuration))
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(
            .graniteSpeech,
            environment: environment,
            graniteConfiguration: .defaultModel))
    }

    func testDeletingCustomGraniteLeavesBuiltInGraniteCacheAlone() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeGraniteQ8Configuration(
            repository: "example/granite-speech-custom-GGUF")

        try writeGraniteModel(in: environment)
        try writeGGUF(GraniteSpeechEngine.modelURL(
            configuration: configuration,
            appSupport: environment.appSupport))
        try writeGGUF(GraniteSpeechEngine.projectorURL(
            configuration: configuration,
            appSupport: environment.appSupport))

        try TranscriptionModelStore.delete(
            .graniteSpeech,
            environment: environment,
            graniteConfiguration: configuration)

        XCTAssertTrue(TranscriptionModelStore.isDownloaded(
            .graniteSpeech,
            environment: environment,
            graniteConfiguration: .defaultModel))
        XCTAssertFalse(TranscriptionModelStore.isDownloaded(
            .graniteSpeech,
            environment: environment,
            graniteConfiguration: configuration))
    }

    private func makeEnvironment() throws -> (URL, TranscriptionModelStore.Environment) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-model-store-\(UUID().uuidString)", isDirectory: true)
        let environment = TranscriptionModelStore.Environment(
            appSupport: root.appendingPathComponent("app-support", isDirectory: true),
            fluidAudioRoot: root.appendingPathComponent("fluidaudio", isDirectory: true),
            fluidAudioModelsRoot: root.appendingPathComponent("fluidaudio-models", isDirectory: true),
            whisperKitDownloadRoot: root.appendingPathComponent(
                "app-support/whisperkit",
                isDirectory: true),
            whisperKitRepoRoot: root.appendingPathComponent(
                "app-support/whisperkit/models/argmaxinc/whisperkit-coreml",
                isDirectory: true),
            legacyWhisperKitRepoRoot: root.appendingPathComponent(
                "documents/huggingface/models/argmaxinc/whisperkit-coreml",
                isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, environment)
    }

    private func writeFluidAudioParakeetV3(in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.fluidAudioModelsRoot.appendingPathComponent(Repo.parakeetV3.folderName)
        for fileName in ModelNames.ASR.requiredModelsV3(precision: .int8V2).union([ModelNames.ASR.vocabularyFile]) {
            try writeFluidAudioComponent(directory.appendingPathComponent(fileName))
        }
    }

    private func writeFluidAudioComponent(_ url: URL) throws {
        guard url.pathExtension == "mlmodelc" else { return try writeEmptyFile(url) }
        try writeEmptyFile(url.appendingPathComponent("coremldata.bin"))
    }

    private func writeFluidAudioCohere(in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.fluidAudioRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        for fileName in ModelNames.CohereTranscribe.requiredModels {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
    }

    private func writeQwenModel(modelID: String, in environment: TranscriptionModelStore.Environment) throws {
        let directory = QwenASREngine.hubStyleCacheDir(
            base: environment.appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
            modelID: modelID)
        try writeEmptyFile(directory.appendingPathComponent("model.safetensors"))
    }

    private func writeGraniteModel(in environment: TranscriptionModelStore.Environment) throws {
        try writeGGUF(GraniteSpeechEngine.modelURL(appSupport: environment.appSupport))
        try writeGGUF(GraniteSpeechEngine.projectorURL(appSupport: environment.appSupport))
    }

    private func makeGraniteQ8Configuration(
        repository: String = GraniteSpeechModelConfiguration.defaultModel.repository
    ) throws -> GraniteSpeechModelConfiguration {
        try GraniteSpeechModelConfiguration(
            repository: repository,
            revision: GraniteSpeechModelConfiguration.defaultModel.revision,
            model: .init(
                path: "granite-speech-4.1-2b-Q8_0.gguf",
                sizeBytes: 1_960_000_000,
                sha256: String(repeating: "a", count: 64)),
            projector: .init(
                path: "mmproj-model-f16.gguf",
                sizeBytes: 1_159_354_752,
                sha256: String(repeating: "b", count: 64)))
    }

    private func writeWhisperModel(in environment: TranscriptionModelStore.Environment) throws {
        _ = try writeWhisperModel(in: environment.whisperKitRepoRoot)
    }

    @discardableResult
    private func writeWhisperModel(in repository: URL) throws -> URL {
        let directory = repository
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        for fileName in ["config.json", "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
        return directory
    }

    private func writeOnnxModel(folderName: String, in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.appSupport
            .appendingPathComponent("sherpa-models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try writeEmptyFile(directory.appendingPathComponent("model.int8.onnx"))
        try writeEmptyFile(directory.appendingPathComponent("tokens.txt"))
        try Data("synthetic-weights".utf8).write(to: directory.appendingPathComponent("model.int8.onnx"))
        try Data("synthetic-tokens".utf8).write(to: directory.appendingPathComponent("tokens.txt"))
        let model: OnnxTranscriptionEngine.Model = folderName == OnnxTranscriptionEngine.Model.senseVoice.folderName ? .senseVoice : .gigaamRussian
        try OnnxTranscriptionEngine.markInstalled(in: directory, model: model)
    }

    private func writeEmptyFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func writeGGUF(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
    }
}
