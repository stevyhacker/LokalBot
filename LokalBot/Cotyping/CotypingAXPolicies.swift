import ApplicationServices
import Foundation

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

enum CotypingSearchFieldDetector {
    static func isSearchField(role: String, subrole: String?) -> Bool {
        role == "AXSearchField" || subrole == "AXSearchField"
    }
}

enum CotypingFileDialogDetector {
    static let panelWindowIdentifiers: Set<String> = ["save-panel", "open-panel"]

    static func isFileDialog(windowIdentifiers: [String?]) -> Bool {
        windowIdentifiers.contains { identifier in
            identifier.map(panelWindowIdentifiers.contains) ?? false
        }
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

enum CotypingMarkedTextState: Equatable, Sendable {
    case active
    case inactive
    case unknown
}
struct CotypingAXAcceptanceSnapshot: Sendable {
    let field: CotypingField?
    let markedTextState: CotypingMarkedTextState
    let hasLiveContent: Bool
}

enum CotypingAcceptanceSnapshotPolicy {
    static func canAccept(
        markedTextState: CotypingMarkedTextState,
        composingInputModeActive: Bool,
        hasLiveContent: Bool,
        selectionLength: Int?
    ) -> Bool {
        guard hasLiveContent, selectionLength == 0, markedTextState != .active else { return false }
        return !composingInputModeActive
    }
}

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

enum CotypingEnhancedAccessibilityRequest {
    static func wasDelivered(_ result: AXError) -> Bool {
        result != .cannotComplete
    }
}
