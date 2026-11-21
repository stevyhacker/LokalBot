// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

nonisolated enum CotypingRenderMode: Equatable, Sendable {
    case inline
    case mirror(reason: MirrorReason)
    case withheld

    nonisolated enum MirrorReason: String, Equatable, Sendable {
        case caretGeometryEstimated
        case caretMidLine
        case userPreference
    }

    var isMirror: Bool { if case .mirror = self { true } else { false } }
}

enum CotypingMirrorPreference: String, Codable, Sendable {
    case auto
    case alwaysInline
    case alwaysMirror
}

nonisolated struct CotypingRenderModePolicy: Equatable, Sendable {
    var userPreference: CotypingMirrorPreference

    init(userPreference: CotypingMirrorPreference = .auto) {
        self.userPreference = userPreference
    }

    static func isCaretAtEndOfLine(trailingText: String) -> Bool {
        guard let first = trailingText.first else { return true }
        return first.isNewline
    }

    func mode(
        caretIsExact: Bool,
        isCaretAtEndOfLine: Bool,
        caretIsFoundOnScreen: Bool = false
    ) -> CotypingRenderMode {
        if !isCaretAtEndOfLine {
            return .mirror(reason: .caretMidLine)
        }
        return preferenceMode(caretIsExact: caretIsExact, caretIsFoundOnScreen: caretIsFoundOnScreen)
    }

    private func preferenceMode(caretIsExact: Bool, caretIsFoundOnScreen: Bool) -> CotypingRenderMode {
        switch userPreference {
        case .alwaysInline:
            return .inline
        case .alwaysMirror:
            return .mirror(reason: .userPreference)
        case .auto:
            if caretIsExact { return .inline }
            return caretIsFoundOnScreen ? .withheld : .mirror(reason: .caretGeometryEstimated)
        }
    }
}

struct CotypingOverlayPlacement: Equatable, Sendable {
    let caretIsExact: Bool
    let isCaretAtEndOfLine: Bool
    let preference: CotypingMirrorPreference
    var caretIsFoundOnScreen = false

    var mode: CotypingRenderMode {
        CotypingRenderModePolicy(userPreference: preference)
            .mode(caretIsExact: caretIsExact, isCaretAtEndOfLine: isCaretAtEndOfLine,
                  caretIsFoundOnScreen: caretIsFoundOnScreen)
    }

    static let inlineDefault = CotypingOverlayPlacement(caretIsExact: true, isCaretAtEndOfLine: true, preference: .auto)
}
