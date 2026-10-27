import Foundation

/// Applies checked plan items to `AppSettings` through the real decoder, so a
/// value the app would reject or adjust is reported instead of silently stored
/// as something else, then applies the couplings Settings enforces
/// (`AppState.coupledSettings`).
enum SettingsChangeApplier {
    static func apply(
        _ items: [SettingsChangePlan.Item],
        to settings: AppSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> AppSettings {
        var object = AppControlHandler.encoded(settings)
        for item in items {
            // Assigning nil removes an optional key, which restores its default.
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
