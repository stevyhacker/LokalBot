import Foundation

enum AgentToolStatus: Equatable {
    case running, succeeded, failed
}

/// App-owned, structured description of a mutating tool request. Keeping the
/// fields separate lets the approval surface show the exact command/content
/// instead of trusting a model-authored one-line summary.
struct AgentApprovalRequest: Equatable, Identifiable {
    struct Edit: Equatable {
        let oldText: String
        let newText: String
    }

    let id: String
    let tool: String
    let workspace: String?
    let path: String?
    let command: String?
    let content: String?
    let edits: [Edit]
    let summary: String?
    let isTruncated: Bool

    /// Also enforced in the extension before an approval is requested. Keep
    /// the host fail-closed for old, malformed, or locally bounded payloads.
    var canApprove: Bool {
        guard ["bash", "shell"].contains(tool.lowercased()) else { return true }
        guard let command, !command.isEmpty else { return false }
        return !isTruncated && command.utf16.count <= 64 * 1_024
    }

    var hasStructuredDetails: Bool {
        workspace != nil || path != nil || command != nil || content != nil || !edits.isEmpty
    }
}

enum AgentTranscriptItem: Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, isStreaming: Bool)
    case tool(id: String, name: String, argsJSON: String, output: String, status: AgentToolStatus)
    case approval(AgentApprovalRequest)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .tool(let id, _, _, _, _),
             .notice(let id, _, _):
            return id
        case .approval(let request):
            return request.id
        }
    }
}

/// Folds the PiEvent stream into a display-ready transcript. Pure state
/// machine — no async, no UI — so every folding rule is unit-testable
/// (same decomposition philosophy as the Cotyping policy types).
struct AgentTranscriptFolder: Equatable {
    static let maximumItems = 500
    static let maximumMessageCharacters = 1_000_000
    static let maximumToolCharacters = 256 * 1_024
    static let maximumTotalCharacters = 8 * 1_024 * 1_024
    static let maximumPendingApprovals = 16
    static let maximumApprovalIdentifierCharacters = 1_024

    private(set) var items: [AgentTranscriptItem] = []
    private(set) var isAgentRunning = false
    private var streamingAssistantID: String?
    private var streamingAssistantCharacters = 0
    private var retainedCharacterCount = 0
    private var counter = 0

    /// Resolved fresh on every use so removals elsewhere in the array
    /// (e.g. resolveApproval) can never leave a stale index behind.
    private var streamingAssistantIndex: Int? {
        guard let streamingAssistantID else { return nil }
        return items.firstIndex { $0.id == streamingAssistantID }
    }

    // MARK: - Local inserts (not driven by pi events)

    mutating func noteUserPrompt(_ text: String) {
        appendItem(.user(id: nextID("user"), text: Self.boundedMessage(text)))
    }

    mutating func appendAssistantMessage(_ text: String) {
        appendItem(.assistant(
            id: nextID("assistant"), text: Self.boundedMessage(text), isStreaming: false))
    }

    mutating func appendNotice(_ text: String, isError: Bool = false) {
        appendItem(.notice(
            id: nextID("notice"), text: Self.boundedMessage(text), isError: isError))
    }

    var canAcceptApproval: Bool {
        pendingApprovalIDs.count < Self.maximumPendingApprovals
    }

    @discardableResult
    mutating func addApproval(_ request: AgentApprovalRequest) -> Bool {
        guard canAcceptApproval,
              request.id.count <= Self.maximumApprovalIdentifierCharacters else { return false }
        appendItem(.approval(Self.boundedApproval(request)))
        return true
    }

    mutating func resolveApproval(requestID: String) {
        guard let index = items.firstIndex(where: {
            if case .approval(let request) = $0 { return request.id == requestID }
            return false
        }) else { return }
        removeItem(at: index)
    }

    var pendingApprovalIDs: [String] {
        items.compactMap {
            if case .approval(let request) = $0 { return request.id }
            return nil
        }
    }

    mutating func resolveAllApprovals() {
        for index in items.indices.reversed() {
            if case .approval = items[index] { removeItem(at: index) }
        }
    }

    mutating func enforceResourceLimits() {
        while items.count > Self.maximumItems
            || retainedCharacterCount > Self.maximumTotalCharacters {
            guard let index = items.firstIndex(where: {
                if case .approval = $0 { return false }
                return true
            }) else { break }
            removeItem(at: index)
        }
    }

    // MARK: - Event folding

    mutating func fold(_ event: PiEvent) {
        switch event {
        case .agentStart:
            isAgentRunning = true
        case .agentSettled:
            isAgentRunning = false
            finishStreamingAssistant()
        case .messageStart(let role):
            guard role == "assistant" else { return }
            let id = nextID("assistant")
            appendItem(.assistant(id: id, text: "", isStreaming: true))
            streamingAssistantID = id
            streamingAssistantCharacters = 0
        case .messageUpdate(.textDelta(let delta)):
            appendToStreamingAssistant(delta)
        case .messageEnd(let role, let text):
            guard role == "assistant" else { return }
            defer {
                streamingAssistantID = nil
                streamingAssistantCharacters = 0
            }
            if let index = streamingAssistantIndex,
               case .assistant(let id, let streamed, _) = items[index] {
                let final = Self.boundedMessage(text.isEmpty ? streamed : text)
                if final.isEmpty {
                    removeItem(at: index)   // tool-call-only turn: drop the empty bubble
                } else {
                    replaceItem(
                        at: index,
                        with: .assistant(id: id, text: final, isStreaming: false))
                }
            } else if !text.isEmpty {
                appendItem(.assistant(
                    id: nextID("assistant"),
                    text: Self.boundedMessage(text),
                    isStreaming: false))
            }
        case .toolExecutionStart(let callID, let name, let argsJSON):
            appendItem(.tool(
                id: callID,
                name: String(name.prefix(256)),
                argsJSON: String(argsJSON.prefix(Self.maximumToolCharacters)),
                output: "",
                status: .running))
        case .toolExecutionUpdate(let callID, let output):
            updateTool(callID) { _, _ in (output, .running) }
        case .toolExecutionEnd(let callID, let output, let isError):
            updateTool(callID) { _, _ in (output, isError ? .failed : .succeeded) }
        case .extensionError(let message):
            appendNotice(message, isError: true)
        case .agentEnd, .messageUpdate, .response, .extensionUIRequest, .unknown:
            break
        }
    }

    // MARK: - Helpers

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private static func boundedMessage(_ text: String) -> String {
        String(text.prefix(maximumMessageCharacters))
    }

    private static func boundedApproval(_ request: AgentApprovalRequest) -> AgentApprovalRequest {
        var remaining = maximumToolCharacters
        var truncated = request.isTruncated

        func consume(_ value: String?) -> String? {
            guard let value else { return nil }
            let bounded = String(value.prefix(remaining))
            if bounded.count < value.count { truncated = true }
            remaining -= bounded.count
            return bounded
        }

        let workspace = consume(request.workspace)
        let path = consume(request.path)
        let command = consume(request.command)
        let content = consume(request.content)
        var edits: [AgentApprovalRequest.Edit] = []
        for edit in request.edits where remaining > 0 {
            let oldText = consume(edit.oldText) ?? ""
            let newText = consume(edit.newText) ?? ""
            edits.append(.init(oldText: oldText, newText: newText))
        }
        if edits.count < request.edits.count { truncated = true }
        let summary = consume(request.summary)
        return AgentApprovalRequest(
            id: request.id,
            tool: String(request.tool.prefix(256)),
            workspace: workspace,
            path: path,
            command: command,
            content: content,
            edits: edits,
            summary: summary,
            isTruncated: truncated)
    }

    private static func characterCount(in item: AgentTranscriptItem) -> Int {
        switch item {
        case .user(let id, let text), .assistant(let id, let text, _),
             .notice(let id, let text, _):
            return id.count + text.count
        case .tool(let id, let name, let args, let output, _):
            return id.count + name.count + args.count + output.count
        case .approval(let request):
            var count = request.id.count
            count += request.tool.count
            if let workspace = request.workspace { count += workspace.count }
            if let path = request.path { count += path.count }
            if let command = request.command { count += command.count }
            if let content = request.content { count += content.count }
            if let summary = request.summary { count += summary.count }
            for edit in request.edits {
                count += edit.oldText.count
                count += edit.newText.count
            }
            return count
        }
    }

    private mutating func appendItem(_ item: AgentTranscriptItem) {
        retainedCharacterCount += Self.characterCount(in: item)
        items.append(item)
    }

    private mutating func replaceItem(at index: Int, with item: AgentTranscriptItem) {
        retainedCharacterCount -= Self.characterCount(in: items[index])
        retainedCharacterCount += Self.characterCount(in: item)
        items[index] = item
    }

    private mutating func removeItem(at index: Int) {
        retainedCharacterCount -= Self.characterCount(in: items[index])
        items.remove(at: index)
    }

    private mutating func appendToStreamingAssistant(_ delta: String) {
        if streamingAssistantIndex == nil {
            let id = nextID("assistant")
            appendItem(.assistant(id: id, text: "", isStreaming: true))
            streamingAssistantID = id
            streamingAssistantCharacters = 0
        }
        if let index = streamingAssistantIndex,
           case .assistant(let id, let text, _) = items[index] {
            let room = max(0, Self.maximumMessageCharacters - streamingAssistantCharacters)
            guard room > 0 else { return }
            let boundedDelta = String(delta.prefix(room))
            streamingAssistantCharacters += boundedDelta.count
            retainedCharacterCount += boundedDelta.count
            items[index] = .assistant(
                id: id,
                text: text + boundedDelta,
                isStreaming: true)
        }
    }

    private mutating func finishStreamingAssistant() {
        defer {
            streamingAssistantID = nil
            streamingAssistantCharacters = 0
        }
        guard let index = streamingAssistantIndex,
              case .assistant(let id, let text, _) = items[index] else { return }
        if text.isEmpty {
            removeItem(at: index)
        } else {
            items[index] = .assistant(id: id, text: text, isStreaming: false)
        }
    }

    private mutating func updateTool(_ callID: String,
                                     _ transform: (String, AgentToolStatus) -> (String, AgentToolStatus)) {
        guard let index = items.firstIndex(where: { $0.id == callID }),
              case .tool(let id, let name, let args, let output, let status) = items[index] else { return }
        let (newOutput, newStatus) = transform(output, status)
        replaceItem(
            at: index,
            with: .tool(
                id: id,
                name: name,
                argsJSON: args,
                output: String(newOutput.prefix(Self.maximumToolCharacters)),
                status: newStatus))
    }
}
