import Foundation

enum CountLabel {
    static func format(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
