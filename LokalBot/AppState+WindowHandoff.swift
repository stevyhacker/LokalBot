import AppKit

extension WindowHandoffTarget {
    @MainActor static var availableOnThisMac: [WindowHandoffTarget] {
        allCases.filter { target in
            target.agent.map { ActionAgentAvailability.route(for: $0) != nil } ?? true
        }
    }
}

extension AppState {
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

    private func handOffWindowToAgentMode(_ package: WindowHandoffPackage) -> String? {
        let folder = "handoffs/\(package.folder.lastPathComponent)"
        let attachesPage = package.pageCharacters <= WindowHandoffPackage.agentModeAttachmentLimit
        let start = settings.startHandoffsAutomatically && agentInstaller.phase == .installed
        let handoff = AgentHandoff(
            source: nil, title: package.title,
            prompt: package.agentModePrompt(folder: folder, attachesPage: attachesPage),
            attachments: [], folder: folder)
        guard let id = agentSessions.handOff([handoff], start: false).first,
              let tab = agentSessions.tabs.first(where: { $0.id == id }) else {
            return "Couldn't open an Agent Mode task."
        }
        let destination = tab.controller.workspace.appendingPathComponent(folder, isDirectory: true)
        do {
            try package.copy(into: destination)
        } catch {
            lokalbotLog("hand off copy into agent workspace failed: \(error.localizedDescription)")
            Task { await agentSessions.setArchived(id, true) }
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
        if start { agentSessions.startHandoffs([id]) }
        return nil
    }
}
