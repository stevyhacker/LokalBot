import AppKit
import Foundation

/// Deterministic sanitizer for auxiliary context that did not come from the
/// focused text field. Clipboard text often carries shell prompts, Markdown
/// fences, ANSI color escapes, and punctuation-heavy output that small local
/// models can copy back into suggestions.
enum CotypingPromptContextSanitizer {
    private static let ansiEscapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "@."))
    private static let replacementScalar = UnicodeScalar(" ")

    static func sanitize(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let withoutANSIEscapes = rawText.replacingOccurrences(
            of: ansiEscapePattern,
            with: " ",
            options: .regularExpression)

        let sanitizedScalars = withoutANSIEscapes.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacementScalar
        }
        let sanitizedText = String(String.UnicodeScalarView(sanitizedScalars))
        let normalizedLines = sanitizedText
            .components(separatedBy: .newlines)
            .map { collapseInlineWhitespace(in: $0) }
            .filter { !$0.isEmpty }

        let normalizedText = normalizedLines.joined(separator: "\n")
        let boundedText = maxCharacters.map { String(normalizedText.prefix($0)) } ?? normalizedText
        return boundedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        let words = text.lowercased().components(separatedBy: .alphanumerics.inverted)
        return Set(words.filter { $0.count >= minimumLength })
    }

    static func containsAlphanumericSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func collapseInlineWhitespace(in line: String) -> String {
        line.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Sanitized clipboard context folded into the cotyping prompt so the model can
/// "see" what was just copied — a trimmed port of Cotabby's clipboard context
/// (`ClipboardRelevanceFilter` + request-factory clipping). The sanitization,
/// bounding, relevance checks, and an "already-in-the-field" guard are pure
/// here; reading the pasteboard is a thin runtime wrapper
/// (`CotypingClipboardProvider`).
///
/// Enabled by default when cotyping runs; snippets may be memoized in memory for
/// one focused field/pasteboard state to keep the prompt prefix stable, but are
/// never persisted or logged.
enum CotypingClipboardContext {
    /// Hard cap on the snippet included in the prompt (mirrors Cotabby's 1_200).
    static let maxSnippetCharacters = 1_200
    private static let compactLineThreshold = 3
    private static let headFallbackCharacters = 300

    /// Sanitizes raw clipboard text: strips prompt-shaped noise, collapses
    /// inline whitespace, keeps meaningful line boundaries, and caps the length.
    /// Nil for empty, whitespace-only, or punctuation-only input.
    static func sanitize(_ raw: String?, maxCharacters: Int? = maxSnippetCharacters) -> String? {
        guard let raw else { return nil }
        let sanitized = CotypingPromptContextSanitizer.sanitize(raw, maxCharacters: maxCharacters)
        guard !sanitized.isEmpty,
              CotypingPromptContextSanitizer.containsAlphanumericSignal(sanitized)
        else {
            return nil
        }
        return sanitized
    }

    /// Whether a clipboard snippet is worth including: false when it is empty, or
    /// when it is already present in the text the user is typing (no point
    /// re-injecting what is already in the field — e.g. right after pasting it).
    static func shouldInclude(snippet: String?, precedingText: String) -> Bool {
        guard let snippet, !snippet.isEmpty else { return false }
        let normalizedSnippet = collapsedContainmentText(snippet)
        guard !normalizedSnippet.isEmpty else { return false }
        let normalizedPreceding = collapsedContainmentText(
            CotypingPromptContextSanitizer.sanitize(precedingText))
        return !normalizedPreceding.contains(normalizedSnippet)
    }

    /// Convenience: sanitize + guard → the snippet to include, or nil.
    static func resolve(rawClipboard: String?, precedingText: String,
                        maxCharacters: Int = maxSnippetCharacters) -> String? {
        guard let sanitized = sanitize(rawClipboard, maxCharacters: nil) else { return nil }
        let distilled = distill(clipboard: sanitized, prefixText: precedingText)
        guard let snippet = sanitize(distilled, maxCharacters: maxCharacters),
              shouldInclude(snippet: snippet, precedingText: precedingText) else { return nil }
        return snippet
    }

    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        CotypingPromptContextSanitizer.significantTokens(from: text, minimumLength: minimumLength)
    }

    /// Keep only the clipboard lines that share meaningful tokens with the
    /// current prefix. Short snippets pass through unchanged; long unrelated
    /// copies fall back to a small head sample rather than crowding the prompt.
    private static func distill(clipboard: String, prefixText: String) -> String {
        let lines = clipboard.components(separatedBy: "\n")
        guard lines.count > compactLineThreshold else { return clipboard }

        let prefixTokens = significantTokens(from: prefixText)
        guard !prefixTokens.isEmpty else { return clipboard }

        let relevantLines = lines.filter { line in
            let lineTokens = significantTokens(from: line)
            return !lineTokens.isDisjoint(with: prefixTokens)
        }
        guard !relevantLines.isEmpty else {
            return String(clipboard.prefix(headFallbackCharacters))
        }
        return relevantLines.joined(separator: "\n")
    }

    private static func collapsedContainmentText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// CoTabby-style gate for clipboard context. The first pasteboard observation is
/// treated as an unknown-age baseline, not a fresh copy. Only later copies made
/// during this app session can enter the prompt, and then only while fresh and
/// related to the typed prefix.
final class CotypingClipboardRelevanceFilter {
    static let staleThresholdSeconds: TimeInterval = 300

    private var lastKnownChangeCount: Int?
    private var lastChangeDate: Date?
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    func filter(
        rawClipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        guard let rawClipboard else { return nil }

        guard let baselineChangeCount = lastKnownChangeCount else {
            lastKnownChangeCount = pasteboardChangeCount
            return nil
        }

        if pasteboardChangeCount != baselineChangeCount {
            lastKnownChangeCount = pasteboardChangeCount
            lastChangeDate = dateProvider()
        }

        guard let lastChangeDate,
              dateProvider().timeIntervalSince(lastChangeDate) < Self.staleThresholdSeconds else {
            return nil
        }

        let clipboardTokens = CotypingClipboardContext.significantTokens(from: rawClipboard)
        let prefixTokens = CotypingClipboardContext.significantTokens(from: precedingText)
        guard !clipboardTokens.isEmpty,
              !clipboardTokens.isDisjoint(with: prefixTokens) else {
            return nil
        }

        return rawClipboard
    }

    func reset() {
        lastKnownChangeCount = nil
        lastChangeDate = nil
    }
}

/// One pinned, non-empty clipboard-context verdict for a focused field and a
/// pasteboard state. Nil verdicts are intentionally not represented: they add
/// nothing to the prompt and should re-evaluate as the user types more context.
nonisolated struct CotypingClipboardPrefaceMemo: Equatable, Sendable {
    let identityKey: String
    let changeCount: Int
    let value: String

    func valueIfReusable(identityKey: String, changeCount: Int) -> String? {
        guard self.identityKey == identityKey,
              self.changeCount == changeCount else { return nil }
        return value
    }
}

nonisolated struct CotypingClipboardPrefaceResolution: Equatable, Sendable {
    let value: String?
    let memo: CotypingClipboardPrefaceMemo?
}

enum CotypingClipboardPrefaceResolver {
    static func resolve(
        snapshot: CotypingClipboardSnapshot?,
        precedingText: String,
        identityKey: String,
        memo: CotypingClipboardPrefaceMemo?,
        relevanceFilter: CotypingClipboardRelevanceFilter
    ) -> CotypingClipboardPrefaceResolution {
        guard let snapshot else {
            relevanceFilter.reset()
            return CotypingClipboardPrefaceResolution(value: nil, memo: nil)
        }
        return resolve(rawClipboard: snapshot.text, pasteboardChangeCount: snapshot.changeCount,
                       precedingText: precedingText, identityKey: identityKey,
                       memo: memo, relevanceFilter: relevanceFilter)
    }

    static func resolve(
        rawClipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String,
        identityKey: String,
        memo: CotypingClipboardPrefaceMemo?,
        relevanceFilter: CotypingClipboardRelevanceFilter
    ) -> CotypingClipboardPrefaceResolution {
        if let pinned = memo?.valueIfReusable(
            identityKey: identityKey,
            changeCount: pasteboardChangeCount) {
            return CotypingClipboardPrefaceResolution(value: pinned, memo: memo)
        }

        guard let relevantClipboard = relevanceFilter.filter(
            rawClipboard: rawClipboard,
            pasteboardChangeCount: pasteboardChangeCount,
            precedingText: precedingText) else {
            return CotypingClipboardPrefaceResolution(value: nil, memo: nil)
        }

        guard let value = CotypingClipboardContext.resolve(
            rawClipboard: relevantClipboard,
            precedingText: precedingText) else {
            return CotypingClipboardPrefaceResolution(value: nil, memo: nil)
        }

        return CotypingClipboardPrefaceResolution(
            value: value,
            memo: CotypingClipboardPrefaceMemo(
                identityKey: identityKey,
                changeCount: pasteboardChangeCount,
                value: value))
    }
}

struct CotypingClipboardSnapshot: Equatable, Sendable {
    let changeCount: Int
    let text: String
}

/// Checks sensitivity markers before asking a pasteboard owner for any text.
/// A concurrent pasteboard change invalidates the entire observation.
@MainActor
final class CotypingClipboardProvider {
    private let readChangeCount: () -> Int
    private let readTypes: () -> [NSPasteboard.PasteboardType]?
    private let readText: () -> String?
    private static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.concealedtype", "org.nspasteboard.transienttype",
        "de.petermaurer.transientpasteboardtype", "com.agilebits.onepassword",
    ]

    convenience init(pasteboard: NSPasteboard = .general) {
        self.init(changeCount: { pasteboard.changeCount }, types: { pasteboard.types },
                  text: { pasteboard.string(forType: .string) })
    }

    init(changeCount: @escaping () -> Int,
         types: @escaping () -> [NSPasteboard.PasteboardType]?, text: @escaping () -> String?) {
        readChangeCount = changeCount
        readTypes = types
        readText = text
    }

    func snapshot() -> CotypingClipboardSnapshot? {
        let count = readChangeCount()
        guard let types = readTypes(), Self.allows(types),
              readChangeCount() == count, let text = readText(),
              let finalTypes = readTypes(), Self.allows(finalTypes),
              Set(finalTypes) == Set(types), readChangeCount() == count else { return nil }
        return CotypingClipboardSnapshot(changeCount: count, text: text)
    }

    private static func allows(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.string)
            && sensitiveTypes.isDisjoint(with: types.map { $0.rawValue.lowercased() })
    }
}
