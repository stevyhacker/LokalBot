//! Privacy & Data: where data lives, screen retention, external agent access
//! and capture exclusions.

use crate::i18n::h_flex;
use gpui_kit::component::slider::Slider;
use gpui_kit::component::v_flex;
use gpui_kit::{AppContext as _, Context, ParentElement as _, SharedString, Styled as _, px};
use lokalbot_core::access::ScreenScope;
use lokalbot_core::settings::SummarizerBackend;

use super::{Section, SettingsPage};
use crate::theme::LbThemeExt as _;
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

impl SettingsPage {
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

        let where_text = if settings.think_is_local() {
            lokalbot_i18n::tr("Audio, transcripts, and captured context stay on this PC. Network access is limited to model downloads and optional Agent Mode setup.").to_string()
        } else {
            let backend = match settings.summarizer_backend {
                SummarizerBackend::Ollama => lokalbot_i18n::tr("Ollama"),
                SummarizerBackend::ChatGptPlan => lokalbot_i18n::tr("ChatGPT plan"),
                SummarizerBackend::ClaudePlan => lokalbot_i18n::tr("Claude plan"),
                _ => lokalbot_i18n::tr("OpenAI-compatible server"),
            };
            lokalbot_i18n::format(
                "Audio stays on this PC. Transcripts and approved context may be sent to your remote Think model ({backend}). Other network access is for model downloads and optional Agent Mode setup.",
                &[("backend", backend.to_string())],
            )
        };
        let local = settings.think_is_local();
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

        let days = settings.retention_days.clamp(1, 90);
        let retention = Section::new(lokalbot_i18n::tr("Screen memory retention"))
            .row(
                "settings.retentionDays",
                settings_row::stacked_row(
                    "settings.retentionDays",
                    lokalbot_i18n::format("Keep screen context {0}", &[("0", days_label(days).to_string())]),
                    Some(lokalbot_i18n::tr("Old images, screen text, screen titles, URLs, document names, and activity titles expire. App names and durations remain, and meetings are never removed. Saved moments stay until unsaved or deleted.").into()),
                    Slider::new(&self.retention_slider).w_full(),
                    self.is_focused("settings.retentionDays"),
                    cx,
                ),
            )
            .row(
                "settings.keepOCRTextForever",
                self.toggle(
                    "settings.keepOCRTextForever",
                    lokalbot_i18n::tr("Keep screen text forever"),
                    Some(lokalbot_i18n::tr("Images and activity titles still expire. Screen text, titles, URLs, and document names stay searchable.")),
                    settings.keep_ocr_text_forever,
                    |s, v| s.keep_ocr_text_forever = v,
                    cx,
                ),
            )
            .row(
                "settings.retentionNote",
                settings_row::content_row(
                    "settings.retentionNote",
                    settings_row::help(lokalbot_i18n::tr("Retention doesn't change day digests, saved Ask conversations, or files you export. Delete conversations in Ask, and remove exported files from their folders."), cx),
                    false,
                    cx,
                ),
            );

        let page = cx.entity();
        let meetings_page = page.clone();
        let screen_page = page.clone();
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

        vec![data_section, retention, agents, exclusions, links]
    }
}
