import Foundation
import FluidAudio

struct TranscriptionModelStore {
    struct Environment {
        let appSupport: URL
        let fluidAudioRoot: URL
        let fluidAudioModelsRoot: URL
        let whisperKitDownloadRoot: URL
        let whisperKitRepoRoot: URL
        let legacyWhisperKitRepoRoot: URL?

        static var live: Environment {
            let fileManager = FileManager.default
            let appSupport = AppDirectories.applicationSupport
            let fluidAudioRoot = AppDirectories.fluidAudioRoot
            let fluidAudioModelsRoot = fluidAudioRoot
                .appendingPathComponent("Models", isDirectory: true)
            let legacyWhisperKitRepoRoot = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            return Environment(
                appSupport: appSupport,
                fluidAudioRoot: fluidAudioRoot,
                fluidAudioModelsRoot: fluidAudioModelsRoot,
                whisperKitDownloadRoot: AppDirectories.whisperKitDownloadRoot,
                whisperKitRepoRoot: AppDirectories.whisperKitRepoRoot,
                legacyWhisperKitRepoRoot: legacyWhisperKitRepoRoot)
        }
    }

    private static let whisperRequiredFiles = [
        "config.json",
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc"
    ]

    static func downloadedChoices(
        environment: Environment = .live,
        graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel
    ) -> Set<String> {
        Set(TranscriptionModelChoice.allCases.filter {
            isDownloaded(
                $0,
                environment: environment,
                graniteConfiguration: graniteConfiguration)
        }.map(\.id))
    }

    static func isDownloaded(_ choice: TranscriptionModelChoice,
                             environment: Environment = .live,
                             graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel) -> Bool {
        switch choice {
        case .parakeetV3:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV3, environment: environment),
                version: .v3)
        case .parakeetV2:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV2, environment: environment),
                version: .v2)
        case .qwenASR17B:
            return qwenModelExists(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                                   environment: environment)
        case .qwenASR06B:
            return qwenModelExists(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                                   environment: environment)
        case .graniteSpeech:
            return ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.modelURL(
                configuration: graniteConfiguration,
                appSupport: environment.appSupport))
                && ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.projectorURL(
                    configuration: graniteConfiguration,
                    appSupport: environment.appSupport))
        case .graniteTurbo:
            return GraniteTurboEngine.isDownloaded(appSupport: environment.appSupport)
        case .whisperLarge:
            return whisperModelDirectories(environment: environment).contains { directory in
                requiredFilesPresent(
                    at: directory,
                    requiredFiles: whisperRequiredFiles)
            }
        case .cohere:
            return requiredFilesPresent(
                at: cohereDirectory(environment: environment),
                requiredFiles: ModelNames.CohereTranscribe.requiredModels)
        case .senseVoice:
            return onnxModelExists(model: .senseVoice, environment: environment)
        case .gigaamRussian:
            return onnxModelExists(model: .gigaamRussian, environment: environment)
        }
    }

    static func delete(_ choice: TranscriptionModelChoice,
                       environment: Environment = .live,
                       graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel) throws {
        let fileManager = FileManager.default
        for directory in cacheDirectories(
            for: choice,
            environment: environment,
            graniteConfiguration: graniteConfiguration) {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private static func cacheDirectories(for choice: TranscriptionModelChoice,
                                         environment: Environment,
                                         graniteConfiguration: GraniteSpeechModelConfiguration) -> [URL] {
        switch choice {
        case .parakeetV3:
            [parakeetDirectory(.parakeetV3, environment: environment)]
        case .parakeetV2:
            [parakeetDirectory(.parakeetV2, environment: environment)]
        case .qwenASR17B:
            [qwenDirectory(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                           environment: environment)]
        case .qwenASR06B:
            [qwenDirectory(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                           environment: environment)]
        case .graniteSpeech:
            [GraniteSpeechEngine.modelRoot(
                configuration: graniteConfiguration,
                appSupport: environment.appSupport)]
        case .graniteTurbo:
            [GraniteTurboEngine.modelRoot(appSupport: environment.appSupport)]
        case .whisperLarge:
            whisperModelDirectories(environment: environment)
        case .cohere:
            [cohereDirectory(environment: environment)]
        case .senseVoice:
            [onnxDirectory(folderName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
                           environment: environment)]
        case .gigaamRussian:
            [onnxDirectory(folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
                           environment: environment)]
        }
    }

    private static func parakeetDirectory(_ repo: Repo, environment: Environment) -> URL {
        environment.fluidAudioModelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    private static func cohereDirectory(environment: Environment) -> URL {
        environment.fluidAudioRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName,
                                                          isDirectory: true)
    }

    private static func qwenDirectory(modelID: String, environment: Environment) -> URL {
        QwenASREngine.hubStyleCacheDir(
            base: environment.appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
            modelID: modelID)
    }

    private static func qwenModelExists(modelID: String, environment: Environment) -> Bool {
        directoryContainsFile(withExtension: "safetensors",
                              at: qwenDirectory(modelID: modelID, environment: environment))
    }

    private static func onnxDirectory(folderName: String, environment: Environment) -> URL {
        environment.appSupport
            .appendingPathComponent("sherpa-models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func onnxModelExists(model: OnnxTranscriptionEngine.Model, environment: Environment) -> Bool {
        // UI reads the successful-install receipt and sizes; preparation does
        // the full digest pass off the MainActor before using any weights.
        OnnxTranscriptionEngine.isModelInstalled(
            in: onnxDirectory(folderName: model.folderName, environment: environment),
            model: model, verifyContents: false)
    }

    private static func whisperModelDirectories(environment: Environment) -> [URL] {
        let legacy = environment.legacyWhisperKitRepoRoot.map {
            whisperModelDirectories(at: $0)
        } ?? []
        return whisperModelDirectories(at: environment.whisperKitRepoRoot) + legacy
    }

    private static func whisperModelDirectories(at repository: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: repository,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return contents.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { return false }
            return url.lastPathComponent.contains("large-v3-v20240930")
        }
    }

    /// Move a valid cache created by older builds out of `~/Documents` before
    /// WhisperKit checks the new Application Support download root. Migration
    /// is deliberately best-effort at the call site: an MDM-denied legacy
    /// folder must never prevent a clean download into the correct location.
    static func migrateLegacyWhisperKitModels(
        environment: Environment = .live,
        fileManager: FileManager = .default
    ) throws {
        guard let legacyRoot = environment.legacyWhisperKitRepoRoot,
              legacyRoot.standardizedFileURL != environment.whisperKitRepoRoot.standardizedFileURL
        else { return }

        for source in whisperModelDirectories(at: legacyRoot)
        where requiredFilesPresent(at: source, requiredFiles: whisperRequiredFiles) {
            let destination = environment.whisperKitRepoRoot.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: true)
            if requiredFilesPresent(at: destination, requiredFiles: whisperRequiredFiles) {
                continue
            }

            try fileManager.createDirectory(
                at: environment.whisperKitRepoRoot,
                withIntermediateDirectories: true)
            let staging = environment.whisperKitRepoRoot.appendingPathComponent(
                ".\(source.lastPathComponent).migration-\(UUID().uuidString)",
                isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: source, to: staging)
            guard requiredFilesPresent(at: staging, requiredFiles: whisperRequiredFiles) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            // The destination is now complete and recoverable. Removing the
            // old cache avoids cloud re-upload; a managed provider may deny
            // deletion, which is harmless and should not undo the migration.
            try? fileManager.removeItem(at: source)
        }
    }

    private static func requiredFilesPresent(at directory: URL, requiredFiles: some Sequence<String>) -> Bool {
        requiredFiles.allSatisfy { fileName in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    private static func directoryContainsFile(withExtension fileExtension: String, at directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return false }

        for case let url as URL in enumerator where url.pathExtension == fileExtension {
            return true
        }
        return false
    }
}
