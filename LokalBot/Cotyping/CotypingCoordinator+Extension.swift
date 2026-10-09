import Foundation

/// Keeps the visible suggestion a few words ahead while it is accepted or
/// typed through, instead of letting it run out and come back.
extension CotypingCoordinator {
    /// Starts a top-up when the visible suggestion is running short. Cheap and
    /// non-blocking: the accept tap calls it from inside its event callback.
    func extendSuggestionIfNeeded() {
        guard isRunning, extensionTask == nil, generationTask == nil, let current = session else { return }
        let settings = settingsProvider()
        guard CotypingSuggestionExtension.shouldExtend(current, wordLimit: settings.cotypingMaxWords) else { return }
        extensionGeneration &+= 1
        let work = extensionGeneration
        extensionTask = Task { [weak self] in
            guard let self else { return }
            let addition = await self.suggestionExtension(for: current, settings: settings)
            if let addition, !Task.isCancelled, work == self.extensionGeneration {
                await self.applySuggestionExtension(addition, to: current, settings: settings, work: work)
            }
            guard work == self.extensionGeneration else { return }
            self.extensionTask = nil
            // More words may have been accepted while the model ran. Only a
            // top-up that landed is followed up, so a refused one cannot loop.
            if let now = self.session, now.fullText != current.fullText {
                self.extendSuggestionIfNeeded()
            }
        }
    }

    func cancelSuggestionExtension() {
        extensionGeneration &+= 1
        extensionTask?.cancel()
        extensionTask = nil
    }

    /// Asks the model to continue from the end of `session`'s suggestion, with
    /// the same context the suggestion was made from. Nil when nothing usable
    /// came back.
    func suggestionExtension(for session: CotypingSession, settings: AppSettings) async -> String? {
        var field = session.field
        field.precedingText = CotypingSuggestionExtension.continuationPrefix(of: session)
        var topUp = settings
        topUp.cotypingMaxWords = CotypingSuggestionExtension.topUpWordLimit(wordLimit: settings.cotypingMaxWords)
        guard let request = buildRequest(
            for: field, settings: topUp, generation: generation,
            memoryContext: activeMemoryContext.selection.text),
              let output = try? await engine.generate(request).text,
              let addition = CotypingSuggestionExtension.addition(from: output, to: session.fullText),
              seamVerdict(precedingText: field.precedingText, completion: addition) == .allow else {
            return nil
        }
        return addition
    }

    /// Appends `addition` to the visible suggestion if it is still the one the
    /// model continued. The session and the ghost change together or not at all,
    /// and only by the words the ghost has room to show.
    func applySuggestionExtension(
        _ addition: String,
        to original: CotypingSession,
        settings: AppSettings,
        work: UInt64
    ) async {
        guard var extended = extendedSession(adding: addition, to: original, settings: settings) else { return }
        var liveField: CotypingField?
        if !overlay.extendInline(
            to: extended.remainingText, emphasisLength: acceptEmphasisLength(for: extended.remainingText)) {
            // A popup or a wrapped ghost is laid out afresh, at the live caret,
            // and only once the app shows the words accepted so far.
            let focus = await focusTracker.refreshNow()
            guard work == extensionGeneration, !Task.isCancelled,
                  let refreshed = extendedSession(adding: addition, to: original, settings: settings),
                  let field = focus.field,
                  CotypingSessionReconciler.isContinuation(of: refreshed, liveField: field),
                  Self.trimmingTrailingSpace(field.precedingText)
                    .hasSuffix(Self.trimmingTrailingSpace(refreshed.acceptedText)) else { return }
            extended = refreshed
            liveField = field
        }
        session = extended
        suggestionAnchorCache.record(
            identityKey: CotypingFieldIdentity.suggestionAnchor(for: extended.field),
            requestFingerprint: activeSuggestionRequestFingerprint ?? "",
            precedingText: extended.field.precedingText,
            fullText: extended.fullText,
            isOpenEnded: extended.isOpenEnded)
        if let liveField {
            showSuggestion(extended.remainingText, on: liveField)
        } else {
            keepSessionToShownText()
            markReady(session?.remainingText ?? extended.remainingText)
        }
    }

    /// The session `addition` would produce, or nil when the visible
    /// suggestion is no longer the one that was continued.
    func extendedSession(
        adding addition: String,
        to original: CotypingSession,
        settings: AppSettings
    ) -> CotypingSession? {
        guard isRunning, let current = session, current.kind == .continuation,
              current.field == original.field, current.fullText == original.fullText,
              !current.isExhausted, overlay.isVisible,
              overlay.acceptanceText == current.remainingText else { return nil }
        var extended = CotypingSession(
            field: current.field, fullText: current.fullText + addition,
            consumedCount: current.consumedCount, kind: .continuation)
        extended.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(
            addition,
            wordLimit: CotypingSuggestionExtension.topUpWordLimit(wordLimit: settings.cotypingMaxWords))
        return extended
    }

    private static func trimmingTrailingSpace(_ text: String) -> Substring {
        var trimmed = text[...]
        while let last = trimmed.last, last == " " { trimmed = trimmed.dropLast() }
        return trimmed
    }
}
