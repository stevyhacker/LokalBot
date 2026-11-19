import Foundation

/// The user's own Antigravity CLI (`agy`), run unmodified in headless stream
/// mode. The user signs in through Antigravity's own flow (`agy`); LokalBot
/// never reads, stores, or forwards Antigravity or Google credentials and
/// never offers an Antigravity login of its own.
enum AntigravityCLI {
    static let setupURL = URL(string: "https://antigravity.google/download")!

    /// Where Antigravity CLI installers put `agy`, checked after PATH.
    static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.antigravity/bin/agy",
            "\(home)/.npm-global/bin/agy",
            "\(home)/.bun/bin/agy",
            "\(home)/.volta/bin/agy",
        ]
    }

    /// The first executable `agy` on PATH or in a known install location.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        for path in pathDirectories.map({ "\($0)/agy" }) + candidatePaths(home: home)
        where seen.insert(path).inserted && path.hasPrefix("/") && isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func locateWithLoginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        await PlanCLIProcess.locateWithLoginShell(command: "agy", environment: environment)
    }

    /// Environment keys inherited from an enclosing Antigravity/ACP session
    /// that must not leak into a standalone `agy` invocation.
    static let nestedEnvironmentPrefixes = ["ANTIGRAVITY_", "AGY_"]
    static let nestedEnvironmentKeys: Set<String> = ["GEMINI_HOME"]

    /// The child environment: LokalBot's own without nested Antigravity
    /// session variables, and with the executable's folder first on PATH.
    static func environment(
        for executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base.filter { key, _ in
            !nestedEnvironmentKeys.contains(key)
                && !nestedEnvironmentPrefixes.contains(where: { key.hasPrefix($0) })
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
        var effortLevels: [ThinkReasoningLevel]

        var id: String { slug }
    }

    struct AuthStatus: Equatable, Sendable {
        var loggedIn: Bool
        var models: [ModelEntry]
    }

    /// Effort suffixes `agy models` appends to model slugs (`-low`, `-medium`,
    /// `-high`, `-xhigh`, `-max`). Passing `--effort` with a slug that already
    /// carries one conflicts in `agy`.
    static let effortSuffixes: [(suffix: String, level: ThinkReasoningLevel, label: String)] = [
        ("-low", .low, "(Low)"),
        ("-medium", .medium, "(Medium)"),
        ("-high", .high, "(High)"),
        ("-xhigh", .xhigh, "(XHigh)"),
        ("-max", .max, "(Max)"),
    ]

    static func hasExplicitEffortSuffix(_ model: String) -> Bool {
        let lowered = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return effortSuffixes.contains { lowered.hasSuffix($0.suffix) }
    }

    /// Parses `agy models` stdout into grouped models. Multi-effort families
    /// (e.g. `gemini-4-neon-low`/`-medium`/`-high`/`-xhigh`) collapse to their
    /// base slug (`gemini-4-neon`) so LokalBot's Reasoning Level setting and
    /// task budgets select `--effort`. Single-variant entries keep their exact
    /// slug.
    static func parseModelsOutput(_ data: Data) -> [ModelEntry] {
        let text = stripANSI(String(decoding: data, as: UTF8.self))
        var rawEntries: [(slug: String, displayName: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // Spinner frames overwrite the line with '\r'; keep only the final segment.
            let line = (rawLine.split(separator: "\r", omittingEmptySubsequences: false).last
                        .map(String.init) ?? String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().contains("fetching available models") else { continue }
            guard let splitRange = line.range(of: #"(?:\t+| {2,})"#, options: .regularExpression) else { continue }
            let slug = String(line[..<splitRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let displayName = String(line[splitRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !slug.isEmpty, !displayName.isEmpty, !slug.contains(" ") else { continue }
            rawEntries.append((slug, displayName))
        }
        return groupModels(rawEntries)
    }

    private static func groupModels(_ rawEntries: [(slug: String, displayName: String)]) -> [ModelEntry] {
        struct Bucket {
            var baseSlug: String
            var baseName: String
            var variants: [(slug: String, displayName: String, level: ThinkReasoningLevel?)]
        }
        var order: [String] = []
        var buckets: [String: Bucket] = [:]

        for entry in rawEntries {
            let lowered = entry.slug.lowercased()
            if let match = effortSuffixes.first(where: { lowered.hasSuffix($0.suffix) }) {
                let baseSlug = String(entry.slug.dropLast(match.suffix.count))
                var baseName = entry.displayName
                if baseName.hasSuffix(" \(match.label)") {
                    baseName = String(baseName.dropLast(match.label.count + 1))
                }
                if buckets[baseSlug] == nil {
                    order.append(baseSlug)
                    buckets[baseSlug] = Bucket(baseSlug: baseSlug, baseName: baseName, variants: [])
                }
                buckets[baseSlug]?.variants.append((entry.slug, entry.displayName, match.level))
            } else {
                if buckets[entry.slug] == nil {
                    order.append(entry.slug)
                    buckets[entry.slug] = Bucket(baseSlug: entry.slug, baseName: entry.displayName, variants: [])
                }
                buckets[entry.slug]?.variants.append((entry.slug, entry.displayName, nil))
            }
        }

        return order.compactMap { key -> ModelEntry? in
            guard let bucket = buckets[key] else { return nil }
            let levels = Array(Set(bucket.variants.compactMap(\.level))).sorted()
            if levels.count > 1 {
                return ModelEntry(slug: bucket.baseSlug, displayName: bucket.baseName, effortLevels: levels)
            }
            if let single = bucket.variants.first {
                return ModelEntry(slug: single.slug, displayName: single.displayName, effortLevels: [])
            }
            return nil
        }
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    /// `agy models` verifies that `agy` is signed in and lists the models
    /// available on the account, without touching credentials.
    static func authStatus(executable: URL) async throws -> AuthStatus {
        let output = try await PlanCLIProcess.run(
            executable: executable,
            arguments: ["models"],
            environment: environment(for: executable),
            timeout: .seconds(20),
            programName: "Antigravity CLI",
            notInstalledError: AntigravityPlanError.notInstalled,
            failedError: AntigravityPlanError.failed)
        let combined = (String(decoding: output.stdout, as: UTF8.self) + "\n" + output.stderrTail).lowercased()
        if output.status != 0 {
            if combined.contains("please sign in") || combined.contains("authentication")
                || combined.contains("not signed in") || combined.contains("launch the cli without arguments") {
                return AuthStatus(loggedIn: false, models: [])
            }
            let detail = stripANSI(output.stderrTail).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AntigravityPlanError.failed(
                detail.isEmpty
                    ? "Antigravity CLI didn't report its available models. Update agy and try again."
                    : String(detail.prefix(300)))
        }
        let models = parseModelsOutput(output.stdout)
        return AuthStatus(loggedIn: true, models: models)
    }

    static func version(executable: URL) async -> String? {
        guard let output = try? await PlanCLIProcess.run(
            executable: executable,
            arguments: ["--version"],
            environment: environment(for: executable),
            timeout: .seconds(20),
            programName: "Antigravity CLI",
            notInstalledError: AntigravityPlanError.notInstalled,
            failedError: AntigravityPlanError.failed) else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}

/// Finds Antigravity CLI once per launch; a manual check looks again.
actor AntigravityLocator {
    static let shared = AntigravityLocator()
    private var cached: URL?

    func executable(refresh: Bool = false) async -> URL? {
        if !refresh, let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        var found = AntigravityCLI.locate()
        if found == nil { found = await AntigravityCLI.locateWithLoginShell() }
        cached = found
        return found
    }
}

enum AntigravityPlanError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case signInRequired
    case usageLimitReached(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Antigravity CLI (agy) isn't installed on this Mac. Install it, sign in by running agy in Terminal, then choose Antigravity plan again under Settings → Models → Think."
        case .signInRequired:
            "Antigravity CLI isn't signed in. Open Terminal, run agy, and sign in with your Google account. LokalBot never sees your Antigravity sign-in."
        case .usageLimitReached(let detail):
            "Your Antigravity plan's usage limit was reached. \(detail)".trimmingCharacters(in: .whitespaces)
        case .failed(let detail):
            detail
        }
    }
}
