import Foundation

enum CotypingAvailability {
    static func disabledReason(
        enabled: Bool,
        excludedApps: [String],
        excludedDomains: [String] = [],
        suggestInIntegratedTerminals: Bool = false,
        selfBundleID: String?,
        focus: CotypingFocus
    ) -> String? {
        guard enabled else { return "Cotyping is off." }

        if let selfBundleID, focus.bundleID == selfBundleID {
            return "Off in LokalBot."
        }

        if isExcluded(appName: focus.appName, bundleID: focus.bundleID, excluded: excludedApps) {
            return "Disabled in \(focus.appName.isEmpty ? "this app" : focus.appName)."
        }

        if CotypingBrowserDomain.isHostDisabled(focus.host, excludedDomains: excludedDomains) {
            return "Disabled on \(focus.host ?? "this site")."
        }

        if CotypingBrowserDomain.hasConfiguredExclusions(excludedDomains),
           CotypingSurfaceClassifier.classify(bundleID: focus.bundleID) == .browser,
           focus.host == nil {
            return "Cannot verify this browser site — Cotyping paused."
        }

        if CotypingSurfaceClassifier.classify(bundleID: focus.bundleID) == .terminal {
            return "Not available in terminal apps."
        }

        if !suggestInIntegratedTerminals, focus.field?.isIntegratedTerminal == true {
            return "Not available in the integrated terminal."
        }

        switch focus.capability {
        case .supported:
            return nil
        case .blocked(let why), .unsupported(let why):
            return why
        }
    }

    static func isExcluded(appName: String, bundleID: String?, excluded: [String]) -> Bool {
        let needles = excluded
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let haystacks = [appName.lowercased(), (bundleID ?? "").lowercased()]
        return needles.contains { needle in
            haystacks.contains { !$0.isEmpty && $0.contains(needle) }
        }
    }
}

enum CotypingSecureFieldDetector {
    static func isSecure(
        role: String?,
        subrole: String?,
        roleDescription: String?,
        title: String?,
        descriptionLabel: String?
    ) -> Bool {
        isSecureRole(role: role, subrole: subrole)
            || hasSecureLabel(roleDescription: roleDescription, title: title, descriptionLabel: descriptionLabel)
    }

    static func isSecureRole(role: String?, subrole: String?) -> Bool {
        containsSensitiveMarker([role, subrole])
    }

    static func hasSecureLabel(
        roleDescription: String?,
        title: String?,
        descriptionLabel: String?,
        extraLabels: [String?] = []
    ) -> Bool {
        let labels = [title, descriptionLabel] + extraLabels
        return containsSensitiveMarker([roleDescription] + labels)
            || labels.contains { $0.map(labelNamesSecret) ?? false }
    }

    private static func containsSensitiveMarker(_ markers: [String?]) -> Bool {
        markers
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
            .contains { marker in
                sensitiveMarkers.contains { marker.contains($0) }
            }
    }

    static let sensitiveMarkers: [String] = [
        "secure",
        "password",
        "passcode",
        "passphrase",
        "cvv",
        "cvc",
        "security code",
        "verification code",
        "one-time code",
        "one time code",
        "social security",
        "card number",
        "credit card",
    ]

    static let secretLabelSubstrings: [String] = [
        "passwort", "kennwort",
        "mot de passe",
        "contraseña",
        "wachtwoord",
        "lösenord",
        "adgangskode",
        "passord",
        "lozinka", "лозинка",
        "パスワード",
        "密码", "密碼",
        "비밀번호", "암호",
        "كلمة المرور", "كلمة السر",
        "סיסמה",
    ]

    static let secretLabelWordStarts: [String] = [
        "senha",
        "şifre", "parola",
        "hasło", "hasła", "haslo", "hasla",
        "парол",
        "api key", "secret key", "secret access key", "access token", "private key",
        "recovery phrase", "seed phrase",
        "ssn", "social security",
    ]

    private static let labelMatchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func labelNamesSecret(_ label: String) -> Bool {
        secretLabelSubstrings.contains { label.range(of: $0, options: labelMatchOptions) != nil }
            || secretLabelWordStarts.contains { startsWord($0, in: label) }
    }

    static func startsWord(_ term: String, in label: String) -> Bool {
        var searchRange = label.startIndex..<label.endIndex
        while let found = label.range(of: term, options: labelMatchOptions, range: searchRange) {
            guard found.lowerBound > label.startIndex else { return true }
            let scalars = label.unicodeScalars
            let previous = scalars[scalars.index(before: found.lowerBound)]
            if !CharacterSet.alphanumerics.contains(previous) {
                return true
            }
            searchRange = found.upperBound..<label.endIndex
        }
        return false
    }
}

enum CotypingCredentialFieldDetector {
    static let labelKeywords: [String] = [
        "email", "e-mail", "username", "user name", "user id", "userid", "login", "log in", "sign in",
        "phone", "mobile number", "password", "passcode", "pin", "one-time", "one time code",
        "verification code", "security code", "otp", "2fa", "two-factor", "authentication code",
        "card number", "cvc", "cvv", "expiry", "expiration",
    ]

    static let proseLabelWords: [String] = [
        "subject", "message", "body", "preview", "title", "signature", "template",
        "comment", "note", "notes", "reply", "search",
    ]

    static let credentialIdentifierWords: [String] = [
        "email", "mail", "username", "userid", "login", "logon", "signin", "passwd", "password", "pwd",
        "passcode", "otp", "totp", "mfa", "2fa", "phone", "telephone", "tel", "mobile", "msisdn", "pin",
        "cvc", "cvv", "cardnumber", "identifierid", "onetimecode", "verificationcode", "securitycode", "authcode",
        "apikey", "secretkey", "secretaccesskey", "accesstoken", "privatekey", "seedphrase", "recoveryphrase", "ssn",
    ]

    static let qualifierIdentifierWords: [String] = [
        "user", "account", "address", "addr", "id", "identifier", "name", "number", "num", "no", "code",
        "field", "input", "txt", "tb", "verification", "verify", "security", "auth", "onetime", "confirm",
        "current", "new", "primary", "your", "enter",
    ]

    static let maximumIdentifierLength = 64

    static func mightBeCredentialField(role: String) -> Bool {
        role == "AXTextField" || role == "AXComboBox"
    }

    static func isCredentialField(
        role: String,
        labels: [String?],
        domIdentifier: String?,
        text: String?
    ) -> Bool {
        guard mightBeCredentialField(role: role) else { return false }
        if labels.contains(where: { $0.map(labelNamesCredential) ?? false }) {
            return true
        }
        if let domIdentifier, domIdentifierNamesCredential(domIdentifier) {
            return true
        }
        return looksLikeAddressEntry(text)
    }

    static func labelNamesCredential(_ label: String) -> Bool {
        let lowered = label.lowercased()
        guard labelKeywords.contains(where: { containsWord($0, in: lowered) })
            || CotypingSecureFieldDetector.labelNamesSecret(label) else {
            return false
        }
        return !proseLabelWords.contains(where: { containsWord($0, in: lowered) })
    }

    static func domIdentifierNamesCredential(_ identifier: String) -> Bool {
        let characters = Array(identifier.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !characters.isEmpty, characters.count <= maximumIdentifierLength else { return false }

        var reach = [Bool?](repeating: nil, count: characters.count + 1)
        reach[0] = false
        for start in characters.indices {
            guard let namesCredential = reach[start] else { continue }
            if characters[start].isNumber {
                reach[start + 1] = (reach[start + 1] ?? false) || namesCredential
            }
            for entry in identifierVocabulary where characters[start...].starts(with: entry.word) {
                let end = start + entry.word.count
                reach[end] = (reach[end] ?? false) || namesCredential || entry.namesCredential
            }
        }
        return reach[characters.count] == true
    }

    static func looksLikeAddressEntry(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return text.range(of: #"^[^\s@/:]+@[^\s@/:]*$"#, options: .regularExpression) != nil
    }

    private static let identifierVocabulary: [(word: [Character], namesCredential: Bool)] =
        credentialIdentifierWords.map { (Array($0), true) } + qualifierIdentifierWords.map { (Array($0), false) }

    static func containsWord(_ keyword: String, in label: String) -> Bool {
        var searchRange = label.startIndex..<label.endIndex
        while let found = label.range(of: keyword, range: searchRange) {
            let before = found.lowerBound == label.startIndex ? nil : label[label.index(before: found.lowerBound)]
            let after = found.upperBound == label.endIndex ? nil : label[found.upperBound]
            let isBoundary: (Character?) -> Bool = { $0.map { !$0.isLetter && !$0.isNumber } ?? true }
            if isBoundary(before) && isBoundary(after) {
                return true
            }
            searchRange = found.upperBound..<label.endIndex
        }
        return false
    }
}

enum CotypingCodeFieldDetector {
    static func isCodeField(labels: [String?]) -> Bool {
        labels.contains { label in
            guard let label else { return false }
            let words = words(in: label)
            guard !words.isEmpty else { return false }
            if words.count == 1, codeWords.contains(words[0]) { return true }
            if words.contains(where: secretWords.contains) { return true }
            if words.contains(where: codeWords.contains),
               words.contains(where: codeContextWords.contains) {
                return true
            }
            let joined = " " + words.joined(separator: " ") + " "
            return phrases.contains { joined.contains(" \($0) ") }
        }
    }

    static func words(in label: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(label)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                continue
            }
            if character.isUppercase, let previous = current.last {
                let nextIsLowercase = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || (previous.isUppercase && nextIsLowercase) {
                    words.append(current.lowercased())
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    static let codeWords: Set<String> = ["code", "kod", "код"]

    static let secretWords: Set<String> = [
        "otp", "totp", "2fa", "mfa", "pin", "passcode",
        "onetimecode", "otpcode", "smscode", "verificationcode",
    ]

    static let codeContextWords: Set<String> = [
        "verification", "verify", "confirmation", "confirm", "authentication",
        "authenticator", "auth", "login", "signin", "sms", "sent", "texted",
        "digit", "digits", "enter", "access", "backup", "recovery",
        "verifikacioni", "verifikacijski", "verifikaciju", "potvrdu", "potvrdni",
        "sigurnosni", "jednokratni", "unesite", "poslat", "poslan",
        "верификациони", "верификацију", "потврду", "потврдни", "сигурносни",
        "једнократни", "унесите", "послат", "смс",
    ]

    static let phrases: [String] = [
        "one time code",
        "one time password",
        "one time passcode",
        "one time pin",
        "two factor",
        "2 factor",
        "two step",
        "2 step",
        "multi factor",
        "sign in code",
        "log in code",
        "jednokratna lozinka",
        "једнократна лозинка",
    ]
}

struct CotypingAppReadPolicy: Equatable, Sendable {
    var enabled = false
    var excludedApps: [String] = []
    var selfBundleID: String?

    func allows(appName: String, bundleID: String?) -> Bool {
        guard enabled, !appName.isEmpty || bundleID?.isEmpty == false else { return false }
        if let selfBundleID, bundleID == selfBundleID { return false }
        return !CotypingAvailability.isExcluded(
            appName: appName, bundleID: bundleID, excluded: excludedApps)
    }

    func readIfAllowed<Value>(appName: String, bundleID: String?, _ read: () -> Value?) -> Value? {
        guard allows(appName: appName, bundleID: bundleID) else { return nil }
        return read()
    }
}
