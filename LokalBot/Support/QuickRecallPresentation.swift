import AppKit

@MainActor
enum QuickRecallApplicationIconResolver {
    private static let cache = NSCache<NSString, NSImage>()
    private static var missing: Set<String> = []

    static func icon(for appName: String) -> NSImage? {
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !missing.contains(key) else { return nil }

        if let icon = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(key) == .orderedSame
        })?.icon {
            cache.setObject(icon, forKey: key as NSString)
            return icon
        }
        // Exclusion rules can name an app by bundle identifier.
        if key.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            cache.setObject(icon, forKey: key as NSString)
            return icon
        }

        let name = key.hasSuffix(".app") ? String(key.dropLast(4)) : key
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in roots {
            let applicationURL = root.appendingPathComponent(name).appendingPathExtension("app")
            guard FileManager.default.fileExists(atPath: applicationURL.path) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            cache.setObject(icon, forKey: key as NSString)
            return icon
        }
        missing.insert(key)
        return nil
    }
}

/// When a row happened, short enough for the end of its first line:
/// "Today 10:43 AM", "Yesterday 4:00 PM", "Wed 11:47 AM" within the week,
/// then the day alone ("Sep 25", with the year once it is not this year).
enum QuickRecallDateLabel {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                       locale: Locale = .current, localize: (String) -> String = { $0 }) -> String {
        var style = Date.FormatStyle()
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        let time = date.formatted(style.hour().minute())
        let dateDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let distance = calendar.dateComponents([.day], from: dateDay, to: today).day ?? .max
        switch distance {
        case 0:
            return "\(localize("Today")) \(time)"
        case 1:
            return "\(localize("Yesterday")) \(time)"
        case 2...6:
            return "\(date.formatted(style.weekday(.abbreviated))) \(time)"
        default:
            return AskDateLabel.day(date, now: now, calendar: calendar, locale: locale)
        }
    }
}
