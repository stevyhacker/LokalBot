import Foundation

enum CodingAgentText {
    static let promptCharacters = 280
    static let replyCharacters = 600
    static let titleCharacters = 160

    static func prompt(_ raw: String) -> String? {
        var text = unwrapAntigravityRequest(raw)
        if let request = text.range(of: "## My request for Codex:") ?? text.range(of: "## My request:") {
            text = String(text[request.upperBound...])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let automation = scheduledRun(in: trimmed) { return automation }
        if let command = firstCapture(of: commandName, in: trimmed) {
            return slashCommand(command, in: trimmed)
        }
        if let command = terminalCommand(in: trimmed) {
            return sanitized("Ran in terminal: \(command)", maxCharacters: promptCharacters)
        }
        guard !ignoredPromptPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        text = pastedContent.stringByReplacingMatches(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed),
            withTemplate: "[pasted text]")
        let clean = sanitized(removingBlocks(text), maxCharacters: promptCharacters)
        guard !clean.isEmpty, firstCapture(of: harnessTagOpening, in: clean) == nil else { return nil }
        return clean
    }

    static func unwrapAntigravityRequest(_ raw: String) -> String {
        var text = raw
        if let extracted = extractTag(named: "USER_REQUEST", from: text) {
            text = extracted
        } else {
            for marker in ["<ADDITIONAL_METADATA>", "<USER_SETTINGS_CHANGE>"] {
                if let range = text.range(of: marker) {
                    text = String(text[..<range.lowerBound])
                }
            }
        }
        if let nested = extractTag(named: "user_request", from: text) {
            text = nested
        }
        return text
    }

    private static func extractTag(named tag: String, from text: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = text.range(of: open) else { return nil }
        let rest = text[start.upperBound...]
        if let end = rest.range(of: close) {
            return String(rest[..<end.lowerBound])
        }
        var tail = String(rest)
        for marker in ["<ADDITIONAL_METADATA>", "<USER_SETTINGS_CHANGE>"] {
            if let range = tail.range(of: marker) {
                tail = String(tail[..<range.lowerBound])
            }
        }
        return tail
    }

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

    static func readsAsRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.hasPrefix("<") || trimmed.hasSuffix("?") || trimmed.hasSuffix("…")
            || trimmed.contains("://")
            || trimmed.range(of: conversationalOpening, options: [.regularExpression, .caseInsensitive]) != nil
    }

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

    static func sanitized(_ text: String, maxCharacters: Int) -> String {
        let redacted = ScreenContextPrivacy.redact(text).text
        return PromptContextSanitizer.sanitize(
            redacted.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            maxCharacters: maxCharacters)
    }

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

    static func pullRequestEvents(
        toolName: String,
        title rawTitle: String?,
        number rawNumber: Int?,
        url rawURL: String?,
        urls rawURLs: [String]
    ) -> [CodingAgentEvent.Kind] {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var events: [CodingAgentEvent.Kind] = []
        if normalized.hasSuffix("pull_request_create") {
            if let rawTitle, let clean = title(rawTitle) {
                events.append(.action(.openedPullRequest(title: clean)))
            }
        } else if normalized.hasSuffix("pull_request_merge") {
            events.append(.action(.mergedPullRequest(number: rawNumber)))
        } else if normalized.hasSuffix("link_pull_request") {
            if let rawURL {
                for url in pullRequestURLs(in: rawURL) { events.append(.pullRequest(url)) }
            }
        } else if normalized.hasSuffix("link_pull_requests") {
            for candidate in rawURLs {
                for url in pullRequestURLs(in: candidate) { events.append(.pullRequest(url)) }
            }
        }
        return events
    }

    static func inferredProjectDirectory(for target: String, isDirectory: Bool = false) -> String? {
        let value = (target as NSString).standardizingPath
        guard value.hasPrefix("/") else { return nil }
        let lowered = value.lowercased()
        let ignoredFragments = ["/.gemini/", "/.t3/userdata/", "/.claude/", "/.codex/"]
        if ignoredFragments.contains(where: lowered.contains)
            || lowered.hasPrefix("/tmp/") || lowered.hasPrefix("/private/tmp/")
            || lowered.hasPrefix("/var/") || lowered.hasPrefix("/private/var/") {
            return nil
        }
        let components = URL(fileURLWithPath: value).standardizedFileURL.pathComponents
        if let marker = components.lastIndex(of: ".t3"),
           components.indices.contains(marker + 2), components[marker + 1] == "worktrees" {
            return NSString.path(withComponents: Array(components.prefix(marker + 3)))
        }
        for index in components.indices.dropLast() where checkoutRootNames.contains(components[index].lowercased()) {
            return NSString.path(withComponents: Array(components.prefix(index + 2)))
        }
        if isDirectory { return value }
        let parent = (value as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "/" ? nil : parent
    }

    private static let checkoutRootNames: Set<String> = [
        "github", "repos", "repositories", "projects", "code", "dev", "workspace", "workspaces",
    ]

    static func readsLokalBot(command: String) -> Bool {
        contains(lokalBotCommand, in: command)
    }

    static func readsLokalBot(toolName: String) -> Bool {
        toolName.range(of: "lokalbot", options: .caseInsensitive) != nil
    }

    static func unwrappedShellCommand(_ command: String) -> String {
        guard command.hasPrefix("["),
              let data = command.data(using: .utf8),
              let argv = try? JSONSerialization.jsonObject(with: data) as? [String],
              let script = argv.last else { return command }
        return script
    }

    static func displayPath(_ path: String, workingDirectory: String?) -> String {
        var value = (path as NSString).standardizingPath
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

    private static let ignoredPromptPrefixes = [
        "<local-command", "Caveat:", "[Request interrupted", "# AGENTS.md instructions",
        "<permissions", "<image", "</image>", "<collaboration_mode",
    ]

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
        #"\bxcodebuild\b[^\n;&|]*\btest(?:-without-building)?\b|\b(?:swift|cargo|go|forge|bun|deno)\s+test\b|\b(?:npm|pnpm|yarn)\s+(?:run\s+)?test\b|\bpytest\b|Scripts/(?:test/)?ui-tests\.sh"#)
    private static let pullRequestURL = regex(
        #"(https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)"#)
    private static let lokalBotCommand = regex(
        #"\blokalbot-cli\b|(?:^|[\s/;&|(])lokalbot\s+(?:list|get|search|path|mcp|people|actions|screen)\b"#,
        options: [.caseInsensitive, .anchorsMatchLines])
    private static let claudeScratchpad = regex(
        #"^/(?:private/)?tmp/claude-\d+/[^/]+/[0-9a-f-]{36}/scratchpad/"#)
    private static let worktreeRoot = regex(
        #"^.*/\.claude/worktrees/[^/]+/|^.*/\.(?:codex|t3)/worktrees/[^/]+/[^/]+/"#)

    private static func regex(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid built-in coding-agent pattern: \(pattern)")
        }
    }

    private static func slashCommand(_ name: String, in text: String) -> String? {
        guard !housekeepingCommands.contains(name.lowercased()) else { return nil }
        let arguments = firstCapture(of: commandArguments, in: text) ?? ""
        return sanitized("\(name) \(arguments)", maxCharacters: promptCharacters)
    }

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

    private static func firstCapture(_ captures: [String?]) -> String? {
        captures.lazy.compactMap { $0 }.first?
            .replacingOccurrences(of: #"\""#, with: "\"")
    }

    private static func contains(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

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

        func prefix(_ limit: Int, contains needle: String) -> Bool {
            let end = bytes.index(bytes.startIndex, offsetBy: min(limit, bytes.count))
            return bytes[bytes.startIndex..<end].range(of: Data(needle.utf8)) != nil
        }

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
