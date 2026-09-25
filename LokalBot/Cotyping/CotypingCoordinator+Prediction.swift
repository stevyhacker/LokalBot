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
            focus: focus) == nil,
              let request = buildRequest(for: field, settings: settings, generation: generation)
        else {
            return
        }

        focusPrewarmFieldIdentity = fieldIdentity
        focusPrewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            try? await self?.engine.prewarm(for: request)
        }
    }

    func scheduleGeneration(consumedDelayMilliseconds: Int = 0) {
        debounceTask?.cancel()
        generationTask?.cancel()
        generationTask = nil
        generation &+= 1
        let work = generation
        clearSuggestion()
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

        guard let request = buildRequest(for: field, settings: settings, generation: work) else {
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
            // Stream: paint ghost text as tokens arrive instead of waiting for the
            // whole completion only when the user enabled streamed suggestions.
            // Even when partial painting is off, keep the streaming transport so
            // the HTTP client can stop at the same decode boundary as Cotabby.
            let streamPartials = settings.cotypingStreamSuggestionsWhileGenerating
            let result = try await engine.generateStreaming(request) { [weak self] partial in
                guard streamPartials else { return }
                Task { @MainActor in self?.queueStreamPartial(partial, work: work, field: field) }
            }
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
        CotypingStatsStore.shared.recordError()
    }

    private func buildRequest(
        for field: CotypingField,
        settings: AppSettings,
        generation: UInt64
    ) -> CotypingRequest? {
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        let clipboardSnippet = pinnedClipboardContext(
            for: field,
            config: cfg,
            enabled: settings.cotypingUseClipboard)
        let learnedExamples = settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: field,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        return CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: settings.cotypingPersonalization, generation: generation,
            clipboardContext: clipboardSnippet,
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: field.precedingText))
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

    private func refreshFocusForPrediction(settings: AppSettings) async -> CotypingFocus {
        let includeSurface = settings.cotypingUseAppContext
        let includeURL = !settings.cotypingExcludedDomainList.isEmpty
        let includeStyle = settings.cotypingMatchHostStyle
        let includeLearningScope = settings.cotypingUseLocalLearning
        guard !includeSurface, !includeURL, !includeStyle, !includeLearningScope else {
            return await focusTracker.refreshNow(
                includeSurface: includeSurface,
                includeURL: includeURL,
                includeStyle: includeStyle,
                includeLearningScope: includeLearningScope)
        }
        return await focusTracker.refreshIfStale(
            maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
    }

    private func validatedLiveFieldForGeneratedResult(
        originalField: CotypingField,
        settings: AppSettings,
        work: UInt64
    ) async -> CotypingField? {
        guard work == generation, isRunning else { return nil }
        let includeSurface = settings.cotypingUseAppContext
        let includeURL = !settings.cotypingExcludedDomainList.isEmpty
        let includeStyle = settings.cotypingMatchHostStyle
        let includeLearningScope = settings.cotypingUseLocalLearning
        guard let focus = await focusTracker.refreshForValidation(
            includeSurface: includeSurface,
            includeURL: includeURL,
            includeStyle: includeStyle,
            includeLearningScope: includeLearningScope) else {
            return nil
        }
        guard work == generation, isRunning else { return nil }
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
        guard originalField.learningScopeKey == focus.field?.learningScopeKey,
              CotypingSessionReconciler.isCurrentGenerationTarget(originalField, liveField: focus.field) else {
            return nil
        }
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
        CotypingStatsStore.shared.recordGeneration(latencyMs: latencyMilliseconds)
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
        suggestionAnchorCache.record(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            requestFingerprint: activeSuggestionRequestFingerprint ?? "",
            precedingText: field.precedingText,
            fullText: text)
        present(
            CotypingSession(field: field, fullText: text, kind: .continuation),
            overlayText: text)
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
        guard let text = suggestionAnchorCache.remainder(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: field),
            requestFingerprint: requestFingerprint,
            precedingText: field.precedingText),
              !text.isEmpty else { return false }

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
        present(
            CotypingSession(field: field, fullText: text, kind: .continuation),
            overlayText: text)
        return true
    }

    /// Coalesces streamed partials to one main-queue render pass. Tokens can
    /// arrive faster than AppKit can relayout the overlay; latest-wins keeps the
    /// visible ghost fresh without stacking window updates on the main actor.
    private func queueStreamPartial(_ result: CotypingNormalizationResult, work: UInt64, field: CotypingField) {
        guard work == generation, isRunning else { return }
        pendingStreamPartial = PendingStreamPartial(result: result, work: work, field: field)
        guard streamValidationTask == nil else { return }
        streamValidationGeneration &+= 1
        let validationGeneration = streamValidationGeneration
        streamValidationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.streamValidationGeneration == validationGeneration,
                  let pending = self.pendingStreamPartial {
                self.pendingStreamPartial = nil
                await self.renderStreamPartial(
                    pending.result,
                    work: pending.work,
                    field: pending.field)
            }
            if self.streamValidationGeneration == validationGeneration {
                self.streamValidationTask = nil
            }
        }
    }

    /// Renders a streamed partial. Monotonic: ignores reordered/shorter partials
    /// so the ghost only grows.
    private func renderStreamPartial(
        _ result: CotypingNormalizationResult,
        work: UInt64,
        field: CotypingField
    ) async {
        guard work == generation, isRunning, !result.text.isEmpty else { return }
        let settings = settingsProvider()
        let liveField = await validatedLiveFieldForGeneratedResult(
            originalField: field,
            settings: settings,
            work: work)
        guard work == generation, isRunning, !Task.isCancelled else { return }
        guard let liveField else {
            clearStaleGeneratedResult()
            return
        }
        guard CotypingSeamGuard.allowsStreamedPartial(
            precedingText: liveField.precedingText,
            completion: result.text
        ) else { return }
        let currentlyRendered = session?.field.contentSignature == liveField.contentSignature
            ? session?.fullText
            : nil
        guard CotypingStreamedGhostTextPolicy.isRenderableExtension(
            candidate: result.text,
            currentlyRendered: currentlyRendered) else {
            return
        }
        present(
            CotypingSession(field: liveField, fullText: result.text, kind: .continuation),
            overlayText: result.text,
            streamedWork: work)
    }

    private func seamVerdict(precedingText: String, completion: String) -> CotypingSeamGuard.Verdict {
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

    /// Bundles the caret-geometry + mid-line + preference signals the overlay
    /// needs to pick inline vs popup rendering, derived from a field snapshot.
    func placement(for field: CotypingField) -> CotypingOverlayPlacement {
        CotypingOverlayPlacement(
            caretIsExact: field.caretIsExact,
            isCaretAtEndOfLine: CotypingRenderModePolicy.isCaretAtEndOfLine(trailingText: field.trailingText),
            preference: settingsProvider().cotypingMirrorPreference)
    }

    func showOverlay(
        text: String,
        field: CotypingField,
        placement: CotypingOverlayPlacement? = nil,
        acceptanceText: String? = nil
    ) {
        overlay.show(
            text: text,
            caretRect: field.caretRect,
            inputFrameRect: field.inputFrameRect,
            focusIdentityKey: field.focusIdentityKey,
            style: field.fieldStyle,
            placement: placement ?? self.placement(for: field),
            acceptanceText: acceptanceText,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(field.precedingText))
    }

    // MARK: - In-app preview

    /// Runs the real pipeline (prompt + model + normalizer) on synthetic text for
    /// the in-app preview playground. No Accessibility / Input Monitoring needed.
    func previewSuggestion(precedingText: String, trailingText: String = "", sampleOnly: Bool = false) async throws -> String {
        let settings = settingsProvider()
        var cfg = config
        cfg.maxResponseTokens = settings.cotypingMaxResponseTokens
        cfg.maxResponseWords = settings.cotypingMaxWords
        let field = CotypingField(
            appName: "LokalBot", bundleID: selfBundleID, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: trailingText, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
        let learnedExamples = !sampleOnly && settings.cotypingUseLocalLearning
            ? learningStore.examples(
                for: field,
                limit: settings.cotypingLearningExamplesInPrompt)
            : []
        guard let request = CotypingRequestBuilder.build(
            field: field, config: cfg,
            personalization: sampleOnly ? .none : settings.cotypingPersonalization, generation: 0,
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: wordPrefixIsValidWord(for: precedingText)) else {
            return ""
        }
        return try await engine.generate(request).text
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
            streamPartials: settings.cotypingStreamSuggestionsWhileGenerating,
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
