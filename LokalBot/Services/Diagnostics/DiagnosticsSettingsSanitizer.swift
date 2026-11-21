import Foundation

enum DiagnosticsSettingsSanitizer {
    private static let secretKeyFragments = ["apikey", "token", "secret", "password", "credential", "authorization"]

    static func sanitize(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(
            withJSONObject: sanitize(object, key: nil),
            options: [.prettyPrinted, .sortedKeys])
    }

    static func isSecret(key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return secretKeyFragments.contains { normalized.contains($0) }
    }

    private static func sanitize(_ value: Any, key: String?) -> Any {
        if let key, isSecret(key: key) { return "<removed>" }
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitize(entry.value, key: entry.key)
            }
        case let array as [Any]:
            return array.map { sanitize($0, key: nil) }
        case let string as String:
            return redactURL(string)
        default:
            return value
        }
    }

    static func redactURL(_ string: String) -> String {
        guard string.contains("://"), var components = URLComponents(string: string),
              components.scheme != nil, components.host != nil else { return string }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? string
    }
}
