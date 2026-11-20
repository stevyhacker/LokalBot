import Foundation

enum ScreenContextPrivacy {
    struct Observation: Equatable, Sendable {
        var appName: String
        var bundleIdentifier: String?
        var windowTitle: String?
        var sourceURL: String?
        var focusedSecureField: Bool?
        var hasWebContent: Bool = false
        var containsSecureField: Bool = false
        var framedURLs: [String] = []
        var hasUnattributedWebContent: Bool = false
    }

    static func focusPermitsCapture(focusedSecureField: Bool?, containsSecureField: Bool) -> Bool {
        switch focusedSecureField {
        case false?: true
        case true?: false
        case nil: !containsSecureField
        }
    }

    static func permitsContent(
        _ observation: Observation,
        excludedApps: [String],
        excludedDomains: [String],
        allowsUnknownFocus: Bool = false
    ) -> Bool {
        guard !isExcluded(appName: observation.appName, bundleIdentifier: observation.bundleIdentifier,
                          rules: excludedApps),
              observation.windowTitle != nil else { return false }
        if allowsUnknownFocus {
            guard focusPermitsCapture(
                focusedSecureField: observation.focusedSecureField,
                containsSecureField: observation.containsSecureField) else { return false }
        } else {
            guard observation.focusedSecureField == false else { return false }
        }
        guard !isExcluded(sourceURL: observation.sourceURL, rules: excludedDomains),
              !observation.framedURLs.contains(where: { isExcluded(sourceURL: $0, rules: excludedDomains) }) else {
            return false
        }
        let hasDomainRules = Self.hasDomainRules(excludedDomains)
        if hasDomainRules, observation.hasWebContent || isBrowser(observation) {
            guard sanitizedURL(observation.sourceURL) != nil, !observation.hasUnattributedWebContent else {
                return false
            }
        }
        return true
    }

    static func hasDomainRules(_ excludedDomains: [String]) -> Bool {
        excludedDomains.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    struct ActivityDisposition: Equatable, Sendable {
        var keepsApp: Bool
        var keepsTitle: Bool
    }

    static func activityDisposition(
        appName: String,
        bundleIdentifier: String? = nil,
        observation: Observation?,
        excludedApps: [String],
        excludedDomains: [String]
    ) -> ActivityDisposition {
        guard !isExcluded(appName: appName, bundleIdentifier: bundleIdentifier ?? observation?.bundleIdentifier,
                          rules: excludedApps) else {
            return ActivityDisposition(keepsApp: false, keepsTitle: false)
        }
        guard let observation else { return ActivityDisposition(keepsApp: true, keepsTitle: false) }
        guard !isExcluded(sourceURL: observation.sourceURL, rules: excludedDomains) else {
            return ActivityDisposition(keepsApp: false, keepsTitle: false)
        }
        let hasDomainRules = Self.hasDomainRules(excludedDomains)
        let unverifiableSite = hasDomainRules
            && (observation.hasWebContent || isBrowser(observation))
            && sanitizedURL(observation.sourceURL) == nil
        let keepsTitle = observation.windowTitle != nil
            && observation.focusedSecureField != true
            && !unverifiableSite
        return ActivityDisposition(keepsApp: true, keepsTitle: keepsTitle)
    }

    static let passwordManagerBundleIdentifiers: Set<String> = [
        "com.apple.passwords", "com.apple.keychainaccess", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    static func isExcluded(appName: String, bundleIdentifier: String? = nil, rules: [String]) -> Bool {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        if passwordManagerBundleIdentifiers.contains(bundle) { return true }
        return rules.contains { rawTerm in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return false }
            if appName.localizedCaseInsensitiveContains(term) { return true }
            let rule = term.lowercased()
            return rule.contains(".") && (bundle == rule || bundle.hasPrefix(rule + "."))
        }
    }

    static func isBrowser(_ observation: Observation) -> Bool {
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
            #"\b((?:[A-Za-z0-9]+[_.-])*(?:api[\s_-]?key|access[\s_-]?token|auth[\s_-]?token|client[\s_-]?secret|password|passwd|secret|private[\s_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|token))(\s*[:=]\s*)[\"']?(?!\[REDACTED)[^\s\"',;]{6,}"#,
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
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{22,}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"\bglpat-[A-Za-z0-9_-]{20,}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+"#, replacement: "[REDACTED_WEBHOOK]"),
        Rule(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#, replacement: "[REDACTED_KEY]"),
        Rule(#"\bAIza[0-9A-Za-z_-]{35}"#, replacement: "[REDACTED_KEY]"),
        Rule(#"\bGOCSPX-[A-Za-z0-9_-]{20,}"#, replacement: "[REDACTED_KEY]"),
        Rule(#"\bnpm_[A-Za-z0-9]{36}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"\bhf_[A-Za-z0-9]{30,}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, replacement: "[REDACTED_KEY]"),
        Rule(#"\bpypi-[A-Za-z0-9_-]{50,}"#, replacement: "[REDACTED_TOKEN]"),
        Rule(#"\b([a-z][a-z0-9+.-]*://[^\s:/@]+):(?!\[REDACTED)[^\s@/]+@"#,
             options: [.caseInsensitive], replacement: "$1:[REDACTED]@"),
        Rule(
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            replacement: "[REDACTED_JWT]"),
        Rule(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
            replacement: "[REDACTED_PRIVATE_KEY]"),
    ]

    private static let checkedRules: [(rule: Rule, isMatch: (String) -> Bool)] = [
        (Rule(#"\b(?:\d{13,19}|\d{4}([ -])\d{4}\1\d{4}\1\d{4}(?:\1\d{3})?|\d{4}([ -])\d{6}\2\d{5})\b"#,
              replacement: "[REDACTED_CARD]"), isPaymentCardNumber),
        (Rule(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#,
              replacement: "[REDACTED_IBAN]"), isIBAN),
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
        for checked in checkedRules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = checked.rule.expression.matches(in: output, range: range).filter { match in
                Range(match.range, in: output).map { checked.isMatch(String(output[$0])) } == true
            }
            guard !matches.isEmpty else { continue }
            count += matches.count
            let replaced = NSMutableString(string: output)
            for match in matches.reversed() {
                replaced.replaceCharacters(in: match.range, with: checked.rule.replacement)
            }
            output = replaced as String
        }
        return Redaction(text: output, count: count)
    }

    static func isPaymentCardNumber(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let two = digits[0] * 10 + digits[1]
        let three = two * 10 + digits[2]
        let four = three * 10 + digits[3]
        let issued = digits[0] == 4 || (51...55).contains(two) || (2_221...2_720).contains(four)
            || [34, 36, 37, 38, 39, 62, 65].contains(two) || (300...305).contains(three)
            || four == 6_011 || (644...649).contains(three) || (3_528...3_589).contains(four)
        guard issued else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            let value = index % 2 == 1 ? digit * 2 : digit
            sum += value > 9 ? value - 9 : value
        }
        return sum % 10 == 0
    }

    static func isIBAN(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }
        guard (15...34).contains(compact.count) else { return false }
        var remainder = 0
        for character in compact.dropFirst(4) + compact.prefix(4) {
            guard let value = character.isLetter
                    ? character.asciiValue.map({ Int($0) - 55 })
                    : character.wholeNumberValue else { return false }
            remainder = (remainder * (value > 9 ? 100 : 10) + value) % 97
        }
        return remainder == 1
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

    static func sanitizedDocumentName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL {
            return String(url.lastPathComponent.prefix(300))
        }
        if let url = URL(string: raw), url.scheme != nil, url.host != nil { return nil }
        return String(URL(fileURLWithPath: raw).lastPathComponent.prefix(300))
    }

    static func hasRichAccessibleText(_ text: String) -> Bool {
        let visible = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
        }
        return visible >= 80
    }
}
