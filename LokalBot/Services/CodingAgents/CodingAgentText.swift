import Foundation

/// Text rules shared by the coding-agent transcript readers. Every string
/// that leaves a reader passes through here: injected context is removed,
/// credentials are redacted, and length is capped before anything is kept.
enum CodingAgentText {
    static let promptCharacters = 280
    static let replyCharacters = 600
    static let titleCharacters = 160

    /// A person's request with harness-injected context removed, or `nil`
    /// when nothing the person wrote remains.
    static func prompt(_ raw: String) -> String? {
        var text = raw
        if let request = text.range(of: "## My request for Codex:") ?? text.range(of: "## My request:") {
            // Codex puts IDE, browser, and file context above the request.
            text = String(text[request.upperBound...])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let automation = scheduledRun(in: trimmed) { return automation }
        if let command = firstCapture(of: commandName, in: trimmed) {
            return slashCommand(command, in: trimmed)
        }
        if let command = terminalCommand(in: trimmed) {
            // The person's own shell input; its captured output is never kept.
            return sanitized("Ran in terminal: \(command)", maxCharacters: promptCharacters)
        }
        guard !ignoredPromptPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        text = pastedContent.stringByReplacingMatches(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed),
            withTemplate: "[pasted text]")
        let clean = sanitized(removingBlocks(text), maxCharacters: promptCharacters)
        // An unclosed harness tag is still harness text.
        guard !clean.isEmpty, firstCapture(of: harnessTagOpening, in: clean) == nil else { return nil }
        return clean
    }

    /// A command the person typed into the agent's terminal mode.
    static func terminalCommand(in raw: String) -> String? {
        firstCapture(of: bashInput, in: raw)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reply(_ raw: String) -> String? {
        let clean = sanitized(removingBlocks(raw), maxCharacters: replyCharacters)
        return clean.isEmpty ? nil : clean
    }

    static func title(_ raw: String) -> String? {
        let clean = sanitized(raw, maxCharacters: titleCharacters)
        return clean.isEmpty ? nil : clean
    }

    /// Text said to an agent rather than a name for work: a question, a
    /// truncated or harness-tagged request, a link, or a conversational
    /// opening such as "can you" or "we should".
    static func readsAsRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.hasPrefix("<") || trimmed.hasSuffix("?") || trimmed.hasSuffix("…")
            || trimmed.contains("://")
            || trimmed.range(of: conversationalOpening, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A request that is a short instruction, as a work title: "Review all
    /// open PRs" as is, "let's commit the benchmark." as "Commit the
    /// benchmark". `nil` for anything else, such as a question, a long or
    /// truncated request, a terminal command, or pasted text.
    static func instruction(_ request: String) -> String? {
        var clean = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.hasPrefix("/"), !clean.hasPrefix("Ran in terminal:"),
              !clean.contains("[pasted text]") else { return nil }
        while let opening = clean.range(of: politeOpening, options: [.regularExpression, .caseInsensitive]) {
            clean.removeSubrange(opening)
        }
        while let last = clean.last, ".!".contains(last) { clean.removeLast() }
        let words = clean.split(whereSeparator: \.isWhitespace)
        guard (2...10).contains(words.count), !readsAsRequest(clean), let first = clean.first else { return nil }
        // "iOS …" keeps its case.
        let second = clean.dropFirst().first
        return first.isLowercase && second?.isUppercase != true
            ? first.uppercased() + clean.dropFirst() : clean
    }

    private static let conversationalOpening =
        #"^((can|could|would|will) (you|we)|(should|shall) we|we (should|need|must|have to)|"#
        + #"i('d| would)? (want|need|like)|let['’]?s|let us|help me|please|pls|hey|hi|hello|"#
        + #"yes|no|ok|okay|thanks|try again|go ahead|how|why|what|which|where|when|who|"#
        + #"(is|are|do|does|did) (there|it|we|you|this|that))\b"#

    private static let politeOpening =
        #"^((can|could|would|will) you|please|pls|let['’]?s|let us|we should|we need to|"#
        + #"i('d like| want| need) you to|go ahead and|ok(ay)?|so|now|and)\b[,:]?\s*"#

    static func truncated(_ text: String, maxCharacters: Int) -> String {
        PromptContextSanitizer.sanitize(text, maxCharacters: maxCharacters)
    }

    /// One line, credentials redacted, capped.
    static func sanitized(_ text: String, maxCharacters: Int) -> String {
        let redacted = ScreenContextPrivacy.redact(text).text
        return PromptContextSanitizer.sanitize(
            redacted.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            maxCharacters: maxCharacters)
    }

    // MARK: - Commands

    /// Outcomes recorded by a shell command. Command output is never read,
    /// so an action means the agent ran it, not that it succeeded.
    static func actions(inCommand command: String) -> [CodingAgentAction] {
        let command = unwrappedShellCommand(command)
        var actions: [CodingAgentAction] = []
        func append(_ action: CodingAgentAction) {
            if !actions.contains(action) { actions.append(action) }
        }
        for match in matches(of: commitMessage, in: command) {
            if let message = firstCapture(match), let clean = title(message) {
                append(.commit(message: clean))
            }
        }
        for match in matches(of: pullRequestTitle, in: command) {
            if let raw = firstCapture(match), let clean = title(raw) {
                append(.openedPullRequest(title: clean))
            }
        }
        for match in matches(of: pullRequestMerge, in: command) {
            append(.mergedPullRequest(number: (match.first ?? nil).flatMap { Int($0) }))
        }
        for match in matches(of: releaseTag, in: command) {
            if let tag = match.first ?? nil { append(.release(tag: tag)) }
        }
        if contains(gitPush, in: command) { append(.pushed) }
        if contains(testRun, in: command) { append(.ranTests) }
        return actions
    }

    static func pullRequestURLs(in text: String) -> [String] {
        var urls: [String] = []
        for match in matches(of: pullRequestURL, in: text) {
            if let url = match.first ?? nil, !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// The agent read LokalBot's library, whose content its replies may echo.
    static func readsLokalBot(command: String) -> Bool {
        contains(lokalBotCommand, in: command)
    }

    static func readsLokalBot(toolName: String) -> Bool {
        toolName.range(of: "lokalbot", options: .caseInsensitive) != nil
    }

    /// Codex records commands as a JSON-encoded argv such as
    /// `["/bin/zsh","-lc","git push"]`; the script is the last element.
    static func unwrappedShellCommand(_ command: String) -> String {
        guard command.hasPrefix("["),
              let data = command.data(using: .utf8),
              let argv = try? JSONSerialization.jsonObject(with: data) as? [String],
              let script = argv.last else { return command }
        return script
    }

    // MARK: - Paths

    /// A changed file as the person would name it: relative to the session's
    /// project, never exposing scratch or worktree plumbing.
    static func displayPath(_ path: String, workingDirectory: String?) -> String {
        var value = (path as NSString).standardizingPath
        // Worktrees sit inside the project folder, so strip them first.
        for pattern in [claudeScratchpad, worktreeRoot] {
            let range = NSRange(value.startIndex..., in: value)
            if let match = pattern.firstMatch(in: value, range: range),
               let matched = Range(match.range, in: value) {
                let prefix = pattern === claudeScratchpad ? "scratchpad/" : ""
                return prefix + value[matched.upperBound...]
            }
        }
        if let workingDirectory {
            let root = (workingDirectory as NSString).standardizingPath
            if value.hasPrefix(root + "/") { return String(value.dropFirst(root.count + 1)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if value.hasPrefix(home + "/") { value = "~" + value.dropFirst(home.count) }
        return value
    }

    // MARK: - Private

    /// Whole messages the harness writes in the person's turn.
    private static let ignoredPromptPrefixes = [
        "<local-command", "Caveat:", "[Request interrupted", "# AGENTS.md instructions",
        "<permissions", "<image", "</image>", "<collaboration_mode",
    ]

    /// Harness context wrapped around or beside a request: system reminders,
    /// IDE and browser state, skill bodies, captured terminal output. These
    /// tags are hyphenated or underscored (`system-reminder`, `bash-stdout`,
    /// `ide_selection`), unlike HTML a person might paste into a prompt.
    private static let ignoredBlocks = regex(
        #"<([a-z]+(?:[-_][a-z0-9]+)+|skill|attachments?)\b[^>]*>[\s\S]*?</\1\s*>"#)
    private static let harnessTagOpening = regex(
        #"^(<[a-z]+(?:[-_][a-z0-9]+)+)\b"#)
    private static let pastedContent = regex(
        #"<pasted_content\b[^>]*>[\s\S]*?</pasted_content[^>]*>"#)
    private static let commandName = regex(
        #"<command-name>\s*(/[^<\s]+)\s*</command-name>"#)
    private static let commandArguments = regex(
        #"<command-args>([\s\S]*?)</command-args>"#)
    private static let bashInput = regex(
        #"<bash-input>([\s\S]*?)</bash-input>"#)
    private static let automationID = regex(
        #"^<heartbeat>[\s\S]*?<automation_id>\s*([^<]+?)\s*</automation_id>"#)
    private static let scheduledTaskName = regex(
        #"^<scheduled-task\b[^>]*\bname="([^"]+)""#)

    /// Session-management commands say nothing about the work.
    private static let housekeepingCommands: Set<String> = [
        "/clear", "/compact", "/model", "/resume", "/exit", "/config", "/login", "/logout",
        "/cost", "/status", "/help", "/context", "/mcp", "/permissions", "/hooks",
        "/memory", "/doctor", "/usage", "/fast", "/effort", "/rename", "/export",
    ]

    private static let commitMessage = regex(
        #"\bgit\s+(?:-C\s+\S+\s+)?commit\b[^\n]*?\s-[a-zA-Z]*m\s*(?:"\$\(cat\s+<<-?\s*'?\w+'?\s*\n\s*([^\n]{3,200})|"((?:[^"\\\n]|\\.){3,200})|'([^'\n]{3,200})')"#)
    private static let pullRequestTitle = regex(
        #"\bgh\s+pr\s+create\b[^\n]*?\s(?:--title|-t)(?:\s+|=)(?:"((?:[^"\\\n]|\\.){3,200})"|'([^'\n]{3,200})')"#)
    private static let pullRequestMerge = regex(
        #"\bgh\s+pr\s+merge\b(?:\s+(?:https://github\.com/[\w.-]+/[\w.-]+/pull/)?(\d+))?"#)
    private static let releaseTag = regex(
        #"\bgh\s+release\s+create\s+([^\s"';&|]+)"#)
    private static let gitPush = regex(
        #"\bgit\s+(?:-C\s+\S+\s+)?push\b"#)
    private static let testRun = regex(
        #"\bxcodebuild\b[^\n;&|]*\btest(?:-without-building)?\b|\b(?:swift|cargo|go|forge|bun|deno)\s+test\b|\b(?:npm|pnpm|yarn)\s+(?:run\s+)?test\b|\bpytest\b|Scripts/ui-tests\.sh"#)
    private static let pullRequestURL = regex(
        #"(https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)"#)
    private static let lokalBotCommand = regex(
        #"\blokalbot-cli\b|(?:^|[\s/;&|(])lokalbot\s+(?:list|get|search|path|mcp|people|actions|screen)\b"#,
        options: [.caseInsensitive, .anchorsMatchLines])
    private static let claudeScratchpad = regex(
        #"^/(?:private/)?tmp/claude-\d+/[^/]+/[0-9a-f-]{36}/scratchpad/"#)
    private static let worktreeRoot = regex(
        #"^.*/\.claude/worktrees/[^/]+/|^.*/\.codex/worktrees/[^/]+/[^/]+/"#)

    private static func regex(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in coding-agent pattern: \(pattern)")
        }
    }

    /// A skill or command the person invoked, e.g. `/code-review high`.
    /// Session housekeeping such as `/fast on` is not a request.
    private static func slashCommand(_ name: String, in text: String) -> String? {
        guard !housekeepingCommands.contains(name.lowercased()) else { return nil }
        let arguments = firstCapture(of: commandArguments, in: text) ?? ""
        return sanitized("\(name) \(arguments)", maxCharacters: promptCharacters)
    }

    /// Runs the person scheduled earlier: they asked for the work, but not
    /// in the words the harness injects for each run.
    private static func scheduledRun(in text: String) -> String? {
        if text.hasPrefix("<heartbeat>") {
            let id = firstCapture(of: automationID, in: text) ?? "unnamed"
            return "Scheduled automation: " + sanitized(id, maxCharacters: 80)
        }
        if let name = firstCapture(of: scheduledTaskName, in: text) {
            return "Scheduled task: " + sanitized(name, maxCharacters: 80)
        }
        return nil
    }

    private static func firstCapture(of expression: NSRegularExpression, in text: String) -> String? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func removingBlocks(_ text: String) -> String {
        ignoredBlocks.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func matches(
        of expression: NSRegularExpression, in text: String
    ) -> [[String?]] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<max(1, match.numberOfRanges)).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    /// The first alternative that matched, with shell-escaped quotes undone.
    private static func firstCapture(_ captures: [String?]) -> String? {
        captures.lazy.compactMap { $0 }.first?
            .replacingOccurrences(of: #"\""#, with: "\"")
    }

    private static func contains(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Streams a JSON Lines transcript without loading it into Swift strings.
/// Tool output dominates these files (one 15 MB session held about a dozen
/// prompts), so readers classify a line from its opening bytes and fully
/// decode only lines that can carry evidence.
struct CodingAgentJSONLines {
    let data: Data

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    init(data: Data) {
        self.data = data
    }

    func forEach(_ body: (Line) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                autoreleasepool { body(Line(bytes: data[start..<end])) }
            }
            start = data.index(after: end)
        }
    }

    struct Line {
        let bytes: Data

        /// Whether `needle` occurs within the first `limit` bytes.
        func prefix(_ limit: Int, contains needle: String) -> Bool {
            let end = bytes.index(bytes.startIndex, offsetBy: min(limit, bytes.count))
            return bytes[bytes.startIndex..<end].range(of: Data(needle.utf8)) != nil
        }

        /// The first unescaped string value for `"key":"`. Escaped quotes in
        /// nested JSON text cannot match, so this safely reads identifiers
        /// and timestamps without decoding a multi-megabyte line.
        func stringValue(forKey key: String) -> String? {
            guard let keyRange = bytes.range(of: Data("\"\(key)\":\"".utf8)) else { return nil }
            let valueStart = keyRange.upperBound
            guard let valueEnd = bytes[valueStart...].firstIndex(of: 0x22) else { return nil }
            return String(data: bytes[valueStart..<valueEnd], encoding: .utf8)
        }

        func object() -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
    }
}

enum CodingAgentTimestamp {
    /// Parses the UTC `yyyy-MM-ddTHH:mm:ss(.SSS…)Z` stamps both agents
    /// write, falling back to Foundation for any other ISO 8601 form.
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        func number(_ from: Int, _ length: Int) -> Int? {
            guard bytes.count >= from + length else { return nil }
            var result = 0
            for byte in bytes[from..<(from + length)] {
                guard byte >= 48, byte <= 57 else { return nil }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return fallback(value) }
        var fraction = 0.0
        if bytes.count > 21, bytes[19] == UInt8(ascii: ".") {
            var scale = 0.1
            for byte in bytes[20..<(bytes.count - 1)] {
                guard byte >= 48, byte <= 57 else { return fallback(value) }
                fraction += Double(byte - 48) * scale
                scale /= 10
            }
        }
        // Days from the civil calendar (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    private static func fallback(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601) { return date }
        return try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
