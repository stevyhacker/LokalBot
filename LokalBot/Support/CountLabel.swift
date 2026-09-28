import Foundation

/// Counted UI copy with correct English number agreement: "1 moment",
/// "2 moments". Pass `plural:` for irregular nouns ("match" → "matches").
enum CountLabel {
    static func format(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        let noun = count == 1 ? singular : plural ?? singular + "s"
        return "\(count) \(noun)"
    }
}
