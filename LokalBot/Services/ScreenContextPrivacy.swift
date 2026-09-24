import Foundation

/// Deterministic privacy rules applied before screen-derived text reaches FTS,
/// embeddings, exports, or an external read-only client. The rules intentionally
/// favor false positives: a redacted capture remains useful, while a persisted
/// credential cannot be taken back.
enum ScreenContextPrivacy {
    /// Only a successfully inspected focused window can supply retained
    /// content. A missing AX value is unknown, not evidence of a safe field.
    struct Observation: Equatable, Sendable {
        var appName: String
        var bundleIdentifier: String?
        var windowTitle: String?
        var sourceURL: String?
        var focusedSecureField: Bool?
        var hasWebContent: Bool = false
    }

    static func permitsContent(
        _ observation: Observation,
        excludedApps: [String],
        excludedDomains: [String],
        capturePrivateWindows: Bool
    ) -> Bool {
        guard !isExcluded(appName: observation.appName, rules: excludedApps),
              let title = observation.windowTitle,
              observation.focusedSecureField == false else { return false }
        guard capturePrivateWindows || !isPrivateWindow(title: title) else { return false }
        if !capturePrivateWindows, observation.hasWebContent || isBrowser(observation),
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        guard !isExcluded(sourceURL: observation.sourceURL, rules: excludedDomains) else {
            return false
        }
        // A browser with an unreadable address cannot establish that it is
        // outside a configured exclusion. Native documents need no web URL.
        let hasDomainRules = excludedDomains.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasDomainRules, observation.hasWebContent || isBrowser(observation) {
            guard sanitizedURL(observation.sourceURL) != nil else { return false }
        }
        return true
    }

    static func isExcluded(appName: String, rules: [String]) -> Bool {
        rules.contains { rawTerm in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            return !term.isEmpty && appName.localizedCaseInsensitiveContains(term)
        }
    }

    private static func isBrowser(_ observation: Observation) -> Bool {
        let identifier = observation.bundleIdentifier?.lowercased() ?? ""
        let browserIdentifiers = [
            "com.apple.safari", "com.google.chrome", "org.chromium.chromium",
            "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
            "company.thebrowser.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "com.duckduckgo.macos.browser", "com.kagi.kagimacOS", "app.zen-browser.zen",
        ]
        if browserIdentifiers.contains(where: { identifier.hasPrefix($0.lowercased()) }) {
            return true
        }
        // Includes development/channel builds with a different bundle ID.
        return ["safari", "chrome", "chromium", "firefox", "brave", "microsoft edge",
                "arc", "opera", "vivaldi", "duckduckgo", "orion", "zen", "browser"]
            .contains { observation.appName.lowercased() == $0 }
    }

    struct Redaction: Equatable, Sendable {
        var text: String
        var count: Int
    }

    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String

        init(_ pattern: String, options: NSRegularExpression.Options = [], replacement: String) {
            do {
                expression = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                preconditionFailure("Invalid built-in redaction pattern: \(pattern)")
            }
            self.replacement = replacement
        }
    }

    private static let redactionRules: [Rule] = [
        Rule(
            #"\b(api[\s_-]?key|access[\s_-]?token|auth[\s_-]?token|client[\s_-]?secret|password|passwd|secret|private[\s_-]?key)(\s*[:=]\s*)[\"']?[^\s\"',;]{6,}"#,
            options: [.caseInsensitive],
            replacement: "$1$2[REDACTED]"),
        Rule(
            #"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            options: [.caseInsensitive],
            replacement: "Bearer [REDACTED]"),
        Rule(
            #"\bAKIA[0-9A-Z]{16}\b"#,
            replacement: "[REDACTED_AWS_KEY]"),
        Rule(
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
            options: [.caseInsensitive],
            replacement: "[REDACTED_TOKEN]"),
        Rule(
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
            replacement: "[REDACTED_KEY]"),
        Rule(
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            replacement: "[REDACTED_JWT]"),
        Rule(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
            replacement: "[REDACTED_PRIVATE_KEY]"),
    ]

    static func redact(_ text: String) -> Redaction {
        guard !text.isEmpty else { return Redaction(text: "", count: 0) }
        var output = text
        var count = 0
        for rule in redactionRules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = rule.expression.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            count += matches
            output = rule.expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: rule.replacement)
        }
        return Redaction(text: output, count: count)
    }

    static func isPrivateWindow(title: String) -> Bool {
        let normalized = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current)
        return [
            "private browsing", "private window", "incognito", "inprivate",
            "navigation privee", "navegacion privada", "privates fenster",
        ].contains { normalized.contains($0) }
    }

    static func isExcluded(sourceURL: String?, rules: [String]) -> Bool {
        guard let sourceURL, !rules.isEmpty else { return false }
        let loweredURL = sourceURL.lowercased()
        let parsedHost = URL(string: sourceURL)?.host?.lowercased()
        return rules.contains { rawRule in
            var rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !rule.isEmpty else { return false }
            if rule.contains("://") {
                return loweredURL.hasPrefix(rule)
            }
            if rule.hasPrefix("*.") { rule.removeFirst(2) }
            rule = rule.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let slash = rule.firstIndex(of: "/") {
                let hostRule = String(rule[..<slash])
                guard let parsedHost,
                      parsedHost == hostRule || parsedHost.hasSuffix("." + hostRule) else {
                    return false
                }
                return loweredURL.contains(String(rule[slash...]))
            }
            guard let parsedHost else { return loweredURL.contains(rule) }
            return parsedHost == rule || parsedHost.hasSuffix("." + rule)
        }
    }

    /// Removes credentials, queries, and fragments before URL provenance is
    /// persisted. The path is useful context and domain exclusions still work,
    /// while common session tokens never become metadata.
    static func sanitizedURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              var components = URLComponents(string: raw),
              components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let value = components.string else { return nil }
        return String(value.prefix(800))
    }

    /// Full local paths disclose user names and folder structure. The document
    /// name preserves citation context without retaining that provenance.
    static func sanitizedDocumentName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL {
            return String(url.lastPathComponent.prefix(300))
        }
        return String(URL(fileURLWithPath: raw).lastPathComponent.prefix(300))
    }

    static func hasRichAccessibleText(_ text: String) -> Bool {
        let visible = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
        }
        return visible >= 80
    }
}
