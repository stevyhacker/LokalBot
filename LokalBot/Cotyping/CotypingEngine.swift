import Foundation

struct CotypingPersonalization: Sendable, Equatable {
    var userName: String?
    var styleNote: String?
    var languageHint: String?
    var isMultiLine: Bool
    var appContextEnabled: Bool
    var extendedContext: String?

    static let none = CotypingPersonalization(
        userName: nil, styleNote: nil, languageHint: nil,
        isMultiLine: false, appContextEnabled: false)
}

enum CotypingRequestBuilder {
    static func build(
        field: CotypingField,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        generation: UInt64,
        clipboardContext: String? = nil,
        memoryContext: String? = nil,
        visibleContext: String? = nil,
        windowContext: String? = nil,
        learnedExamples: [String] = [],
        wordPrefixIsValidWord: Bool = true,
        allowsBlankPrefix: Bool = false
    ) -> CotypingRequest? {
        guard allowsBlankPrefix || CotypingPrefixWindow.shouldGenerate(for: field.precedingText) else { return nil }
        let prefix = CotypingPrefixWindow.truncatedPrefix(
            from: field.precedingText,
            maxCharacters: config.maxPrefixCharacters,
            maxWords: config.maxPrefixWords)
        let surfaceLines: [String]
        if personalization.appContextEnabled,
           let surface = CotypingSurfaceComposer.compose(
               appName: field.appName, bundleID: field.bundleID,
               windowTitle: field.windowTitle,
               fieldPlaceholder: field.fieldPlaceholder,
               isIntegratedTerminal: field.isIntegratedTerminal) {
            surfaceLines = CotypingSurfaceComposer.prefaceLines(for: surface)
        } else {
            surfaceLines = []
        }
        let renderedPrompt = CotypingPromptRenderer.render(
            prefixText: prefix,
            surfaceLines: surfaceLines,
            userName: personalization.userName,
            styleNote: personalization.styleNote,
            languageHint: personalization.languageHint,
            extendedContext: personalization.extendedContext,
            clipboardContext: clipboardContext,
            memoryContext: memoryContext,
            visibleContext: visibleContext,
            windowContext: windowContext,
            learnedExamples: learnedExamples)
#if LOKALBOT_TEST_HOOKS
        if TestHooks.filmsAutocomplete,
           let json = try? JSONSerialization.data(withJSONObject: ["prefix": prefix, "prompt": renderedPrompt.prompt]) {
            lokalbotLog("film: request \(String(decoding: json, as: UTF8.self))")
        }
#endif
        return CotypingRequest(
            prompt: renderedPrompt.prompt,
            prefixText: prefix,
            trailingText: field.trailingText,
            isMultiLine: personalization.isMultiLine,
            maxTokens: config.maxResponseTokens,
            maxWords: config.maxResponseWords,
            temperature: config.temperature,
            topP: config.topP,
            topK: config.topK,
            minP: config.minP,
            repeatPenalty: config.repeatPenalty,
            seed: config.seed,
            generation: generation,
            forceWordContinuation: CotypingMidWord.shouldForceContinuation(
                precedingText: field.precedingText, trailingText: field.trailingText),
            wordPrefixAtCaret: CotypingMidWord.currentPartialWord(in: prefix),
            wordPrefixIsValidWord: wordPrefixIsValidWord,
            conditioningPreface: renderedPrompt.conditioningPreface)
    }
}

@MainActor
protocol CotypingCompleting: AnyObject {
    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile { get }
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult
    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult
    func prewarm() async throws
    func prewarm(for request: CotypingRequest) async throws
    func warmAfterPause() async
    func unload() async
}

extension CotypingCompleting {
    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile { .modelServer }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        let result = try await generate(request)
        onPartial(result)
        return result
    }

    func prewarm() async throws {}

    func prewarm(for request: CotypingRequest) async throws {
        try await prewarm()
    }

    func warmAfterPause() async {}

    func unload() async {}
}

@MainActor
final class CotypingEngine: CotypingCompleting {
    private let makeEngine: () async throws -> TextEngine
    private let stopRuntime: () async -> Void
    private let healsCaretBoundary: Bool
    private let restoresWordSpace: Bool

    init(
        makeEngine: @escaping () async throws -> TextEngine,
        stopRuntime: @escaping () async -> Void = {},
        healsCaretBoundary: Bool = false,
        restoresWordSpace: Bool = false
    ) {
        self.makeEngine = makeEngine
        self.stopRuntime = stopRuntime
        self.healsCaretBoundary = healsCaretBoundary
        self.restoresWordSpace = restoresWordSpace
    }

    func unload() async {
        await stopRuntime()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        let engine = try await makeEngine()
        let (completion, requiredPrefix) = completionRequest(for: request)
        let raw = try await engine.complete(completion)
        let reply = restoresWordSpace ? Self.restoringWordSpace(raw, for: request) : raw
        return Self.normalize(reply, requiredPrefix: requiredPrefix, for: request)
    }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        let engine = try await makeEngine()
        let (completion, requiredPrefix) = completionRequest(for: request)
        let restoresWordSpace = self.restoresWordSpace
        let raw = try await engine.completeStreaming(completion) { cumulative in
            guard cumulative.count > requiredPrefix.count || requiredPrefix.isEmpty else { return }
            let reply = restoresWordSpace ? Self.restoringWordSpace(cumulative, for: request) : cumulative
            onPartial(Self.normalize(reply, requiredPrefix: requiredPrefix, for: request))
        }
        let reply = restoresWordSpace ? Self.restoringWordSpace(raw, for: request) : raw
        return Self.normalize(reply, requiredPrefix: requiredPrefix, for: request)
    }

    private func completionRequest(for request: CotypingRequest) -> (CompletionRequest, requiredPrefix: String) {
        var prompt = request.prompt
        var requiredPrefix = ""
        if healsCaretBoundary {
            let healed = LocalLlamaCotypingEngine.healedGeneration(for: request)
            prompt = healed.prompt
            requiredPrefix = String(decoding: healed.requiredPrefixUTF8, as: UTF8.self)
        }
        let healingTokens = requiredPrefix.allSatisfy(\.isWhitespace) ? 0 : 4
        let completion = CompletionRequest(
            prompt: prompt, maxTokens: request.maxTokens + healingTokens, temperature: request.temperature,
            topP: request.topP, topK: request.topK, minP: request.minP,
            repeatPenalty: request.repeatPenalty, seed: request.seed,
            stop: request.isMultiLine ? [] : ["\n"])
        return (completion, requiredPrefix)
    }

    nonisolated static func restoringWordSpace(_ reply: String, for request: CotypingRequest) -> String {
        guard !request.forceWordContinuation, request.wordPrefixIsValidWord,
              let last = request.prefixText.last, let first = reply.first,
              isSpacedWordCharacter(last), isSpacedWordCharacter(first) else { return reply }
        let word = request.wordPrefixAtCaret.lowercased()
        if word.count >= 2, reply.lowercased().hasPrefix(word) { return reply }
        return " " + reply
    }

    private nonisolated static func isSpacedWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return false
        default:
            return true
        }
    }

    nonisolated static func normalize(_ raw: String, requiredPrefix: String,
                                      for request: CotypingRequest) -> CotypingNormalizationResult {
        guard !requiredPrefix.isEmpty else { return CotypingTextNormalizer.normalizeDetailed(raw, for: request) }
        guard raw.hasPrefix(requiredPrefix) else {
            return CotypingNormalizationResult(text: "", suppression: raw.isEmpty ? .emptyGeneration : .wordCompletionMismatch)
        }
        return CotypingTextNormalizer.normalizeDetailed(String(raw.dropFirst(requiredPrefix.count)), for: request)
    }
}
