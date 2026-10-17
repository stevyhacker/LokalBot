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
                    .foregroundStyle(.tint).font(.scaled(.title3))
                CommandPaletteTextField(
                    text: $query,
                    focusRequest: focusRequest,
                    onSubmit: runSelection,
                    onPrevious: { move(by: -1) },
                    onNext: { move(by: 1) },
                    onCancel: { dismiss() })
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                Text("⌘K").font(.scaled(.caption).monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()

            if results.isEmpty {
                Text("No matches")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
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
    private var results: [PaletteCommand] {
        let actions = PaletteCommandCatalog.commands(app: app, source: "palette", inWorkspace: true)
        let q = query.trimmingCharacters(in: .whitespaces)
        // Empty query: commands + recent meetings (quick navigation).
        guard !q.isEmpty else {
            let recents = app.meetings.prefix(8).map { meeting in
                PaletteCommand(id: "meeting.\(meeting.id.uuidString)", icon: "waveform",
                               title: meeting.title,
                               subtitle: "Open · \(meeting.appName) · \(meeting.displayDuration)",
                               action: { app.openMeeting(meeting.id) })
            }
            return actions + recents
        }
        // Non-empty query: matching commands, then a single handoff into Ask
        // (spec §2.3: the palette's meeting-search rows hand off to Ask).
        let matched = PaletteCommandFilter.filter(actions, query: q, matching: .substring)
        let handoff = PaletteCommand(id: "ask.handoff", icon: "sparkle.magnifyingglass",
                                     title: "Search “\(q)” in Ask",
                                     subtitle: "Ask",
                                     action: { app.openAsk(query: q) })
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

    private func run(_ item: PaletteCommand) {
        item.action()
        dismiss()
    }
}

private struct PaletteRow: View {
    let item: PaletteCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.scaled(.title3)).foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.scaled(.callout)).lineLimit(1)
                Text(item.subtitle).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Brand.teal.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.row)
            .strokeBorder(selected ? Brand.teal.opacity(0.4) : .clear, lineWidth: 1))
    }
}
