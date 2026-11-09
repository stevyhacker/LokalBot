import Foundation

/// The context window OpenRouter publishes for the selected model. It is read
/// only from an OpenRouter origin the user approved for inference, and the
/// request carries the model id in its path and nothing else: no API key and
/// no meeting content. The last answer is kept so a failed lookup cannot
/// change a meeting's part plan and discard its partial notes.
actor OpenRouterModelCatalog {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = OpenRouterModelCatalog()
    static let defaultsKey = "lokalbotv3.openRouterContextTokens"
    /// Endpoint lists change; a running app looks again once a day.
    static let refreshInterval: TimeInterval = 86_400

    private static let session = InferenceURLSession.make(requestTimeout: 5, resourceTimeout: 10)

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var fetched: [String: (tokens: Int, at: Date)] = [:]
    private var reasoningByModel: [String: ReasoningSupport] = [:]
    private var reasoningFetchedAt: Date?
    private var reasoningAttemptedAt: Date?
    private var reasoningLookup: Task<Void, Never>?
    /// A failed list read waits this long, so an offline Mac does not add a
    /// timeout to every Think request.
    static let reasoningRetryInterval: TimeInterval = 600

    init(fetch: Fetch? = nil, defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch ?? { try await OpenRouterModelCatalog.session.data(for: $0) }
        self.defaults = defaults ?? Self.appDefaults
        self.now = now
    }

    /// Nil when the server is not an approved OpenRouter origin, or OpenRouter
    /// has never published a usable window for this model.
    func contextTokens(model: String, baseURL: URL, approvedOrigins: [String]) async -> Int? {
        guard ChatCompletionDialect.inferred(from: baseURL) == .openRouter,
              (try? InferenceEndpointPolicy.validate(baseURL, approvedOrigins: approvedOrigins)) != nil,
              let url = Self.endpointsURL(baseURL: baseURL, model: model) else { return nil }
        let key = model.lowercased()
        if let cached = fetched[key], now().timeIntervalSince(cached.at) < Self.refreshInterval {
            return cached.tokens
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await fetch(request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let tokens = Self.smallestWindow(inEndpoints: data) {
            fetched[key] = (tokens, now())
            var stored = stored()
            stored[key] = tokens
            defaults.set(stored, forKey: Self.defaultsKey)
            return tokens
        }
        return fetched[key]?.tokens ?? stored()[key]
    }

    /// The selected model's reasoning levels from OpenRouter's model list
    /// (`GET <base>/models`, read at most daily). Same rules as the context
    /// window: an approved OpenRouter origin, no key, no content. Nil when
    /// the origin does not qualify or the model is not listed.
    ///
    /// Callers that arrive during a read wait for it, and the read runs apart
    /// from its caller, so a Settings view that disappears cannot cancel it
    /// into a failed attempt. Either miss would leave the menu on the generic
    /// levels for ten minutes, without the model's own Max.
    func reasoningSupport(model: String, baseURL: URL, approvedOrigins: [String]) async -> ReasoningSupport? {
        guard ChatCompletionDialect.inferred(from: baseURL) == .openRouter,
              (try? InferenceEndpointPolicy.validate(baseURL, approvedOrigins: approvedOrigins)) != nil
        else { return nil }
        let current = now()
        let stale = reasoningFetchedAt.map { current.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        let waiting = reasoningAttemptedAt.map { current.timeIntervalSince($0) < Self.reasoningRetryInterval } ?? false
        if let reasoningLookup {
            await reasoningLookup.value
        } else if stale, !waiting {
            reasoningAttemptedAt = current
            let lookup = Task {
                var request = URLRequest(url: baseURL.appendingPathComponent("models"))
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let (data, response) = try? await fetch(request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let parsed = Self.reasoningSupport(inModels: data) {
                    reasoningByModel = parsed
                    reasoningFetchedAt = current
                }
                reasoningLookup = nil
            }
            reasoningLookup = lookup
            await lookup.value
        }
        return reasoningByModel[model.lowercased()]
    }

    static func reasoningSupport(inModels data: Data) -> [String: ReasoningSupport]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return nil }
        var result: [String: ReasoningSupport] = [:]
        for model in models {
            guard let id = (model["id"] as? String)?.lowercased() else { continue }
            result[id] = reasoningSupport(model["reasoning"] as? [String: Any])
        }
        return result
    }

    /// A model's `reasoning` object: `supported_efforts`, whether reasoning is
    /// `mandatory` (no Off), and its defaults. No object: the model does not
    /// reason. Without listed efforts, reasoning can only be switched off.
    static func reasoningSupport(_ reasoning: [String: Any]?) -> ReasoningSupport {
        guard let reasoning else { return .unavailable }
        let mandatory = reasoning["mandatory"] as? Bool ?? false
        var levels = Set((reasoning["supported_efforts"] as? [String] ?? [])
            .compactMap(ThinkReasoningLevel.init(effort:)))
        if mandatory { levels.remove(.off) } else { levels.insert(.off) }
        let defaultLevel: ThinkReasoningLevel? = !mandatory && reasoning["default_enabled"] as? Bool == false
            ? .off : (reasoning["default_effort"] as? String).flatMap(ThinkReasoningLevel.init(effort:))
        return ReasoningSupport(levels: Array(levels), defaultLevel: defaultLevel)
    }

    /// `<base>/models/<author>/<slug>/endpoints`. Ids that are not a plain
    /// author/slug pair are never sent.
    static func endpointsURL(baseURL: URL, model: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        let parts = model.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return parts.reduce(baseURL.appendingPathComponent("models")) { $0.appendingPathComponent($1) }
            .appendingPathComponent("endpoints")
    }

    /// The smallest window any endpoint may route to, including endpoints
    /// that cap the prompt below their context. One endpoint without a window
    /// makes the answer unknown rather than optimistic.
    static func smallestWindow(inEndpoints data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["data"] as? [String: Any],
              let endpoints = model["endpoints"] as? [[String: Any]], !endpoints.isEmpty else { return nil }
        var smallest = Int.max
        for endpoint in endpoints {
            guard let context = endpoint["context_length"] as? Int, context > 0 else { return nil }
            let prompt = (endpoint["max_prompt_tokens"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? context
            smallest = min(smallest, context, prompt)
        }
        return smallest
    }

    private func stored() -> [String: Int] {
        (defaults.dictionary(forKey: Self.defaultsKey) ?? [:]).compactMapValues { $0 as? Int }
    }

    private static var appDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
}
