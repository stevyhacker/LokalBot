import Foundation

extension CotypingCoordinator {
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
