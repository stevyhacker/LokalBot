import Foundation

enum CotypingMemoryContext {
    struct Policy: Equatable, Sendable {
        var meetings: Bool
        var screenDerived: Bool

        init(meetings: Bool, screenDerived: Bool) {
            self.meetings = meetings
            self.screenDerived = screenDerived
        }

        init(settings: AppSettings) {
            meetings = settings.cotypingUseMeetingMemory
            screenDerived = settings.cotypingUseScreenMemory
        }

        var enabled: Bool { meetings || screenDerived }

        func permits(_ item: Item) -> Bool {
            (!item.requiresMeetings || meetings) && (!item.requiresScreenMemory || screenDerived)
                && (item.requiresMeetings || item.requiresScreenMemory)
        }
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var text: String
        var updatedAt: Date
        var requiresMeetings: Bool
        var requiresScreenMemory: Bool = false
        var isWorkMemory: Bool = false
    }

    struct Selection: Equatable, Sendable {
        var items: [Item] = []
        var text: String? {
            items.isEmpty ? nil : items.map(\.text).joined(separator: "\n")
        }
        var sourceTitles: [String] { Array(Set(items.map(\.title))).sorted() }
    }

    struct Query: Equatable, Sendable {
        var own: Set<String> = []
        var all: Set<String> = []
        var named: Set<String> = []
        var capitalized: Set<String> = []
        var search: [String] = []

        init() {}

        init(draft: String, title: String = "", visible: String = "", appName: String = "") {
            let appTerms = CotypingMemoryContext.terms(appName)
            let titleWords = CotypingMemoryContext.tokens(title).filter { !appTerms.contains($0) }
            let draftWords = CotypingMemoryContext.tokens(draft)
            let visibleWords = CotypingMemoryContext.tokens(visible)

            own = Set(draftWords.filter(CotypingMemoryContext.isDistinctive))
            own.formUnion(titleWords.filter(CotypingMemoryContext.isDistinctive))
            all = own.union(visibleWords.filter(CotypingMemoryContext.isDistinctive))

            let draftCapitals = CotypingMemoryContext.capitalizedTerms(in: draft)
            let titleCapitals = CotypingMemoryContext.capitalizedTerms(in: title)
            named = draftCapitals.inside.union(titleCapitals.inside).union(titleCapitals.opening)
            named.subtract(appTerms)
            capitalized = named.union(draftCapitals.opening)

            var ordered: [String] = []
            var seen = Set<String>()
            var candidates = Array(draftWords.reversed())
            candidates.append(contentsOf: titleWords)
            candidates.append(contentsOf: visibleWords.reversed())
            for word in candidates where CotypingMemoryContext.isDistinctive(word) && seen.insert(word).inserted {
                ordered.append(word)
            }
            search = Array(ordered.prefix(CotypingMemoryContext.maxSearchTerms))
        }
    }

    struct Relevance: Equatable, Sendable {
        var score: Int
        var named: Bool
    }

    static let maxItems = 2
    static let maxItemCharacters = 180
    static let maxSearchTerms = 12
    static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    private static let genericTerms: Set<String> = [
        "please", "thanks", "thank", "hello", "dear", "hi", "team", "notes", "note", "meeting", "meetings",
        "project", "update", "status", "owner", "deadline", "decision", "decisions", "action", "next", "today",
        "tomorrow", "yesterday", "week", "month", "year", "send", "write", "writing", "message", "email",
        "review", "follow", "following", "need", "want", "just", "quick", "new", "work", "working", "plan",
        "planning", "discuss", "discussed", "subject", "topic", "draft", "check", "regarding", "due", "name",
    ]

    static func tokens(_ text: String) -> [String] {
        LibrarySearch.folded(text).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func isTerm(_ word: String) -> Bool {
        word.count >= 3 && !SearchIndex.stopWords.contains(word) && !genericTerms.contains(word)
    }

    static func isDistinctive(_ word: String) -> Bool {
        isTerm(word) && !everydayTerms.contains(word)
    }

    static func terms(_ text: String) -> Set<String> {
        Set(tokens(text).filter(isTerm))
    }

    static func distinctiveTerms(_ text: String) -> Set<String> {
        Set(tokens(text).filter(isDistinctive))
    }

    static func capitalizedTerms(in text: String) -> (inside: Set<String>, opening: Set<String>) {
        var inside = Set<String>()
        var opening = Set<String>()
        var word = ""
        var nextOpens = true
        var wordOpens = true
        func flush() {
            defer { word = "" }
            guard let first = word.first else { return }
            let nameShaped = first.isUppercase
                || (word.contains(where: \.isNumber) && word.contains(where: \.isLetter))
            let term = LibrarySearch.folded(word)
            guard nameShaped, isDistinctive(term) else { return }
            if wordOpens { opening.insert(term) } else { inside.insert(term) }
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if word.isEmpty {
                    wordOpens = nextOpens
                    nextOpens = false
                }
                word.append(character)
            } else {
                flush()
                if ".!?:;\n\r•".contains(character) { nextOpens = true }
            }
        }
        flush()
        return (inside, opening)
    }

    static let maxVisibleQueryCharacters = 600

    static func query(for field: CotypingField, includeTitle: Bool, includeVisibleContext: Bool = true) -> Query {
        guard !field.isSecure, field.selectionLength == 0,
              ![CotypingSurfaceClass.codeEditor, .terminal].contains(
                CotypingSurfaceClassifier.classify(bundleID: field.bundleID,
                                                   isIntegratedTerminal: field.isIntegratedTerminal)) else { return Query() }
        let draft = String(field.precedingText.suffix(500))
        let title = includeTitle ? field.windowTitle ?? "" : ""
        let visible = includeVisibleContext
            ? String((field.visibleContext?.text ?? "").suffix(maxVisibleQueryCharacters)) : ""
        guard ScreenContextPrivacy.redact([draft, title, visible].joined(separator: " ")).count == 0 else { return Query() }
        return Query(draft: draft, title: title, visible: visible, appName: field.appName)
    }

    static func names(title: String, query: Query) -> Int? {
        let titleTerms = distinctiveTerms(title)
        let shared = titleTerms.intersection(query.all).count
        return shared > 0 && shared * 2 >= titleTerms.count ? shared : nil
    }

    static func isHeading(_ text: String, of title: String) -> Bool {
        let titleWords = Set(tokens(title))
        return !tokens(text).contains { word in
            (isTerm(word) || word.contains(where: \.isNumber)) && !titleWords.contains(word)
        }
    }

    static func relevance(text: String, title: String, query: Query,
                          allowBodyMatch: Bool = true, isStatement: Bool = false) -> Relevance? {
        guard isStatement || !isHeading(text, of: title) else { return nil }
        let shared = distinctiveTerms(text).intersection(query.own)
        if let named = names(title: title, query: query) {
            return Relevance(score: named * 3 + shared.count, named: true)
        }
        guard allowBodyMatch, shared.count >= 2 else { return nil }
        let capitals = capitalizedTerms(in: text)
        let sharesName = shared.contains { word in
            capitals.inside.contains(word) || query.named.contains(word)
                || (capitals.opening.contains(word) && query.capitalized.contains(word))
        }
        guard sharesName || shared.count >= 3 else { return nil }
        return Relevance(score: shared.count, named: false)
    }

    static func select(items: [Item], for field: CotypingField, includeTitle: Bool,
                       policy: Policy, now: Date = Date(), allowBodyMatch: Bool = true) -> Selection {
        select(items: items, query: query(for: field, includeTitle: includeTitle),
               policy: policy, now: now, allowBodyMatch: allowBodyMatch)
    }

    static func select(items: [Item], query: String, policy: Policy, now: Date = Date()) -> Selection {
        select(items: items, query: Query(draft: query), policy: policy, now: now)
    }

    static func select(items: [Item], query: Query, policy: Policy, now: Date = Date(),
                       allowBodyMatch: Bool = true) -> Selection {
        guard policy.enabled, !query.all.isEmpty else { return Selection() }
        var ranked: [(Item, Int, Bool)] = []
        for item in items where policy.permits(item) {
            guard now.timeIntervalSince(item.updatedAt) >= -60,
                  now.timeIntervalSince(item.updatedAt) <= maxAge,
                  let text = sanitized(item.text), let title = sanitized(item.title),
                  let relevance = relevance(text: text, title: title, query: query,
                                            allowBodyMatch: allowBodyMatch,
                                            isStatement: item.isWorkMemory) else { continue }
            var selected = item
            selected.text = PromptContextSanitizer.sanitize(text, maxCharacters: maxItemCharacters)
            selected.title = String(title.prefix(80))
            ranked.append((selected, relevance.score, relevance.named))
        }
        if ranked.contains(where: { $0.2 }) { ranked.removeAll { !$0.2 } }
        ranked.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id < $1.0.id
        }
        let newest = Dictionary(grouping: ranked.map(\.0), by: { LibrarySearch.folded($0.title) })
            .mapValues { $0.map(\.updatedAt).max() ?? Date.distantPast }
        var seen = Set<String>()
        return Selection(items: ranked.compactMap { item, _, _ in
            guard item.updatedAt == newest[LibrarySearch.folded(item.title)] else { return nil }
            return seen.insert(LibrarySearch.folded(item.text)).inserted ? item : nil
        }.prefix(maxItems).map { $0 })
    }

    static func sanitized(_ text: String) -> String? {
        guard !text.isEmpty, ScreenContextPrivacy.redact(text).count == 0 else { return nil }
        let lower = text.lowercased()
        guard !["<|", "[inst]", "[system]", "ignore previous", "ignore all previous", "system prompt",
                "assistant:", "system:", "developer:", "previously accepted completion:"].contains(where: lower.contains)
        else { return nil }
        let cleaned = PromptContextSanitizer.sanitize(text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }
}
