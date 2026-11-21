import Foundation

struct CotypingContinuationAcceptance: Equatable, Sendable {
    struct Options: Equatable, Sendable {
        var granularity: CotypingAcceptGranularity = .word
        var autoAcceptTrailingPunctuation = false
        var addSpaceAfterAccept = false

        init(granularity: CotypingAcceptGranularity = .word,
             autoAcceptTrailingPunctuation: Bool = false,
             addSpaceAfterAccept: Bool = false) {
            self.granularity = granularity
            self.autoAcceptTrailingPunctuation = autoAcceptTrailingPunctuation
            self.addSpaceAfterAccept = addSpaceAfterAccept
        }

        init(settings: AppSettings) {
            granularity = settings.cotypingAcceptGranularity
            autoAcceptTrailingPunctuation = settings.cotypingAutoAcceptTrailingPunctuation
            addSpaceAfterAccept = settings.cotypingAddSpaceAfterAccept
        }
    }

    let acceptedChunk: String
    let insertionText: String
    let forwardDeleteCount: Int

    static func plan(
        session: CotypingSession,
        scope: CotypingAcceptScope,
        precedingText: String,
        trailingText: String,
        options: Options
    ) -> CotypingContinuationAcceptance? {
        let remaining = session.remainingText
        let baseChunk: String
        switch scope {
        case .whole:
            baseChunk = remaining
        case .chunk:
            switch options.granularity {
            case .word:
                baseChunk = CotypingAcceptanceChunker.nextWord(
                    in: remaining,
                    autoAcceptTrailingPunctuation: options.autoAcceptTrailingPunctuation)
            case .phrase:
                baseChunk = CotypingAcceptanceChunker.nextPhrase(
                    in: remaining,
                    autoAcceptTrailingPunctuation: options.autoAcceptTrailingPunctuation)
            }
        }
        let acceptedChunk = options.addSpaceAfterAccept
            ? CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(baseChunk, remainingText: remaining)
            : baseChunk
        guard !acceptedChunk.isEmpty else { return nil }
        let insertionChunk = CotypingAcceptanceChunker.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: precedingText)
        let insertionText = CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
            insertionChunk: insertionChunk,
            acceptedChunk: acceptedChunk,
            session: session,
            addSpaceAfterAccept: options.addSpaceAfterAccept)
        let forwardDeleteCount = CotypingMidWord.shouldForceContinuation(
            precedingText: precedingText,
            trailingText: trailingText)
            ? CotypingMidWord.acceptedTrailingOverlapCount(
                acceptedText: insertionText,
                trailingText: trailingText)
            : 0
        return CotypingContinuationAcceptance(
            acceptedChunk: acceptedChunk,
            insertionText: insertionText,
            forwardDeleteCount: forwardDeleteCount)
    }
}

struct CotypingRehearsal: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case unchanged
        case advanced
        case stale
    }

    private(set) var session: CotypingSession?
    private(set) var anchor = ""

    var ghost: String { session?.remainingText ?? "" }

    mutating func present(_ suggestion: String, after text: String, wordLimit: Int? = nil) {
        guard !suggestion.isEmpty else {
            dismiss()
            return
        }
        var fresh = CotypingSession(field: Self.field(precedingText: text), fullText: suggestion)
        if let wordLimit {
            fresh.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(suggestion, wordLimit: wordLimit)
        }
        session = fresh
        anchor = text
    }

    func topUpPrefix(wordLimit: Int) -> String? {
        guard let session, CotypingSuggestionExtension.shouldExtend(session, wordLimit: wordLimit) else { return nil }
        return CotypingSuggestionExtension.continuationPrefix(of: session)
    }

    mutating func topUp(with output: String, continuing prefix: String, wordLimit: Int) -> Bool {
        guard let current = session,
              CotypingSuggestionExtension.continuationPrefix(of: current) == prefix,
              let addition = CotypingSuggestionExtension.addition(from: output, to: current.fullText) else {
            return false
        }
        var extended = CotypingSession(
            field: current.field, fullText: current.fullText + addition,
            consumedCount: current.consumedCount)
        extended.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(
            addition, wordLimit: CotypingSuggestionExtension.topUpWordLimit(wordLimit: wordLimit))
        session = extended
        return true
    }

    mutating func dismiss() {
        session = nil
        anchor = ""
    }

    mutating func accept(
        _ scope: CotypingAcceptScope,
        text: String,
        options: CotypingContinuationAcceptance.Options
    ) -> String? {
        guard let current = session, text == anchor,
              let acceptance = CotypingContinuationAcceptance.plan(
                session: current, scope: scope, precedingText: text, trailingText: "",
                options: options) else { return nil }
        let updated = text + acceptance.insertionText
        let advanced = current.advanced(by: acceptance.acceptedChunk.count)
        if advanced.isExhausted {
            dismiss()
        } else {
            session = advanced
            anchor = updated
        }
        return updated
    }

    mutating func textChanged(to text: String) -> Change {
        guard let current = session else { return .stale }
        if text == anchor { return .unchanged }
        guard text.hasPrefix(anchor),
              let advanced = CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
                current, typedCharacters: String(text.dropFirst(anchor.count))),
              !advanced.isExhausted else {
            dismiss()
            return .stale
        }
        session = advanced
        anchor = text
        return .advanced
    }

    private static func field(precedingText: String) -> CotypingField {
        CotypingField(
            appName: "LokalBot", bundleID: nil, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
    }
}
