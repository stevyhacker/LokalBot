import Foundation

/// How the user scoped an approval from the transcript card.
enum ApprovalScope: Equatable {
    case once, session
}

/// Approval levels exposed by Agent Mode. Raw values are ordered from least to
/// most permissive so the UI can confirm only escalations. The selected level
/// is remembered app-wide; individual tool exceptions remain session-only.
enum AgentApprovalMode: Int, CaseIterable, Identifiable, Equatable {
    case askBeforeChanges
    case approveReads
    case approveReadsAndEdits
    case fullAccess

    var id: Self { self }
}

/// Pure approval policy for gated agent tools. The bundled pi extension
/// raises an approval request for every tool call except a `read` inside the
/// selected workspace and outside the private library. This type
/// decides whether a raised request can be answered automatically
/// (a read-only library lookup with a model on this Mac, the approval mode,
/// session allowances) or must be shown to the user.
struct AgentApprovalPolicy: Equatable {
    var mode: AgentApprovalMode = .askBeforeChanges
    var protectedWriteRoots: [URL] = []
    private(set) var sessionAllowedTools: Set<String> = []
    private(set) var automationApprovesWorkspaceFileChanges = false
    /// True only while the task's model is known to run on this Mac. A
    /// lookup's output is fed to the model, so with a model anywhere else,
    /// or one whose place is not known, a lookup is not let through here.
    var modelRunsOnThisMac = false
    /// Lets read-only `lokalbot-cli` lookups through in the read modes
    /// wherever the model runs. Set for tasks handed off from a meeting's
    /// actions, which may start with no one watching. It belongs to the
    /// task, like `mode`, so session resets keep it.
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

        // Automatic modes only apply to structured approvals emitted by the
        // process for this selected workspace. Stale or malformed
        // cross-workspace requests remain fail-closed.
        if Self.requestMatchesSelectedWorkspace(
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) {
            // A lone read-only lookup of the user's own library runs in every
            // mode, the default included, when the model runs on this Mac.
            // With a model elsewhere it asks, except for a handed-off task
            // in the read modes. Anything `isLibraryLookup` cannot prove to
            // be a lookup falls through and follows the mode.
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
                // Every agent tool, including MCP tools and tools that later
                // Pi releases add. Protected file changes already asked above.
                return .allow
            }
        }

        // An individual "Allow for Session" choice stays narrower than the
        // global modes: only canonical write/edit paths inside the matching
        // workspace may inherit it.
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

    /// The headless test harness has no person to click file-change cards. It
    /// may opt into workspace-contained write/edit calls without inheriting
    /// the broader read/edit mode exposed in the app.
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

    /// The options `lokalbot-cli brief`, `list`, `get` and `search` take.
    /// None of them writes a file or reaches the network. A word that starts
    /// with `-` and is not listed here keeps the command from counting as a
    /// lookup, so an option a later release adds asks until it is added.
    private static let lookupOptions: [String: Set<String>] = [
        "brief": [],
        "list": ["--since", "--until", "--query", "--limit", "--include", "--table"],
        "get": ["--include", "--format"],
        "search": ["--limit", "--table"],
    ]

    /// One `lokalbot-cli brief`, `list`, `get` or `search` call made of plain
    /// and quoted words, so nothing can chain, redirect, substitute or expand
    /// into another command. Those four only read the library and print, and
    /// only with the options listed above. A trailing `2>&1` and `| head` or
    /// `| tail` with a line count are allowed.
    static func isLibraryLookup(_ command: String?) -> Bool {
        guard let words = plainCommandWords(command), words.count >= 2, words[0] == "lokalbot-cli",
              let options = lookupOptions[words[1]] else { return false }
        return words.dropFirst(2).allSatisfy { word in
            guard word.hasPrefix("-") else { return true }
            return options.contains(String(word.prefix { $0 != "=" }))
        }
    }

    /// The words of a command that is a single call made of plain and quoted
    /// words, after an optional `2>&1` and `| head` or `| tail` with a line
    /// count. Nil when the text holds anything a shell could use to chain,
    /// redirect, substitute or expand.
    static func plainCommandWords(_ command: String?) -> [String]? {
        guard let command = command?.replacingOccurrences(
            of: #"(\s+2>&1)?(\s*\|\s*(head|tail)(\s+-n\s+[0-9]+|\s+-[0-9]+))?\s*$"#,
            with: "", options: .regularExpression) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.,:=\"'"))
        guard command.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // With `$`, backticks and backslashes excluded, quotes only group words.
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

    /// Resolve symlinks through the nearest existing ancestor, then append any
    /// not-yet-created suffix. This matches the bundled extension's path rule
    /// and prevents a symlinked parent from turning an apparently local write
    /// into an external one.
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

/// Private app data is never an implicit working folder. File tools may still
/// request individual reads, and explicit attachments keep their own scope.
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
