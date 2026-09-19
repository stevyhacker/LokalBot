import SwiftUI

/// A ⌘K command palette for keyboard-first navigation. Fires record/stop,
/// jumps to any sidebar section, opens recent meetings, and toggles cotyping —
/// all from a single fuzzy-filtered list. Built for the power-user audience
/// (menu-bar residents, agent-CLI users) who reach for the keyboard, not the
/// trackpad. Summoned via ⌘K (registered in `LokalBotApp.commands`).
struct CommandPaletteView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.tint).font(.title3)
                CommandPaletteTextField(
                    text: $query,
                    focusRequest: focusRequest,
                    onSubmit: runSelection,
                    onPrevious: { move(by: -1) },
                    onNext: { move(by: 1) },
                    onCancel: { dismiss() })
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                Text("⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()

            if results.isEmpty {
                Text("No matches")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { run(item) }
                                .accessibilityIdentifier("palette.row.\(item.id)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .onAppear { focusRequest &+= 1 }
        .onChange(of: query) { selection = 0 }
    }

    // MARK: - Items

    /// Everything the palette can do, computed live from app state. Commands,
    /// plus recent meetings when idle; typed queries add one handoff row into
    /// Ask — the palette stays a command surface, Ask is the search surface.
    private var results: [PaletteItem] {
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
        var actions: [PaletteItem] = [
            .init(id: "record", icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                  title: app.isRecording ? "Stop recording" : "Record now",
                  subtitle: "Recording", action: {
                app.isRecording ? app.stopRecording()
                                : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "palette")
            }),
            .init(id: "nav.today", icon: "sun.max", title: "Go to Today",
                  subtitle: "Home", action: { app.navSection = .today }),
            .init(id: "nav.actions", icon: "checklist", title: "Review all actions",
                  subtitle: "Today", action: { app.openActions() }),
            .init(id: "nav.timeline", icon: "calendar.day.timeline.left", title: "Go to Timeline",
                  subtitle: "Library", action: { app.navSection = .timeline }),
            .init(id: "nav.meetings", icon: "waveform.circle", title: "Go to Meetings",
                  subtitle: "Library", action: { app.navSection = .meetings }),
            .init(id: "nav.ask", icon: "sparkle.magnifyingglass", title: "Go to Ask",
                  subtitle: "Library", action: { app.openAsk() }),
            .init(id: "dictation", icon: dictationIcon,
                  title: dictationTitle,
                  subtitle: "Automation", action: { app.dictation.toggle(source: "palette") }),
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
                  subtitle: "Settings", action: { app.openSettings() })
        ]
        if app.navSection == .agent {
            actions += [
                .init(id: "agent.new", icon: "square.and.pencil", title: "New Agent task", subtitle: "⌘N", action: { app.agentSessions.addSession() }),
                .init(id: "agent.search", icon: "magnifyingglass", title: "Search Agent tasks", subtitle: "⌘⇧F", action: { app.agentSessions.searchRequest += 1 }),
                .init(id: "agent.find", icon: "text.magnifyingglass", title: "Find in this task", subtitle: "⌘F", action: { app.agentSessions.findRequest += 1 }),
                .init(id: "agent.results", icon: "sidebar.right", title: "Toggle results and sources", subtitle: "⌘⌥B", action: { app.agentSessions.resultsRequest += 1 })
            ]
            actions += app.agentSessions.orderedTasks.filter { !$0.record.isArchived }.prefix(30).map { task in
                PaletteItem(id: "agent.task.\(task.id)", icon: "text.bubble", title: task.title,
                            subtitle: "Agent task · \(task.controller.workspaceDisplayName)", action: { app.agentSessions.select(task.id) })
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Empty query: commands + recent meetings (quick navigation).
        guard !q.isEmpty else {
            let recents = app.meetings.prefix(8).map { meeting in
                PaletteItem(id: "meeting.\(meeting.id.uuidString)", icon: "waveform",
                            title: meeting.title,
                            subtitle: "Open · \(meeting.appName) · \(meeting.durationLabel)",
                            action: { app.openMeeting(meeting.id) })
            }
            return actions + recents
        }
        // Non-empty query: matching commands, then a single handoff into Ask
        // (spec §2.3: the palette's meeting-search rows hand off to Ask).
        let tokens = q.split(separator: " ").map(String.init)
        let matched = actions.filter { item in
            let hay = (item.title + " " + item.subtitle).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        let raw = query.trimmingCharacters(in: .whitespaces)
        let handoff = PaletteItem(id: "ask.handoff", icon: "sparkle.magnifyingglass",
                                  title: "Search “\(raw)” in Ask",
                                  subtitle: "Ask",
                                  action: { app.openAsk(query: raw) })
        return matched + [handoff]
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func runSelection() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ item: PaletteItem) {
        item.action()
        dismiss()
    }
}

private struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.title3).foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Brand.teal.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.row)
            .strokeBorder(selected ? Brand.teal.opacity(0.4) : .clear, lineWidth: 1))
    }
}
