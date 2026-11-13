import SwiftUI

/// Settings → Screen & Activity → Coding agent sessions. Sessions are on by
/// default and their saved records can be deleted here. Notes are off until
/// turned on after a notice. The agents' own files stay untouched either way.
struct CodingAgentEvidenceSettings: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmingDeletion = false
    @State private var confirmingNotes = false
    @State private var error: String?

    var body: some View {
        Group {
            Toggle(isOn: $app.settings.codingAgentEvidenceEnabled) {
                SettingsLabel("Read coding agent sessions",
                              help: "Adds Claude Code and Codex sessions on this Mac to the day digest: your requests, changed file names, commits, and pull requests. Tool output and file contents are never read.")
            }
            .settingTarget("settings.codingAgentEvidenceEnabled", selected: app.focusedSettingID)
            .accessibilityIdentifier("settings.codingAgentEvidence")
            Toggle(isOn: Binding(
                get: { app.settings.codingAgentNotesEnabled },
                set: { on in
                    if on { confirmingNotes = true } else { app.settings.codingAgentNotesEnabled = false }
                })) {
                SettingsLabel("Read coding agent notes",
                              help: "Makes the notes Claude Code and Codex keep for their own later sessions searchable in Ask, Search and Quick Recall. Turning it off deletes LokalBot's copies.")
            }
            .settingTarget("settings.codingAgentNotesEnabled", selected: app.focusedSettingID)
            .accessibilityIdentifier("settings.codingAgentNotes")
            if app.settings.codingAgentEvidenceEnabled || app.settings.codingAgentNotesEnabled {
                Toggle("Claude Code", isOn: $app.settings.codingAgentReadsClaudeCode)
                Toggle("Codex", isOn: $app.settings.codingAgentReadsCodex)
                ExclusionRulesEditor(
                    title: "Never read sessions in these folders",
                    value: $app.settings.codingAgentExcludedFolders,
                    kind: .folders)
                    .settingTarget("settings.codingAgentExcludedFolders", selected: app.focusedSettingID)
            }
            LabeledContent {
                Button("Delete saved agent sessions…", role: .destructive) { confirmingDeletion = true }
            } label: {
                SettingsLabel("Saved sessions", help: "Stops reading and deletes what LokalBot saved. Generated journals that used it are withdrawn.")
            }
            SettingsDetails("What is read",
                            "LokalBot reads the session files in ~/.claude/projects and ~/.codex/sessions, never "
                                + "the agents' credentials or settings. It keeps your requests, the agent's final report, "
                                + "changed file names, and actions such as commits, pull requests, pushes, and test runs. "
                                + "Tool output, command output, file contents, and reasoning are skipped, and detected "
                                + "credentials are redacted. Work in progress is added after ten quiet minutes. Saved "
                                + "sessions follow screen-text retention, and turning this off keeps them until you "
                                + "delete them. The agents' own files are never changed.")
            if app.settings.codingAgentNotesEnabled {
                AgentNotesStatusRow(notes: app.agentNotes)
            }
            SettingsDetails("What is read from notes",
                            "LokalBot reads the Markdown notes in ~/.claude/projects/*/memory and, from "
                                + "~/.codex/memories, MEMORY.md, memory_summary.md and the session summaries. It reads "
                                + "nothing else there: no credentials, settings, skills or instruction files. It keeps "
                                + "each note's title, text and file path in its library, with detected credentials "
                                + "redacted, and checks for changes every ten minutes. Notes about a folder listed "
                                + "above are left out. A note the agent deletes leaves LokalBot at the next check, and "
                                + "turning this off deletes every copy. Notes are an agent's own summary, so Ask "
                                + "treats them as leads to check, not as facts.")
            if let error { Text(error).workspaceTextRole(.warning) }
        }
        .alert("Read coding agent notes?", isPresented: $confirmingNotes) {
            Button("Turn On") { app.settings.codingAgentNotesEnabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LokalBot reads the notes Claude Code and Codex saved for themselves, for every project they worked in, and keeps a searchable copy in its library. Nothing leaves this Mac. Turning this off deletes the copy.")
        }
        .confirmationDialog(
            "Delete saved agent sessions?", isPresented: $confirmingDeletion, titleVisibility: .visible
        ) {
            Button("Delete and Stop Reading", role: .destructive) {
                do {
                    try app.deleteCodingAgentEvidence()
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LokalBot stops reading coding agent sessions and deletes what it saved. Claude Code and Codex keep their own session files.")
        }
    }
}

/// How many notes are saved, or why none are.
private struct AgentNotesStatusRow: View {
    @ObservedObject var notes: AgentMemoryIngestor

    var body: some View {
        LabeledContent("Saved notes") {
            if let error = notes.lastError {
                Text(error).workspaceTextRole(.warning)
            } else {
                Text(summary).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("settings.codingAgentNotes.status")
    }

    private var summary: String {
        let parts = CodingAgentKind.allCases.compactMap { agent -> String? in
            guard let count = notes.counts[agent], count > 0 else { return nil }
            return "\(agent.displayName) \(count)"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
