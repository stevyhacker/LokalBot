import Foundation

enum ApprovalScope: Equatable {
    case once, session
}

enum AgentApprovalMode: Int, CaseIterable, Identifiable, Equatable {
    case askBeforeChanges
    case approveReads
    case approveReadsAndEdits
    case fullAccess

    var id: Self { self }
}

struct AgentApprovalPolicy: Equatable {
    var mode: AgentApprovalMode = .askBeforeChanges
    var protectedWriteRoots: [URL] = []
    private(set) var sessionAllowedTools: Set<String> = []
    private(set) var automationApprovesWorkspaceFileChanges = false
    var modelRunsOnThisMac = false
    var allowsLibraryLookups = false

    enum Verdict: Equatable { case allow, ask }

    func verdict(
        tool: String,
        path: String?,
        command: String? = nil,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) -> Verdict {
        let normalizedTool = tool.lowercased()
        if Self.isFileChange(tool: normalizedTool),
           Self.isProtected(path, roots: protectedWriteRoots) { return .ask }

        if Self.requestMatchesSelectedWorkspace(
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) {
            if normalizedTool == "bash", Self.isLibraryLookup(command),
               modelRunsOnThisMac || (allowsLibraryLookups && mode != .askBeforeChanges) { return .allow }
            switch mode {
            case .askBeforeChanges:
                break
            case .approveReads:
                if normalizedTool == "read" { return .allow }
            case .approveReadsAndEdits:
                if normalizedTool == "read" || Self.isFileChange(tool: normalizedTool) {
                    return .allow
                }
            case .fullAccess:
                return .allow
            }
        }

        guard Self.canPersistApproval(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace,
            protectedWriteRoots: protectedWriteRoots) else { return .ask }
        if automationApprovesWorkspaceFileChanges { return .allow }
        if sessionAllowedTools.contains(normalizedTool) { return .allow }
        return .ask
    }

    mutating func allowForSession(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) {
        guard Self.canPersistApproval(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace,
            protectedWriteRoots: protectedWriteRoots) else { return }
        sessionAllowedTools.insert(tool.lowercased())
    }

    mutating func approveWorkspaceFileChangesForAutomation() {
        automationApprovesWorkspaceFileChanges = true
    }

    static func canPersistApproval(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL,
        protectedWriteRoots: [URL] = []
    ) -> Bool {
        guard isFileChange(tool: tool),
              !isProtected(path, roots: protectedWriteRoots),
              let path,
              let requestWorkspace,
              let requestedRoot = canonicalFileURL(URL(fileURLWithPath: requestWorkspace)),
              let selectedRoot = canonicalFileURL(selectedWorkspace),
              requestedRoot.path == selectedRoot.path,
              let requestedFile = canonicalFileURL(URL(fileURLWithPath: path)) else {
            return false
        }
        let rootComponents = selectedRoot.pathComponents
        let fileComponents = requestedFile.pathComponents
        return fileComponents.count >= rootComponents.count
            && Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func requestMatchesSelectedWorkspace(
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) -> Bool {
        guard let requestWorkspace,
              let requestedRoot = canonicalFileURL(URL(fileURLWithPath: requestWorkspace)),
              let selectedRoot = canonicalFileURL(selectedWorkspace) else { return false }
        return requestedRoot.path == selectedRoot.path
    }

    private static let lookupOptions: [String: Set<String>] = [
        "brief": [],
        "list": ["--since", "--until", "--query", "--limit", "--include", "--table"],
        "get": ["--include", "--format"],
        "search": ["--limit", "--table"],
    ]

    static func isLibraryLookup(_ command: String?) -> Bool {
        guard let words = plainCommandWords(command), words.count >= 2, words[0] == "lokalbot-cli",
              let options = lookupOptions[words[1]] else { return false }
        return words.dropFirst(2).allSatisfy { word in
            guard word.hasPrefix("-") else { return true }
            return options.contains(String(word.prefix { $0 != "=" }))
        }
    }

    static func plainCommandWords(_ command: String?) -> [String]? {
        guard let command = command?.replacingOccurrences(
            of: #"(\s+2>&1)?(\s*\|\s*(head|tail)(\s+-n\s+[0-9]+|\s+-[0-9]+))?\s*$"#,
            with: "", options: .regularExpression) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.,:=\"'"))
        guard command.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        var words: [String] = []
        var word: String?
        var quote: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { word?.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                word = word ?? ""
            } else if character == " " {
                if let finished = word { words.append(finished) }
                word = nil
            } else {
                word = (word ?? "") + String(character)
            }
        }
        guard quote == nil else { return nil }
        if let finished = word { words.append(finished) }
        return words
    }

    private static func isFileChange(tool: String) -> Bool {
        tool.lowercased() == "write" || tool.lowercased() == "edit"
    }

    private static func isProtected(_ path: String?, roots: [URL]) -> Bool {
        guard !roots.isEmpty else { return false }
        guard let path, let file = canonicalFileURL(URL(fileURLWithPath: path)) else { return true }
        return roots.contains { root in
            guard let root = canonicalFileURL(root) else { return true }
            return file.pathComponents.starts(with: root.pathComponents)
        }
    }

    static func canonicalFileURL(_ url: URL) -> URL? {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    mutating func resetSession() {
        sessionAllowedTools.removeAll()
        automationApprovesWorkspaceFileChanges = false
    }
}

struct AgentWorkspacePolicy {
    let privateRoots: [URL]

    func containsPrivateWorkspace(_ workspace: URL) -> Bool {
        guard let workspace = AgentApprovalPolicy.canonicalFileURL(workspace) else { return true }
        return privateRoots.contains { root in
            guard let root = AgentApprovalPolicy.canonicalFileURL(root) else { return true }
            return workspace.pathComponents.starts(with: root.pathComponents)
        }
    }

    static let privateWorkspaceNotice = "This task uses an older working folder inside LokalBot’s private data. Its saved history is still available, but it cannot run here. Choose a folder outside LokalBot’s private data to start a new task; attach specific sources or use the scoped library tools."
}
