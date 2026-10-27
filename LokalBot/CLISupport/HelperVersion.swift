import Foundation

/// Reads the enclosing app bundle's version for `--version` and the MCP
/// server handshake.
enum HelperVersion {
    /// Defaults to the executable's real path: a shell that finds the helper
    /// on PATH passes only the bare name as argv[0].
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
