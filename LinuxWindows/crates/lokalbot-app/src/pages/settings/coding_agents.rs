//! Day Memory → Coding agent sessions (`CodingAgentEvidenceSettings.swift`).
//! Nothing is read until the person has chosen, in setup or here. The saved
//! records can be deleted here. Notes are off until turned on after a notice.
//! The agents' own files stay untouched either way.

use gpui_kit::component::Sizable as _;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::button::{Button, ButtonVariant};
use gpui_kit::{
    AnyElement, App, Context, Entity, IntoElement as _, ParentElement as _, SharedString,
    Styled as _, Window, div,
};

use super::{Section, SettingsPage};
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

const DETAILS_UNIX: &str = "LokalBot reads the session files in ~/.claude/projects and ~/.codex/sessions, never the agents' credentials or settings. It keeps your requests, the agent's final report, changed file names, and actions such as commits, pull requests, pushes, and test runs. Tool output, command output, file contents, and reasoning are skipped, and detected credentials are redacted. Work in progress is added after ten quiet minutes. Saved sessions follow screen-text retention, and turning this off keeps them until you delete them. The agents' own files are never changed.";
const DETAILS_WINDOWS: &str = "LokalBot reads the session files in %USERPROFILE%\\.claude\\projects and %USERPROFILE%\\.codex\\sessions, never the agents' credentials or settings. It keeps your requests, the agent's final report, changed file names, and actions such as commits, pull requests, pushes, and test runs. Tool output, command output, file contents, and reasoning are skipped, and detected credentials are redacted. Work in progress is added after ten quiet minutes. Saved sessions follow screen-text retention, and turning this off keeps them until you delete them. The agents' own files are never changed.";

const NOTES_DETAILS_UNIX: &str = "LokalBot reads the Markdown notes in ~/.claude/projects/*/memory and, from ~/.codex/memories, MEMORY.md, memory_summary.md and the session summaries. It reads nothing else there: no credentials, settings, skills or instruction files. It keeps each note's title, text and file path in its library, with detected credentials redacted, and checks for changes every ten minutes. Notes about a folder listed above are left out. A note the agent deletes leaves LokalBot at the next check, and turning this off deletes every copy. Notes are an agent's own summary, so Ask treats them as leads to check, not as facts.";
const NOTES_DETAILS_WINDOWS: &str = "LokalBot reads the Markdown notes in %USERPROFILE%\\.claude\\projects\\*\\memory and, from %USERPROFILE%\\.codex\\memories, MEMORY.md, memory_summary.md and the session summaries. It reads nothing else there: no credentials, settings, skills or instruction files. It keeps each note's title, text and file path in its library, with detected credentials redacted, and checks for changes every ten minutes. Notes about a folder listed above are left out. A note the agent deletes leaves LokalBot at the next check, and turning this off deletes every copy. Notes are an agent's own summary, so Ask treats them as leads to check, not as facts.";

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

/// The notice before notes are read: they cover every project the agents
/// worked in, so reading starts only on Turn On.
fn confirm_notes(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        alert
            .title(lokalbot_i18n::tr("Read coding agent notes?"))
            .description(lokalbot_i18n::tr(
                "LokalBot reads the notes Claude Code and Codex saved for themselves, for every project they worked in, and keeps a searchable copy in its library. Nothing leaves this PC. Turning this off deletes the copy.",
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Turn On"))
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.update_settings(|s| s.coding_agent_notes_enabled = true, cx);
                });
                true
            })
    });
}

/// "Claude Code 12 · Codex 3", or a dash while nothing is saved.
pub fn saved_notes_summary(status: &lokalbot_engine::agent_notes::AgentNotesStatus) -> String {
    if status.counts.is_empty() {
        return "—".into();
    }
    status
        .counts
        .iter()
        .map(|(agent, count)| format!("{} {}", agent.display_name(), lokalbot_i18n::number(*count)))
        .collect::<Vec<_>>()
        .join(" · ")
}

impl SettingsPage {
    pub(super) fn coding_agents_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let reading = reads_sessions(&settings);
        let reading_notes = settings.coding_agent_notes_enabled;
        let notes_data = self.data.clone();
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
        section = section.row(
            "settings.codingAgentNotesEnabled",
            settings_row::row(
                "settings.codingAgentNotesEnabled",
                lokalbot_i18n::tr("Read coding agent notes"),
                Some(lokalbot_i18n::tr("Makes the notes Claude Code and Codex keep for their own later sessions searchable in Ask and Quick Recall. Turning it off deletes LokalBot's copies.").into()),
                settings_row::switch(
                    "settings.codingAgentNotesEnabled",
                    reading_notes,
                    move |on, window, cx| {
                        if on {
                            confirm_notes(notes_data.clone(), window, cx);
                        } else {
                            notes_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.coding_agent_notes_enabled = false, cx)
                            });
                        }
                    },
                ),
                self.is_focused("settings.codingAgentNotesEnabled"),
                cx,
            ),
        );
        // The agent switches and the excluded folders apply to notes too.
        if reading || reading_notes {
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
        if reading_notes {
            let status = self.data.read(cx).agent_notes.clone();
            let value = match &status.error {
                Some(error) => div()
                    .text_size(ty::BODY)
                    .text_color(cx.lb().attention_text)
                    .child(error.clone())
                    .into_any_element(),
                None => settings_row::value(saved_notes_summary(&status), cx).into_any_element(),
            };
            section = section.row(
                "settings.codingAgentNotesStatus",
                settings_row::row(
                    "settings.codingAgentNotesStatus",
                    lokalbot_i18n::tr("Saved notes"),
                    None,
                    value,
                    false,
                    cx,
                ),
            );
        }
        section = section.row(
            "settings.codingAgentNotesDetails",
            self.details(
                "settings.codingAgentNotesDetails",
                "What is read from notes",
                if cfg!(windows) {
                    NOTES_DETAILS_WINDOWS
                } else {
                    NOTES_DETAILS_UNIX
                },
                cx,
            ),
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
