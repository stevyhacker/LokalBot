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
/// raises approval requests for `write`, `edit`, `bash`, and any `read` whose
/// canonical path escapes the selected workspace. This type
/// decides whether a raised request can be answered automatically
/// (approval mode, session allowances) or must be shown to the user.
struct AgentApprovalPolicy: Equatable {
    var mode: AgentApprovalMode = .askBeforeChanges
    private(set) var sessionAllowedTools: Set<String> = []
    private(set) var automationApprovesWorkspaceFileChanges = false

    enum Verdict: Equatable { case allow, ask }

    func verdict(
        tool: String,
        path: String?,
        requestWorkspace: String?,
        selectedWorkspace: URL
    ) -> Verdict {
        let normalizedTool = tool.lowercased()

        // Automatic modes only apply to structured approvals emitted by the
        // process for this selected workspace. Unknown future tools and stale
        // or malformed cross-workspace requests remain fail-closed.
        if Self.isKnownGatedTool(normalizedTool),
           Self.requestMatchesSelectedWorkspace(
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) {
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

        // An individual "Allow for Session" choice stays narrower than the
        // global modes: only canonical write/edit paths inside the matching
        // workspace may inherit it.
        guard Self.canPersistApproval(
            tool: tool,
            path: path,
            requestWorkspace: requestWorkspace,
            selectedWorkspace: selectedWorkspace) else { return .ask }
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
            selectedWorkspace: selectedWorkspace) else { return }
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
        selectedWorkspace: URL
    ) -> Bool {
        guard isFileChange(tool: tool),
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

    private static func isKnownGatedTool(_ tool: String) -> Bool {
        tool == "read" || isFileChange(tool: tool) || tool == "bash"
    }

    private static func isFileChange(tool: String) -> Bool {
        tool.lowercased() == "write" || tool.lowercased() == "edit"
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
