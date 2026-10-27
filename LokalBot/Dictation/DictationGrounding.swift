import Foundation

/// Which spoken openings count as a writing request that may use context.
/// Production uses `.production`; the replay benchmark compares the others
/// (Benchmarks/Dictation/results/2026-10-08-routing-window). `relays`
/// answered more requests but routed "Tell him I am running 10 minutes late"
/// as one and copied a screen fact into it; `referencedRelays` never did.
enum DictationRequestRouting: String, Codable, Sendable, CaseIterable {
    /// The original command list ("reply", "draft", "napiši", …).
    case commands
    /// Also skips leading filler ("hey", "okay so", "dobro") and accepts relay
    /// verbs aimed at someone else: "tell him…", "let her know…", "email
    /// Marko…", "reci mu…", never "tell me…" or "javi mi…".
    case relays
    /// Like `relays`, but a relay verb counts only when the request also
    /// points at context ("…from the message above", "…iz poruke").
    case referencedRelays

    static let production: Self = .referencedRelays
}

/// Dictation has its own grants. Reuse the current-source lookup without
/// enabling Autocomplete or inheriting its permissions or writing history.
enum DictationGrounding {
    /// Context can complete an explicit writing instruction. A direct sentence
    /// must not acquire claims from nearby messages, even in Compose mode.
    /// Unknown/ambiguous phrasing conservatively gets ordinary cleanup.
    static func requestsContext(_ speech: String, routing: DictationRequestRouting = .production) -> Bool {
        switch routing {
        case .commands: return requestsContextByCommand(speech)
        case .relays: return requestsContextWithRelays(speech, requiresReference: false)
        case .referencedRelays: return requestsContextWithRelays(speech, requiresReference: true)
        }
    }

    private static let commandWords: Set<String> = [
        "reply", "respond", "answer", "draft", "write", "compose", "rewrite", "rephrase", "edit", "polish",
        "summarize", "summarise", "translate", "odgovori", "napisi", "sastavi", "prevedi", "preformulisi",
        "ecris", "redige", "reponds", "reformule", "traduis", "schreibe", "verfasse", "antworte",
        "ubersetze", "escribe", "redacta", "responde", "traduce", "напиши", "ответь", "переведи",
        "rispondi", "scrivi", "redigi", "componi", "riscrivi", "riformula", "traduci", "riassumi",
    ]
    private static let politePhrases: [[String]] = [
        ["please"], ["can", "you"], ["could", "you"], ["would", "you"], ["i", "want", "you", "to"],
        ["i'd", "like", "you", "to"], ["molim", "te"], ["molim", "vas"], ["mozes", "li"], ["mozete", "li"],
        ["bitte"], ["por", "favor"], ["s'il", "te", "plait"], ["per", "favore"],
    ]
    private static let fillerWords: Set<String> = [
        "hey", "ok", "okay", "so", "um", "uh", "alright", "well", "okej", "dobro", "ajde", "hajde", "evo",
    ]
    private static let relayVerbs: Set<String> = [
        "tell", "ask", "remind", "email", "text", "reci", "kazi", "javi", "pitaj", "posalji", "podsjeti", "podseti",
    ]
    private static let otherPeople: Set<String> = [
        "him", "her", "them", "everyone", "everybody",
        "mu", "joj", "im", "ga", "je", "ih", "njemu", "njoj", "njima", "njega", "nju", "njih", "svima",
    ]
    private static let contextCues: Set<String> = [
        "above", "mentioned", "earlier", "previous", "message", "thread", "chat", "email", "screen",
        "iznad", "gore", "poruke", "poruci", "poruka", "pomenut", "pomenuto", "spomenut", "spomenuto",
    ]

    private static func requestsContextWithRelays(_ speech: String, requiresReference: Bool) -> Bool {
        let original = speech.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        let words = original.map { LibrarySearch.folded($0).replacingOccurrences(of: "’", with: "'") }
        var index = 0
        stripping: for _ in 0..<5 {
            guard index < words.count else { return false }
            if fillerWords.contains(words[index]) {
                index += 1
                continue
            }
            for phrase in politePhrases where words[index...].starts(with: phrase) {
                index += phrase.count
                continue stripping
            }
            break
        }
        guard index < words.count else { return false }
        let command = words[index]
        if commandWords.contains(command) { return true }
        let next = index + 1 < words.count ? words[index + 1] : nil
        // A capitalized second word is a name ("Email Marko…"); lower-case
        // "email works" is a sentence about email.
        let namesSomeone = index + 1 < original.count && original[index + 1].first?.isUppercase == true
            && words[index + 1] != "i"
        let aimedElsewhere = next.map { otherPeople.contains($0) } == true || namesSomeone
        let isRelay = (relayVerbs.contains(command) && aimedElsewhere)
            || (command == "let" && aimedElsewhere && index + 2 < words.count && words[index + 2] == "know")
        guard isRelay else { return false }
        return !requiresReference || words[(index + 1)...].contains { contextCues.contains($0) }
    }

    private static func requestsContextByCommand(_ speech: String) -> Bool {
        var text = LibrarySearch.folded(speech).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["please ", "can you ", "could you ", "would you ", "i want you to ", "i'd like you to ",
                        "molim te ", "molim vas ", "mozes li ", "mozete li ", "bitte ", "por favor ", "s'il te plait ",
                        "per favore "]
        for _ in 0..<3 {
            guard let prefix = prefixes.first(where: text.hasPrefix) else { break }
            text.removeFirst(prefix.count)
        }
        let command = text.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return ["reply", "respond", "answer", "draft", "write", "compose", "rewrite", "rephrase", "edit", "polish",
                "summarize", "summarise", "translate", "odgovori", "napisi", "sastavi", "prevedi", "preformulisi",
                "ecris", "redige", "reponds", "reformule", "traduis", "schreibe", "verfasse", "antworte",
                "ubersetze", "escribe", "redacta", "responde", "traduce", "напиши", "ответь", "переведи",
                "rispondi", "scrivi", "redigi", "componi", "riscrivi", "riformula", "traduci", "riassumi"].contains(command)
    }

    static func memorySettings(_ settings: AppSettings) -> AppSettings {
        var selected = settings
        selected.cotypingUseMeetingMemory = settings.dictationIntent == .compose && settings.dictationUseMeetingMemory
        selected.cotypingUseScreenMemory = settings.dictationIntent == .compose && settings.dictationUseScreenMemory
        selected.cotypingUseAppContext = settings.dictationUseScreenContext || settings.dictationUseVisibleContext
        return selected
    }

    static func visiblePolicy(_ settings: AppSettings) -> CotypingVisibleContext.Policy {
        .init(enabled: settings.dictationIntent == .compose && settings.dictationUseVisibleContext,
              excludedApps: settings.excludedAppList, excludedDomains: settings.excludedScreenDomainList)
    }

    static func field(speech: String, screen: DictationScreenContext?,
                      visible: CotypingVisibleContext.Snapshot?) -> CotypingField {
        // This query is a spoken writing request, not typed shell/code input.
        var field = CotypingField(appName: "Dictation", processID: 0, role: "AXTextArea",
                                  precedingText: speech, trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true,
                                  windowTitle: visible?.target.windowTitle ?? screen?.windowTitle)
        field.visibleContext = visible
        return field
    }

    static func permissionsMatch(_ frozen: AppSettings, _ current: AppSettings) -> Bool {
        frozen.dictationIntent == current.dictationIntent
            && frozen.dictationUseScreenContext == current.dictationUseScreenContext
            && frozen.dictationUseVisibleContext == current.dictationUseVisibleContext
            && frozen.dictationUseMeetingMemory == current.dictationUseMeetingMemory
            && frozen.dictationUseScreenMemory == current.dictationUseScreenMemory
            && frozen.excludedApps == current.excludedApps
            && frozen.excludedScreenDomains == current.excludedScreenDomains
            && frozen.approvedRemoteInferenceOrigins == current.approvedRemoteInferenceOrigins
            && destinationMatches(frozen.dictationCompositionTextEngineSettings,
                                  current.dictationCompositionTextEngineSettings)
    }

    private static func destinationMatches(_ frozen: AppSettings, _ current: AppSettings) -> Bool {
        frozen.summarizerBackend == current.summarizerBackend
            && frozen.builtInModelID == current.builtInModelID
            && frozen.openAIBaseURL == current.openAIBaseURL
            && frozen.ollamaBaseURL == current.ollamaBaseURL
            && !InferencePresentation(settings: current).isBlocked
    }
}
