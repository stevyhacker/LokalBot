import Foundation

actor ServerContextWindowCatalog {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = ServerContextWindowCatalog()
    static let defaultsKey = "lokalbotv3.serverContextTokens"
    static let refreshInterval: TimeInterval = 86_400
    static let retryInterval: TimeInterval = 600
    static let modelListFields = ["max_model_len", "context_window", "context_length", "max_context_length"]

    private static let session = InferenceURLSession.make(requestTimeout: 5, resourceTimeout: 10)

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var fetched: [String: (tokens: Int, at: Date)] = [:]
    private var attempted: [String: Date] = [:]

    init(fetch: Fetch? = nil, defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch ?? { try await ServerContextWindowCatalog.session.data(for: $0) }
        self.defaults = defaults ?? Self.appDefaults
        self.now = now
    }

    func contextTokens(model: String, baseURL: URL, approvedOrigins: [String],
                       apiKey: @Sendable () -> String?) async -> Int? {
        guard !model.isEmpty, ChatCompletionDialect.inferred(from: baseURL) != .openRouter,
              InferenceEndpointPolicy.isAllowed(baseURL, approvedOrigins: approvedOrigins),
              let origin = InferenceEndpointPolicy.origin(for: baseURL) else { return nil }
        let key = "\(origin)\(baseURL.path)|\(model.lowercased())"
        let current = now()
        if let cached = fetched[key], current.timeIntervalSince(cached.at) < Self.refreshInterval {
            return cached.tokens
        }
        if let last = attempted[key], current.timeIntervalSince(last) < Self.retryInterval {
            return fetched[key]?.tokens ?? stored()[key]
        }
        attempted[key] = current
        if let tokens = await lookUp(model: model, baseURL: baseURL, apiKey: apiKey()) {
            fetched[key] = (tokens, current)
            var stored = stored()
            stored[key] = tokens
            defaults.set(stored, forKey: Self.defaultsKey)
            return tokens
        }
        return fetched[key]?.tokens ?? stored()[key]
    }

    private func lookUp(model: String, baseURL: URL, apiKey: String?) async -> Int? {
        if AnthropicAPI.isAnthropic(baseURL) {
            guard let url = Self.anthropicModelURL(baseURL: baseURL, model: model) else { return nil }
            return await read(url, apiKey: apiKey, anthropic: true, parse: Self.window(inAnthropicModel:))
        }
        if let tokens = await read(baseURL.appendingPathComponent("models"), apiKey: apiKey, parse: {
            Self.window(inModelList: $0, model: model)
        }) { return tokens }
        guard InferenceEndpointPolicy.isLoopback(baseURL) else { return nil }
        let root = Self.serverRoot(baseURL)
        if let tokens = await read(root.appendingPathComponent("props"), apiKey: apiKey,
                                   parse: Self.window(inLlamaServerProps:)) { return tokens }
        guard let lmStudio = Self.lmStudioModelURL(root: root, model: model) else { return nil }
        return await read(lmStudio, apiKey: apiKey, parse: Self.window(inLMStudioModel:))
    }

    private func read(_ url: URL, apiKey: String?, anthropic: Bool = false,
                      parse: (Data) -> Int?) async -> Int? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if anthropic {
            AnthropicAPI.authorize(&request, apiKey: apiKey)
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func windows(inModelList data: Data) -> [String: Int] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let models = (object as? [String: Any])?["data"] as? [[String: Any]] ?? object as? [[String: Any]] ?? []
        var windows: [String: Int] = [:]
        for model in models {
            guard let id = (model["id"] as? String)?.lowercased(),
                  let window = modelListFields.compactMap({ positive(model[$0]) }).min() else { continue }
            windows[id] = window
        }
        return windows
    }

    static func window(inModelList data: Data, model: String) -> Int? {
        windows(inModelList: data)[model.lowercased()]
    }

    static func window(inLlamaServerProps data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return positive((object["default_generation_settings"] as? [String: Any])?["n_ctx"]) ?? positive(object["n_ctx"])
    }

    static func window(inLMStudioModel data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return positive(object["loaded_context_length"])
    }

    static func window(inAnthropicModel data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return positive(object["max_input_tokens"])
    }

    static func anthropicModelURL(baseURL: URL, model: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        guard !model.isEmpty, model != ".", model != "..",
              model.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return AnthropicAPI.modelURL(baseURL, model: model)
    }

    static func serverRoot(_ baseURL: URL) -> URL {
        baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
    }

    static func lmStudioModelURL(root: URL, model: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:@")
        let parts = model.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return parts.reduce(root.appendingPathComponent("api/v0/models")) { $0.appendingPathComponent($1) }
    }

    private static func positive(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let tokens = number.intValue
        return tokens > 0 ? tokens : nil
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
