import AppKit

/// One command the ⌘K palette and the system-wide Ask window can run.
struct PaletteCommand: Identifiable {
    /// Where a command's result appears. Workspace commands show something in
    /// the main window. Background commands (recording, dictation) act in
    /// place, so the system-wide window hands focus back to the app the person
    /// was using before running them.
    enum Placement: Equatable {
        case workspace
        case background
    }

    let id: String
    let icon: String
    let title: String
    let subtitle: String
    /// English words that still find a translated command.
    var searchAliases: String = ""
    var placement: Placement = .workspace
    let action: () -> Void
}

enum PaletteCommandFilter {
    enum Matching {
        /// Each query word may appear anywhere (the ⌘K palette).
        case substring
        /// Each query word must start a word. The system-wide window mixes
        /// commands with memory search, so "ion" must not offer Dictation.
        case wordPrefix
    }

    /// Commands whose title, subtitle, and aliases contain every query word.
    /// An empty query matches nothing; callers decide what idle shows.
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
                // Chinese titles have no spaces between words; match those
                // anywhere instead.
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

/// The app-wide commands, computed live from app state so titles follow
/// recording and dictation status.
@MainActor
enum PaletteCommandCatalog {
    /// `inWorkspace` adds commands that act on the main window's current
    /// section (Agent tasks), which only make sense from inside it. `source`
    /// labels recording and dictation starts in the log.
    static func commands(app: AppState, source: String, inWorkspace: Bool) -> [PaletteCommand] {
        var commands = appCommands(app: app, source: source)
        if inWorkspace, app.navSection == .agent {
            commands += [
                .init(id: "agent.new", icon: "square.and.pencil", title: "New Agent task", subtitle: "⌘N",
                      action: { app.agentSessions.addSession() }),
                .init(id: "agent.search", icon: "magnifyingglass", title: "Search Agent tasks", subtitle: "⌘⇧F",
                      action: { app.agentSessions.searchRequest += 1 }),
                .init(id: "agent.find", icon: "text.magnifyingglass", title: "Find in this task", subtitle: "⌘F",
                      action: { app.agentSessions.findRequest += 1 }),
                .init(id: "agent.results", icon: "sidebar.right", title: "Toggle results and sources", subtitle: "⌘⌥B",
                      action: { app.agentSessions.resultsRequest += 1 }),
            ]
        }
        // Translate app commands before adding user-owned task titles.
        commands = commands.map { command in
            PaletteCommand(id: command.id, icon: command.icon,
                           title: app.settings.appLanguage.localized(command.title),
                           subtitle: app.settings.appLanguage.localized(command.subtitle),
                           searchAliases: command.title + " " + command.subtitle,
                           placement: command.placement, action: command.action)
        }
        if inWorkspace, app.navSection == .agent {
            commands += app.agentSessions.orderedTasks.filter { !$0.record.isArchived }.prefix(30).map { task in
                PaletteCommand(id: "agent.task.\(task.id)", icon: "text.bubble", title: task.title,
                               subtitle: "Agent task · \(task.controller.workspaceDisplayName)",
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
        var commands: [PaletteCommand] = [
            .init(id: "record", icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                  title: app.isRecording ? "Stop recording" : "Record now",
                  subtitle: "Recording", placement: .background, action: {
                app.isRecording ? app.stopRecording()
                                : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: source)
            }),
            .init(id: "nav.today", icon: "sun.max", title: "Go to Today",
                  subtitle: "Home", action: { app.navSection = .today }),
            .init(id: "nav.actions", icon: "checklist", title: "Review all actions",
                  subtitle: "Today", action: { app.openActions() }),
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
                  subtitle: "Settings", action: { app.openSettings() }),
        ]
        // From the system-wide window this hands focus back, ready to paste.
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
