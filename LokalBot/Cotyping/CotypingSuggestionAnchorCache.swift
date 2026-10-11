import CryptoKit
import Foundation

/// Bounded memory of recently shown continuation suggestions. It lets common
/// editing paths re-show the still-valid tail instantly, without debounce or a
/// model call: focus bounce, backspace rollback, and typing through a suggestion
/// after the active session was cleared.
nonisolated struct CotypingSuggestionAnchorCache {
    static let prefixTailLength = 256
    static let capacity = 16
    static let maxEntryAge: TimeInterval = 180

    private struct Anchor: Equatable {
        let identityKey: String
        let requestFingerprint: String
        let prefixTail: String
        let fullText: String
    }

    private struct Entry {
        let anchor: Anchor
        let recordedAt: Date
        let isOpenEnded: Bool
    }

    /// A still-valid tail, and whether the suggestion it came from may be
    /// topped up as it is accepted or typed through.
    struct Restoration: Equatable {
        let text: String
        let isOpenEnded: Bool
    }

    private struct Match {
        let remainder: String
        let consumed: Int
        let recordedAt: Date
        let isOpenEnded: Bool

        func beats(_ other: Match?) -> Bool {
            guard let other else { return true }
            if consumed != other.consumed { return consumed > other.consumed }
            return recordedAt > other.recordedAt
        }
    }

    private var entries: [Entry] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    mutating func record(
        identityKey: String,
        requestFingerprint: String,
        precedingText: String,
        fullText: String,
        isOpenEnded: Bool = false
    ) {
        guard !identityKey.isEmpty,
              !requestFingerprint.isEmpty,
              !fullText.isEmpty else { return }
        let anchor = Anchor(
            identityKey: identityKey,
            requestFingerprint: requestFingerprint,
            prefixTail: Self.tail(of: precedingText),
            fullText: fullText)
        entries.removeAll { $0.anchor == anchor }
        entries.append(Entry(anchor: anchor, recordedAt: now(), isOpenEnded: isOpenEnded))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func remainder(
        identityKey: String,
        requestFingerprint: String,
        precedingText: String
    ) -> String? {
        restoration(identityKey: identityKey, requestFingerprint: requestFingerprint,
                    precedingText: precedingText)?.text
    }

    mutating func restoration(
        identityKey: String,
        requestFingerprint: String,
        precedingText: String
    ) -> Restoration? {
        pruneExpired()
        let liveTail = Self.tail(of: precedingText)
        var best: Match?
        for entry in entries.reversed()
        where entry.anchor.identityKey == identityKey
            && entry.anchor.requestFingerprint == requestFingerprint {
            guard let consumed = Self.consumedPrefixLength(
                liveTail: liveTail,
                anchorTail: entry.anchor.prefixTail,
                fullText: entry.anchor.fullText)
            else { continue }
            let match = Match(
                remainder: String(entry.anchor.fullText.dropFirst(consumed)),
                consumed: consumed,
                recordedAt: entry.recordedAt,
                isOpenEnded: entry.isOpenEnded)
            if match.beats(best) {
                best = match
            }
        }
        guard let best else { return nil }
        return Restoration(text: best.remainder, isOpenEnded: best.isOpenEnded)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.maxEntryAge)
        entries.removeAll { $0.recordedAt < cutoff }
    }

    private static func consumedPrefixLength(
        liveTail: String,
        anchorTail: String,
        fullText: String
    ) -> Int? {
        let live = Array(liveTail)
        let composed = Array(anchorTail) + Array(fullText)
        let anchorCount = anchorTail.count

        for consumed in 0..<max(0, composed.count - anchorCount) {
            let end = anchorCount + consumed
            let start = max(0, end - prefixTailLength)
            guard end - start == live.count else { continue }
            if composed[start..<end].elementsEqual(live) {
                return consumed
            }
        }
        return nil
    }

    private static func tail(of text: String) -> String {
        String(text.suffix(prefixTailLength))
    }
}

/// Stable, deterministic identity for the parts of a generation request that
/// are allowed to outlive the active session in `CotypingSuggestionAnchorCache`.
/// The live caret prefix is intentionally excluded: typing through a displayed
/// suggestion is exactly what the cache accelerates. Everything else that can
/// change the model or its output is included.
enum CotypingSuggestionCacheFingerprint {
    static func make(request: CotypingRequest, settings: AppSettings) -> String {
        let selectedModel = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels)
            ?? ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID)

        let personalization = settings.cotypingPersonalization
        let components: [String] = [
            settings.cotypingBuiltInModelID,
            selectedModel?.id ?? "",
            selectedModel?.fileName ?? "",
            selectedModel?.url ?? "",
            selectedModel?.expectedSHA256 ?? "",
            selectedModel?.expectedSizeBytes.map(String.init) ?? "",
            settings.cotypingInProcessRuntime ? "local" : "http",
            settings.cotypingUseClipboard ? "clipboard:on" : "clipboard:off",
            settings.cotypingUseLocalLearning ? "learning:on" : "learning:off",
            settings.cotypingUseMeetingMemory ? "meeting-memory:on" : "meeting-memory:off",
            settings.cotypingUseScreenMemory ? "screen-memory:on" : "screen-memory:off",
            String(settings.cotypingLearningExamplesInPrompt),
            personalization.userName ?? "",
            personalization.styleNote ?? "",
            personalization.languageHint ?? "",
            personalization.isMultiLine ? "multiline" : "singleline",
            personalization.appContextEnabled ? "app-context:on" : "app-context:off",
            personalization.extendedContext ?? "",
            request.conditioningPreface ?? "",
            request.trailingText,
            request.isMultiLine ? "multiline" : "singleline",
            String(request.maxTokens),
            String(request.maxWords),
            String(request.temperature.bitPattern),
            String(request.topP.bitPattern),
            String(request.topK),
            String(request.minP.bitPattern),
            String(request.repeatPenalty.bitPattern),
            String(request.seed),
        ]

        // Length-prefix every component so embedded separators cannot collide.
        let payload = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
