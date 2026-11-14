//! Privacy & permissions (what LokalBot may use on this computer and what
//! leaves it), and the sections that moved out of the old Privacy & Data:
//! screen retention and capture exclusions (now on Screen & activity) and
//! external agent access (now on AI agents).

use crate::i18n::h_flex;
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, InteractiveElement as _, IntoElement as _,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::access::ScreenScope;

use super::status::{AGENT_READ_KINDS, Access, SettingsStatus};
use super::{Section, SettingsPage, header, models};
use crate::pages::people::model::fill;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

const SCOPES: [ScreenScope; 3] = [
    ScreenScope::Today,
    ScreenScope::RecentWeek,
    ScreenScope::RetainedHistory,
];

fn scope_detail(scope: ScreenScope) -> &'static str {
    match scope {
        ScreenScope::Today => {
            lokalbot_i18n::tr("Agents can read only context captured since local midnight.")
        }
        ScreenScope::RecentWeek => {
            lokalbot_i18n::tr("Agents can read context from the rolling last seven days.")
        }
        ScreenScope::RetainedHistory => lokalbot_i18n::tr(
            "Agents can read everything still inside the configured retention window.",
        ),
    }
}

fn days_label(days: u32) -> String {
    if days == 1 {
        lokalbot_i18n::tr("1 day").into()
    } else {
        lokalbot_i18n::format("{days} days", &[("days", format!("{}", days))])
    }
}

/// One kind of agent access, shown again on the page of what it reads
/// (`AgentKindAccessSection`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AgentKind {
    ScreenMemory,
    Files,
}

impl SettingsPage {
    /// The same switch as on Privacy & Data, on the page it reads from.
    pub(super) fn agent_kind_section(&self, kind: AgentKind, cx: &mut Context<Self>) -> Section {
        let page = cx.entity();
        let (id, title, help, on) = match kind {
            AgentKind::ScreenMemory => (
                "settings.agentKind.screenMemory",
                "Let external agents read screen memory",
                "Captured text and metadata, within the history you grant. Screenshot pixels are never returned.",
                self.screen_access.flatten().is_some(),
            ),
            AgentKind::Files => (
                "settings.agentKind.files",
                "Let external agents search Files",
                "Search the folders you chose under Files by their words. Files are never changed.",
                self.files_access.unwrap_or_else(|| {
                    lokalbot_core::files::access::is_enabled(self.data.read(cx).library.paths())
                }),
            ),
        };
        let mut section = Section::new(lokalbot_i18n::tr("External agents")).row(
            id,
            settings_row::row(
                id,
                lokalbot_i18n::tr(title),
                Some(lokalbot_i18n::tr(help).into()),
                settings_row::switch(id, on, move |on, _, cx| {
                    page.update(cx, |page, cx| match kind {
                        AgentKind::ScreenMemory => {
                            page.set_screen_access(on.then_some(ScreenScope::RecentWeek), cx)
                        }
                        AgentKind::Files => page.set_files_access(on, cx),
                    })
                }),
                self.is_focused(id),
                cx,
            ),
        );
        if kind == AgentKind::ScreenMemory
            && let Some(scope) = self.screen_access.flatten()
        {
            let scope_page = cx.entity();
            section = section.row(
                "settings.agentKind.screenMemoryScope",
                settings_row::row(
                    "settings.agentKind.screenMemoryScope",
                    lokalbot_i18n::tr("Granted history"),
                    Some(scope_detail(scope).into()),
                    settings_row::picker(
                        "settings-agent-kind-screen-scope",
                        lokalbot_i18n::tr(scope.label()),
                        SCOPES
                            .iter()
                            .map(|s| {
                                (
                                    SharedString::from(lokalbot_i18n::tr(s.label())),
                                    *s == scope,
                                )
                            })
                            .collect(),
                        move |index, _, cx| {
                            let scope = SCOPES[index];
                            scope_page
                                .update(cx, |page, cx| page.set_screen_access(Some(scope), cx))
                        },
                    ),
                    false,
                    cx,
                ),
            );
        }
        section.row(
            "settings.agentKindHelp",
            settings_row::content_row(
                "settings.agentKindHelp",
                settings_row::help(
                    lokalbot_i18n::tr(
                        "The same switch as on AI agents. Agents read only; they never change anything.",
                    ),
                    cx,
                ),
                false,
                cx,
            ),
        )
    }

    fn set_meetings_access(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.meetings_access = Some(enabled);
        let paths = self.data.read(cx).library.paths().clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_core::access::set_meetings_access(&paths, enabled)
                })
                .await;
            if let Err(err) = result {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not change agent access: {err}",
                            &[("err", format!("{}", err))],
                        ),
                        cx,
                    )
                });
            }
            let _ = this.update(cx, |this, cx| this.reload_access(cx));
        })
        .detach();
        cx.notify();
    }

    /// The Files grant, with the folder list it keeps (`FilesAccessManager`).
    fn set_files_access(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.files_access = Some(enabled);
        let (paths, folders) = {
            let data = self.data.read(cx);
            (
                data.library.paths().clone(),
                data.settings
                    .file_search_enabled
                    .then(|| data.settings.file_search_folders.clone()),
            )
        };
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_core::files::access::set_enabled(&paths, enabled)?;
                    if enabled {
                        lokalbot_core::files::access::refresh(&paths, folders.as_deref())?;
                    }
                    anyhow::Ok(())
                })
                .await;
            if let Err(err) = result {
                let _ = this.update(cx, |this, cx| {
                    this.files_access = Some(!enabled);
                    cx.notify();
                });
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "LokalBot couldn't turn on file access: {err}",
                            &[("err", format!("{err:#}"))],
                        ),
                        cx,
                    )
                });
            }
        })
        .detach();
    }

    /// The Agent notes grant: only a marker. Agents find notes only while Read
    /// coding agent notes is on, because turning that off deletes the copy.
    fn set_agent_notes_access(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.agent_notes_access = Some(enabled);
        let paths = self.data.read(cx).library.paths().clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    lokalbot_core::agent_notes::access::set_enabled(&paths, enabled)
                })
                .await;
            if let Err(err) = result {
                let _ = this.update(cx, |this, cx| {
                    this.agent_notes_access = Some(!enabled);
                    cx.notify();
                });
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "LokalBot couldn't turn on agent-notes access: {err}",
                            &[("err", format!("{err:#}"))],
                        ),
                        cx,
                    )
                });
            }
        })
        .detach();
        cx.notify();
    }

    fn set_screen_access(&mut self, scope: Option<ScreenScope>, cx: &mut Context<Self>) {
        self.screen_access = Some(scope);
        let paths = self.data.read(cx).library.paths().clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(
                    async move { lokalbot_core::access::set_screen_access(&paths, scope) },
                )
                .await;
            if let Err(err) = result {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not change screen memory access: {err}",
                            &[("err", format!("{}", err))],
                        ),
                        cx,
                    )
                });
            }
            let _ = this.update(cx, |this, cx| this.reload_access(cx));
        })
        .detach();
        cx.notify();
    }

    /// Privacy & permissions (`SettingsPrivacySections`): the one place
    /// that shows what LokalBot may use on this computer and what leaves it.
    /// Each permission says which features use it and where it stands; each
    /// server that receives something is listed with the control that
    /// revokes it; sharing with agents and with phones is summed up and opens
    /// its own page, where its consent lives. PRIVACY.md is the contract for
    /// every sentence here.
    pub(super) fn privacy_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        self.refresh_library_size(cx);
        let status = self.status(cx);
        let permissions = self.permissions_section(&status, cx);
        let leaves = self.leaves_section(&status, cx);
        let kept = Section::new(lokalbot_i18n::tr("Where it’s kept"))
            .row("settings.libraryLocation", self.library_row(true, cx));
        let links = Section::new(None).row(
            "settings.privacyLinks",
            settings_row::content_row(
                "settings.privacyLinks",
                h_flex()
                    .gap(px(16.))
                    .child(settings_row::link_button(
                        "settings-privacy-policy",
                        lokalbot_i18n::tr("Privacy Policy"),
                        |_, cx| cx.open_url("https://www.lokalbot.com/privacy"),
                        cx,
                    ))
                    .child(settings_row::link_button(
                        "settings-support",
                        lokalbot_i18n::tr("Support"),
                        |_, cx| cx.open_url("https://www.lokalbot.com/support"),
                        cx,
                    )),
                false,
                cx,
            ),
        );

        vec![permissions, leaves, kept, links]
    }

    /// Screen memory retention (`retentionSection`), on Screen & activity.
    pub(super) fn retention_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let days = self
            .retention_draft
            .unwrap_or(settings.retention_days)
            .clamp(1, 90);
        let keep_page = cx.entity();
        let keep_days = settings.retention_days;
        let review_page = cx.entity();
        let (review_days, review_forever) =
            (settings.retention_days, settings.keep_ocr_text_forever);
        let retention_status = self
            .retention_error
            .clone()
            .map(|error| (error, true))
            .or_else(|| self.retention_completion.clone().map(|text| (text, false)));
        let mut retention = Section::new(lokalbot_i18n::tr("Screen memory retention"))
            .row(
                "settings.retentionDays",
                settings_row::stacked_row(
                    "settings.retentionDays",
                    lokalbot_i18n::format("Keep screen context {0}", &[("0", days_label(days).to_string())]),
                    Some(lokalbot_i18n::tr("Old images, screen text, screen titles, URLs, document names, saved coding agent sessions, and activity titles expire. App names and durations remain. Saved moments stay until unsaved or deleted.").into()),
                    Slider::new(&self.retention_slider).w_full(),
                    self.is_focused("settings.retentionDays"),
                    cx,
                ),
            )
            .row(
                "settings.keepOCRTextForever",
                settings_row::row(
                    "settings.keepOCRTextForever",
                    lokalbot_i18n::tr("Keep screen text forever"),
                    Some(lokalbot_i18n::tr("Images and activity titles still expire. Screen text, titles, URLs, and document names stay searchable.").into()),
                    settings_row::switch(
                        "settings.keepOCRTextForever",
                        settings.keep_ocr_text_forever,
                        move |on, window, cx| {
                            // Turning this off deletes text, so it goes through the review.
                            keep_page.update(cx, |page, cx| {
                                page.propose_retention(keep_days, on, window, cx)
                            })
                        },
                    ),
                    self.is_focused("settings.keepOCRTextForever"),
                    cx,
                ),
            )
            .row(
                "settings.retentionCleanup",
                settings_row::row(
                    "settings.retentionCleanup",
                    lokalbot_i18n::tr("Cleanup"),
                    Some(lokalbot_i18n::tr("Shortening retention opens this review before anything is deleted.").into()),
                    Button::new("settings-retention-review")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Review expired context…"))
                        .on_click(move |_, window, cx| {
                            review_page.update(cx, |page, cx| {
                                page.load_retention_review(
                                    review_days,
                                    review_forever,
                                    None,
                                    window,
                                    cx,
                                )
                            })
                        }),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.retentionNote",
                settings_row::content_row(
                    "settings.retentionNote",
                    settings_row::help(lokalbot_i18n::tr("Unedited generated journals and dependent Dream memory retract when their source is removed. Edited or legacy journals, saved Ask/Agent conversations, and exported or routine files have separate lifetimes. Delete conversations in Ask or clear saved Agent history; remove edited journals and exported files from their folders."), cx),
                    false,
                    cx,
                ),
            );
        if let Some((message, is_error)) = retention_status {
            let color = if is_error {
                cx.lb().attention_text
            } else {
                cx.lb().text_secondary
            };
            retention = retention.row(
                "settings.retentionStatus",
                settings_row::content_row(
                    "settings.retentionStatus",
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(color)
                        .child(crate::ui::text::paragraph(message)),
                    false,
                    cx,
                ),
            );
        }

        retention
    }

    /// What external agents may read or change (`agentAccessSection`), on
    /// AI agents. The switches are the same as before the move.
    pub(super) fn agent_access_section(&mut self, cx: &mut Context<Self>) -> Section {
        self.reload_personal(cx);
        let page = cx.entity();
        let meetings_page = page.clone();
        let screen_page = page.clone();
        let files_page = cx.entity();
        let files_on = self.files_access.unwrap_or_else(|| {
            lokalbot_core::files::access::is_enabled(self.data.read(cx).library.paths())
        });
        let notes_page = cx.entity();
        let notes_on = self.agent_notes_access.unwrap_or_else(|| {
            lokalbot_core::agent_notes::access::is_enabled(self.data.read(cx).library.paths())
        });
        let meetings_on = self.meetings_access.unwrap_or(false);
        let screen_scope = self.screen_access.flatten();
        let mut agents = Section::new(lokalbot_i18n::tr("External agents"))
            .row(
                "settings.agentAccess",
                settings_row::row(
                    "settings.agentAccess",
                    lokalbot_i18n::tr("Allow external agents to read your meeting library"),
                    Some(lokalbot_i18n::tr("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, search, and ask about your meetings — read-only and on this PC only. Off by default.").into()),
                    settings_row::switch("settings.agentAccess", meetings_on, move |on, _, cx| {
                        meetings_page.update(cx, |page, cx| page.set_meetings_access(on, cx))
                    }),
                    self.is_focused("settings.agentAccess"),
                    cx,
                ),
            )
            .row(
                "settings.filesAccess",
                settings_row::row(
                    "settings.filesAccess",
                    lokalbot_i18n::tr("Allow external agents to search your files"),
                    Some(lokalbot_i18n::tr("Lets MCP clients and the lokalbot-cli skill search the folders you chose under Files, by their words only. What they read then goes wherever that agent sends it. Off by default.").into()),
                    settings_row::switch("settings.filesAccess", files_on, move |on, _, cx| {
                        files_page.update(cx, |page, cx| page.set_files_access(on, cx))
                    }),
                    self.is_focused("settings.filesAccess"),
                    cx,
                ),
            )
            .row(
                "settings.agentNotesAccess",
                settings_row::row(
                    "settings.agentNotesAccess",
                    lokalbot_i18n::tr("Allow external agents to search agent notes"),
                    Some(lokalbot_i18n::tr("Lets MCP clients and the lokalbot-cli skill search the notes Claude Code and Codex saved for themselves, by their words. What they read then goes wherever that agent sends it. Off by default.").into()),
                    settings_row::switch("settings.agentNotesAccess", notes_on, move |on, _, cx| {
                        notes_page.update(cx, |page, cx| page.set_agent_notes_access(on, cx))
                    }),
                    self.is_focused("settings.agentNotesAccess"),
                    cx,
                ),
            )
            .row(
                "settings.screenMemoryAccess",
                settings_row::row(
                    "settings.screenMemoryAccess",
                    lokalbot_i18n::tr("Allow external agents to read screen memory"),
                    Some(lokalbot_i18n::tr("Separate, scoped, read-only access to captured text and metadata. Screenshot pixels are never returned.").into()),
                    settings_row::switch("settings.screenMemoryAccess", screen_scope.is_some(), move |on, _, cx| {
                        screen_page.update(cx, |page, cx| page.set_screen_access(on.then_some(ScreenScope::RecentWeek), cx))
                    }),
                    self.is_focused("settings.screenMemoryAccess"),
                    cx,
                ),
            );
        agents = agents.row(
            "settings.personalContextAccess",
            self.personal_access_row(None, cx),
        );
        // The way to the items, once there's a grant for them to go through.
        if self.personal.access_on {
            let shared = self.shared_personal_items();
            let choose_page = page.clone();
            agents = agents.row(
                "settings.personalContextItems",
                settings_row::row(
                    "settings.personalContextItems",
                    if shared == 1 {
                        lokalbot_i18n::tr("1 item shared").to_string()
                    } else {
                        lokalbot_i18n::format("{0} items shared", &[("0", shared.to_string())])
                    },
                    Some(lokalbot_i18n::tr("Agents get the most relevant shared items for their task, at most 12 at a time.").into()),
                    settings_row::link_button(
                        "settings-choose-personal-items",
                        lokalbot_i18n::tr("Choose items…"),
                        move |window, cx| {
                            choose_page.update(cx, |page, cx| {
                                page.select_category(
                                    crate::state::SettingsCategory::PersonalContext,
                                    window,
                                    cx,
                                )
                            })
                        },
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        // Agents can search only the folders chosen under Files.
        let settings = self.data.read(cx).settings.clone();
        if files_on && (!settings.file_search_enabled || settings.file_search_folders.is_empty()) {
            let choose_page = page.clone();
            agents = agents.row(
                "settings.filesAccessFolders",
                settings_row::row(
                    "settings.filesAccessFolders",
                    lokalbot_i18n::tr("Files has no folders yet"),
                    Some(
                        lokalbot_i18n::tr(
                            "Agents can search only the folders you chose under Files.",
                        )
                        .into(),
                    ),
                    settings_row::link_button(
                        "settings-choose-agent-folders",
                        lokalbot_i18n::tr("Choose folders…"),
                        move |window, cx| {
                            choose_page.update(cx, |page, cx| {
                                page.reveal("settings.fileSearchEnabled", window, cx)
                            })
                        },
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        // Agents find notes only while they are being read.
        if notes_on && !settings.coding_agent_notes_enabled {
            let notes_page = page.clone();
            agents = agents.row(
                "settings.agentNotesAccessOff",
                settings_row::row(
                    "settings.agentNotesAccessOff",
                    lokalbot_i18n::tr("Coding agent notes are off"),
                    Some(
                        lokalbot_i18n::tr(
                            "Agents can search the notes only while Read coding agent notes is on.",
                        )
                        .into(),
                    ),
                    settings_row::link_button(
                        "settings-read-agent-notes",
                        lokalbot_i18n::tr("Read coding agent notes"),
                        move |window, cx| {
                            notes_page.update(cx, |page, cx| {
                                page.reveal("settings.codingAgentNotesEnabled", window, cx)
                            })
                        },
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        if let Some(scope) = screen_scope {
            let scope_page = page.clone();
            agents = agents.row(
                "settings.screenMemoryScope",
                settings_row::row(
                    "settings.screenMemoryScope",
                    lokalbot_i18n::tr("Granted history"),
                    Some(scope_detail(scope).into()),
                    settings_row::picker(
                        "settings-screen-scope",
                        lokalbot_i18n::tr(scope.label()),
                        SCOPES
                            .iter()
                            .map(|s| {
                                (
                                    SharedString::from(lokalbot_i18n::tr(s.label())),
                                    *s == scope,
                                )
                            })
                            .collect(),
                        move |index, _, cx| {
                            let scope = SCOPES[index];
                            scope_page
                                .update(cx, |page, cx| page.set_screen_access(Some(scope), cx))
                        },
                    ),
                    false,
                    cx,
                ),
            );
        }

        self.settings_control_rows(agents, cx)
    }

    /// Capture exclusions (`exclusionsSection`), on Screen & activity.
    pub(super) fn exclusions_section(&mut self, cx: &mut Context<Self>) -> Section {
        Section::new(lokalbot_i18n::tr("Capture exclusions"))
            .row(
                "settings.excludedApps",
                settings_row::content_row("settings.excludedApps", self.excluded_apps.clone(), self.is_focused("settings.excludedApps"), cx),
            )
            .row(
                "settings.excludedScreenDomains",
                settings_row::content_row(
                    "settings.excludedScreenDomains",
                    self.excluded_sites.clone(),
                    self.is_focused("settings.excludedScreenDomains"),
                    cx,
                ),
            )
            .row(
                "settings.exclusionsHelp",
                settings_row::content_row(
                    "settings.exclusionsHelp",
                    settings_row::help(lokalbot_i18n::tr("Every app and window is tracked, including browsers. Add apps or sites here to keep them out: they are logged as “Private”, with the time only. Password managers (1Password, Bitwarden, KeePassXC, and others), focused password fields, private browser windows, and detected credentials are never captured. While any site is listed, a browser window whose address LokalBot cannot read keeps no title and no screen context."), cx),
                    false,
                    cx,
                ),
            )
    }

    /// "Allow external agents to change LokalBot settings", and what they changed.
    fn settings_control_rows(&mut self, section: Section, cx: &mut Context<Self>) -> Section {
        let Some(host) = crate::control::global(cx) else {
            return section;
        };
        let enabled = host.read(cx).enabled;
        let toggle_host = host.clone();
        let section = section.row(
            "settings.settingsControlAccess",
            settings_row::row(
                "settings.settingsControlAccess",
                lokalbot_i18n::tr("Allow external agents to change LokalBot settings"),
                Some(lokalbot_i18n::tr("Lets lokalbot-cli read and change your preferences, show you a setting, and start LokalBot in the background. Turning on capture, a data source, or sharing still needs you here. Separate from the other agent access toggles. Off by default.").into()),
                settings_row::switch("settings.settingsControlAccess", enabled, move |on, _, cx| {
                    toggle_host.update(cx, |host, cx| host.set_enabled(on, cx));
                }),
                self.is_focused("settings.settingsControlAccess"),
                cx,
            ),
        );
        let entries: Vec<_> = host
            .read(cx)
            .changes
            .recent
            .iter()
            .take(10)
            .cloned()
            .collect();
        if entries.is_empty() {
            return section;
        }
        let lb = cx.lb().clone();
        let open = self.agent_changes_open;
        let settings = self.data.read(cx).settings.clone();
        let header = settings_row::row(
            "settings.agentChanges",
            lokalbot_i18n::tr("Recent changes by agents"),
            Some(lokalbot_i18n::tr("Settings changed from the terminal. Undo restores the earlier value while the setting still holds the agent's.").into()),
            Button::new("settings-agent-changes-toggle")
                .outline()
                .small()
                .label(if open { lokalbot_i18n::tr("Hide") } else { lokalbot_i18n::tr("Show") })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.agent_changes_open = !this.agent_changes_open;
                    cx.notify();
                })),
            false,
            cx,
        );
        let mut section = section.row("settings.agentChanges", header);
        if !open {
            return section;
        }
        for (index, entry) in entries.into_iter().enumerate() {
            let can_undo = lokalbot_core::control::audit::can_undo(&entry, &settings);
            let when = entry
                .time
                .with_timezone(&chrono::Local)
                .format_localized(
                    lokalbot_i18n::date_pattern("%b %-d, %Y, %-I:%M %p"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string();
            let undo_host = host.clone();
            let row = h_flex()
                .gap(px(10.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(lokalbot_core::control::audit::summary(&entry)),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(format!("{} · {when}", entry.caller)),
                        ),
                )
                .child(
                    Button::new(("settings-agent-change-undo", index))
                        .outline()
                        .small()
                        .disabled(!can_undo)
                        .label(lokalbot_i18n::tr("Undo"))
                        .on_click(move |_, _, cx| {
                            undo_host.update(cx, |host, cx| host.undo(&entry, cx));
                        }),
                );
            section = section.row(
                "settings.agentChange",
                settings_row::content_row(("settings-agent-change", index), row, false, cx),
            );
        }
        section
    }

    /// Every permission this desktop has, with its real state and its fix
    /// (`SettingsPrivacySections.permissionRow`). Features that are on and
    /// use one name it; one that nothing uses now says so.
    fn permissions_section(&mut self, status: &SettingsStatus, cx: &mut Context<Self>) -> Section {
        let lb = cx.lb().clone();
        let focused = self.is_focused("settings.permissions");
        let open = header::opener(&cx.entity());
        let mut section = Section::new(lokalbot_i18n::tr("Permissions"));
        for (index, permission) in status.input.permissions.iter().enumerate() {
            let access = permission.access();
            let (sign, color) = match access {
                Access::Allowed => (Ico::CircleCheck, lb.success_text),
                Access::Missing => (Ico::CircleAlert, lb.attention_text),
                Access::NotNeeded | Access::Unchecked => (Ico::CircleMinus, lb.text_tertiary),
            };
            let state: Option<AnyElement> = match access {
                Access::Allowed => {
                    Some(settings_row::value(lokalbot_i18n::tr("Allowed"), cx).into_any_element())
                }
                Access::NotNeeded => Some(
                    settings_row::value(lokalbot_i18n::tr("Not needed now"), cx).into_any_element(),
                ),
                Access::Missing | Access::Unchecked => None,
            };
            let fix = permission
                .fix_action()
                .zip(permission.fix_title())
                .map(|(action, title)| {
                    let data = self.data.clone();
                    let open = open.clone();
                    Button::new(("settings-permission-fix", index))
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr(title))
                        .on_click(move |_, window, cx| {
                            header::perform(&action, &data, &open, window, cx)
                        })
                });
            let needed = (access == Access::Missing).then(|| {
                fill(
                    lokalbot_i18n::tr("Needed for: %@"),
                    &[&permission.needed_by.join(", ")],
                )
            });
            let row = h_flex()
                .gap(px(10.))
                .items_center()
                .child(ui::icon(sign, px(16.), color))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(permission.title.clone()),
                        )
                        .child(settings_row::help(permission.detail.clone(), cx))
                        .when_some(needed, |this, needed| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.attention_text)
                                    .child(ui::text::paragraph(needed)),
                            )
                        }),
                )
                .children(state)
                .children(fix);
            section = section.row(
                "settings.permissions",
                settings_row::content_row(
                    ("settings-permission", index),
                    row,
                    focused && index == 0,
                    cx,
                ),
            );
        }
        section.row(
            "settings.permissionsHelp",
            settings_row::content_row(
                "settings.permissionsHelp",
                settings_row::help(
                    lokalbot_i18n::tr(
                        "This desktop doesn’t ask for these: each row says what it allows LokalBot now. Only the features listed use them.",
                    ),
                    cx,
                ),
                false,
                cx,
            ),
        )
    }

    /// Every server approved to receive something, with its Revoke; the
    /// server Autocomplete sends typing to; what agents and phones may have,
    /// each opening its own page; and the rest of the network use.
    fn leaves_section(&mut self, status: &SettingsStatus, cx: &mut Context<Self>) -> Section {
        let lb = cx.lb().clone();
        let settings = self.data.read(cx).settings.clone();
        let open = header::opener(&cx.entity());
        let mut section = Section::new(lokalbot_i18n::tr("What leaves this PC"));
        let autocomplete_host = lokalbot_ai::autocomplete::server::leaves_this_computer(&settings)
            .then(|| lokalbot_ai::autocomplete::server::configured_host(&settings))
            .flatten();
        if settings.approved_remote_inference_origins.is_empty()
            && settings.approved_remote_transcription_origins.is_empty()
            && autocomplete_host.is_none()
        {
            let models_open = open.clone();
            section = section.row(
                "settings.onlineModels",
                settings_row::row(
                    "settings.onlineModels",
                    lokalbot_i18n::tr("Online models"),
                    Some(lokalbot_i18n::tr("None. Every model runs on this PC.").into()),
                    Button::new("settings-privacy-models")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Models…"))
                        .on_click(move |_, window, cx| {
                            models_open(SettingsCategory::Models, None, window, cx)
                        }),
                    false,
                    cx,
                ),
            );
        }
        let origin_row = |id: SharedString,
                          icon: Ico,
                          name: String,
                          detail: &'static str,
                          control: AnyElement,
                          cx: &mut Context<Self>| {
            settings_row::content_row(
                id,
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(ui::icon(icon, px(16.), lb.attention_text))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(div().text_size(ty::BODY).text_color(lb.text).child(name))
                            .child(settings_row::help(detail, cx)),
                    )
                    .child(control),
                false,
                cx,
            )
        };
        for origin in settings.approved_remote_inference_origins.clone() {
            let data = self.data.clone();
            let revoke = origin.clone();
            let control = Button::new(SharedString::from(format!("privacy-revoke-{origin}")))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Revoke…"))
                .on_click(move |_, window, cx| {
                    models::confirm_revoke(data.clone(), revoke.clone(), window, cx)
                })
                .into_any_element();
            let row = origin_row(
                SharedString::from(format!("settings-privacy-origin-{origin}")),
                Ico::Globe,
                models::origin_display_name(&origin),
                models::approved_origin_notice(),
                control,
                cx,
            );
            section = section.row("settings.privacyOrigin", row);
        }
        for origin in settings.approved_remote_transcription_origins.clone() {
            let data = self.data.clone();
            let revoke = origin.clone();
            let control = Button::new(SharedString::from(format!("privacy-revoke-audio-{origin}")))
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Revoke…"))
                .on_click(move |_, window, cx| {
                    models::confirm_revoke_audio(data.clone(), revoke.clone(), window, cx)
                })
                .into_any_element();
            let row = origin_row(
                SharedString::from(format!("settings-privacy-audio-origin-{origin}")),
                Ico::AudioLines,
                origin.clone(),
                models::approved_audio_origin_notice(),
                control,
                cx,
            );
            section = section.row("settings.privacyOrigin", row);
        }
        if let Some(host) = autocomplete_host {
            let change = open.clone();
            let control = settings_row::link_button(
                "settings-privacy-autocomplete-server",
                lokalbot_i18n::tr("Change…"),
                move |window, cx| {
                    change(
                        SettingsCategory::Models,
                        Some("settings.cotypingBackend"),
                        window,
                        cx,
                    )
                },
                cx,
            )
            .into_any_element();
            let detail = fill(
                lokalbot_i18n::tr(
                    "Autocomplete also sends what you type, with the context you turn on under Autocomplete, to %@.",
                ),
                &[&host],
            );
            section = section.row(
                "settings.privacyAutocompleteServer",
                settings_row::content_row(
                    "settings-privacy-autocomplete",
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(ui::icon(Ico::TextCursorInput, px(16.), lb.attention_text))
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text)
                                        .child(host.clone()),
                                )
                                .child(settings_row::help(detail, cx)),
                        )
                        .child(control),
                    false,
                    cx,
                ),
            );
        }
        // Sharing with agents and phones is agreed to on its own page.
        let kinds = status.input.agent_kinds;
        let agents_detail = if kinds == 0 {
            lokalbot_i18n::tr("Can’t read anything").to_string()
        } else {
            fill(
                lokalbot_i18n::tr("%lld of %lld kinds"),
                &[&kinds.to_string(), &AGENT_READ_KINDS.to_string()],
            )
        };
        section = section.row(
            "settings.privacyAgents",
            page_row(
                "settings-privacy-agents",
                lokalbot_i18n::tr("AI agents on this PC"),
                agents_detail,
                SettingsCategory::Agents,
                open.clone(),
                cx,
            ),
        );
        let devices_detail = if settings.companion_sharing_enabled {
            fill(
                lokalbot_i18n::tr("%lld paired"),
                &[&status.input.paired_devices.to_string()],
            )
        } else {
            lokalbot_i18n::tr("Off").to_string()
        };
        section = section.row(
            "settings.privacyDevices",
            page_row(
                "settings-privacy-devices",
                lokalbot_i18n::tr("Phones & tablets"),
                devices_detail,
                SettingsCategory::Devices,
                open,
                cx,
            ),
        );
        section.row(
            "settings.privacyElse",
            settings_row::row(
                "settings.privacyElse",
                lokalbot_i18n::tr("Anything else"),
                Some(
                    lokalbot_i18n::tr(
                        "Model downloads, update checks, and Agent Mode’s one-time setup use the internet. So do calendar links you add under Meetings.",
                    )
                    .into(),
                ),
                div(),
                false,
                cx,
            ),
        )
    }
}

/// A summary that opens the page where the sharing is set up and agreed to.
fn page_row(
    id: &'static str,
    title: &'static str,
    detail: String,
    page: SettingsCategory,
    open: header::Opener,
    cx: &gpui_kit::App,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let lb = cx.lb();
    settings_row::content_row(
        id,
        h_flex()
            .id(SharedString::from(format!("{id}-open")))
            .gap(px(12.))
            .items_center()
            .cursor_pointer()
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(div().text_size(ty::BODY).text_color(lb.text).child(title))
                    .child(settings_row::help(detail, cx)),
            )
            .child(ui::icon(
                super::overview::chevron(),
                px(12.),
                lb.text_secondary,
            ))
            .on_click(move |_, window, cx| open(page, None, window, cx)),
        false,
        cx,
    )
}
