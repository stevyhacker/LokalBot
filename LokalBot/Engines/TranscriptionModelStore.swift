import Foundation
import FluidAudio

struct TranscriptionModelStore {
    static let retiredModelFolders = ["granite-turbo"]

    @discardableResult
    static func removeRetiredModels(appSupport: URL) -> [URL] {
        var removed: [URL] = []
        for name in retiredModelFolders {
            let folder = appSupport.appendingPathComponent(name, isDirectory: true)
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                removed.append(folder)
                lokalbotLog("removed retired transcription model folder=\(name)")
            } catch {
                lokalbotLog("could not remove retired transcription model folder=\(name): \(error.localizedDescription)")
            }
        }
        return removed
    }

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
            let legacyWhisperKitRepoRoot = UITestRuntime.isUnitTesting ? nil : fileManager.urls(
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

    static func qwenWeights(for choice: TranscriptionModelChoice) -> QwenLlamaASR.Weights? {
        switch choice {
        case .qwenASR17BLokalBotV3: QwenLlamaASR.accuracyLokalBotV3
        case .qwenASR17B: QwenLlamaASR.accuracy
        case .qwenASR06BLokalBotV1: QwenLlamaASR.compactLokalBotV1
        case .qwenASR06B: QwenLlamaASR.compact
        default: nil
        }
    }

    static func qwenASRMissingBytes(
        _ choice: TranscriptionModelChoice,
        environment: Environment = .live
    ) -> Int64 {
        qwenWeights(for: choice)?.missingBytes(appSupport: environment.appSupport) ?? 0
    }

    static func downloadedChoices(
        environment: Environment = .live,
        graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel,
        funASRNanoDirectory: String = "",
        remoteTranscriptionReady: Bool = false,
        appleSpeechAssetInstalled: Bool = false
    ) -> Set<String> {
        Set(TranscriptionModelChoice.allCases.filter {
            isDownloaded(
                $0,
                environment: environment,
                graniteConfiguration: graniteConfiguration,
                funASRNanoDirectory: funASRNanoDirectory,
                remoteTranscriptionReady: remoteTranscriptionReady,
                appleSpeechAssetInstalled: appleSpeechAssetInstalled)
        }.map(\.id))
    }

    static func isDownloaded(_ choice: TranscriptionModelChoice,
                             environment: Environment = .live,
                             graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel,
                             funASRNanoDirectory: String = "",
                             remoteTranscriptionReady: Bool = false,
                             appleSpeechAssetInstalled: Bool = false) -> Bool {
        switch choice {
        case .parakeetUltra:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetUltra, environment: environment),
                version: .ultra)
        case .parakeetV3:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV3, environment: environment),
                version: .v3, encoderPrecision: ParakeetEngine.Variant.v3.encoderPrecision)
        case .parakeetV2:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV2, environment: environment),
                version: .v2)
        case .qwenASR17BLokalBotV3, .qwenASR17B, .qwenASR06BLokalBotV1, .qwenASR06B:
            return qwenWeights(for: choice)?.isDownloaded(appSupport: environment.appSupport) ?? false
        case .graniteSpeech, .graniteSpeech5:
            let graniteConfiguration = choice == .graniteSpeech5
                ? GraniteSpeechModelConfiguration.speech5 : graniteConfiguration
            return ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.modelURL(
                configuration: graniteConfiguration,
                appSupport: environment.appSupport))
                && ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.projectorURL(
                    configuration: graniteConfiguration,
                    appSupport: environment.appSupport))
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
        case .funASRNano:
            return (try? FunASRNanoModel.load(directory: funASRNanoDirectory)) != nil
        case .senseVoice:
            return onnxModelExists(model: .senseVoice, environment: environment)
        case .gigaamRussian:
            return onnxModelExists(model: .gigaamRussian, environment: environment)
        case .appleSpeech:
            return appleSpeechAssetInstalled
        case .speechRuntime:
            return false
        case .remoteServer:
            return remoteTranscriptionReady
        }
    }

    static func delete(_ choice: TranscriptionModelChoice,
                       environment: Environment = .live,
                       graniteConfiguration: GraniteSpeechModelConfiguration = .defaultModel) throws {
        if let weights = qwenWeights(for: choice) {
            try weights.removeFiles(appSupport: environment.appSupport)
            return
        }
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
        case .parakeetUltra:
            [parakeetDirectory(.parakeetUltra, environment: environment)]
        case .parakeetV3:
            [parakeetDirectory(.parakeetV3, environment: environment)]
        case .parakeetV2:
            [parakeetDirectory(.parakeetV2, environment: environment)]
        case .qwenASR17BLokalBotV3, .qwenASR17B, .qwenASR06BLokalBotV1, .qwenASR06B:
            []
        case .graniteSpeech:
            [GraniteSpeechEngine.modelRoot(
                configuration: graniteConfiguration,
                appSupport: environment.appSupport)]
        case .graniteSpeech5:
            [GraniteSpeechEngine.modelRoot(
                configuration: .speech5,
                appSupport: environment.appSupport)]
        case .whisperLarge:
            whisperModelDirectories(environment: environment)
        case .cohere:
            [cohereDirectory(environment: environment)]
        case .funASRNano:
            []
        case .senseVoice:
            [onnxDirectory(folderName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
                           environment: environment)]
        case .gigaamRussian:
            [onnxDirectory(folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
                           environment: environment)]
        case .appleSpeech, .speechRuntime:
            []
        case .remoteServer:
            []
        }
    }

    private static func parakeetDirectory(_ repo: Repo, environment: Environment) -> URL {
        environment.fluidAudioModelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    private static func cohereDirectory(environment: Environment) -> URL {
        environment.fluidAudioRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName,
                                                          isDirectory: true)
    }

    private static func onnxDirectory(folderName: String, environment: Environment) -> URL {
        environment.appSupport
            .appendingPathComponent("sherpa-models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func onnxModelExists(model: OnnxTranscriptionEngine.Model, environment: Environment) -> Bool {
        OnnxTranscriptionEngine.isModelInstalled(
            in: onnxDirectory(folderName: model.folderName, environment: environment),
            model: model, verifyContents: false)
    }

    private static func whisperModelDirectories(environment: Environment) -> [URL] {
        whisperModelDirectories(at: environment.whisperKitRepoRoot)
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

    static func migrateLegacyWhisperKitModels(
        environment: Environment = .live,
        fileManager: FileManager = .default
    ) throws {
        guard let legacyRoot = environment.legacyWhisperKitRepoRoot,
              legacyRoot.standardizedFileURL != environment.whisperKitRepoRoot.standardizedFileURL,
              !isDownloaded(.whisperLarge, environment: environment)
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
