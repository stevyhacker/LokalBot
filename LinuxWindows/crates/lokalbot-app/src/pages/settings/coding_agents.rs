//! Day Memory → Coding agent sessions (`CodingAgentEvidenceSettings.swift`).
//! Nothing is read until the person has chosen, in setup or here. The saved
//! records can be deleted here, while the agents' own files stay untouched.

use gpui_kit::component::Sizable as _;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::button::{Button, ButtonVariant};
use gpui_kit::{AnyElement, App, Context, Entity, SharedString, Window};

use super::{Section, SettingsPage};
use crate::state::AppData;
use crate::ui::settings_row;

const DETAILS_UNIX: &str = "LokalBot reads the session files in ~/.claude/projects and ~/.codex/sessions, never the agents' credentials or settings. It keeps your requests, the agent's final report, changed file names, and actions such as commits, pull requests, pushes, and test runs. Tool output, command output, file contents, and reasoning are skipped, and detected credentials are redacted. Work in progress is added after ten quiet minutes. Saved sessions follow screen-text retention, and turning this off keeps them until you delete them. The agents' own files are never changed.";
const DETAILS_WINDOWS: &str = "LokalBot reads the session files in %USERPROFILE%\\.claude\\projects and %USERPROFILE%\\.codex\\sessions, never the agents' credentials or settings. It keeps your requests, the agent's final report, changed file names, and actions such as commits, pull requests, pushes, and test runs. Tool output, command output, file contents, and reasoning are skipped, and detected credentials are redacted. Work in progress is added after ten quiet minutes. Saved sessions follow screen-text retention, and turning this off keeps them until you delete them. The agents' own files are never changed.";

/// The row reads what actually happens: on only once the person has chosen.
pub fn reads_sessions(settings: &lokalbot_core::Settings) -> bool {
    settings.coding_agent_evidence_enabled && settings.coding_agent_evidence_confirmed
}

/// Flipping the row is the person's choice, whichever way they flip it.
pub fn choose(settings: &mut lokalbot_core::Settings, on: bool) {
    settings.coding_agent_evidence_enabled = on;
    settings.coding_agent_evidence_confirmed = true;
}

fn confirm_deletion(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        alert
            .title(lokalbot_i18n::tr("Delete saved agent sessions?"))
            .description(lokalbot_i18n::tr(
                "LokalBot stops reading coding agent sessions and deletes what it saved. Claude Code and Codex keep their own session files.",
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Delete and Stop Reading"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.update_settings(|s| choose(s, false), cx);
                    data.delete_coding_agent_evidence(cx);
                });
                true
            })
    });
}

impl SettingsPage {
    pub(super) fn coding_agents_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let reading = reads_sessions(&settings);
        let data = self.data.clone();
        let help: SharedString = if settings.coding_agent_evidence_confirmed {
            lokalbot_i18n::tr("Adds Claude Code and Codex sessions on this computer to the day digest: your requests, changed file names, commits, and pull requests. Tool output and file contents are never read.").into()
        } else {
            lokalbot_i18n::tr("Off until you choose. LokalBot hasn't read anything in your Claude Code or Codex folders. Turn this on to add their sessions on this computer to the day digest: your requests, changed file names, commits, and pull requests. Tool output and file contents are never read.").into()
        };
        let mut section = Section::new(lokalbot_i18n::tr("Coding agent sessions")).row(
            "settings.codingAgentEvidenceEnabled",
            settings_row::row(
                "settings.codingAgentEvidenceEnabled",
                lokalbot_i18n::tr("Read coding agent sessions"),
                Some(help),
                settings_row::switch(
                    "settings.codingAgentEvidenceEnabled",
                    reading,
                    move |on, _, cx| {
                        data.update(cx, |data, cx| data.update_settings(|s| choose(s, on), cx))
                    },
                ),
                self.is_focused("settings.codingAgentEvidenceEnabled"),
                cx,
            ),
        );
        if reading {
            section = section
                .row(
                    "settings.codingAgentReadsClaudeCode",
                    self.toggle(
                        "settings.codingAgentReadsClaudeCode",
                        "Claude Code",
                        None,
                        settings.coding_agent_reads_claude_code,
                        |s, v| s.coding_agent_reads_claude_code = v,
                        cx,
                    ),
                )
                .row(
                    "settings.codingAgentReadsCodex",
                    self.toggle(
                        "settings.codingAgentReadsCodex",
                        "Codex",
                        None,
                        settings.coding_agent_reads_codex,
                        |s, v| s.coding_agent_reads_codex = v,
                        cx,
                    ),
                )
                .row(
                    "settings.codingAgentExcludedFolders",
                    settings_row::content_row(
                        "settings.codingAgentExcludedFolders",
                        self.coding_agent_folders.clone(),
                        self.is_focused("settings.codingAgentExcludedFolders"),
                        cx,
                    ),
                );
        }
        let delete_data = self.data.clone();
        section = section
            .row(
                "settings.codingAgentSavedSessions",
                settings_row::row(
                    "settings.codingAgentSavedSessions",
                    lokalbot_i18n::tr("Saved sessions"),
                    Some(lokalbot_i18n::tr("Stops reading and deletes what LokalBot saved. Generated journals that used it are withdrawn.").into()),
                    Button::new("settings-delete-agent-sessions")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Delete saved agent sessions…"))
                        .on_click(move |_, window, cx| {
                            confirm_deletion(delete_data.clone(), window, cx)
                        }),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.codingAgentDetails",
                self.coding_agent_details(cx),
            );
        section
    }

    fn coding_agent_details(&self, cx: &mut Context<Self>) -> AnyElement {
        self.details(
            "settings.codingAgentDetails",
            "What is read",
            if cfg!(windows) {
                DETAILS_WINDOWS
            } else {
                DETAILS_UNIX
            },
            cx,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::Settings;

    #[test]
    fn the_row_stays_off_until_the_person_chooses() {
        let mut settings = Settings::default();
        // Saved as true without ever having been asked.
        assert!(settings.coding_agent_evidence_enabled);
        assert!(!reads_sessions(&settings));
        assert!(settings.enabled_coding_agents().is_empty());

        choose(&mut settings, true);
        assert!(reads_sessions(&settings));
        assert_eq!(settings.enabled_coding_agents().len(), 2);

        // Turning it off is a choice too, so it isn't asked again.
        choose(&mut settings, false);
        assert!(!reads_sessions(&settings));
        assert!(settings.coding_agent_evidence_confirmed);
        assert!(settings.enabled_coding_agents().is_empty());
    }
}
