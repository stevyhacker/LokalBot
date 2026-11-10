//! Privacy & Data: where data lives, screen retention, external agent access
//! and capture exclusions.

use crate::i18n::h_flex;
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{AppContext as _, Context, ParentElement as _, SharedString, Styled as _, div, px};
use lokalbot_core::access::ScreenScope;
use lokalbot_core::settings::SummarizerBackend;

use super::{Section, SettingsPage};
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
                        "The same switch as on External Agents. Agents read only; they never change anything.",
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

    pub(super) fn privacy_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, root) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.library.paths().root().to_path_buf(),
            )
        };
        let lb = cx.lb().clone();

        let audio_host = lokalbot_core::remote_transcription::audio_destination(&settings);
        let backend = match settings.summarizer_backend {
            SummarizerBackend::Ollama => lokalbot_i18n::tr("Ollama"),
            SummarizerBackend::ChatGptPlan => lokalbot_i18n::tr("ChatGPT plan"),
            SummarizerBackend::ClaudePlan => lokalbot_i18n::tr("Claude plan"),
            _ => lokalbot_i18n::tr("OpenAI-compatible server"),
        };
        let where_text = match (&audio_host, settings.think_is_local()) {
            (None, true) => lokalbot_i18n::tr("Audio, transcripts, and captured context stay on this PC. Network access is limited to model downloads, updates, and optional Agent Mode setup.").to_string(),
            (None, false) => lokalbot_i18n::format(
                "Audio stays on this PC. Transcripts and approved context may be sent to your remote Think model ({backend}). Other network access is for model downloads, updates, and optional Agent Mode setup.",
                &[("backend", backend.to_string())],
            ),
            (Some(host), true) => lokalbot_i18n::format(
                "Audio and your vocabulary go to your transcription server ({host}). Transcripts and captured context stay on this PC. Other network access is for model downloads, updates, and optional Agent Mode setup.",
                &[("host", host.clone())],
            ),
            (Some(host), false) => lokalbot_i18n::format(
                "Audio and your vocabulary go to your transcription server ({host}). Transcripts and approved context may be sent to your remote Think model ({backend}). Other network access is for model downloads, updates, and optional Agent Mode setup.",
                &[("host", host.clone()), ("backend", backend.to_string())],
            ),
        };
        let autocomplete_leaves =
            lokalbot_ai::autocomplete::server::leaves_this_computer(&settings);
        let where_text = match autocomplete_leaves
            .then(|| lokalbot_ai::autocomplete::server::configured_host(&settings))
            .flatten()
        {
            Some(host) => format!(
                "{where_text} {}",
                lokalbot_i18n::format(
                    "Autocomplete also sends what you type, with the context you turn on under Writing, to {0}.",
                    &[("0", host)],
                )
            ),
            None => where_text,
        };
        let local = settings.think_is_local() && audio_host.is_none() && !autocomplete_leaves;
        let root_text: SharedString = root.display().to_string().into();
        let where_row = h_flex()
            .gap(px(10.))
            .items_start()
            .child(ui::icon(
                if local {
                    Ico::ShieldCheck
                } else {
                    Ico::Network
                },
                px(16.),
                if local {
                    lb.accent_text
                } else {
                    lb.attention_text
                },
            ))
            .child(settings_row::help(where_text, cx).flex_1().min_w_0());
        let open_root = root.clone();
        let data_section = Section::new(lokalbot_i18n::tr("Where your data lives"))
            .row(
                "settings.whereData",
                settings_row::content_row("settings.whereData", where_row, false, cx),
            )
            .row(
                "settings.libraryLocation",
                settings_row::row(
                    "settings.libraryLocation",
                    lokalbot_i18n::tr("Library location"),
                    Some(lokalbot_i18n::tr("Meetings, day memory, and the search index.").into()),
                    v_flex().items_end().max_w(px(320.)).child(
                        settings_row::link_button(
                            "settings-library-path",
                            root_text,
                            move |_, cx| cx.open_with_system(&open_root),
                            cx,
                        )
                        .truncate(),
                    ),
                    self.is_focused("settings.libraryLocation"),
                    cx,
                ),
            );

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

        self.reload_personal(cx);
        let page = cx.entity();
        let meetings_page = page.clone();
        let screen_page = page.clone();
        let files_page = cx.entity();
        let files_on = self.files_access.unwrap_or_else(|| {
            lokalbot_core::files::access::is_enabled(self.data.read(cx).library.paths())
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

        agents = self.settings_control_rows(agents, cx);

        let exclusions = Section::new(lokalbot_i18n::tr("Capture exclusions"))
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
            );

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

        let permissions = self.permissions_section(cx);
        vec![
            data_section,
            retention,
            agents,
            permissions,
            exclusions,
            links,
        ]
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

    /// What LokalBot needs from this computer (`PermissionRow.swift`).
    fn permissions_section(&mut self, cx: &mut Context<Self>) -> Section {
        let lb = cx.lb().clone();
        let needs = crate::control::permissions::needs(self.data.read(cx), cx);
        let focused = self.is_focused("settings.permissions");
        let mut section = Section::new(lokalbot_i18n::tr("Permissions"));
        for (index, need) in needs.into_iter().enumerate() {
            let granted = need.granted;
            let name = need.name;
            let data = self.data.clone();
            let can_open = cfg!(target_os = "windows") && name == "microphone";
            let row = h_flex()
                .gap(px(10.))
                .items_start()
                .child(ui::icon(
                    if granted {
                        Ico::CircleCheck
                    } else {
                        Ico::TriangleAlert
                    },
                    px(16.),
                    if granted {
                        lb.accent_text
                    } else {
                        lb.attention_text
                    },
                ))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(need.title),
                        )
                        .child(settings_row::help(need.detail, cx)),
                )
                .when(can_open, |this| {
                    this.child(
                        Button::new(("settings-permission-open", index))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Open System Settings…"))
                            .on_click(move |_, _, cx| {
                                crate::control::permissions::request(name, &data, cx)
                            }),
                    )
                });
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
        section
    }
}
