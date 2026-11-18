import XCTest
@testable import LokalBot

#if canImport(Speech)
import Speech
#endif

final class AppleSpeechEngineTests: XCTestCase {
    func testEngineMetadataMatchesContract() {
        let engine = AppleSpeechEngine.shared
        XCTAssertEqual(engine.displayName, "Apple Speech")
        XCTAssertEqual(engine.checkpointIdentity, "apple-speech")
        XCTAssertFalse(engine.supportsStreaming)
    }

    func testSerbianIsRejectedBeforeAvailabilityOrFileAccess() async {
        let missingAudio = URL(fileURLWithPath: "/nonexistent/serbian-check.wav")
        let engine = AppleSpeechEngine(backend: .init(
            availabilityError: {
                XCTFail("Availability should not be checked when language is unsupported")
                return nil
            },
            resolve: { _ in
                XCTFail("Locale resolver should not run when language is unsupported")
                throw CancellationError()
            },
            ensureAsset: { _, _ in
                XCTFail("Asset installer should not run when language is unsupported")
            },
            analyze: { _, _ in
                XCTFail("Analyzer should not read audio when language is unsupported")
                return []
            }))

        do {
            try await engine.prepare(language: "sr")
            XCTFail("Expected Serbian to fail prepare")
        } catch {
            XCTAssertEqual(
                error as? UnsupportedTranscriptionLanguage,
                UnsupportedTranscriptionLanguage(language: "Serbian", model: "Apple Speech"))
        }

        do {
            _ = try await engine.transcribe(audio: missingAudio, language: "sr")
            XCTFail("Expected Serbian to fail transcribe")
        } catch {
            XCTAssertEqual(
                error as? UnsupportedTranscriptionLanguage,
                UnsupportedTranscriptionLanguage(language: "Serbian", model: "Apple Speech"))
        }
    }

    func testUnavailableSystemThrowsConsistentError() async {
        let engine = AppleSpeechEngine(backend: .init(
            availabilityError: { AppleSpeechAvailability.unsupportedMessage },
            resolve: { _ in
                XCTFail("Resolver should not run on unavailable OS")
                throw CancellationError()
            },
            ensureAsset: { _, _ in },
            analyze: { _, _ in [] }))

        for action in 0..<2 {
            do {
                if action == 0 {
                    try await engine.prepare(language: "en")
                } else {
                    _ = try await engine.transcribe(audio: URL(fileURLWithPath: "/tmp/unused.wav"), language: "en")
                }
                XCTFail("Expected unavailable error")
            } catch {
                XCTAssertEqual(
                    error as? AppleSpeechError,
                    .unavailable(AppleSpeechAvailability.unsupportedMessage))
            }
        }
    }

    func testPrepareReportsProgressAndCompletesWhenInstalled() async throws {
        let english = AppleSpeechLocaleResolver.Resolution(
            localeIdentifier: "en_US",
            languageCode: "en",
            module: .speechTranscriber)
        let collector = UpdateCollector()

        let downloadingEngine = AppleSpeechEngine(backend: .init(
            availabilityError: { nil },
            resolve: { _ in english },
            ensureAsset: { resolution, progress in
                XCTAssertEqual(resolution, english)
                progress?(0.5, "Downloading…")
                progress?(1.0, "Ready")
            },
            analyze: { _, _ in [] }))

        try await downloadingEngine.prepare(language: "en") { update in
            Task { await collector.append(update) }
        }
        try await Task.sleep(for: .milliseconds(50))
        let updates = await collector.updates
        XCTAssertTrue(updates.contains { $0.status == "Checking..." })
        XCTAssertTrue(updates.contains { $0.fractionCompleted == 0.5 && $0.status == "Downloading…" })
        XCTAssertEqual(updates.last?.fractionCompleted, 1.0)
        XCTAssertEqual(updates.last?.status, "Ready")
    }

    func testTranscribeFiltersEmptyAndInvalidSegmentsAndPropagatesCancellation() async throws {
        let resolution = AppleSpeechLocaleResolver.Resolution(
            localeIdentifier: "tr_TR",
            languageCode: "tr",
            module: .dictationTranscriber)
        let engine = AppleSpeechEngine(backend: .init(
            availabilityError: { nil },
            resolve: { _ in resolution },
            ensureAsset: { _, _ in },
            analyze: { _, _ in
                [
                    .init(start: 0.2, end: 1.8, text: "  Merhaba   dünya. "),
                    .init(start: 2.0, end: 3.0, text: "   "),
                    .init(start: 4.0, end: 4.0, text: "zero length"),
                    .init(start: .nan, end: 5.0, text: "nan start"),
                    .init(start: 5.2, end: 6.4, text: "Devam ediyoruz."),
                ]
            }))

        let transcript = try await engine.transcribe(audio: URL(fileURLWithPath: "/tmp/mock.wav"), language: "tr")
        XCTAssertEqual(transcript.engine, "Apple Speech (tr_TR)")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].text, "Merhaba dünya.")
        XCTAssertEqual(transcript.segments[0].start, 0.2, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[0].end, 1.8, accuracy: 0.001)
        XCTAssertEqual(transcript.segments[0].timingPrecision, .span)
        XCTAssertEqual(transcript.segments[1].text, "Devam ediyoruz.")

        let cancellable = AppleSpeechEngine(backend: .init(
            availabilityError: { nil },
            resolve: { _ in resolution },
            ensureAsset: { _, _ in },
            analyze: { _, _ in
                try await Task.sleep(for: .seconds(5))
                return []
            }))

        let task = Task {
            try await cancellable.transcribe(audio: URL(fileURLWithPath: "/tmp/mock.wav"), language: "tr")
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        }
    }

    func testEmptyAudioFileProducesEmptyTranscriptWithLiveAnalyzerWhenAvailable() async throws {
        #if canImport(Speech)
        if #available(macOS 26.0, *), AppleSpeechAvailability.isSystemSupported {
            let speechInstalled = await SpeechTranscriber.installedLocales
            let dictationInstalled = await DictationTranscriber.installedLocales
            let candidateCodes = (speechInstalled + dictationInstalled).compactMap { locale -> String? in
                guard let code = locale.language.languageCode?.identifier,
                      AppleSpeechLocaleResolver.canonicalLocale[code] != nil else { return nil }
                return code
            }
            var readyCode: String?
            for code in candidateCodes {
                let resolved = try await AppleSpeechLocaleResolver.resolveLive(language: code)
                let status: AssetInventory.Status
                switch resolved.module {
                case .speechTranscriber:
                    let m = SpeechTranscriber(
                        locale: resolved.locale,
                        transcriptionOptions: [],
                        reportingOptions: [],
                        attributeOptions: [.audioTimeRange])
                    status = await AssetInventory.status(forModules: [m])
                case .dictationTranscriber:
                    let m = DictationTranscriber(locale: resolved.locale, preset: .timeIndexedLongDictation)
                    status = await AssetInventory.status(forModules: [m])
                }
                if status == .installed {
                    readyCode = code
                    break
                }
            }
            guard let base = readyCode else { return }

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-speech-empty-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temp) }
            let writer = try WavWriter(url: temp, sampleRate: 16_000)
            try writer.finish()

            let transcript = try await AppleSpeechEngine.shared.transcribe(audio: temp, language: base)
            XCTAssertTrue(transcript.segments.isEmpty)
        }
        #endif
    }
}

private actor UpdateCollector {
    private(set) var updates: [ModelPreparationUpdate] = []
    func append(_ update: ModelPreparationUpdate) { updates.append(update) }
}
