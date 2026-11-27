import Foundation

enum DictationContextReplay {
    struct Input: Decodable {
        var cases: [Case]
        var memoryItems: [CotypingMemoryContext.Item]
        var now: Date
        var useVisibleContext: Bool
        var useMeetingMemory: Bool
        var useScreenMemory: Bool = false
        var useScreenContext: Bool?
        var windowTextPolicy: DictationWindowTextPolicy?
        var routing: DictationRequestRouting?
        var cleanupPrompt: DictationCleanupPrompt?
        var wordLock: DictationWordLock?
    }

    struct Case: Decodable {
        var id: String
        var speech: String
        var transcribe: Bool?
        var visible: CotypingVisibleContextReplay.Fixture?
        var screen: ScreenFixture?
    }

    struct ScreenFixture: Decodable {
        var appName: String
        var windowTitle: String
        var text: String
    }

    struct Observation: Encodable {
        var id: String
        var text: String
        var prompt: String
        var system: String
        var memoryIDs: [String]
        var visibleIDs: [String]
        var textReadIDs: [String]
        var modelCalls: Int
        var screenReads: Int
        var routedAsRequest: Bool?
        var latencyMs: Double
        var error: String?
    }

    @MainActor
    static func run(input: URL, endpoint: URL) async -> Int32 {
        do {
            guard InferenceEndpointPolicy.isLoopback(endpoint), endpoint.scheme == "http",
                  endpoint.user == nil, endpoint.password == nil else { throw ReplayError.invalidInput }
            let data = try Data(contentsOf: input)
            guard data.count <= 4_194_304 else { throw ReplayError.invalidInput }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fixture = try decoder.decode(Input.self, from: data)
            guard !fixture.cases.isEmpty, fixture.cases.count <= 500,
                  Set(fixture.cases.map(\.id)).count == fixture.cases.count else { throw ReplayError.invalidInput }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var failed = false
            for item in fixture.cases {
                let result = await replay(item, fixture: fixture, endpoint: endpoint)
                failed = failed || result.error != nil
                try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data([10]))
            }
            return failed ? 1 : 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Dictation replay failed: \(error)\n".utf8))
            return 1
        }
    }

    @MainActor
    private static func replay(_ item: Case, fixture: Input, endpoint: URL) async -> Observation {
        var settings = AppSettings()
        settings.dictationIntent = item.transcribe == true ? .transcribe : .compose
        let useScreen = fixture.useScreenContext ?? false
        settings.dictationUseScreenContext = useScreen
        settings.dictationUseVisibleContext = fixture.useVisibleContext
        settings.dictationUseMeetingMemory = fixture.useMeetingMemory
        settings.dictationUseScreenMemory = fixture.useScreenMemory
        let source = item.visible.map(CotypingVisibleContextReplay.init)
        var visible: CotypingVisibleContext.Snapshot?
        var selection = CotypingMemoryContext.Selection()
        var screenReads = 0
        let engine = RecordingEngine(baseURL: endpoint)
        let start = ContinuousClock.now
        var output = "", failure: String?, routed: Bool?
        do {
            let prepared = try await DictationTextPreparation.prepare(speech: item.speech, settings: settings,
                screenContext: {
                    screenReads += 1
                    guard useScreen, let screen = item.screen else { return nil }
                    return DictationScreenContext(appName: screen.appName, bundleID: nil,
                                                  windowTitle: screen.windowTitle, visibleText: screen.text)
                }, visibleContext: {
                    visible = source?.capture(enabled: fixture.useVisibleContext)
                    return visible
                }, memoryContext: { field, selected in
                    let policy = CotypingMemoryContext.Policy(settings: selected)
                    selection = CotypingMemoryContext.select(items: fixture.memoryItems, for: field,
                        includeTitle: selected.cotypingUseAppContext, policy: policy, now: fixture.now, allowBodyMatch: false)
                    return .init(selection: selection, policy: policy)
                }, validateVisibleContext: { expected in source?.capture(enabled: fixture.useVisibleContext) == expected },
                validateScreenContext: { _ in true },
                windowTextPolicy: fixture.windowTextPolicy ?? .production,
                routing: fixture.routing ?? .production,
                cleanupPrompt: fixture.cleanupPrompt ?? .production,
                wordLock: fixture.wordLock ?? .production,
                makeEngine: { _ in engine })
            output = prepared.text
            routed = prepared.contextUse?.wasWritingRequest
        } catch { failure = String(describing: error) }
        let duration = start.duration(to: .now).components
        return .init(id: item.id, text: output, prompt: engine.prompt, system: engine.system,
                     memoryIDs: selection.items.map(\.id), visibleIDs: visible?.excerpts.map(\.id) ?? [],
                     textReadIDs: source?.textReadIDs ?? [], modelCalls: engine.calls, screenReads: screenReads,
                     routedAsRequest: routed,
                     latencyMs: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, error: failure)
    }

    private enum ReplayError: Error { case invalidInput }

    private final class RecordingEngine: TextEngine {
        let baseURL: URL
        var system = "", prompt = "", calls = 0
        var displayName: String { "Local replay" }
        init(baseURL: URL) { self.baseURL = baseURL }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await generate(system: system, prompt: prompt, context: context, options: .init())
        }
        func generate(system: String, prompt: String, context: [String], options: TextGenerationOptions) async throws -> String {
            self.system = system
            self.prompt = prompt
            calls += 1
            return try await OpenAICompatibleEngine(baseURL: baseURL, model: "local", chatDialect: .llamaServer)
                .generate(system: system, prompt: prompt, context: context, options: options)
        }
    }
}
