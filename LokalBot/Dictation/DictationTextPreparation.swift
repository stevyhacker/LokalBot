import Foundation

enum DictationTextPreparation {
    struct Result {
        let text: String
        let compositionModel: String?
        var sourceTitles: [String] = []
        var contextIsCurrent: @MainActor () -> Bool = { true }
        var contextUse: DictationContextUse?
    }

    static let composeOptions = TextGenerationOptions(maxTokens: 4_096, reasoningBudgetTokens: 0, temperature: 0.2)

    @MainActor
    static func prepare(
        speech: String,
        settings: AppSettings,
        screenContext: () async -> DictationScreenContext?,
        visibleContext: () async -> CotypingVisibleContext.Snapshot? = { nil },
        memoryContext: (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot = { _, _ in .empty },
        currentSettings: @escaping () -> AppSettings? = { nil },
        validateVisibleContext: (CotypingVisibleContext.Snapshot) async -> Bool = { _ in false },
        validateScreenContext: (DictationScreenContext) async -> Bool = { _ in false },
        windowTextPolicy: DictationWindowTextPolicy = .production,
        routing: DictationRequestRouting = .production,
        cleanupPrompt: DictationCleanupPrompt = .production,
        makeEngine: (AppSettings) async throws -> TextEngine
    ) async throws -> Result {
        try Task.checkCancellation()
        guard settings.dictationIntent == .compose else {
            return Result(text: speech, compositionModel: nil)
        }
        func permissionsCurrent() -> Bool {
            DictationGrounding.permissionsMatch(settings, currentSettings() ?? settings)
        }
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let usesContext = DictationGrounding.requestsContext(speech, routing: routing)
        let context = usesContext && settings.dictationUseScreenContext ? await screenContext() : nil
        try Task.checkCancellation()
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let visible = usesContext && settings.dictationUseVisibleContext ? await visibleContext() : nil
        try Task.checkCancellation()
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let selectedSettings = DictationGrounding.memorySettings(settings)
        let memory = usesContext && CotypingMemoryContext.Policy(settings: selectedSettings).enabled
            ? await memoryContext(DictationGrounding.field(speech: speech, screen: context, visible: visible), selectedSettings)
            : .empty
        let isCurrent = {
            permissionsCurrent() && memory.isCurrent(settings: DictationGrounding.memorySettings(currentSettings() ?? settings))
        }
        func validate() async throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw DictationComposeError.contextChanged }
            if let visible, !(await validateVisibleContext(visible)) { throw DictationComposeError.contextChanged }
            if let context, !(await validateScreenContext(context)) { throw DictationComposeError.contextChanged }
            try Task.checkCancellation()
            guard isCurrent() else { throw DictationComposeError.contextChanged }
        }
        try await validate()
        let engine = try await makeEngine(settings)
        try await validate()
        let profile = DictationComposeProfile(personalization: settings.cotypingPersonalization)
        let cleansAsData = !usesContext && cleanupPrompt == .transcriptAsData
        let system = cleansAsData ? DictationCleanupPromptText.system(profile: profile) : DictationComposePrompt.system
        let prompt = cleansAsData
            ? DictationCleanupPromptText.userPrompt(spokenText: speech)
            : DictationComposePrompt.userPrompt(
                spokenText: speech, context: context, profile: profile,
                visibleContext: visible?.text, memoryContext: memory.selection.text,
                windowTextPolicy: windowTextPolicy)
        let output = try await engine.generate(system: system, prompt: prompt, context: [],
                                               options: Self.composeOptions)
        try await validate()
        let text = DictationComposePrompt.insertableText(
            cleansAsData
                ? DictationCleanupPromptText.normalizedOutput(output, spokenText: speech)
                : DictationComposePrompt.normalizedOutput(output),
            spokenText: speech, context: context)
        guard !text.isEmpty else { throw DictationComposeError.emptyOutput }
        let contextUse = DictationContextUse(
            wasWritingRequest: usesContext,
            focusedWindow: !(context?.visibleText.isEmpty ?? true),
            visibleText: !(visible?.text?.isEmpty ?? true),
            savedFactSources: memory.selection.sourceTitles)
        return Result(text: text, compositionModel: engine.displayName,
                      sourceTitles: memory.selection.sourceTitles, contextIsCurrent: isCurrent,
                      contextUse: contextUse)
    }
}

struct DictationContextUse: Equatable, Sendable {
    var wasWritingRequest: Bool
    var focusedWindow = false
    var visibleText = false
    var savedFactSources: [String] = []

    func summary(localized: (String) -> String = { $0 }) -> String {
        guard wasWritingRequest else {
            return localized("Cleanup only. Context is read only for writing requests such as “reply…” or “draft…”.")
        }
        var used: [String] = []
        if focusedWindow { used.append(localized("focused window")) }
        if visibleText { used.append(localized("visible text")) }
        if !savedFactSources.isEmpty {
            used.append(String(format: localized("saved facts from %@"),
                               savedFactSources.joined(separator: ", ")))
        }
        guard !used.isEmpty else { return localized("Writing request. No enabled context matched it.") }
        return String(format: localized("Used: %@"), used.joined(separator: "; "))
    }
}
