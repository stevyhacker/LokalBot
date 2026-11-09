import SwiftUI

/// Settings → Screen & Activity → Coding agent sessions. On by default; the saved
/// records can be deleted here, while the agents' own files stay untouched.
struct CodingAgentEvidenceSettings: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmingDeletion = false
    @State private var error: String?

    var body: some View {
        Group {
            Toggle(isOn: $app.settings.codingAgentEvidenceEnabled) {
                SettingsLabel("Read coding agent sessions",
                              help: "Adds Claude Code and Codex sessions on this Mac to the day digest: your requests, changed file names, commits, and pull requests. Tool output and file contents are never read.")
            }
            .settingTarget("settings.codingAgentEvidenceEnabled", selected: app.focusedSettingID)
            .accessibilityIdentifier("settings.codingAgentEvidence")
            if app.settings.codingAgentEvidenceEnabled {
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
            if let error { Text(error).workspaceTextRole(.warning) }
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
