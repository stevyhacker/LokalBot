import Foundation

/// Read-only transcript loading and native Pi branching. No model, process,
/// tool execution, or permission grant is needed to open a saved conversation.
enum AgentConversationArchive {
    static let maximumBytes = 32 * 1_024 * 1_024

    static func records(for session: AgentSavedSession, directory: URL) throws -> [[String: Any]] {
        guard AgentSessionHistory.validated(session, in: directory) != nil else {
            throw AgentSavedSessionOpenError.unavailable
        }
        let handle = try FileHandle(forReadingFrom: session.fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw ArchiveError.tooLarge
        }
        return try data.split(separator: 0x0A).map {
            guard let record = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return record
        }
    }

    /// Pi files contain a tree. Only the most recent leaf's ancestor chain is
    /// visible; abandoned branches must not leak into previews or a new fork.
    static func activeBranch(_ records: [[String: Any]]) -> [[String: Any]] {
        let entries = records.filter { $0["type"] as? String != "session" }
        guard let leaf = entries.last?["id"] as? String else { return entries }
        var byID: [String: [String: Any]] = [:]
        for entry in entries { if let id = entry["id"] as? String { byID[id] = entry } }
        var result: [[String: Any]] = [], visited = Set<String>(), next: String? = leaf
        while let id = next, visited.insert(id).inserted, let entry = byID[id] {
            result.append(entry)
            next = entry["parentId"] as? String
        }
        return result.reversed()
    }

    static func transcript(for session: AgentSavedSession, directory: URL) throws -> AgentTranscriptFolder {
        try preview(for: session, directory: directory).folder
    }

    struct Preview {
        var folder: AgentTranscriptFolder
        var attachments: [String: [AgentAttachment]]
    }

    static func preview(for session: AgentSavedSession, directory: URL) throws -> Preview {
        var folder = AgentTranscriptFolder()
        var attachments: [String: [AgentAttachment]] = [:]
        for entry in activeBranch(try records(for: session, directory: directory)) {
            guard let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let text = messageText(message)
            switch role {
            case "user":
                if !text.isEmpty {
                    folder.noteUserPrompt(AgentContextResolver.displayPrompt(text))
                    if let item = folder.items.last { attachments[item.id] = AgentContextResolver.attachments(in: text) }
                }
            case "assistant":
                if !text.isEmpty { folder.appendAssistantMessage(text) }
                if let failure = PiEvent.terminalFailure(
                    stopReason: message["stopReason"] as? String,
                    errorMessage: message["errorMessage"] as? String) {
                    folder.appendNotice(failure, isError: true)
                }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "toolCall" {
                    let args = (try? JSONSerialization.data(withJSONObject: block["arguments"] ?? [:])) ?? Data()
                    folder.fold(.toolExecutionStart(callID: block["id"] as? String ?? UUID().uuidString,
                                                    name: block["name"] as? String ?? "Tool",
                                                    argsJSON: String(decoding: args, as: UTF8.self)))
                }
            case "toolResult":
                folder.fold(.toolExecutionEnd(callID: message["toolCallId"] as? String ?? "",
                                             output: text, isError: message["isError"] as? Bool ?? false))
            default: break
            }
        }
        folder.enforceResourceLimits()
        let visibleIDs = Set(folder.items.map(\.id))
        return Preview(folder: folder, attachments: attachments.filter { visibleIDs.contains($0.key) })
    }

    static func fork(_ session: AgentSavedSession, through item: AgentTranscriptItem,
                     matchingOccurrenceFromEnd: Int, directory: URL) throws -> AgentSavedSession {
        let role: String, text: String
        switch item {
        case .user(_, let value): role = "user"; text = value
        case .assistant(_, let value, false): role = "assistant"; text = value
        default: throw ArchiveError.unsavedMessage
        }
        let raw = try records(for: session, directory: directory)
        let branch = activeBranch(raw)
        let matches = branch.indices.filter {
            guard let message = branch[$0]["message"] as? [String: Any] else { return false }
            return message["role"] as? String == role && (role == "user" ? AgentContextResolver.displayPrompt(messageText(message)) : messageText(message)) == text
        }
        guard matchingOccurrenceFromEnd < matches.count,
              var header = raw.first, header["type"] as? String == "session" else {
            throw ArchiveError.unsavedMessage
        }
        var lastIndex = matches[matches.count - 1 - matchingOccurrenceFromEnd]
        // A textual assistant message can also contain tool calls. Include its
        // already-recorded results so the fork never has dangling tool calls.
        let message = branch[lastIndex]["message"] as? [String: Any]
        var pendingCalls = Set((message?["content"] as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "toolCall" ? $0["id"] as? String : nil
        })
        while !pendingCalls.isEmpty, lastIndex + 1 < branch.count {
            let next = branch[lastIndex + 1]["message"] as? [String: Any]
            if let next, next["role"] as? String != "toolResult" { break }
            lastIndex += 1
            if let call = next?["toolCallId"] as? String { pendingCalls.remove(call) }
        }
        guard pendingCalls.isEmpty else { throw ArchiveError.unsavedMessage }
        let id = UUID().uuidString
        header["id"] = id
        header["parentSession"] = session.fileURL.path
        header["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let file = directory.appendingPathComponent("\(id).jsonl")
        let lines = try ([header] + Array(branch[...lastIndex])).map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard let saved = try AgentSessionHistory.load(from: directory).first(where: { $0.fileURL == file }) else {
            throw ArchiveError.unsavedMessage
        }
        return saved
    }

    static func messageText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }.joined()
    }

    enum ArchiveError: LocalizedError {
        case tooLarge, unsavedMessage
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This conversation is too large to preview (32 MB limit). Its saved history is unchanged."
            case .unsavedMessage: "This message is not yet available in saved history. Wait for the turn to finish and try again."
            }
        }
    }
}
