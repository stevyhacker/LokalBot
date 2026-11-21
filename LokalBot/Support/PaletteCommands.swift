import AppKit

struct PaletteCommand: Identifiable {
    enum Placement: Equatable {
        case workspace
        case background
    }

    let id: String
    let icon: String
    let title: String
    let subtitle: String
    var searchAliases: String = ""
    var placement: Placement = .workspace
    var detail: String?
    var shortcut: String?
    let action: () -> Void
}

enum PaletteCommandFilter {
    enum Matching {
        case substring
        case wordPrefix
    }

    static func ranked(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let split = split(commands, query: query)
        return split.leading + split.loose
    }

    static func split(_ commands: [PaletteCommand], query: String) -> (leading: [PaletteCommand], loose: [PaletteCommand]) {
        let leading = filter(commands, query: query, matching: .wordPrefix)
        let leadingIDs = Set(leading.map(\.id))
        return (leading, filter(commands, query: query, matching: .substring).filter { !leadingIDs.contains($0.id) })
    }

    static func idleOrder(_ commands: [PaletteCommand]) -> [PaletteCommand] {
        commands.filter { $0.placement == .background } + commands.filter { $0.placement != .background }
    }

    static func filter(_ commands: [PaletteCommand], query: String, matching: Matching) -> [PaletteCommand] {
        let tokens = matching == .substring
            ? query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            : words(in: query)
        guard !tokens.isEmpty else { return [] }
        return commands.filter { command in
            let haystack = [command.title, command.subtitle, command.searchAliases].joined(separator: " ")
            switch matching {
            case .substring:
                let lowered = haystack.lowercased()
                return tokens.allSatisfy { lowered.contains($0) }
            case .wordPrefix:
                let lowered = haystack.lowercased()
                let candidates = words(in: haystack)
                return tokens.allSatisfy { token in
                    token.unicodeScalars.contains { !$0.isASCII }
                        ? lowered.contains(token)
                        : candidates.contains { $0.hasPrefix(token) }
                }
            }
        }
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

@MainActor
enum PaletteCommandCatalog {
    static func commands(app: AppState, source: String, inWorkspace: Bool) -> [PaletteCommand] {
        var commands = appCommands(app: app, source: source)
        if inWorkspace, app.navSection == .agent {
            commands += [
                .init(id: "agent.new", icon: "square.and.pencil", title: "New Agent task", subtitle: "Agent",
                      shortcut: "⌘N", action: { app.agentSessions.addSession() }),
                .init(id: "agent.search", icon: "magnifyingglass", title: "Search Agent tasks", subtitle: "Agent",
                      shortcut: "⇧⌘F", action: { app.agentSessions.searchRequest += 1 }),
                .init(id: "agent.find", icon: "text.magnifyingglass", title: "Find in this task", subtitle: "Agent",
                      shortcut: "⌘F", action: { app.agentSessions.findRequest += 1 }),
                .init(id: "agent.results", icon: "sidebar.right", title: "Toggle results and sources", subtitle: "Agent",
                      shortcut: "⌥⌘B", action: { app.agentSessions.resultsRequest += 1 }),
            ]
        }
        commands = commands.map { command in
            PaletteCommand(id: command.id, icon: command.icon,
                           title: app.settings.appLanguage.localized(command.title),
                           subtitle: app.settings.appLanguage.localized(command.subtitle),
                           searchAliases: command.title + " " + command.subtitle,
                           placement: command.placement, detail: command.detail, shortcut: command.shortcut,
                           action: command.action)
        }
        if inWorkspace, app.navSection == .agent {
            commands += app.agentSessions.orderedTasks.filter { !$0.record.isArchived }.prefix(30).map { task in
                PaletteCommand(id: "agent.task.\(task.id)", icon: "text.bubble", title: task.title,
                               subtitle: "Agent task · \(task.controller.workspaceDisplayName)",
                               detail: task.controller.workspaceDisplayName,
                               action: { app.agentSessions.select(task.id) })
            }
        }
        return commands
    }

    private static func appCommands(app: AppState, source: String) -> [PaletteCommand] {
        let dictationTitle: String
        let dictationIcon: String
        if app.dictation.isStarting {
            dictationTitle = "Cancel dictation"
            dictationIcon = "xmark.circle"
        } else {
            switch app.dictation.state {
            case .idle:
                dictationTitle = "Start dictation"
                dictationIcon = "mic.badge.plus"
            case .recording:
                dictationTitle = "Stop & compose dictation"
                dictationIcon = "stop.circle.fill"
            case .transcribing, .composing:
                dictationTitle = "Cancel dictation"
                dictationIcon = "xmark.circle"
            }
        }
        let openCount = app.outcomeIndex.openUserActionThreads.count
        let openActions = openCount > 0
            ? String(format: app.settings.appLanguage.localized("%lld open"), openCount) : nil
        var commands: [PaletteCommand] = [
            .init(id: "record", icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                  title: app.isRecording ? "Stop recording" : "Record now",
                  subtitle: "Recording", placement: .background, shortcut: "⇧⌘R", action: {
                app.isRecording ? app.stopRecording()
                                : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: source)
            }),
            .init(id: "nav.today", icon: "sun.max", title: "Go to Today",
                  subtitle: "Home", action: { app.openToday() }),
            .init(id: "nav.actions", icon: "checkmark.circle", title: "Review all actions",
                  subtitle: "Home", detail: openActions, action: { app.openActions() }),
            .init(id: "nav.timeline", icon: "calendar.day.timeline.left", title: "Go to Timeline",
                  subtitle: "Library", action: { app.navSection = .timeline }),
            .init(id: "nav.meetings", icon: "waveform.circle", title: "Go to Meetings",
                  subtitle: "Library", action: { app.navSection = .meetings }),
            .init(id: "followUp", icon: "arrowshape.turn.up.right", title: "Draft follow-up for latest meeting",
                  subtitle: "Meetings", action: {
                if let meeting = app.latestMeetingWithOutcomes { app.draftFollowUp(for: meeting) }
            }),
            .init(id: "nav.people", icon: "person.2", title: "Go to People",
                  subtitle: "Library", action: { app.navSection = .people }),
            .init(id: "nav.projects", icon: "folder", title: "Go to Projects",
                  subtitle: "Library", action: { app.navSection = .projects }),
            .init(id: "nav.ask", icon: "sparkle.magnifyingglass", title: "Go to Ask",
                  subtitle: "Library", action: { app.openAsk() }),
            .init(id: "dictation", icon: dictationIcon,
                  title: dictationTitle,
                  subtitle: "Automation", placement: .background,
                  shortcut: app.settings.dictationEnabled ? app.settings.dictationShortcut.displayLabel : nil,
                  action: { app.dictation.toggle(source: source) }),
            .init(id: "nav.dictation", icon: "mic.badge.plus",
                  title: app.settings.dictationEnabled ? "Go to Dictation (on)" : "Go to Dictation (off)",
                  subtitle: "Write", action: { app.openType(.dictation) }),
            .init(id: "nav.cotyping", icon: "text.cursor",
                  title: app.settings.cotypingEnabled ? "Go to Autocomplete (on)" : "Go to Autocomplete (off)",
                  subtitle: "Write", action: { app.openType(.cotyping) }),
            .init(id: "nav.agent", icon: "wand.and.sparkles", title: "Go to Agent",
                  subtitle: "Automation", action: { app.navSection = .agent }),
            .init(id: "nav.models", icon: "brain", title: "Go to Models",
                  subtitle: "Settings", action: { app.openSettings(tab: .models) }),
            .init(id: "nav.settings", icon: "gearshape", title: "Go to Settings",
                  subtitle: "Settings", shortcut: "⌘,", action: { app.openSettings() }),
        ]
        if !app.dictation.history.entries.isEmpty,
           let index = commands.firstIndex(where: { $0.id == "dictation" }) {
            commands.insert(
                .init(id: "dictation.copyLast", icon: "doc.on.clipboard", title: "Copy last dictation",
                      subtitle: "Dictation", placement: .background,
                      action: { _ = app.dictation.copyFromHistory() }),
                at: index + 1)
        }
        return commands
    }
}
