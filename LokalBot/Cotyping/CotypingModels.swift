import CoreGraphics
import Foundation

enum CotypingCapability: Equatable, Sendable {
    case supported
    case blocked(String)
    case unsupported(String)
}

struct CotypingField: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var processID: pid_t
    var role: String
    var focusIdentityKey: String?
    var precedingText: String
    var trailingText: String
    var selectionLength: Int
    var caretRect: CGRect
    var inputFrameRect: CGRect?
    var isSecure: Bool
    var isIntegratedTerminal: Bool = false
    var caretIsExact: Bool
    var windowTitle: String?
    var fieldPlaceholder: String?
    var fieldStyle: CotypingFieldStyle?
    var precedingTextIsTruncated: Bool = false
    var learningScopeKey: String?
    var visibleContext: CotypingVisibleContext.Snapshot?
    var visibleContextWasRequested: Bool = false
    var selectionSkipsParagraphBreaks: Bool = false

    var contentSignature: String {
        [
            String(selectionLength),
            precedingText,
            trailingText,
            isSecure ? "secure" : "plain",
            isIntegratedTerminal ? "terminal" : "text"
        ]
            .joined(separator: "\u{1f}")
    }
}

struct CotypingFocus: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var capability: CotypingCapability
    var field: CotypingField?
    var focusIdentityKey: String?
    var host: String?

    static let none = CotypingFocus(
        appName: "", bundleID: nil,
        capability: .unsupported("No focused text field."), field: nil)
}

struct CotypingConfiguration: Sendable, Equatable {
    var maxPrefixCharacters: Int
    var maxPrefixWords: Int
    var maxResponseTokens: Int
    var maxResponseWords: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repeatPenalty: Double
    var seed: Int

    static let standard = CotypingConfiguration(
        maxPrefixCharacters: 2500,
        maxPrefixWords: 500,
        maxResponseTokens: 26,
        maxResponseWords: 20,
        temperature: 0.1,
        topP: 0.7,
        topK: 20,
        minP: 0.08,
        repeatPenalty: 1.05,
        seed: 0x00C0_FFEE)
}

struct CotypingRequest: Sendable, Equatable {
    let prompt: String
    let prefixText: String
    let trailingText: String
    let isMultiLine: Bool
    let maxTokens: Int
    var maxWords: Int = CotypingConfiguration.standard.maxResponseWords
    let temperature: Double
    let topP: Double
    let topK: Int
    let minP: Double
    let repeatPenalty: Double
    let seed: Int
    let generation: UInt64
    var forceWordContinuation: Bool = false

    var wordPrefixAtCaret: String = ""

    var wordPrefixIsValidWord: Bool = true

    var conditioningPreface: String?

    var precedingEndsWithWhitespace: Bool {
        prefixText.last.map { $0.isWhitespace } ?? false
    }
}

enum CotypingSuggestionKind: Equatable, Sendable {
    case continuation
    case correction(typoWord: String)
    case emoji(shortcode: String)
    case macro(query: String)
}

struct CotypingSession: Equatable, Sendable {
    let field: CotypingField
    let fullText: String
    var consumedCount: Int = 0
    var kind: CotypingSuggestionKind = .continuation
    var isOpenEnded = false

    var acceptedText: String { String(fullText.prefix(consumedCount)) }
    var remainingText: String { String(fullText.dropFirst(consumedCount)) }
    var isExhausted: Bool { consumedCount >= fullText.count }

    func advanced(by count: Int) -> CotypingSession {
        var copy = self
        copy.consumedCount = min(fullText.count, consumedCount + count)
        return copy
    }
}

enum CotypingAcceptanceOwnershipPolicy {
    static func shouldOwnAcceptKey(overlayIsVisible: Bool, hasSession: Bool) -> Bool {
        overlayIsVisible && hasSession
    }
}

enum CotypingState: Equatable, Sendable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String)
    case failed(String)
}
