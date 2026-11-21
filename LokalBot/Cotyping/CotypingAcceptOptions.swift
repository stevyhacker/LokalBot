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

enum CotypingFullAcceptKey: Int, Codable, Sendable {
    case backtick = 50
    case rightArrow = 124
    case off = -1

    var keyCode: CGKeyCode? { self == .off ? nil : CGKeyCode(rawValue) }
    var label: String? {
        switch self {
        case .backtick: "`"
        case .rightArrow: "Right Arrow"
        case .off: nil
        }
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
        if let full = fullAcceptKey.label, fullAcceptKey.rawValue != acceptKey.rawValue {
            parts.append("\(full) accepts the rest")
        }
        parts.append("Esc dismisses")
        return parts.joined(separator: " · ")
    }
}
