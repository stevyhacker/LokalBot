import Foundation

enum DeviceInfo {
    struct Snapshot: Equatable {
        let appVersion: String?
        let macosVersion: String?
        let model: String?
        let chip: String?
        let memoryGB: Int?

        var summaryLine: String {
            var parts: [String] = []
            if let appVersion { parts.append("v\(appVersion)") }
            if let macosVersion { parts.append("macOS \(macosVersion)") }
            if let model { parts.append(model) }
            if let chip { parts.append(chip) }
            if let memoryGB { parts.append("\(memoryGB) GB") }
            return parts.isEmpty ? "Device information unavailable" : parts.joined(separator: " · ")
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            appVersion: bundleVersion(),
            macosVersion: macosVersionString(),
            model: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryGB: physicalMemoryGB()
        )
    }

    private static func bundleVersion() -> String? {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return nil
    }

    private static func macosVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func physicalMemoryGB() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return nil }
        return Int((Double(bytes) / 1_073_741_824.0).rounded())
    }
}
