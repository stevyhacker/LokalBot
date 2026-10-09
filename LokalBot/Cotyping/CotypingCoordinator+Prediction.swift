import CoreGraphics
import Foundation

/// Debounce, generation, streamed partials, stale-result handling, and preview commands.
extension CotypingCoordinator {
    // MARK: - Generation

    func scheduleFocusPrewarm(for focus: CotypingFocus) {
        guard isRunning,
              !isMeetingRecordingActive(),
              case .supported = focus.capability,
              let field = focus.field else {
            focusPrewarmTask?.cancel()
            focusPrewarmTask = nil
            focusPrewarmFieldIdentity = nil
            return
        }

        let fieldIdentity = CotypingFieldIdentity.prewarm(for: field)
        guard fieldIdentity != focusPrewarmFieldIdentity else { return }

        focusPrewarmTask?.cancel()
        focusPrewarmTask = nil
        guard session == nil, state == .idle else {
            return
        }
        let settings = settingsProvider()
        guard CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID,
            focus: focus) == nil else {
            return
        }

        focusPrewarmFieldIdentity = fieldIdentity
        focusPrewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            // Read the field as the first keystroke will, which also caches its
            // font and the text above it, and have the model read that prompt
            // now, so the first suggestion only adds what was typed.
            let settings = self.settingsProvider()
            let live = await self.refreshFocusForPrediction(settings: settings)
            guard !Task.isCancelled, let field = live.field,
                  CotypingFieldIdentity.prewarm(for: field) == fieldIdentity,
                  let request = self.buildRequest(
                    for: field, settings: settings, generation: self.generation, allowsBlankPrefix: true)
            else { return }
            try? await self.engine.prewarm(for: request)
        }
    }

    func scheduleGeneration(consumedDelayMilliseconds: Int = 0) {
        debounceTask?.cancel()
        generationTask?.cancel()
        generationTask = nil
        generation &+= 1
        let work = generation
        clearSuggestion()
        activeMemoryContext = .empty
        activeVisibleContext = nil
        memoryContextSources = []
        memoryContextSearched = false
        state = .debouncing
        let delay = CotypingDebouncePolicy.milliseconds(
            lastLatencyMilliseconds: lastLatencyMilliseconds,
            configured: settingsProvider().cotypingDebounceMs,
            profile: engine.debounceProfile,
            consumedDelayMilliseconds: consumedDelayMilliseconds)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.replaceGenerationWork(for: work)
        }
    }

    func cancelPendingGenerationWork() {
        focusPrewarmTask?.cancel()
        focusPrewarmTask = nil
        hostPublishPollGeneration &+= 1
        hostPublishPollTask?.cancel()
        hostPublishPollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        generationTask?.cancel()
        generationTask = nil
        generation &+= 1
    }

    private func replaceGenerationWork(for work: UInt64) {
        guard work == generation, isRunning else { return }
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, work == self.generation else { return }
            defer {
                if self.generation == work {
                    self.generationTask = nil
                }
            }
            await self.generate(work: work)
        }
    }

    private func generate(work: UInt64) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()
        if isMeetingRecordingActive() {
            clearSuggestion()
            state = .disabled(CotypingMeetingPause.reason)
            return
        }
        let focus = await refreshFocusForPrediction(settings: settings)
        guard work == generation, isRunning, !Task.isCancelled else { return }

        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID, focus: focus) {
            state = .disabled(reason)
            return
        }
        guard let field = focus.field else { state = .idle; return }
        guard !isPausedByEscape(in: field) else { state = .idle; return }
        prepareVisualCaret(for: field, host: focus.host, settings: settings)

        // Emoji: an explicit `:shortcode` intent wins over autocorrect and the LLM.
        if settings.cotypingEmoji, let emoji = CotypingEmoji.match(trailing: field.precedingText) {
            present(
                CotypingSession(field: field, fullText: emoji.glyph, kind: .emoji(shortcode: emoji.shortcode)),
                overlayText: "\(emoji.glyph) :\(emoji.shortcode):",
                acceptanceText: emoji.glyph)
            return
        }

        // Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.
        if settings.cotypingMacros, let macro = CotypingMacro.match(trailing: field.precedingText) {
            present(
                CotypingSession(
                    field: field,
                    fullText: macro.result.insertion,
                    kind: .macro(query: macro.query)),
                overlayText: macro.result.preview,
                acceptanceText: macro.result.insertion)
            return
        }

        // Autocorrect: offer to fix the trailing word before spending an LLM call.
        switch typoDecision(for: field.precedingText, enabled: settings.cotypingAutocorrect) {
        case .offerCorrection(let word, let corrected):
            present(
                CotypingSession(field: field, fullText: corrected, kind: .correction(typoWord: word)),
                overlayText: corrected)
            return
        case .suppress:
            clearSuggestion()
            state = .idle
            return
        case .proceed:
            break
        }

        var memory = latestSavedContext(for: field, settings: settings)
        if !memory.isCurrent(settings: settingsProvider()) {
            // A source changed or was withdrawn since the lookup: look again.
            memoryLookup.reset()
            memory = .empty
        }
        activeMemoryContext = memory
        activeVisibleContext = field.visibleContext?.text == nil ? nil : field.visibleContext
        memoryContextSources = memory.selection.sourceTitles
        memoryContextSearched = CotypingMemoryContext.Policy(settings: settings).enabled
        guard let request = buildRequest(for: field, settings: settings, generation: work,
                                         memoryContext: memory.selection.text) else {
            state = .idle
            return
        }
        let requestFingerprint = CotypingSuggestionCacheFingerprint.make(
            request: request,
            settings: settings)
        if restoreSuggestionFromAnchorCache(
            field: field,
            work: work,
            requestFingerprint: requestFingerprint) {
            return
        }
        activeSuggestionRequestFingerprint = requestFingerprint

        state = .generating
        let start = Date()
        do {
            // The whole suggestion appears at once, as in Cotypist.
            let result = try await engine.generate(request)
            await completeGeneration(
                result,
                targetField: field,
                work: work,
                latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            handleGenerationFailure(error, work: work)
        }
    }

    /// Validates a finished generation against the live field before applying it.
    private func completeGeneration(
        _ result: CotypingNormalizationResult,
        targetField: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int
    ) async {
        guard work == generation, isRunning else { return }
        let settings = settingsProvider()

        guard let liveField = await validatedLiveFieldForGeneratedResult(
            originalField: targetField,
            settings: settings,
            work: work) else {
            guard work == generation, isRunning else { return }
            clearStaleGeneratedResult()
            return
        }
        await visualCaret.waitForPending(milliseconds: Self.visualCaretWaitMilliseconds)
        guard work == generation, isRunning else { return }
        let pendingAcceptedTail = lastAcceptedTail
        lastAcceptedTail = nil
        _ = applyGenerationResult(
            result,
            field: liveField,
            work: work,
            latencyMilliseconds: latencyMilliseconds,
            pendingAcceptedTail: pendingAcceptedTail)
    }

    /// Cancellation is expected when newer input supersedes this request.
    private func handleGenerationFailure(_ error: Error, work: UInt64) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        guard work == generation else { return }
        state = .failed(shortError(error))
        stats.recordError()
    }

    func buildRequest(
        for field: CotypingField,
        settings: AppSettings,
        generation: UInt64,
        memoryContext: String? = nil,
        allowsBlankPrefix: Bool = false
    ) -> CotypingRequest? {
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        let clipboardSnippet = pinnedClipboardContext(
            for: field,
            config: cfg,
            enabled: settings.cotypingUseClipboard)
        // Ranked on finished words only: a half-typed word reordering the
        // examples would change the prompt, and the model would read it again.
        var rankingField = field
        rankingField.precedingText = CotypingMemoryLookup.finishedWords(of: field.precedingText)
        let learnedExamples = settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: rankingField,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        return CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: generation,
            clipboardContext: clipboardSnippet,
            memoryContext: memoryContext,
            visibleContext: field.visibleContext?.text,
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: field.precedingText),
            allowsBlankPrefix: allowsBlankPrefix)
    }

    private func pinnedClipboardContext(
        for field: CotypingField,
        config: CotypingConfiguration,
        enabled: Bool
    ) -> String? {
        guard enabled else {
            clipboardPrefaceMemo = nil
            clipboardRelevanceFilter.reset()
            return nil
        }
        let identityKey = CotypingFieldIdentity.suggestionAnchor(for: field)
        let clipboardSnapshot = clipboardProvider.snapshot()
        let prefix = CotypingPrefixWindow.truncatedPrefix(
            from: field.precedingText,
            maxCharacters: config.maxPrefixCharacters,
            maxWords: config.maxPrefixWords)
        let resolution = CotypingClipboardPrefaceResolver.resolve(
            snapshot: clipboardSnapshot,
            precedingText: prefix,
            identityKey: identityKey,
            memo: clipboardPrefaceMemo,
            relevanceFilter: clipboardRelevanceFilter)
        clipboardPrefaceMemo = resolution.memo
        return resolution.value
    }

    func refreshFocusForPrediction(settings: AppSettings) async -> CotypingFocus {
        let includeVisibleContext = settings.cotypingUseVisibleContext
        let includeSurface = settings.cotypingUseAppContext
        let includeURL = !settings.cotypingExcludedDomainList.isEmpty
        let includeStyle = settings.cotypingMatchHostStyle
        let includeLearningScope = settings.cotypingUseLocalLearning
        guard !includeSurface, !includeURL, !includeStyle, !includeLearningScope, !includeVisibleContext else {
            return await focusTracker.refreshNow(
                includeSurface: includeSurface,
                includeURL: includeURL,
                includeStyle: includeStyle,
                includeLearningScope: includeLearningScope,
                includeVisibleContext: includeVisibleContext)
        }
        return await focusTracker.refreshIfStale(
            maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
    }

    /// One quick read of the field before painting: the suggestion is shown
    /// only if the text it continues is still exactly what is there. The
    /// field's font and the text above it come from the request's own read.
    private func validatedLiveFieldForGeneratedResult(
        originalField: CotypingField,
        settings: AppSettings,
        work: UInt64
    ) async -> CotypingField? {
        guard work == generation, isRunning, !discardRevokedMemoryContext() else { return nil }
        guard var focus = await focusTracker.refreshForValidation(
            includeSurface: settings.cotypingUseAppContext,
            includeURL: !settings.cotypingExcludedDomainList.isEmpty) else {
            return nil
        }
        guard work == generation, isRunning, !discardRevokedMemoryContext() else { return nil }
        if let reason = CotypingAvailability.disabledReason(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            excludedDomains: settings.cotypingExcludedDomainList,
            suggestInIntegratedTerminals: settings.cotypingSuggestInIntegratedTerminals,
            selfBundleID: selfBundleID,
            focus: focus) {
            state = .disabled(reason)
            return nil
        }
        guard CotypingSessionReconciler.isCurrentGenerationTarget(originalField, liveField: focus.field) else {
            return nil
        }
        focus.field?.fieldStyle = originalField.fieldStyle
        focus.field?.learningScopeKey = originalField.learningScopeKey
        focus.field?.visibleContext = originalField.visibleContext
        return focus.field
    }

    private func clearStaleGeneratedResult() {
        clearSuggestion()
        if !isDisabledState {
            state = .idle
        }
    }

    private func applyGenerationResult(
        _ result: CotypingNormalizationResult,
        field: CotypingField,
        work: UInt64,
        latencyMilliseconds: Int,
        pendingAcceptedTail: AcceptedSuggestionTail?
    ) -> Bool {
        guard work == generation, isRunning else { return false }
        lastLatencyMilliseconds = latencyMilliseconds
        stats.recordGeneration(latencyMs: latencyMilliseconds)
        let text = result.text
        guard !text.isEmpty else {
            clearSuggestion()
            state = .idle
            return false
        }
        if let pendingAcceptedTail,
           CotypingSessionReconciler.isStaleAcceptanceEcho(
               resultText: text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: field.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText) {
            clearSuggestion()
            state = .idle
            return false
        }
        guard seamVerdict(precedingText: field.precedingText, completion: text) == .allow else {
            clearSuggestion()
            state = .idle
            return false
        }
        var fresh = CotypingSession(field: field, fullText: text, kind: .continuation)
        fresh.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(
            text, wordLimit: settingsProvider().cotypingMaxWords)
        suggestionAnchorCache.record(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            requestFingerprint: activeSuggestionRequestFingerprint ?? "",
            precedingText: field.precedingText,
            fullText: text,
            isOpenEnded: fresh.isOpenEnded)
        present(fresh, overlayText: text)
        return true
    }

    private func restoreSuggestionFromAnchorCache(
        field: CotypingField,
        work: UInt64,
        requestFingerprint: String
    ) -> Bool {
        guard work == generation,
              field.selectionLength == 0,
              !field.isSecure else { return false }
        guard let restored = suggestionAnchorCache.restoration(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            requestFingerprint: requestFingerprint,
            precedingText: field.precedingText),
              !restored.text.isEmpty else { return false }
        let text = restored.text

        guard !CotypingTrailingDuplicationFilter.duplicatesTrailingText(
            text,
            trailingText: field.trailingText) else {
            return false
        }
        if let pendingAcceptedTail = lastAcceptedTail,
           CotypingSessionReconciler.isStaleAcceptanceEcho(
               resultText: text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: field.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText) {
            return false
        }
        guard seamVerdict(precedingText: field.precedingText, completion: text) == .allow else {
            return false
        }

        lastAcceptedTail = nil
        var restoredSession = CotypingSession(field: field, fullText: text, kind: .continuation)
        restoredSession.isOpenEnded = restored.isOpenEnded
        present(restoredSession, overlayText: text)
        return true
    }

    func seamVerdict(precedingText: String, completion: String) -> CotypingSeamGuard.Verdict {
        let verdictsApply = spellChecker.verdictsApply(context: precedingText)
        return CotypingSeamGuard.verdict(
            precedingText: precedingText,
            completion: completion,
            isKnownWord: { verdictsApply ? !spellChecker.isTypo($0) : true })
    }

    /// Resolves the typo gate for the trailing word using the native spell checker.
    private func typoDecision(for precedingText: String, enabled: Bool) -> CotypingTypoDecision {
        guard spellChecker.verdictsApply(context: precedingText) else { return .proceed }
        return CotypingTypoGate.resolve(
            precedingText: precedingText, enabled: enabled,
            isTypo: { spellChecker.isTypo($0) },
            bestCorrection: { spellChecker.bestCorrection(for: $0) },
            isCompletableWordPrefix: { spellChecker.isCompletableWordPrefix($0) })
    }

    /// Whether the word fragment at the caret is a valid standalone word — the
    /// normalizer's signal for accepting a whitespace-leading continuation
    /// after a fragment ("the" may be complete; "follo" must be extended).
    private func wordPrefixIsValidWord(for precedingText: String) -> Bool {
        let partial = CotypingMidWord.currentPartialWord(in: precedingText)
        guard partial.count >= 2 else { return true }
        guard spellChecker.verdictsApply(context: precedingText) else { return true }
        return !spellChecker.isTypo(partial)
    }

    /// Starts finding the caret on screen for a field whose app reports
    /// none, unless the field may not be captured.
    func prepareVisualCaret(for field: CotypingField, host: String?, settings: AppSettings) {
        guard !field.caretIsExact else { return }
        let permitted = CotypingVisualCaretLocator.permitsCapture(
            appName: field.appName, bundleID: field.bundleID, host: host, isSecure: field.isSecure,
            excludedApps: settings.excludedAppList + settings.cotypingExcludedAppList,
            excludedDomains: settings.excludedScreenDomainList + settings.cotypingExcludedDomainList)
        visualCaret.notePermission(permitted, for: field)
        guard permitted else { return }
        visualCaret.refreshIfNeeded(for: field)
    }

    /// `field` as the ghost is placed for it: with the caret found on screen
    /// when its app reports none.
    func displayField(_ field: CotypingField) -> CotypingField {
        visualCaret.resolve(field)
    }

    /// Bundles the caret-geometry + mid-line + preference signals the overlay
    /// needs to pick inline vs popup rendering, derived from a field snapshot.
    func placement(for field: CotypingField) -> CotypingOverlayPlacement {
        let field = displayField(field)
        return CotypingOverlayPlacement(
            caretIsExact: field.caretIsExact,
            isCaretAtEndOfLine: CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: field.trailingText),
            preference: settingsProvider().cotypingMirrorPreference,
            caretIsFoundOnScreen: visualCaret.canFind(field))
    }

    func showOverlay(
        text: String,
        field: CotypingField,
        placement: CotypingOverlayPlacement? = nil,
        acceptanceText: String? = nil
    ) {
        var field = field
        if field.fieldStyle == nil { field.fieldStyle = sessionStyle(for: field) }
        field = displayField(field)
        overlay.show(
            text: text,
            caretRect: field.caretRect,
            inputFrameRect: field.inputFrameRect,
            style: field.fieldStyle,
            placement: placement ?? self.placement(for: field),
            acceptanceText: acceptanceText,
            // A correction, emoji or calculation is shown whole or not at all.
            mayShowPart: session.map { $0.kind == .continuation } ?? true,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText),
            precedingText: field.precedingText,
            trailingText: field.trailingText,
            emphasisLength: acceptEmphasisLength(for: text))
    }

    /// A quick re-read of the field leaves out its font. The suggestion keeps
    /// the font it was first drawn in, so it does not change size mid-line.
    private func sessionStyle(for field: CotypingField) -> CotypingFieldStyle? {
        guard let session,
              CotypingFieldIdentity.suggestionAnchor(for: session.field)
                == CotypingFieldIdentity.suggestionAnchor(for: field) else { return nil }
        return session.field.fieldStyle
    }

    /// Characters of `text` the next accept keypress takes, which the ghost
    /// draws a little stronger. Nil when one accept takes the whole suggestion.
    func acceptEmphasisLength(for text: String) -> Int? {
        guard let session, case .continuation = session.kind else { return nil }
        let settings = settingsProvider()
        let chunk = CotypingGhostHighlight.acceptancePrefix(
            in: text,
            granularity: settings.cotypingAcceptGranularity,
            autoAcceptTrailingPunctuation: settings.cotypingAutoAcceptTrailingPunctuation)
        return chunk.isEmpty ? nil : chunk.count
    }

    // MARK: - Saved memory

    /// Saved facts for a live keystroke. Looking them up reads the library,
    /// which takes tens of milliseconds, so the suggestion uses the newest
    /// lookup that has finished for this field. Another starts in the
    /// background when the finished words before the caret could name
    /// something new, and the following keystroke picks it up.
    private func latestSavedContext(for field: CotypingField, settings: AppSettings)
        -> CotypingMemoryContextProvider.Snapshot {
        guard CotypingMemoryContext.Policy(settings: settings).enabled else {
            memoryLookup.reset()
            return .empty
        }
        var lookupField = field
        lookupField.precedingText = CotypingMemoryLookup.finishedWords(of: field.precedingText)
        let anchor = CotypingFieldIdentity.suggestionAnchor(for: field)
        let query = CotypingMemoryContext.query(for: lookupField, includeTitle: settings.cotypingUseAppContext)
        if memoryLookup.needsLookup(anchor: anchor, query: query) {
            let lookup = memoryLookup.begin(anchor: anchor, query: query)
            memoryLookup.task = Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.memoryContextProvider(lookupField, settings)
                guard !Task.isCancelled else { return }
                self.memoryLookup.finish(lookup, with: snapshot)
            }
        }
        return memoryLookup.snapshot
    }

    // MARK: - In-app preview

    private func savedContext(for field: CotypingField, settings: AppSettings) async
        -> CotypingMemoryContextProvider.Snapshot {
        guard CotypingMemoryContext.Policy(settings: settings).enabled else { return .empty }
        return await memoryContextProvider(field, settings)
    }

    /// Runs the real pipeline (prompt + model + normalizer) on synthetic text for
    /// the in-app preview playground. No Accessibility / Input Monitoring needed.
    func previewSuggestion(precedingText: String, trailingText: String = "", sampleOnly: Bool = false) async throws -> String {
        try await preview(precedingText: precedingText, trailingText: trailingText, sampleOnly: sampleOnly).text
    }

    /// The same pipeline, also reporting which optional sources shaped the
    /// result. With the visible-text grant on, `conversation` stands in for the
    /// text above a live field; the screen is never read.
    func preview(
        precedingText: String,
        trailingText: String = "",
        conversation: [CotypingRehearsalConversation.Message] = [],
        sampleOnly: Bool = false,
        maxWords: Int? = nil
    ) async throws -> CotypingPreview {
        var settings = settingsProvider()
        if let maxWords { settings.cotypingMaxWords = maxWords }
        let work = generation
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        var field = CotypingField(
            appName: "LokalBot", bundleID: selfBundleID, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: trailingText, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
        if !sampleOnly, settings.cotypingUseVisibleContext, !conversation.isEmpty {
            field.visibleContext = CotypingRehearsalConversation.snapshot(of: conversation)
        }
        let learnedExamples = !sampleOnly && settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: field,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        let memory = sampleOnly ? CotypingMemoryContextProvider.Snapshot.empty
            : await savedContext(for: field, settings: settings)
        guard !Task.isCancelled, work == generation,
              memory.isCurrent(settings: settingsProvider()) else { return CotypingPreview() }
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: sampleOnly ? .none : settings.cotypingPersonalization, generation: 0,
            memoryContext: memory.selection.text,
            visibleContext: field.visibleContext?.text,
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: precedingText)) else {
            return CotypingPreview()
        }
        let result = try await engine.generate(request).text
        guard !Task.isCancelled, work == generation,
              memory.isCurrent(settings: settingsProvider()),
              field.visibleContext == nil || settingsProvider().cotypingUseVisibleContext else {
            return CotypingPreview()
        }
        let searched = !sampleOnly && CotypingMemoryContext.Policy(settings: settings).enabled
        if !sampleOnly {
            memoryContextSources = memory.selection.sourceTitles
            memoryContextSearched = searched
        }
        return CotypingPreview(
            text: result,
            use: CotypingContextUse(
                visibleText: field.visibleContext?.text != nil,
                selection: memory.selection,
                searchedMemory: searched))
    }

    func runQualityBenchmark() async -> CotypingBenchmarkSummary {
        let settings = settingsProvider()
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        return await CotypingBenchmarkRunner.run(
            engine: engine,
            config: cfg,
            personalization: settings.cotypingPersonalization,
            learnedExamples: { [weak self] field in
                guard let self, settings.cotypingUseLocalLearning else { return [] }
                return self.learningStore.examples(
                    for: field,
                    limit: settings.cotypingLearningExamplesInPrompt)
            })
    }

    private func shortError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
