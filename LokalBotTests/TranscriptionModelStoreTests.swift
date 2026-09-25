import XCTest
import FluidAudio
@testable import LokalBot

final class TranscriptionModelStoreTests: XCTestCase {
    func testDownloadedChoicesReadDiskCaches() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFluidAudioParakeetV3(in: environment)
        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", in: environment)
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

    func testDeleteRemovesOnlySelectedTranscriptionCache() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", in: environment)
        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", in: environment)

        try TranscriptionModelStore.delete(.qwenASR06B, environment: environment)

        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.qwenASR06B, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.qwenASR17B, environment: environment))
    }

    func testLegacyWhisperCacheIsRecognizedAndMigratedToApplicationSupport() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = try XCTUnwrap(environment.legacyWhisperKitRepoRoot)
        let legacyModel = try writeWhisperModel(in: legacyRoot)

        XCTAssertTrue(TranscriptionModelStore.isDownloaded(
            .whisperLarge,
            environment: environment))

        try TranscriptionModelStore.migrateLegacyWhisperKitModels(environment: environment)

        let migrated = environment.whisperKitRepoRoot.appendingPathComponent(
            legacyModel.lastPathComponent,
            isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrated.appendingPathComponent("config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyModel.path))
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
        for fileName in ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile]) {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
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
