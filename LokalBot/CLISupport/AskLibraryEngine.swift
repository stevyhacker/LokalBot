import Darwin
import Foundation

/// Shared on-disk identity and bearer contract for the private llama-server.
/// The marker is mode 0600, the token rotates on every subprocess start, and
/// CLI callers validate that its PID is alive, is the recorded executable,
/// and owns the expected listening port before trusting localhost.
struct LocalLlamaServerMarker: Codable {
    var pid: pid_t
    var port: Int
    var binaryPath: String
    var modelPath: String
    var contextTokens: Int?
    var extraArgs: [String]?
    var authenticationToken: String?
    var ownerID: UUID?
    var ownerPID: pid_t?
    var ownerStartTime: UInt64?
    var processStartTime: UInt64?
}

enum LocalLlamaServerAuthentication {
    static func markerURL(port: Int) -> URL {
        AppDirectories.localServerSupport
            .appendingPathComponent("llama-server-\(port).pid.json")
    }

    static func readMarker(port: Int) -> LocalLlamaServerMarker? {
        guard let data = try? Data(contentsOf: markerURL(port: port)),
              let marker = try? JSONDecoder().decode(LocalLlamaServerMarker.self, from: data),
              marker.port == port else { return nil }
        return marker
    }

    static func validatedToken(port: Int) -> String? {
        guard let marker = readMarker(port: port),
              let token = marker.authenticationToken,
              token.count >= 32,
              kill(marker.pid, 0) == 0,
              processPath(for: marker.pid) == marker.binaryPath,
              marker.binaryPath.hasSuffix("/llama-server"),
              listeningPIDs(onPort: port).contains(marker.pid) else { return nil }
        return token
    }

    static func apply(to request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        return result > 0 ? String(cString: buffer) : nil
    }

    private static func listeningPIDs(onPort port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { pid_t($0) }
    }
}

/// Minimal local llama-server chat surface so tests can substitute a mock.
protocol LlamaChatClient {
    func healthy() async -> Bool
    func complete(messages: [[String: String]]) async throws -> String
}

struct URLSessionLlamaChatClient: LlamaChatClient {
    /// The enclosing app's Main LLM server: 127.0.0.1:17872 for the release app.
    static var mainServerBaseURL: URL {
        URL(string: "http://127.0.0.1:\(LlamaServerRole.main.port)")!
    }

    var baseURL = URLSessionLlamaChatClient.mainServerBaseURL
    var authenticationToken: () -> String? = {
        LocalLlamaServerAuthentication.validatedToken(port: LlamaServerRole.main.port)
    }

    func healthy() async -> Bool {
        guard let token = authenticationToken() else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        LocalLlamaServerAuthentication.apply(to: &request, token: token)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func complete(messages: [[String: String]]) async throws -> String {
        guard let token = authenticationToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LocalLlamaServerAuthentication.apply(to: &request, token: token)
        request.timeoutInterval = 300
        // The main server runs with reasoning on. A short grounded answer must
        // not spend its whole 1,024-token allowance thinking, so disable the
        // thinking turn as the app's own zero-budget requests do.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 1024,
            "thinking_budget_tokens": 0,
            "chat_template_kwargs": ["enable_thinking": false],
        ] as [String: Any])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}

/// What one `AskLibraryEngine` request produced.
enum AskLibraryOutcome: Equatable {
    /// The model's text and the meetings its context came from.
    case answered(String, citations: [AskLibraryContext.Citation])
    /// A friendly non-error result: the library is empty or nothing matched.
    case notFound(String)
    case failed(ToolErrorCode, String)

    /// The MCP `ask_library` form: the answer with a Sources list appended.
    var toolResult: ToolResult {
        switch self {
        case .answered(let text, let citations):
            guard !citations.isEmpty else { return .text(text) }
            let sources = citations.map {
                "- \($0.title) (\($0.date), id \($0.meeting_id))"
            }
            return .text(text + "\n\nSources:\n" + sources.joined(separator: "\n"))
        case .notFound(let text):
            return .text(text)
        case .failed(let code, let message):
            return .error(code, message)
        }
    }
}

/// Question in, local model reads the library, synthesized answer and
/// citations out. Owns the health probe, app wake, and error taxonomy.
/// The same path drafts a reply to a message from what the meetings say.
struct AskLibraryEngine {
    var gate: AgentAccessGate
    var client: LlamaChatClient = URLSessionLlamaChatClient()
    var loadMeetings: () throws -> [Meeting] = SessionLookup.loadAllMeetings
    var pollDelay: () async -> Void = {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    var maxPollAttempts = 60

    func ask(_ question: String) async -> ToolResult {
        await answer(question).toolResult
    }

    /// Answers `question` from the meeting library.
    func answer(_ question: String) async -> AskLibraryOutcome {
        // Access comes first: a disabled library says so before anything else.
        guard gate.authorizationID() != nil else {
            return .failed(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(
                .invalidArguments,
                "ask_library requires a non-empty \"question\" string.")
        }
        guard trimmed.count <= LibraryInputPolicy.maximumQuestionCharacters else {
            return .failed(
                .invalidArguments,
                "ask_library questions are limited to \(LibraryInputPolicy.maximumQuestionCharacters) characters.")
        }
        return await respond(
            retrievalText: trimmed,
            notFound: "I couldn't find anything in your meetings matching that question. Try search_meetings with a specific keyword."
        ) { contextText in
            AskLibraryContext.messages(question: trimmed, contextText: contextText)
        }
    }

    /// Drafts the user's reply to `message` from what their meetings say.
    /// Meetings are retrieved by the message's own words (and the
    /// instruction's); a message nothing matches gets no draft, since the
    /// point is to add what the user's meetings know.
    func draftReply(to message: String, instruction: String? = nil) async -> AskLibraryOutcome {
        guard gate.authorizationID() != nil else {
            return .failed(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return .failed(.invalidArguments, "A reply needs the message being answered.")
        }
        guard trimmed.count + extra.count <= LibraryInputPolicy.maximumQuestionCharacters else {
            return .failed(
                .invalidArguments,
                "The message and instruction are limited to \(LibraryInputPolicy.maximumQuestionCharacters) characters together.")
        }
        return await respond(
            retrievalText: extra.isEmpty ? trimmed : trimmed + "\n" + extra,
            notFound: "Nothing in your meetings matches this message, so LokalBot did not draft a reply."
        ) { contextText in
            AskLibraryContext.replyMessages(
                message: trimmed,
                instruction: extra.isEmpty ? nil : extra,
                contextText: contextText)
        }
    }

    private func respond(
        retrievalText: String,
        notFound: String,
        messages: (String) -> [[String: String]]
    ) async -> AskLibraryOutcome {
        guard let authorization = gate.authorizationID() else {
            return .failed(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        if await !client.healthy(), let failure = await wakeAndWait(authorization: authorization) {
            return failure
        }
        if let failure = authorizationFailure(authorization) { return failure }

        let meetings = (try? loadMeetings()) ?? []
        guard !meetings.isEmpty else {
            return .notFound("The meeting library is empty — record a meeting in LokalBot first.")
        }
        let bundle = AskLibraryContext.build(question: retrievalText, meetings: meetings)
        guard !bundle.contextText.isEmpty else {
            return .notFound(notFound)
        }

        let answer: String
        do {
            if let failure = authorizationFailure(authorization) { return failure }
            answer = try await client.complete(messages: messages(bundle.contextText))
        } catch {
            if let failure = authorizationFailure(authorization) { return failure }
            return .failed(
                .appNotRunning,
                "Lost the connection to LokalBot's model server mid-answer (\(error.localizedDescription)). Make sure the LokalBot app is running and try again.")
        }
        if let failure = authorizationFailure(authorization) { return failure }
        return .answered(answer, citations: bundle.citations)
    }

    private func authorizationFailure(_ authorization: String) -> AskLibraryOutcome? {
        guard gate.authorizationID() == authorization else {
            return .failed(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        if Task.isCancelled { return .failed(.appNotRunning, "ask_library was cancelled.") }
        return nil
    }

    private func wakeAndWait(authorization: String) async -> AskLibraryOutcome? {
        if let failure = authorizationFailure(authorization) { return failure }
        gate.clearWakeError()
        do {
            try gate.touchWake()
        } catch {
            return .failed(
                .appNotRunning,
                "Could not signal the LokalBot app (\(error.localizedDescription)). Open LokalBot and try again.")
        }

        for _ in 0..<max(0, maxPollAttempts) {
            if Task.isCancelled {
                return .failed(.appNotRunning, "ask_library was cancelled.")
            }
            await pollDelay()
            if let failure = authorizationFailure(authorization) { return failure }
            if await client.healthy() { return nil }
            if let failure = authorizationFailure(authorization) { return failure }
            if let reason = gate.readWakeError() {
                return .failed(.engineUnavailable, reason)
            }
        }
        if gate.pendingWake {
            return .failed(
                .appNotRunning,
                "ask_library needs the LokalBot app running (read tools still work without it). Open LokalBot and try again.")
        }
        return .failed(
            .modelLoadingTimeout,
            "The model is still loading. Try again in a moment — the first question after a cold start takes the longest.")
    }
}
