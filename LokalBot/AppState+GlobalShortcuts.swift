import AppKit

extension AppState {
    func openQuickRecall() {
        shortcutSourceApplication = FocusReturn.frontmostOtherApplication()
        if let application = NSApp {
            let alreadyOpen = WindowAccess.visibleWindow("quick-recall", in: application)?.isKeyWindow == true
            let fromMainWindow = shortcutSourceApplication == nil
                && WindowAccess.visibleMainWindow(in: application)?.isKeyWindow == true
            if !alreadyOpen, quickRecallOpenedFromMainWindow != fromMainWindow {
                quickRecallOpenedFromMainWindow = fromMainWindow
            }
        }
        WindowAccess.shared.open("quick-recall")
    }

    func continueQuickRecallConversationInAsk() {
        if let scope = chat.currentQuestionScope {
            recallState.selectEvidence(meetingIDs: scope.meetingIDs, screenIDs: scope.screenSnapshotIDs,
                                       sources: scope.sources)
            askDateScope = scope.dayScopeKey.flatMap { AskDateScope(storageKey: $0) }
        }
        recallQuery = ""
        askMode = .ask
        navSection = .ask
    }

    func returnFocusToShortcutSource(then action: @escaping @MainActor () -> Void) {
        guard let application = shortcutSourceApplication else {
            action()
            return
        }
        shortcutSourceApplication = nil
        Task {
            await FocusReturn.activate(application)
            action()
        }
    }

    func applySelectionActionsSetting(replacing previous: DictationShortcut? = nil) {
        guard settings.selectionActionsEnabled else {
            selectionActionsHotKey.setShortcut(nil)
            return
        }
        let shortcut = settings.selectionActionsShortcut
        guard !selectionActionsHotKey.setShortcut(shortcut) else { return }
        lastError = "The selection actions shortcut could not register \(shortcut.displayLabel). Another app may already use it."
        if let previous, previous != shortcut, selectionActionsHotKey.setShortcut(previous) {
            settings.selectionActionsShortcut = previous
        } else {
            settings.selectionActionsEnabled = false
        }
    }

    func selectionMemoryContext(query: String) async -> SelectionMemoryContext {
        guard libraryReady, !query.isEmpty else { return .empty }
        let search = await libraryTools.run(ChatToolCall(name: "search_meetings", arguments: ["query": query]))
        var parts: [String] = []
        var sources: [SelectionMemoryContext.Source] = []
        if !search.evidence.meetingIDs.isEmpty {
            parts.append(PromptContextSanitizer.sanitize(search.text, maxCharacters: 6_000))
            sources = meetings
                .filter { search.evidence.meetingIDs.contains(SessionLookup.shortID($0.id).lowercased()) }
                .prefix(6)
                .map { SelectionMemoryContext.Source(id: $0.id, title: $0.title, date: $0.startedAt) }
        }
        let workMemory = ChatPrompt.workMemoryContext(
            memory: (try? dreamStore.loadMemory()) ?? nil,
            dreamingEnabled: settings.dreamingEnabled)
        if !workMemory.isEmpty {
            parts.append("Ongoing work:\n\(workMemory)")
        }
        return SelectionMemoryContext(excerpts: parts.joined(separator: "\n\n"), sources: sources)
    }
}
