import Foundation

enum HelperVersion {
    static func current(
        binaryPath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]
    ) -> String {
        let binary = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil),
              let info = object as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            return "dev"
        }
        return version
    }
}
