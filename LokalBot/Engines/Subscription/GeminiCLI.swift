import Foundation

enum GeminiCLI {
    static let setupURL = URL(string: "https://geminicli.com/docs/get-started/installation/")!

    static func candidatePaths(home: String) -> [String] {
        [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "\(home)/.bun/bin/gemini",
            "\(home)/.volta/bin/gemini",
        ]
    }

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        for path in pathDirectories.map({ "\($0)/gemini" }) + candidatePaths(home: home)
        where seen.insert(path).inserted && path.hasPrefix("/") && isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func locateWithLoginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        await PlanCLIProcess.locateWithLoginShell(command: "gemini", environment: environment)
    }

    static func environment(
        for executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment,
        systemPromptPath: String? = nil,
        systemSettingsPath: String? = nil
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "GEMINI_HOME")
        environment["NO_COLOR"] = "1"
        if let systemPromptPath {
            environment["GEMINI_SYSTEM_MD"] = systemPromptPath
        }
        if let systemSettingsPath {
            environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = systemSettingsPath
            environment["GEMINI_CLI_TRUST_WORKSPACE"] = "true"
        }
        var path = [executable.deletingLastPathComponent().path]
        path += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        path += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen: Set<String> = []
        environment["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    struct ModelEntry: Equatable, Identifiable, Sendable {
        var slug: String
        var displayName: String
        var inputTokens: Int?

        var id: String { slug }
    }

    static let fallbackModels: [ModelEntry] = [
        .init(slug: "", displayName: "Gemini CLI default", inputTokens: 1_048_576),
        .init(slug: "gemini-2.5-pro", displayName: "gemini-2.5-pro", inputTokens: 1_048_576),
        .init(slug: "gemini-3.5-flash", displayName: "gemini-3.5-flash", inputTokens: 1_048_576),
        .init(slug: "gemini-3.1-flash-lite", displayName: "gemini-3.1-flash-lite", inputTokens: 1_048_576),
    ]

    static func parseModelsJSON(_ data: Data) -> [ModelEntry] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        var entries: [ModelEntry] = []
        for item in list {
            let rawSlug = ((item["modelId"] as? String) ?? (item["id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawSlug.isEmpty else { continue }
            let slug = rawSlug == "auto" ? "" : rawSlug
            guard seen.insert(slug).inserted else { continue }
            let rawName = ((item["displayName"] as? String) ?? (item["name"] as? String) ?? rawSlug)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = rawSlug == "auto" ? "Gemini CLI default (Auto)" : (rawName.isEmpty ? rawSlug : rawName)
            let limits = item["contextLimits"] as? [String: Any]
            let inputTokens = limits?["inputTokens"] as? Int
            entries.append(ModelEntry(slug: slug, displayName: displayName, inputTokens: inputTokens))
        }
        return entries
    }

    static func models(executable: URL) async -> [ModelEntry] {
        guard let output = try? await PlanCLIProcess.run(
            executable: executable,
            arguments: ["models", "-o", "json"],
            environment: environment(for: executable),
            timeout: .seconds(20),
            programName: "Gemini CLI",
            notInstalledError: GeminiPlanError.notInstalled,
            failedError: GeminiPlanError.failed),
              output.status == 0 else {
            return fallbackModels
        }
        let parsed = parseModelsJSON(output.stdout)
        return parsed.isEmpty ? fallbackModels : parsed
    }

    static func version(executable: URL) async -> String? {
        guard let output = try? await PlanCLIProcess.run(
            executable: executable,
            arguments: ["--version"],
            environment: environment(for: executable),
            timeout: .seconds(20),
            programName: "Gemini CLI",
            notInstalledError: GeminiPlanError.notInstalled,
            failedError: GeminiPlanError.failed) else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}

actor GeminiCLILocator {
    static let shared = GeminiCLILocator()
    private var cached: URL?

    func executable(refresh: Bool = false) async -> URL? {
        if !refresh, let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        var found = GeminiCLI.locate()
        if found == nil { found = await GeminiCLI.locateWithLoginShell() }
        cached = found
        return found
    }
}

enum GeminiPlanError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case signInRequired
    case usageLimitReached(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Gemini CLI isn't installed on this Mac. Install it, sign in by running gemini in Terminal, then choose Gemini plan again under Settings → Models → Think."
        case .signInRequired:
            "Gemini CLI isn't signed in. Open Terminal, run gemini, and sign in with your Google account. LokalBot never sees your Google sign-in."
        case .usageLimitReached(let detail):
            "Your Gemini plan's usage limit was reached. \(detail)".trimmingCharacters(in: .whitespaces)
        case .failed(let detail):
            detail
        }
    }
}
