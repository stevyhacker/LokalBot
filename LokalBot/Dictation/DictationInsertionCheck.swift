import Foundation

enum DictationInsertionVerdict: Equatable, Sendable {
    case landed
    case missing
    case unknown
}

enum DictationInsertionCheck {
    static let readDelaysMilliseconds = [250, 650, 1_200]
    static let probeLength = 24

    static func allowsReadBack(boundIdentity: String?, liveIdentity: String?, isSecure: Bool) -> Bool {
        guard let boundIdentity, !boundIdentity.isEmpty, !isSecure else { return false }
        return liveIdentity == boundIdentity
    }

    static func verdict(textBeforeCaret: String?, inserted: String) -> DictationInsertionVerdict {
        guard let textBeforeCaret else { return .unknown }
        let sent = significant(inserted)
        guard !sent.isEmpty else { return .unknown }
        let probe = String(sent.suffix(probeLength))
        let field = significant(String(textBeforeCaret.suffix(inserted.count + 400)))
        return field.contains(probe) ? .landed : .missing
    }

    static func significant(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }
}

struct DictationDeliveryNotice: Equatable, Sendable {
    let text: String
    var copied = false
}
