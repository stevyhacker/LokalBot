import CoreGraphics
import Foundation

enum CotypingAcceptGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case word
    case phrase

    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: "One word"
        case .phrase: "One phrase"
        }
    }
}

enum CotypingAcceptKey: Int, Codable, CaseIterable, Identifiable, Sendable {
    case tab = 48
    case rightArrow = 124

    var id: Int { rawValue }
    var keyCode: CGKeyCode { CGKeyCode(rawValue) }
    var label: String {
        switch self {
        case .tab: "Tab"
        case .rightArrow: "Right Arrow"
        }
    }
}

enum CotypingFullAcceptKey: Int, Codable, CaseIterable, Identifiable, Sendable {
    case backtick = 50
    case rightArrow = 124
    case doubleTap = -2
    case off = -1

    var id: Int { rawValue }
    var keyCode: CGKeyCode? {
        switch self {
        case .backtick, .rightArrow: CGKeyCode(rawValue)
        case .doubleTap, .off: nil
        }
    }
    var label: String? {
        switch self {
        case .backtick: "`"
        case .rightArrow: "Right Arrow"
        case .doubleTap: "Double-tap"
        case .off: nil
        }
    }
    var pickerLabel: String {
        switch self {
        case .backtick: "` (Backtick)"
        case .rightArrow: "Right Arrow"
        case .doubleTap: "Double-tap accept key"
        case .off: "Off"
        }
    }
}

struct CotypingDoubleTapAcceptanceState: Equatable, Sendable {
    static let windowSeconds: TimeInterval = 0.3

    private var lastAcceptedKey: String?
    private var lastAcceptedAt: TimeInterval?

    mutating func reset() {
        lastAcceptedKey = nil
        lastAcceptedAt = nil
    }

    mutating func resolveScope(
        requested: CotypingAcceptScope,
        fullAcceptKey: CotypingFullAcceptKey,
        suggestionKey: String,
        now: TimeInterval,
        isRepeat: Bool = false
    ) -> CotypingAcceptScope {
        guard requested == .chunk, fullAcceptKey == .doubleTap else {
            reset()
            return requested
        }
        if isRepeat {
            reset()
            return .chunk
        }
        if let previousKey = lastAcceptedKey,
           let previousAt = lastAcceptedAt,
           previousKey == suggestionKey,
           now >= previousAt,
           now - previousAt <= Self.windowSeconds {
            reset()
            return .whole
        }
        lastAcceptedKey = suggestionKey
        lastAcceptedAt = now
        return .chunk
    }
}

enum CotypingTabFormNavigationPolicy {
    static func shouldPassTabToHost(
        enabled: Bool,
        acceptKey: CotypingAcceptKey,
        scope: CotypingAcceptScope,
        fieldRole: String,
        bundleID: String?
    ) -> Bool {
        guard enabled, acceptKey == .tab, scope == .chunk else { return false }
        guard fieldRole == "AXTextField" || fieldRole == "AXComboBox" else { return false }
        let surface = CotypingSurfaceClassifier.classify(bundleID: bundleID)
        guard surface != .chat, surface != .codeEditor else { return false }
        return !CotypingAXHelper.isElectronEditor(bundleID: bundleID)
    }
}

enum CotypingEscapeBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case pause
    case passThrough

    static let pauseSeconds: TimeInterval = 10

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pause: "Dismiss and pause briefly"
        case .passThrough: "Dismiss and send Escape to the app"
        }
    }
}

enum CotypingAcceptScope: Sendable {
    case chunk
    case whole
}

enum CotypingAcceptHint {
    static func text(acceptKey: CotypingAcceptKey, fullAcceptKey: CotypingFullAcceptKey,
                     granularity: CotypingAcceptGranularity) -> String {
        var parts = ["\(acceptKey.label) accepts the next \(granularity == .word ? "word" : "phrase")"]
        if fullAcceptKey == .doubleTap {
            parts.append("Double-tap \(acceptKey.label) accepts the rest")
        } else if let full = fullAcceptKey.label, fullAcceptKey.rawValue != acceptKey.rawValue {
            parts.append("\(full) accepts the rest")
        }
        parts.append("Esc dismisses")
        return parts.joined(separator: " · ")
    }
}
