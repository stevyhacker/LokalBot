import Foundation

struct CotypingBenchmarkScenario: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var field: CotypingField
    var expectedTerms: [String]
    var latencyTargetMs: Int
    var expectsVisibleSuggestion: Bool = true
    var allowedSuppressions: [CotypingSuppressionReason] = []
    /// Word-completion contract (Cotypist parity): the caret sits at the end of
    /// a word fragment and a visible suggestion MUST extend it — begin with a
    /// word character, and (when provided) with one of
    /// `expectedCompletionPrefixes`, the tails of every real word that fits the
    /// fragment. Silence is safe but counts as a miss unless it is one of the
    /// `allowedSuppressions`.
    var expectsWordCompletion: Bool = false
    var expectedCompletionPrefixes: [String] = []
    /// Mirrors the coordinator's spell-checker verdict for the fragment at the
    /// caret; drives the normalizer's whitespace-leading rejection.
    var wordPrefixIsValidWord: Bool = true

    private static func field(
        app: String, bundleID: String, role: String = "AXTextArea",
        preceding: String, trailing: String = "",
        windowTitle: String? = nil, placeholder: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: app, bundleID: bundleID, processID: 0, role: role,
            precedingText: preceding, trailingText: trailing, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: windowTitle, fieldPlaceholder: placeholder)
    }

    /// 26 scenarios in four groups: next-word continuations, word completions
    /// (the caret is mid-word and the suggestion must finish the word — the
    /// Cotypist parity gap), strictly-inside-word safety, and context/format
    /// robustness. Latency targets: 2000 ms for the cold first case, 1500 ms
    /// steady-state, 1200 ms for short mid-word prompts.
    static let defaults: [CotypingBenchmarkScenario] = [
        // — Next-word continuations —
        CotypingBenchmarkScenario(
            id: "email-follow-up", name: "Email follow-up",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
                windowTitle: "Re: Q3 planning"),
            expectedTerms: ["up", "today", "tomorrow", "with"],
            latencyTargetMs: 2_000),
        CotypingBenchmarkScenario(
            id: "chat-ownership", name: "Chat ownership",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Sounds good, I can take",
                windowTitle: "project-launch", placeholder: "Message #project-launch"),
            expectedTerms: ["that", "it", "this", "over", "care"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "browser-prose", name: "Browser prose",
            field: field(
                app: "Safari", bundleID: "com.apple.Safari",
                preceding: "The main tradeoff is",
                windowTitle: "Design note", placeholder: "Leave a comment"),
            expectedTerms: ["that", "between", "latency", "quality", "speed"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "email-update", name: "Email status update",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi team,\nJust a quick update on the",
                windowTitle: "Weekly sync"),
            expectedTerms: ["project", "status", "progress", "launch", "release"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "email-scheduling", name: "Email scheduling",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Could we move our call to",
                windowTitle: "Re: catch-up"),
            expectedTerms: ["tomorrow", "next", "monday", "friday", "afternoon", "later"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "notes-list", name: "Notes list continuation",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Top priorities for next week:\n1. Ship the beta\n2.",
                windowTitle: "Planning"),
            expectedTerms: ["fix", "review", "write", "prepare", "follow", "update"],
            latencyTargetMs: 1_500),

        // — Word completion: caret at the end of a fragment no dictionary word
        //   equals, so the ghost text MUST extend it (Cotypist parity) —
        CotypingBenchmarkScenario(
            id: "wc-follow", name: "Complete: follo→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Sarah,\nThanks for sending this over. I wanted to follo",
                windowTitle: "Re: Q3 planning"),
            expectedTerms: ["up"],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-conversation", name: "Complete: conversati→on",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Great catching up today — let's continue this conversati",
                windowTitle: "dm-alex"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["on"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-tomorrow", name: "Complete: tomorro→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "I'll send over the final report tomorro",
                windowTitle: "Re: deliverables"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-receive", name: "Complete: recei→ve",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Please let me know as soon as you recei",
                windowTitle: "Re: files"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["ve", "pt"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-productive", name: "Complete: producti→ve",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Thanks everyone, that was a really producti",
                windowTitle: "team-standup"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["ve", "vity", "on"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-schedule", name: "Complete: schedu→le",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Let me double-check my schedu",
                windowTitle: "Todo"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["le", "ling"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-important", name: "Complete: importa→nt",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "One more thing — this part is really importa",
                windowTitle: "project-launch"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["nt", "nce"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-weekend", name: "Complete: weeke→nd",
            field: field(
                app: "Messages", bundleID: "com.apple.MobileSMS",
                preceding: "Sounds great, have a lovely weeke",
                windowTitle: "Mom"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["nd"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-around", name: "Complete: aro→und",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "The budget for Q3 lands somewhere aro",
                windowTitle: "Re: budget"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["und", "use", "se", "ma"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-german", name: "Complete (de): Unterstüt→zung",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hallo Jonas,\nvielen Dank für deine Unterstüt",
                windowTitle: "AW: Projekt"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["zung", "zen", "zt"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-long-context", name: "Complete in long email: revie→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Priya,\n\nThanks for pulling the launch numbers together so quickly. "
                    + "The conversion funnel looks stronger than last quarter, and the retention "
                    + "curve is finally flattening where we hoped it would. Before we share this "
                    + "with the wider team I want to make sure the annotations are right, the "
                    + "cohort definitions match the dashboard, and the appendix links resolve. "
                    + "When you have a moment, could you please revie",
                windowTitle: "Re: launch metrics"),
            expectedTerms: [],
            latencyTargetMs: 2_000,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),

        // — Word fragments that are already valid words: both "extend the word"
        //   and "start the next word" are legitimate, so only visibility is
        //   asserted —
        CotypingBenchmarkScenario(
            id: "valid-fragment-the", name: "Valid fragment: the",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "I think we should discuss the",
                windowTitle: "Agenda"),
            expectedTerms: [],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "valid-fragment-can", name: "Valid fragment: can",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Absolutely, we can",
                windowTitle: "support-queue"),
            expectedTerms: [],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "valid-fragment-don", name: "Valid fragment: don('t)",
            field: field(
                app: "Messages", bundleID: "com.apple.MobileSMS",
                preceding: "I'm sure we'll figure it out, don",
                windowTitle: "Alex"),
            expectedTerms: [],
            latencyTargetMs: 1_200),

        // — Strictly inside a word (text after the caret): the suggestion must
        //   continue the word or stay quiet —
        CotypingBenchmarkScenario(
            id: "mid-word", name: "Mid-word safety",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Please rec",
                trailing: "eive the files when ready.",
                windowTitle: "Project notes"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            allowedSuppressions: [.duplicatesTrailingText, .unsafeToInsert, .wordCompletionMismatch],
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["eive"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "mid-word-budget", name: "Mid-word safety: bud|get",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "The quarterly bud",
                trailing: "get review is next Thursday.",
                windowTitle: "Finance"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            allowedSuppressions: [.duplicatesTrailingText, .unsafeToInsert, .wordCompletionMismatch],
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["get"],
            wordPrefixIsValidWord: false),

        // — Context and format robustness —
        CotypingBenchmarkScenario(
            id: "question", name: "Question continuation",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Could you send over the final version before",
                windowTitle: "design-review"),
            expectedTerms: ["friday", "monday", "tomorrow", "end", "meeting", "we"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "bullet-list", name: "Bullet list item",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Shopping list:\n- milk\n- eggs\n- ",
                windowTitle: "Groceries"),
            expectedTerms: ["bread", "butter", "cheese", "flour", "sugar", "coffee"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "support-reply", name: "Support reply",
            field: field(
                app: "Safari", bundleID: "com.apple.Safari",
                preceding: "Hi! Sorry for the trouble — I've reset your account and you should",
                windowTitle: "Helpdesk", placeholder: "Reply"),
            expectedTerms: ["be able", "now", "receive", "see", "get"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "german-prose", name: "German continuation",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Vielen Dank für deine Nachricht. Ich melde mich",
                windowTitle: "AW: Termin"),
            expectedTerms: ["morgen", "später", "nächste", "sobald", "bald", "bei"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "comma-clause", name: "Comma clause continuation",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "If the numbers hold up through Friday,",
                windowTitle: "Re: forecast"),
            expectedTerms: ["we", "then", "i", "the"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "sentence-start", name: "Fresh sentence start",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "The rollout went smoothly overall. ",
                windowTitle: "Retro"),
            expectedTerms: ["we", "the", "there", "a few", "next"],
            latencyTargetMs: 1_500),
    ]
}

/// What a scenario's result means for the person typing.
enum CotypingBenchmarkOutcome: String, Codable, Sendable {
    /// A suggestion the scenario accepts.
    case shown
    /// Silence the scenario explicitly allows (e.g. strictly inside a word).
    case allowedSilence
    /// No suggestion where one was expected, e.g. the confidence gate held it back.
    case withheld
    /// A real word tail, but not one the scenario accepts.
    case wrongCompletion
    /// Text that would damage the field: a leaked prompt, a split or corrupted
    /// word, or any insertion where silence was required.
    case unsafe
    case error
}

struct CotypingBenchmarkCaseResult: Identifiable, Equatable, Sendable {
    var id: String { scenarioID }
    var scenarioID: String
    var name: String
    var text: String
    var latencyMs: Int
    var firstVisibleLatencyMs: Int?
    var expectedTermHits: Int
    var expectedTermCount: Int
    var suppression: CotypingSuppressionReason?
    var error: String?
    var expectedVisibleSuggestion: Bool
    var allowedSuppression: Bool
    var expectedWordCompletion: Bool = false
    var expectedCompletionPrefixes: [String] = []
    /// Letters follow the caret, so any insertion lands inside an existing word.
    var insideWord: Bool = false

    var outcome: CotypingBenchmarkOutcome {
        if error != nil { return .error }
        if CotypingPromptLeakGuard.looksLikePromptScaffolding(text) { return .unsafe }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard expectedVisibleSuggestion || expectedWordCompletion, !allowedSuppression else {
                return .allowedSilence
            }
            return .withheld
        }
        if expectedWordCompletion {
            // The ghost text sits right after the fragment: a leading space or
            // punctuation would split the word ("follo w up").
            guard let first = text.first, first.isLetter || first.isNumber else { return .unsafe }
            let folded = text.lowercased()
            if expectedCompletionPrefixes.isEmpty
                || expectedCompletionPrefixes.contains(where: { folded.hasPrefix($0.lowercased()) }) {
                return .shown
            }
            // A wrong tail is only a miss at the end of a word; inside one it
            // corrupts the text that follows the caret.
            return insideWord ? .unsafe : .wrongCompletion
        }
        return expectedVisibleSuggestion ? .shown : .unsafe
    }

    /// Nothing harmful reached the field: no prompt leak, no split or corrupted
    /// word, no text where silence was required, and no engine error. Staying
    /// quiet is safe; how often that happens is reported as `withheld`.
    var passedSafety: Bool { outcome != .unsafe && outcome != .error }

    /// True when the suggestion completes the caret fragment into an accepted
    /// word (word-completion scenarios only) — surfaced separately so summaries
    /// can report the Cotypist-parity rate on its own.
    var wordCompletionHit: Bool {
        expectedWordCompletion && outcome == .shown
    }

    var latencyForTargetMs: Int { firstVisibleLatencyMs ?? latencyMs }
    var metLatencyTarget: Bool { latencyForTargetMs <= latencyTargetMs }
    var latencyTargetMs: Int
    var passed: Bool { passedSafety && metLatencyTarget }
}

struct CotypingBenchmarkSummary: Equatable, Sendable {
    var results: [CotypingBenchmarkCaseResult]

    var total: Int { results.count }
    var passed: Int { results.filter(\.passed).count }
    var safetyPassed: Int { results.filter(\.passedSafety).count }
    var keywordHits: Int { results.map(\.expectedTermHits).reduce(0, +) }
    var keywordTotal: Int { results.map(\.expectedTermCount).reduce(0, +) }

    /// Cotypist-parity signal: of the scenarios that demand a word completion,
    /// how many produced a suggestion that extends the typed fragment.
    var wordCompletionTotal: Int { results.filter(\.expectedWordCompletion).count }
    var wordCompletionPassed: Int { results.filter(\.wordCompletionHit).count }

    func count(_ outcome: CotypingBenchmarkOutcome) -> Int {
        results.filter { $0.outcome == outcome }.count
    }

    var averageLatencyMs: Int? {
        guard !results.isEmpty else { return nil }
        return results.map(\.latencyMs).reduce(0, +) / results.count
    }

    var averageFirstVisibleLatencyMs: Int? {
        let values = results.compactMap(\.firstVisibleLatencyMs)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    var p95LatencyMs: Int? {
        percentile(results.map(\.latencyMs), 0.95)
    }

    var p95FirstVisibleLatencyMs: Int? {
        let values = results.compactMap(\.firstVisibleLatencyMs)
        return percentile(values, 0.95)
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
}

/// Machine-readable rendering for `LokalBot --cotyping-bench` — the scriptable
/// evaluation model consumed by `Benchmarks/Cotyping/side_by_side.py`.
extension CotypingBenchmarkSummary {
    fileprivate struct CaseJSON: Codable {
        let id: String
        let name: String
        let text: String
        let latencyMs: Int
        let firstVisibleLatencyMs: Int?
        let suppression: String?
        let error: String?
        let outcome: CotypingBenchmarkOutcome
        let passedSafety: Bool
        let metLatencyTarget: Bool
        let expectedTermHits: Int
        let expectedTermCount: Int
        let expectsWordCompletion: Bool
        let wordCompletionHit: Bool
    }

    fileprivate struct ReportJSON: Codable {
        let total: Int
        let passed: Int
        let safetyPassed: Int
        let keywordHits: Int
        let keywordTotal: Int
        let wordCompletionPassed: Int
        let wordCompletionTotal: Int
        let averageLatencyMs: Int?
        let p95LatencyMs: Int?
        let averageFirstVisibleLatencyMs: Int?
        let outcomes: [String: Int]
        let scenarios: [CaseJSON]
    }

    func jsonReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(reportJSON()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate func reportJSON() -> ReportJSON {
        ReportJSON(
            total: total,
            passed: passed,
            safetyPassed: safetyPassed,
            keywordHits: keywordHits,
            keywordTotal: keywordTotal,
            wordCompletionPassed: wordCompletionPassed,
            wordCompletionTotal: wordCompletionTotal,
            averageLatencyMs: averageLatencyMs,
            p95LatencyMs: p95LatencyMs,
            averageFirstVisibleLatencyMs: averageFirstVisibleLatencyMs,
            outcomes: Dictionary(results.map { ($0.outcome.rawValue, 1) }, uniquingKeysWith: +),
            scenarios: results.map { result in
                CaseJSON(
                    id: result.scenarioID,
                    name: result.name,
                    text: result.text,
                    latencyMs: result.latencyMs,
                    firstVisibleLatencyMs: result.firstVisibleLatencyMs,
                    suppression: result.suppression?.rawValue,
                    error: result.error,
                    outcome: result.outcome,
                    passedSafety: result.passedSafety,
                    metLatencyTarget: result.metLatencyTarget,
                    expectedTermHits: result.expectedTermHits,
                    expectedTermCount: result.expectedTermCount,
                    expectsWordCompletion: result.expectedWordCompletion,
                    wordCompletionHit: result.wordCompletionHit)
            })
    }
}

/// `LokalBot --cotyping-bench --model-path` output: pass 1's scenario results,
/// model loading on its own, and latency split into the first pass (each
/// prompt seen for the first time after loading) and the warm passes after it.
struct CotypingEngineBenchmarkReport {
    var loadMs: Int
    var maxWords: Int
    var summaries: [CotypingBenchmarkSummary]

    struct LatencyJSON: Codable, Equatable {
        let count: Int
        let meanMs: Int
        let medianMs: Int
        let p90Ms: Int
        let p95Ms: Int
        let maxMs: Int
    }

    private struct ReportJSON: Codable {
        let loadMs: Int
        let maxWords: Int
        let passes: Int
        let consistentAcrossPasses: Bool
        let unsafe: Int
        let errors: Int
        let firstPassLatency: LatencyJSON?
        let warmLatency: LatencyJSON?
        let firstPass: CotypingBenchmarkSummary.ReportJSON
    }

    var unsafe: Int { summaries.map { $0.count(.unsafe) }.reduce(0, +) }
    var errors: Int { summaries.map { $0.count(.error) }.reduce(0, +) }

    /// Decoding is greedy, so every pass should show exactly the same thing.
    var consistentAcrossPasses: Bool {
        let shown = summaries.map { $0.results.map { "\($0.text)|\($0.suppression?.rawValue ?? "")" } }
        return shown.allSatisfy { $0 == shown.first }
    }

    /// Nearest-rank percentiles, as the replay scripts compute them.
    static func latency(_ values: [Int]) -> LatencyJSON? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Int { sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)] }
        return LatencyJSON(
            count: sorted.count, meanMs: sorted.reduce(0, +) / sorted.count, medianMs: rank(0.5),
            p90Ms: rank(0.9), p95Ms: rank(0.95), maxMs: sorted[sorted.count - 1])
    }

    func json() -> String {
        guard let first = summaries.first else { return "{}" }
        let report = ReportJSON(
            loadMs: loadMs, maxWords: maxWords, passes: summaries.count,
            consistentAcrossPasses: consistentAcrossPasses, unsafe: unsafe, errors: errors,
            firstPassLatency: Self.latency(first.results.map(\.latencyMs)),
            warmLatency: Self.latency(summaries.dropFirst().flatMap { $0.results.map(\.latencyMs) }),
            firstPass: first.reportJSON())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class CotypingBenchmarkLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVisibleLatencyMs: Int?

    func recordFirstVisible(start: Date, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard firstVisibleLatencyMs == nil else { return }
        firstVisibleLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return firstVisibleLatencyMs
    }
}

@MainActor
enum CotypingBenchmarkRunner {
    static func run(
        scenarios: [CotypingBenchmarkScenario] = CotypingBenchmarkScenario.defaults,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        streamPartials: Bool = false,
        learnedExamples: (CotypingField) -> [String] = { _ in [] }
    ) async -> CotypingBenchmarkSummary {
        var results: [CotypingBenchmarkCaseResult] = []
        for scenario in scenarios {
            results.append(await runOne(
                scenario,
                engine: engine,
                config: config,
                personalization: personalization,
                streamPartials: streamPartials,
                learnedExamples: learnedExamples(scenario.field)))
        }
        return CotypingBenchmarkSummary(results: results)
    }

    /// Runs every scenario `passes` times against the runtime the app builds for
    /// autocomplete, with fresh-install settings. Like `--cotyping-replay`, it
    /// reads only the given model: no saved settings, library, learning or
    /// window. Exit 1 when anything was unsafe or errored.
    static func runEngine(model: URL, passes: Int) async -> Int32 {
        let engine = LocalLlamaCotypingEngine(runtime: .forAutocomplete(), modelPath: model.path)
        let settings = AppSettings()
        var config = CotypingConfiguration.standard
        config.maxResponseTokens = settings.cotypingMaxResponseTokens
        config.maxResponseWords = settings.cotypingMaxWords
        let loadStart = Date()
        do {
            try await engine.prewarm()
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Cotyping bench: \(error)\n".utf8))
            return 1
        }
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        var summaries: [CotypingBenchmarkSummary] = []
        for _ in 0..<passes {
            summaries.append(await run(
                engine: engine, config: config, personalization: settings.cotypingPersonalization))
        }
        await engine.unload()
        let report = CotypingEngineBenchmarkReport(
            loadMs: loadMs, maxWords: config.maxResponseWords, summaries: summaries)
        print(report.json())
        return report.unsafe + report.errors == 0 ? 0 : 1
    }

    static func evaluate(
        scenario: CotypingBenchmarkScenario,
        text: String,
        suppression: CotypingSuppressionReason?,
        latencyMs: Int,
        firstVisibleLatencyMs: Int? = nil,
        error: String? = nil
    ) -> CotypingBenchmarkCaseResult {
        let folded = text.lowercased()
        let hits = scenario.expectedTerms.filter { folded.contains($0.lowercased()) }.count
        return CotypingBenchmarkCaseResult(
            scenarioID: scenario.id,
            name: scenario.name,
            text: text,
            latencyMs: max(0, latencyMs),
            firstVisibleLatencyMs: firstVisibleLatencyMs.map { max(0, $0) },
            expectedTermHits: hits,
            expectedTermCount: scenario.expectedTerms.count,
            suppression: suppression,
            error: error,
            expectedVisibleSuggestion: scenario.expectsVisibleSuggestion,
            allowedSuppression: suppression.map { scenario.allowedSuppressions.contains($0) } ?? false,
            expectedWordCompletion: scenario.expectsWordCompletion,
            expectedCompletionPrefixes: scenario.expectedCompletionPrefixes,
            insideWord: scenario.field.trailingText.first?.isLetter == true,
            latencyTargetMs: scenario.latencyTargetMs)
    }

    private static func runOne(
        _ scenario: CotypingBenchmarkScenario,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        streamPartials: Bool,
        learnedExamples: [String]
    ) async -> CotypingBenchmarkCaseResult {
        guard let request = CotypingRequestBuilder.build(
            field: scenario.field,
            config: config,
            personalization: personalization,
            generation: 0,
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: scenario.wordPrefixIsValidWord)
        else {
            return evaluate(
                scenario: scenario,
                text: "",
                suppression: .emptyGeneration,
                latencyMs: 0,
                error: "Could not build request.")
        }

        let start = Date()
        let latencyProbe = CotypingBenchmarkLatencyProbe()
        do {
            let result = try await engine.generateStreaming(request) { partial in
                guard streamPartials else { return }
                latencyProbe.recordFirstVisible(start: start, text: partial.text)
            }
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return evaluate(
                scenario: scenario,
                text: result.text,
                suppression: result.suppression,
                latencyMs: latency,
                firstVisibleLatencyMs: latencyProbe.value)
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return evaluate(
                scenario: scenario,
                text: "",
                suppression: nil,
                latencyMs: latency,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
