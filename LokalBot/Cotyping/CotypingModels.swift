import CoreGraphics
import Foundation

// Cotyping — LokalBot's third major feature: on-device, inline AI autocomplete
// in (almost) any macOS text field, reusing the same local LLM backend that
// powers summarization. Modeled on Cotabby's suggestion pipeline but driven by
// LokalBot's HTTP `llama-server` (`/v1/completions`) instead of in-process
// llama.cpp.
//
// This file holds the value types shared across the cotyping subsystem. They
// are deliberately `Sendable` value types so they can cross the async /
// main-actor boundaries the pipeline runs over (focus poll → debounce →
// generation → overlay → acceptance) without aliasing live AX handles.

/// Whether the currently focused element can host a suggestion.
enum CotypingCapability: Equatable, Sendable {
    /// An editable text field with a collapsed caret — suggestions allowed.
    case supported
    /// Editable, but a suggestion is intentionally withheld (secure field, or a
    /// non-empty selection). The string is a short human-readable reason.
    case blocked(String)
    /// Not an editable text field we can drive (button, web link, image, …).
    case unsupported(String)
}

/// A value-type snapshot of the focused editable field. Produced by
/// `CotypingAXHelper`/`CotypingFocusTracker` from a synchronous Accessibility
/// read and then carried, unaliased, through the rest of the pipeline.
struct CotypingField: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var processID: pid_t
    var role: String
    /// Stable-enough identity for short-lived focus smoothing. This is not part
    /// of the content signature because host apps may recycle AX element handles.
    var focusIdentityKey: String?
    /// Bounded text immediately before the caret (newest text at the end).
    var precedingText: String
    /// Bounded text immediately after the caret (used by the trailing-duplication filter).
    var trailingText: String
    /// 0 means a collapsed caret; >0 means an active selection (suppresses suggestions).
    var selectionLength: Int
    /// Caret rectangle in global Cocoa coordinates (bottom-left origin, already
    /// Y-flipped against the primary display in `CotypingAXHelper`).
    var caretRect: CGRect
    /// Focused editable element bounds in global Cocoa coordinates, when AX
    /// exposes them. Inline ghost layout uses this as the wrapping budget.
    var inputFrameRect: CGRect?
    /// True for password / secure-entry fields — never read or suggested into.
    var isSecure: Bool
    /// True when the focused web text field is an xterm.js terminal surface
    /// embedded inside a non-terminal host like VS Code, Cursor, or a browser.
    var isIntegratedTerminal: Bool = false
    /// `true` when the caret rect came from an exact AX range query; `false`
    /// when it was estimated from the field frame (lower placement confidence).
    var caretIsExact: Bool
    /// The focused window's title (email subject, doc name, chat channel, page
    /// title) when app-context is enabled — the strongest topic cue we get.
    var windowTitle: String?
    /// The field's placeholder / label (e.g. "To:", "Search", "Message #general").
    var fieldPlaceholder: String?
    /// The field's own font/color (resolved from AX, cached per element) when
    /// host-style matching is enabled, so the ghost can mimic the field.
    var fieldStyle: CotypingFieldStyle?
    /// The leading edge was clipped by the shared UTF-16 context policy.
    var precedingTextIsTruncated: Bool = false
    /// Hash of a positively identified document, never inferred from a recipient
    /// name or generic window title. Nil means local learning must abstain.
    var learningScopeKey: String?

    /// Content-only fingerprint used to detect "did the field actually change"
    /// across keystrokes and to drop stale async generations. Excludes the AX
    /// element identity on purpose: web engines recycle element handles.
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

/// The focus tracker's published result: which app is focused, whether we can
/// suggest there, and (when supported) the field snapshot.
struct CotypingFocus: Equatable, Sendable {
    var appName: String
    var bundleID: String?
    var capability: CotypingCapability
    var field: CotypingField?
    /// Identity of the focused editable element when it can be read without
    /// exposing text. Used for transient capability smoothing while blocked
    /// snapshots intentionally omit a full field payload.
    var focusIdentityKey: String?
    /// Normalized host of the focused tab's URL (browsers only), read over AX when
    /// per-domain rules are configured. Nil otherwise. Used only for site gating.
    var host: String?

    static let none = CotypingFocus(
        appName: "", bundleID: nil,
        capability: .unsupported("No focused text field."), field: nil)
}

/// Sampling + windowing knobs for one generation. Defaults mirror Cotabby's
/// shipped `SuggestionConfiguration.standard` (low temperature for stable inline
/// completions); the fixed seed keeps identical context reproducible.
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
        maxPrefixWords: 150,
        maxResponseTokens: 26,
        maxResponseWords: 20,
        temperature: 0.1,
        topP: 0.7,
        topK: 20,
        minP: 0.08,
        repeatPenalty: 1.05,
        // 0x00C0FFEE — Cotabby's "coffee" sampler seed; stable so the same
        // context yields the same ghost text.
        seed: 0x00C0_FFEE)
}

/// One generation request handed to `CotypingCompleting`. Carries everything the
/// engine needs to call the model AND everything `CotypingTextNormalizer` needs
/// to clean the result, so the normalizer stays a pure function of the request.
struct CotypingRequest: Sendable, Equatable {
    /// The full rendered prompt (optional conditioning preface + caret prefix).
    let prompt: String
    /// The windowed caret prefix alone (used to strip prefix echoes from output).
    let prefixText: String
    /// Text after the caret (used by the trailing-duplication filter).
    let trailingText: String
    /// When `false`, the normalizer keeps only the first line of the completion.
    let isMultiLine: Bool
    let maxTokens: Int
    /// User-facing word ceiling for one suggestion. The normalizer enforces this
    /// after model output so token-budget drift cannot make the setting lie.
    var maxWords: Int = CotypingConfiguration.standard.maxResponseWords
    let temperature: Double
    let topP: Double
    let topK: Int
    let minP: Double
    let repeatPenalty: Double
    let seed: Int
    /// Monotonic freshness token — the coordinator drops results whose
    /// generation no longer matches the live focus.
    let generation: UInt64
    /// True when the caret is strictly inside a word (Cotabby's
    /// `forceWordContinuation`): the completion must continue the current word.
    /// Enforced at the output layer by `CotypingTextNormalizer`.
    var forceWordContinuation: Bool = false

    /// The run of word characters immediately before the caret ("" at a word
    /// boundary). When non-empty the user is mid-word and the completion should
    /// extend this fragment: the in-process runtime heals the prompt at the
    /// word boundary and decodes with this as a required prefix; the normalizer
    /// uses it to reject continuations that ignore the fragment.
    var wordPrefixAtCaret: String = ""

    /// Whether `wordPrefixAtCaret` is itself a valid standalone word (per the
    /// native spell checker). A valid word ("the") may legitimately be followed
    /// by a space; an invalid fragment ("follo") must be extended, so a
    /// whitespace-leading completion is rejected. Defaults permissive.
    var wordPrefixIsValidWord: Bool = true

    /// Exact hidden conditioning preface included in `prompt`, after renderer
    /// truncation. This never reaches the UI; the normalizer uses it solely to
    /// recognize and suppress prompt-context echoes, including streamed prefixes.
    var conditioningPreface: String?

    /// `true` when the caret prefix ends on whitespace, so the normalizer drops
    /// a leading space the model may add (deterministic space management).
    var precedingEndsWithWhitespace: Bool {
        prefixText.last.map { $0.isWhitespace } ?? false
    }
}

/// What an active suggestion does when accepted.
enum CotypingSuggestionKind: Equatable, Sendable {
    /// Append a continuation of the current text (the normal case).
    case continuation
    /// Replace the misspelled `typoWord` just before the caret with `fullText`.
    case correction(typoWord: String)
    /// Replace the trailing `:shortcode` token with the emoji glyph (`fullText`).
    case emoji(shortcode: String)
    /// Replace the trailing `/query` run with the already-previewed macro result
    /// (`fullText`). Keeping the exact query prevents a stale session from acting
    /// on a different macro and avoids re-rolling random macros during accept.
    case macro(query: String)
}

/// An active suggestion: the field it was generated against, the full completion,
/// and how much of it the user has already accepted (in Characters). Accepting a
/// word advances `consumedCount`; the overlay then shows only `remainingText`.
struct CotypingSession: Equatable, Sendable {
    let field: CotypingField
    let fullText: String
    var consumedCount: Int = 0
    /// Continuation vs typo correction — drives how `accept` applies it.
    var kind: CotypingSuggestionKind = .continuation

    var acceptedText: String { String(fullText.prefix(consumedCount)) }
    var remainingText: String { String(fullText.dropFirst(consumedCount)) }
    var isExhausted: Bool { consumedCount >= fullText.count }

    func advanced(by count: Int) -> CotypingSession {
        var copy = self
        copy.consumedCount = min(fullText.count, consumedCount + count)
        return copy
    }
}

/// The consuming event tap may own an accept key only while there is a visible
/// suggestion backed by a live session. In particular, generation in flight is
/// never enough: swallowing Tab while no suggestion is visible breaks ordinary
/// keyboard navigation and can accept output the user has not reviewed.
enum CotypingAcceptanceOwnershipPolicy {
    static func shouldOwnAcceptKey(overlayIsVisible: Bool, hasSession: Bool) -> Bool {
        overlayIsVisible && hasSession
    }
}

/// Coordinator-published state for cotyping lifecycle and diagnostics.
enum CotypingState: Equatable, Sendable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String)
    case failed(String)
}
