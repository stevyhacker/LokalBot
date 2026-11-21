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
        let markers = [role, subrole, roleDescription, title, descriptionLabel]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        return markers.contains { marker in
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
