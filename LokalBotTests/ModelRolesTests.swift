import XCTest
@testable import LokalBot

@MainActor
final class ModelRolesTests: XCTestCase {
    private enum TestPreparationError: LocalizedError {
        case failed

        var errorDescription: String? { "Expected preparation failure" }
    }

    private actor PreparationGate {
        private var started = false
        private var released = false
        private var completed = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []

        func run() async {
            started = true
            let waitingForStart = startWaiters
            startWaiters.removeAll()
            for waiter in waitingForStart { waiter.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            completed = true
            let waitingForCompletion = completionWaiters
            completionWaiters.removeAll()
            for waiter in waitingForCompletion { waiter.resume() }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilCompleted() async {
            if completed { return }
            await withCheckedContinuation { completionWaiters.append($0) }
        }
    }

    func testCoreReadyOnlyWhenEveryRoleIsReady() {
        let snapshot = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .ready,
            .autocomplete: .ready,
        ])

        XCTAssertTrue(snapshot.coreReady)
        XCTAssertEqual(snapshot.primaryActionStatus, .ready)
    }

    func testLocalFunASRIsLoadCheckedEvenWhenFilesArePresent() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var settings = isolatedSettings(transcription: .funASRNano)
        settings.funASRNanoModelDirectory = "/tmp/selected-model"
        var loadedPath: String?
        let roles = ModelRoles(
            settings: { settings }, storage: storage, downloads: ModelDownloadManager(),
            prepareTranscription: { configuration, _, _ in loadedPath = configuration.funASRNanoModelDirectory },
            downloadedTranscriptionModels: { _ in [TranscriptionModelChoice.funASRNano.id] },
            onReadinessChanged: {})
        try await roles.ensureTranscriptionAvailable(.funASRNano, configuration: settings)
        XCTAssertEqual(loadedPath, settings.funASRNanoModelDirectory)
    }

    func testChangingFunASRDirectoryCancelsOldPreparation() async {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var settings = isolatedSettings(transcription: .funASRNano)
        settings.funASRNanoModelDirectory = "/tmp/old-model"
        let gate = PreparationGate()
        let roles = ModelRoles(
            settings: { settings }, storage: storage, downloads: ModelDownloadManager(),
            prepareTranscription: { _, _, _ in await gate.run() },
            downloadedTranscriptionModels: { _ in [] }, onReadinessChanged: {})
        roles.prepareTranscriptionModel(.funASRNano)
        await gate.waitUntilStarted()
        let previous = settings
        settings.funASRNanoModelDirectory = "/tmp/new-model"
        roles.settingsDidChange(from: previous, to: settings)
        XCTAssertFalse(roles.isPreparingTranscription)
        await gate.release()
        await gate.waitUntilCompleted()
        XCTAssertNil(roles.transcriptionErrors[TranscriptionModelChoice.funASRNano.id])
    }

    func testFailureStopsOnboardingSpinnerAndOffersRecovery() {
        let snapshot = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .needsAttention("Network unavailable"),
            .autocomplete: .unavailable,
        ])

        XCTAssertEqual(snapshot.primaryActionStatus, .needsAttention("Network unavailable"))
        XCTAssertEqual(
            snapshot.detail,
            "A selected model needs attention before the stack is ready.")
    }

    func testPreparationAndDownloadExposeRoleSpecificProgress() {
        let preparing = makeSnapshot(statuses: [
            .transcribe: .preparing(progress: 0.25, label: "Loading vocabulary…"),
            .think: .unavailable,
            .autocomplete: .unavailable,
        ])
        let downloading = makeSnapshot(statuses: [
            .transcribe: .ready,
            .think: .downloading(progress: 0.42),
            .autocomplete: .unavailable,
        ])

        XCTAssertEqual(
            preparing.primaryActionStatus,
            .preparing(progress: 0.25, label: "Loading vocabulary…"))
        XCTAssertEqual(downloading.primaryActionStatus.label, "Downloading… 42%")
    }

    func testMissingStatusDefaultsToUnavailable() {
        let snapshot = makeSnapshot(statuses: [.transcribe: .ready])

        XCTAssertEqual(snapshot[.think], .unavailable)
        XCTAssertFalse(snapshot.coreReady)
    }

    func testRetryRerunsFailedPreparationWhenModelIsAlreadyDownloaded() async {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let settings = isolatedSettings(transcription: .graniteSpeech)
        var preparationAttempts = 0
        let roles = ModelRoles(
            settings: { settings },
            storage: storage,
            downloads: ModelDownloadManager(),
            prepareTranscription: { _, _, _ in
                preparationAttempts += 1
                if preparationAttempts == 1 { throw TestPreparationError.failed }
            },
            downloadedTranscriptionModels: { _ in [TranscriptionModelChoice.graniteSpeech.id] },
            onReadinessChanged: {})

        roles.prepareTranscriptionModel(.graniteSpeech)
        await waitUntil {
            preparationAttempts == 1 && !roles.isPreparingTranscription
        }
        XCTAssertNotNil(roles.transcriptionErrors[TranscriptionModelChoice.graniteSpeech.id])

        roles.startCoreModelDownloads()
        await waitUntil {
            preparationAttempts == 2 && !roles.isPreparingTranscription
        }

        XCTAssertNil(roles.transcriptionErrors[TranscriptionModelChoice.graniteSpeech.id])
        XCTAssertEqual(roles.transcriptionStatus(for: .graniteSpeech), .ready)
    }

    func testSelectingActivePreparationKeepsItRunningButChangingAwayCancelsIt() async {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var settings = isolatedSettings(transcription: .parakeetV3)
        let gate = PreparationGate()
        let roles = ModelRoles(
            settings: { settings },
            storage: storage,
            downloads: ModelDownloadManager(),
            prepareTranscription: { _, _, _ in await gate.run() },
            downloadedTranscriptionModels: { _ in [] },
            onReadinessChanged: {})

        roles.prepareTranscriptionModel(.qwenASR06B)
        await gate.waitUntilStarted()

        var previous = settings
        settings.transcriptionModel = .qwenASR06B
        roles.settingsDidChange(from: previous, to: settings)
        XCTAssertTrue(roles.isPreparingTranscription,
                      "selecting the active preparation must keep its progress alive")

        previous = settings
        settings.transcriptionModel = .parakeetV3
        roles.settingsDidChange(from: previous, to: settings)
        XCTAssertFalse(roles.isPreparingTranscription,
                       "changing away from the active selected model should cancel it")

        await gate.release()
        await gate.waitUntilCompleted()
    }

    func testGraniteConfigurationChangeClearsFailureFromPreviousConfiguration() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var settings = isolatedSettings(transcription: .graniteSpeech)
        let roles = ModelRoles(
            settings: { settings },
            storage: storage,
            downloads: ModelDownloadManager(),
            prepareTranscription: { _, _, _ in throw TestPreparationError.failed },
            downloadedTranscriptionModels: { _ in [TranscriptionModelChoice.graniteSpeech.id] },
            onReadinessChanged: {})

        roles.prepareTranscriptionModel(.graniteSpeech)
        await waitUntil { !roles.isPreparingTranscription }
        XCTAssertNotNil(roles.transcriptionErrors[TranscriptionModelChoice.graniteSpeech.id])

        let previous = settings
        settings.graniteSpeechModel = try alternateGraniteConfiguration()
        roles.settingsDidChange(from: previous, to: settings)

        XCTAssertNil(roles.transcriptionErrors[TranscriptionModelChoice.graniteSpeech.id])
        XCTAssertEqual(roles.transcriptionStatus(for: .graniteSpeech), .ready)
    }

    func testDeletingGGUFThroughModelRolesInvalidatesReadiness() throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let entry = try XCTUnwrap(ModelCatalog.entry(id: ModelCatalog.defaultSummarizationID))
        let modelURL = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: modelURL)
        var settings = isolatedSettings(transcription: .graniteSpeech)
        settings.summarizerBackend = .builtIn
        settings.builtInModelID = entry.id
        var readinessChanges = 0
        let roles = ModelRoles(
            settings: { settings },
            storage: storage,
            downloads: ModelDownloadManager(),
            downloadedTranscriptionModels: { _ in [] },
            onReadinessChanged: { readinessChanges += 1 })

        XCTAssertEqual(roles.snapshot[.think], .ready)
        let previousRevision = roles.revision

        roles.deleteGGUFModel(entry)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
        XCTAssertEqual(roles.snapshot[.think], .unavailable)
        XCTAssertGreaterThan(roles.revision, previousRevision)
        XCTAssertEqual(readinessChanges, 1)
    }

    func testPreparingDraftGraniteUsesItsConfigurationWithoutChangingActiveModel() async throws {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let settings = isolatedSettings(transcription: .parakeetV3)
        var draft = settings
        draft.transcriptionModel = .graniteSpeech
        draft.graniteSpeechModel = try alternateGraniteConfiguration()
        let gate = PreparationGate()
        var preparedConfiguration: GraniteSpeechModelConfiguration?
        let roles = ModelRoles(
            settings: { settings }, storage: storage, downloads: ModelDownloadManager(),
            prepareTranscription: { configuration, _, _ in
                await gate.run()
                preparedConfiguration = configuration.graniteSpeechModel
            },
            downloadedTranscriptionModels: { configuration in
                preparedConfiguration == configuration.graniteSpeechModel ? [TranscriptionModelChoice.graniteSpeech.id] : []
            }, onReadinessChanged: {})

        let preparation = Task { try await roles.ensureTranscriptionAvailable(.graniteSpeech, configuration: draft) }
        await gate.waitUntilStarted()
        XCTAssertEqual(settings.transcriptionModel, .parakeetV3)
        XCTAssertEqual(roles.snapshot[.transcribe], .unavailable)
        await gate.release()
        try await preparation.value

        XCTAssertEqual(preparedConfiguration, draft.graniteSpeechModel)
        XCTAssertFalse(roles.isPreparingTranscription)
        XCTAssertEqual(settings.transcriptionModel, .parakeetV3)
    }

    func testCancelledPreparationRejectsFilesThatArriveAfterCancellation() async {
        let storage = temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let settings = isolatedSettings(transcription: .parakeetV3)
        let gate = PreparationGate()
        var downloaded = false
        let roles = ModelRoles(
            settings: { settings }, storage: storage, downloads: ModelDownloadManager(),
            prepareTranscription: { _, _, _ in
                await gate.run()
                downloaded = true // Simulate a backend that finishes despite cancellation.
            },
            downloadedTranscriptionModels: { _ in downloaded ? [TranscriptionModelChoice.qwenASR06B.id] : [] },
            onReadinessChanged: {})
        let preparation = Task { try await roles.ensureTranscriptionAvailable(.qwenASR06B, configuration: settings) }
        await gate.waitUntilStarted()
        roles.cancelTranscriptionPreparation(.qwenASR06B)
        await gate.release()
        do {
            try await preparation.value
            XCTFail("A cancelled download must not authorize activation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(downloaded)
        XCTAssertFalse(roles.isPreparingTranscription)
        XCTAssertTrue(roles.transcriptionPreparations.isEmpty)
    }

    private func makeSnapshot(
        statuses: [ModelRole: ModelRoleStatus]
    ) -> ModelRolesSnapshot {
        ModelRolesSnapshot(
            readiness: ModelReadinessSnapshot(
                transcriptionReady: statuses[.transcribe]?.isReady == true,
                thinkReady: statuses[.think]?.isReady == true,
                autocompleteReady: statuses[.autocomplete]?.isReady == true,
                provenance: .local,
                storedBytes: 0,
                availableBytes: nil,
                activeDownloads: statuses.values.filter(\.isWorking).count,
                failedDownloads: statuses.values.filter {
                    $0.errorMessage != nil
                }.count),
            statuses: statuses)
    }

    private func isolatedSettings(
        transcription: TranscriptionModelChoice
    ) -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = transcription
        settings.summarizerBackend = .appleIntelligence
        settings.cotypingBuiltInModelID = "model-roles-test-no-download"
        return settings
    }

    private func temporaryStorage() -> StorageManager {
        StorageManager(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("model-roles-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func alternateGraniteConfiguration() throws -> GraniteSpeechModelConfiguration {
        try GraniteSpeechModelConfiguration(
            repository: "lokalbot-tests/granite-speech",
            revision: String(repeating: "a", count: 40),
            model: .init(
                path: "granite-speech-test-Q4_K_M.gguf",
                sizeBytes: 8,
                sha256: String(repeating: "b", count: 64)),
            projector: .init(
                path: "mmproj-model-test.gguf",
                sizeBytes: 8,
                sha256: String(repeating: "c", count: 64)))
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for ModelRoles state")
    }
}
