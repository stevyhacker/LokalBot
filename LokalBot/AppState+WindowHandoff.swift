import AppKit

extension WindowHandoffTarget {
    /// Agent Mode and Copy always; Claude Code and Codex when installed.
    @MainActor static var availableOnThisMac: [WindowHandoffTarget] {
        allCases.filter { target in
            target.agent.map { ActionAgentAvailability.route(for: $0) != nil } ?? true
        }
    }
}

/// Hand off: the shortcut, and delivering a reviewed handoff to its target.
extension AppState {
    /// `previous` is the shortcut to fall back to when a newly chosen one is
    /// refused; without one, a refused shortcut turns Hand off off.
    func applyWindowHandoffSetting(replacing previous: DictationShortcut? = nil) {
        guard settings.windowHandoffEnabled else {
            windowHandoffHotKey.setShortcut(nil)
            return
        }
        let shortcut = settings.windowHandoffShortcut
        guard !windowHandoffHotKey.setShortcut(shortcut) else { return }
        lastError = "The Hand off shortcut could not register \(shortcut.displayLabel). Another app may already use it."
        if let previous, previous != shortcut, windowHandoffHotKey.setShortcut(previous) {
            settings.windowHandoffShortcut = previous
        } else {
            settings.windowHandoffEnabled = false
        }
    }

    /// Delivers `package` to `target`. Returns why it could not, or nil.
    func deliverWindowHandoff(_ package: WindowHandoffPackage, to target: WindowHandoffTarget) -> String? {
        switch target {
        case .agentMode:
            return handOffWindowToAgentMode(package)
        case .claudeCode, .codex:
            guard let agent = target.agent, let route = ActionAgentAvailability.route(for: agent),
                  let url = route.url(prompt: package.prompt()) else {
                return "\(target.rawValue) isn't installed on this Mac."
            }
            guard NSWorkspace.shared.open(url) else { return "Couldn't open \(target.rawValue)." }
            package.recordDelivery(target: target.manifestID, route: route.link)
            return nil
        case .copy:
            SelectionDelivery.copy(package.prompt(limit: 200_000))
            package.recordDelivery(target: target.manifestID, route: nil)
            return nil
        }
    }

    /// A new Agent Mode task with the brief in its composer and a copy of the
    /// package in its working folder, so the agent reads it without asking.
    /// "Start handoffs automatically" sends it right away.
    private func handOffWindowToAgentMode(_ package: WindowHandoffPackage) -> String? {
        let folder = "handoffs/\(package.folder.lastPathComponent)"
        let attachesPage = package.pageCharacters <= WindowHandoffPackage.agentModeAttachmentLimit
        let start = settings.startHandoffsAutomatically && agentInstaller.phase == .installed
        let handoff = AgentHandoff(
            source: nil, title: package.title,
            prompt: package.agentModePrompt(folder: folder, attachesPage: attachesPage),
            attachments: [], folder: folder)
        // Nothing runs until this method returns, so the copy and the
        // attachment are in place before an automatic start sends the task.
        guard let id = agentSessions.handOff([handoff], start: start).first,
              let tab = agentSessions.tabs.first(where: { $0.id == id }) else {
            return "Couldn't open an Agent Mode task."
        }
        let destination = tab.controller.workspace.appendingPathComponent(folder, isDirectory: true)
        do {
            try package.copy(into: destination)
        } catch {
            lokalbotLog("hand off copy into agent workspace failed: \(error.localizedDescription)")
            return "Couldn't copy the handoff into Agent Mode's working folder: \(error.localizedDescription)"
        }
        if attachesPage {
            let page = destination.appendingPathComponent("context/page.md").standardizedFileURL
            tab.controller.attachments = [AgentAttachment(
                id: "file:\(page.path)", kind: .file, title: "Window text: \(package.title)", reference: page.path)]
        }
        agentSessions.persist()
        agentSessions.select(id)
        openAgent()
        WindowAccess.shared.open("main")
        package.recordDelivery(target: WindowHandoffTarget.agentMode.manifestID, route: nil)
        return nil
    }
}
