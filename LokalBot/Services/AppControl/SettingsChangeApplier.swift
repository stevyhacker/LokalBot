import Foundation

enum SettingsChangeApplier {
    static func apply(
        _ items: [SettingsChangePlan.Item],
        to settings: AppSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> AppSettings {
        var object = AppControlHandler.encoded(settings)
        for item in items {
            object[item.spec.key] = item.stored
        }
        let decoded: AppSettings
        do {
            decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(object))
        } catch {
            throw AppControlError.invalidRequest("LokalBot could not read the changed settings: \(error.localizedDescription)")
        }
        let result = AppControlHandler.encoded(decoded)
        for item in items where decoded.corruptedSettingsKeys.contains(item.spec.key) || result[item.spec.key] != item.stored {
            throw AppControlError.invalidValue(item.spec.key, "isn't a value LokalBot accepts")
        }
        var updated = decoded
        updated.corruptedSettingsKeys = settings.corruptedSettingsKeys
        return AppState.coupledSettings(updated, from: settings, now: now, calendar: calendar)
    }
}
