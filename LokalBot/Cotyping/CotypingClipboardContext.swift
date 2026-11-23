// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 24 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

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

enum CotypingClipboardContext {
    static let maxSnippetCharacters = 1_200
    private static let compactLineThreshold = 3
    private static let headFallbackCharacters = 300

    static func sanitize(_ raw: String?, maxCharacters: Int? = maxSnippetCharacters) -> String? {
        guard let raw, let scrubbed = droppingCredentialLines(from: raw) else { return nil }
        let sanitized = CotypingPromptContextSanitizer.sanitize(scrubbed, maxCharacters: maxCharacters)
        guard !sanitized.isEmpty,
              CotypingPromptContextSanitizer.containsAlphanumericSignal(sanitized)
        else {
            return nil
        }
        return sanitized
    }

    private static func droppingCredentialLines(from raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let keptLines = raw
            .components(separatedBy: .newlines)
            .filter { ScreenContextPrivacy.redact($0).count == 0 }
        guard !keptLines.isEmpty else { return nil }
        let joined = keptLines.joined(separator: "\n")
        guard ScreenContextPrivacy.redact(joined).count == 0 else { return nil }
        return joined
    }

    static func shouldInclude(snippet: String?, precedingText: String) -> Bool {
        guard let snippet, !snippet.isEmpty else { return false }
        let normalizedSnippet = collapsedContainmentText(snippet)
        guard !normalizedSnippet.isEmpty else { return false }
        let normalizedPreceding = collapsedContainmentText(
            CotypingPromptContextSanitizer.sanitize(precedingText))
        return !normalizedPreceding.contains(normalizedSnippet)
    }

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

@MainActor
final class CotypingClipboardProvider {
    private let readChangeCount: () -> Int
    private let readTypes: () -> [NSPasteboard.PasteboardType]?
    private let readText: () -> String?
    private static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.concealedtype", "org.nspasteboard.transienttype",
        "org.nspasteboard.autogeneratedtype", "de.petermaurer.transientpasteboardtype",
        "com.agilebits.onepassword", "net.antelle.keeweb",
        "com.typeit4me.clipping", "com.lastpass.lastpass",
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
