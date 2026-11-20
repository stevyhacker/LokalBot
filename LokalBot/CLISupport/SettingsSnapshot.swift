import Foundation

enum SettingsSnapshot {
    static func entries(
        current: [String: JSONValue],
        defaults: [String: JSONValue],
        specs: [SettingSpec] = SettingRegistry.all,
        redactURL: (String) -> String = { $0 }
    ) -> [JSONValue] {
        specs.map { spec in
            let value = presented(current[spec.key], spec: spec, redactURL: redactURL)
            let defaultValue = presented(defaults[spec.key], spec: spec, redactURL: redactURL)
            return [
                "key": .string(spec.key),
                "title": .string(spec.title),
                "category": .string(spec.category.rawValue),
                "tier": .string(spec.tier.rawValue),
                "type": .string(spec.kind.typeName),
                "value": value,
                "default": defaultValue,
                "changed": .bool(value != defaultValue),
            ]
        }
    }

    static func specs(category: String?, keys: [String]?) throws -> [SettingSpec] {
        if let keys {
            return try keys.map { key in
                guard let spec = SettingRegistry.spec(for: key) else { throw AppControlError.unknownKey(key) }
                return spec
            }
        }
        guard let category else { return SettingRegistry.all }
        guard let wanted = SettingCategory(rawValue: category) else {
            throw AppControlError.invalidRequest(
                "Unknown category \(category). Categories: "
                    + SettingCategory.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return SettingRegistry.all.filter { $0.category == wanted }
    }

    private static func presented(
        _ stored: JSONValue?,
        spec: SettingSpec,
        redactURL: (String) -> String
    ) -> JSONValue {
        guard let stored else { return .null }
        if case .text(.url) = spec.kind, case .string(let url) = stored {
            return .string(redactURL(url))
        }
        return spec.presented(stored)
    }
}
