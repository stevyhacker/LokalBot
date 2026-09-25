import Foundation

/// Builds the focused-element key used to authorize a consuming accept. AX
/// identifiers are app-provided labels and are not required to be unique (for
/// example, repeated SwiftUI rows can expose the same identifier). Pairing that
/// label with the concrete AX element hash keeps two same-text fields from
/// authorizing each other's synthetic edit.
enum CotypingAXFocusIdentityKey {
    static func make(
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?,
        axIdentifier: String?,
        elementHash: UInt
    ) -> String {
        let identifier = axIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        return [
            String(processID),
            bundleID ?? "",
            role,
            subrole ?? "",
            "id:\(identifier)",
            "cf:\(elementHash)",
        ].joined(separator: "\u{1f}")
    }
}

struct CotypingAcceptanceContentRanges: Equatable, Sendable {
    let preceding: NSRange
    let trailing: NSRange
}

struct CotypingTextContext: Equatable, Sendable {
    let preceding: String
    let trailing: String
    let precedingIsTruncated: Bool
}

/// Pure bounds for accept-time text reads. The event tap never needs the whole
/// host document: it only needs the same 4,096/1,024 UTF-16 windows carried by
/// `CotypingField`. Hosts that cannot provide bounded ranges are eligible for a
/// whole-value fallback only when AX first proves the entire value is no larger
/// than those windows combined.
enum CotypingAcceptanceContentBounds {
    static let maximumPrecedingUTF16Length = 4_096
    static let maximumTrailingUTF16Length = 1_024
    static let maximumWholeValueUTF16Length =
        maximumPrecedingUTF16Length + maximumTrailingUTF16Length

    static func ranges(
        selection: NSRange,
        totalUTF16Length: Int
    ) -> CotypingAcceptanceContentRanges? {
        guard totalUTF16Length >= 0,
              selection.location >= 0,
              selection.length == 0,
              selection.location <= totalUTF16Length else {
            return nil
        }
        let precedingLength = min(selection.location, maximumPrecedingUTF16Length)
        let trailingLength = min(
            totalUTF16Length - selection.location,
            maximumTrailingUTF16Length)
        return CotypingAcceptanceContentRanges(
            preceding: NSRange(
                location: selection.location - precedingLength,
                length: precedingLength),
            trailing: NSRange(
                location: selection.location,
                length: trailingLength))
    }

    static func returnedTextMatchesRequestedRanges(
        precedingText: String,
        trailingText: String,
        ranges: CotypingAcceptanceContentRanges
    ) -> Bool {
        (precedingText as NSString).length == ranges.preceding.length
            && (trailingText as NSString).length == ranges.trailing.length
    }

    static func allowsWholeValueFallback(totalUTF16Length: Int) -> Bool {
        (0...maximumWholeValueUTF16Length).contains(totalUTF16Length)
    }

    /// Prediction and acceptance apply this same policy to identical UTF-16
    /// ranges. Discard the outermost grapheme of a clipped range: AX can cut a
    /// surrogate pair, combining sequence, or joined emoji at that boundary.
    static func context(precedingText: String, trailingText: String,
                        ranges: CotypingAcceptanceContentRanges,
                        totalUTF16Length: Int) -> CotypingTextContext {
        let precedingIsTruncated = ranges.preceding.location > 0
        let trailingIsTruncated = NSMaxRange(ranges.trailing) < totalUTF16Length
        return CotypingTextContext(
            preceding: precedingIsTruncated ? String(precedingText.dropFirst()) : precedingText,
            trailing: trailingIsTruncated ? String(trailingText.dropLast()) : trailingText,
            precedingIsTruncated: precedingIsTruncated)
    }

    static func context(in value: String, selection: NSRange) -> CotypingTextContext? {
        let text = value as NSString
        guard let ranges = ranges(selection: selection, totalUTF16Length: text.length) else { return nil }
        return context(precedingText: text.substring(with: ranges.preceding),
                       trailingText: text.substring(with: ranges.trailing),
                       ranges: ranges, totalUTF16Length: text.length)
    }
}

/// Hard ceiling for deletion bursts posted from the consuming event tap. Every
/// deleted grapheme creates and posts a down/up event pair, so an unbounded typo
/// or overlap could otherwise trigger the event-tap watchdog before the original
/// key can fail open.
enum CotypingSyntheticEditPolicy {
    static let maximumBackwardDeletionCount = 64
    static let maximumForwardDeletionCount = 64

    static func allowsBackwardDeletion(_ count: Int) -> Bool {
        (0...maximumBackwardDeletionCount).contains(count)
    }

    static func allowsForwardDeletion(_ count: Int) -> Bool {
        (0...maximumForwardDeletionCount).contains(count)
    }
}

/// Whether the currently focused input reports an active marked-text range.
/// `unknown` is distinct from `inactive`: some third-party editors expose no
/// marked-text Accessibility attribute at all.
enum CotypingMarkedTextState: Equatable, Sendable {
    case active
    case inactive
    case unknown
}
/// Minimal live state needed by the consuming accept tap. Unlike a prediction
/// snapshot, this deliberately omits geometry, style, window, URL, DOM, and
/// ancestor-tree reads so a slow host cannot keep the global keyboard event in
/// the tap callback for an unbounded Accessibility walk.
struct CotypingAXAcceptanceSnapshot: Sendable {
    let field: CotypingField?
    let markedTextState: CotypingMarkedTextState
    /// True only when a live collapsed selection and bounded surrounding-text
    /// ranges were both read at accept time. Identity-only validation is
    /// insufficient even for continuations: a mouse selection can change without
    /// crossing the keyboard observer, causing a synthetic Unicode insert to
    /// overwrite newly selected text.
    let hasLiveContent: Bool
}

/// Fail-closed policy for deciding whether a bounded accept-time snapshot is
/// trustworthy enough to consume the user's key. Rejection itself is fail-open
/// for the keyboard: the original event passes through to the host unchanged.
enum CotypingAcceptanceSnapshotPolicy {
    static func canAccept(
        markedTextState: CotypingMarkedTextState,
        composingInputModeActive: Bool,
        hasLiveContent: Bool,
        selectionLength: Int?
    ) -> Bool {
        guard hasLiveContent, selectionLength == 0, markedTextState != .active else { return false }
        // Tab may belong to an IME's candidate UI even when the host currently
        // reports an inactive marked range. A composing (or unknown) input
        // source therefore always passes the original key through untouched.
        return !composingInputModeActive
    }
}

/// Pure authorization rule for the AX hit-test fallback. Hit-testing describes
/// what is under the pointer, not what will receive keyboard input, so every
/// candidate must independently prove ownership, editability, and focus.
enum CotypingAXHitTestFocusValidator {
    static func canUseCandidate(
        frontmostProcessID: pid_t?,
        expectedProcessID: pid_t,
        candidateProcessID: pid_t?,
        isEditable: Bool,
        isFocused: Bool
    ) -> Bool {
        guard expectedProcessID > 0,
              frontmostProcessID == expectedProcessID,
              candidateProcessID == expectedProcessID else {
            return false
        }
        return isEditable && isFocused
    }
}
