//! Settings → Day Memory → Overnight review (`SettingsView.dreamingSection`):
//! the switch and hour, Review now, the projects and goals it keeps, Clear work
//! memory, and what the review uses.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, IntoElement as _, ParentElement as _,
    SharedString, Styled as _, div, px,
};
use lokalbot_core::dream::{DreamMemory, DreamStore, MemoryEntry, day_key};

use super::{Section, SettingsPage, hour_label};
use crate::i18n::h_flex;
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

/// What the page read about saved reviews, off the main thread.
#[derive(Default)]
pub(super) struct OvernightState {
    loaded_revision: Option<u64>,
    memory: Option<DreamMemory>,
    has_report: bool,
    projects_open: bool,
    confirming_clear: bool,
}

fn last_reviewed(at: chrono::DateTime<chrono::Utc>) -> String {
    let local = at.with_timezone(&chrono::Local);
    lokalbot_i18n::format(
        "Last reviewed {0}",
        &[(
            "0",
            local
                .format_localized(
                    lokalbot_i18n::date_pattern("%b %-d, %H:%M"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string(),
        )],
    )
}

impl SettingsPage {
    fn reload_overnight(&mut self, cx: &mut Context<Self>) {
        let revision = self.data.read(cx).revision;
        if self.overnight.loaded_revision == Some(revision) {
            return;
        }
        self.overnight.loaded_revision = Some(revision);
        let root = self.data.read(cx).library.paths().root().to_path_buf();
        cx.spawn(async move |this, cx| {
            let (memory, has_report) = cx
                .background_spawn(async move {
                    let store = DreamStore::new(root);
                    (
                        store.load_memory().ok().flatten(),
                        store.latest_report().is_some(),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.overnight.memory = memory;
                this.overnight.has_report = has_report;
                cx.notify();
            });
        })
        .detach();
    }

    fn pin_row(
        &self,
        index: usize,
        title: &str,
        detail: &str,
        pinned: bool,
        entry: MemoryEntry,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let dreaming = self.data.read(cx).dream.is_dreaming;
        h_flex()
            .gap(px(10.))
            .items_center()
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .child(div().text_size(ty::BODY).text_color(lb.text).child(
                        crate::ui::text::paragraph(SharedString::from(title.to_string())),
                    ))
                    .child(settings_row::help(detail.to_string(), cx)),
            )
            .child(
                Switch::new(("settings-memory-pin", index))
                    .checked(pinned)
                    .disabled(dreaming)
                    .on_click(move |checked, _, cx| {
                        crate::pages::today::brief::set_pinned(&data, *checked, entry.clone(), cx);
                    }),
            )
            .into_any_element()
    }

    /// One row per kept project and goal, with its pin.
    fn memory_rows(&self, memory: &DreamMemory, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let heading = |text: &'static str| {
            div()
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(text)
        };
        let mut column = v_flex().gap(px(8.)).child(settings_row::help(
            lokalbot_i18n::tr("Pin items to keep them during automatic memory cleanup."),
            cx,
        ));
        let mut index = 0;
        if !memory.active_projects.is_empty() {
            column = column.child(heading(lokalbot_i18n::tr("Active projects")));
            for project in &memory.active_projects {
                column = column.child(self.pin_row(
                    index,
                    &project.name,
                    &project.status,
                    project.pinned,
                    MemoryEntry::Project(project.name.clone()),
                    cx,
                ));
                index += 1;
            }
        }
        if !memory.work_goals.is_empty() {
            column = column.child(heading(lokalbot_i18n::tr("Current goals")));
            for goal in &memory.work_goals {
                column = column.child(self.pin_row(
                    index,
                    &goal.text,
                    &goal.horizon,
                    goal.pinned,
                    MemoryEntry::Goal(goal.text.clone()),
                    cx,
                ));
                index += 1;
            }
        }
        column.into_any_element()
    }

    pub(super) fn overnight_review_section(&mut self, cx: &mut Context<Self>) -> Section {
        self.reload_overnight(cx);
        let settings = self.data.read(cx).settings.clone();
        let status = self.data.read(cx).dream.clone();
        let lb = cx.lb().clone();
        let mut section = Section::new(lokalbot_i18n::tr("Overnight review")).row(
            "settings.dreamingEnabled",
            self.toggle(
                "settings.dreamingEnabled",
                lokalbot_i18n::tr("Review the day overnight"),
                Some(lokalbot_i18n::tr(
                    "After the chosen time, once your computer is on power and LokalBot isn't recording or processing, LokalBot turns the previous day into a morning retrospective on Today. It uses your Think model; if that model is remote, the compiled evidence is sent to it.",
                )),
                settings.dreaming_enabled,
                |s, v| s.dreaming_enabled = v,
                cx,
            ),
        );
        if settings.dreaming_enabled {
            let hour = settings.dreaming_hour.min(23);
            let hour_data = self.data.clone();
            section = section.row(
                "settings.dreamingHour",
                settings_row::row(
                    "settings.dreamingHour",
                    lokalbot_i18n::format(
                        "Review after {0}",
                        &[("0", hour_label(hour).to_string())],
                    ),
                    None,
                    settings_row::stepper(
                        "settings-dreaming-hour",
                        "",
                        hour > 0,
                        hour < 23,
                        move |step, _, cx| {
                            let next = (hour as i32 + step).clamp(0, 23) as u32;
                            hour_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.dreaming_hour = next, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.dreamingHour"),
                    cx,
                ),
            );
            let data = self.data.clone();
            let detail: Option<SharedString> = if status.is_dreaming {
                Some(lokalbot_i18n::tr("Reviewing…").into())
            } else {
                status.last_dreamed_at.map(|at| last_reviewed(at).into())
            };
            section = section.row(
                "settings.dreamNow",
                settings_row::row(
                    "settings.dreamNow",
                    lokalbot_i18n::tr("Review now"),
                    detail,
                    Button::new("settings-review-now")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Review now"))
                        .disabled(status.is_dreaming)
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.request(AppEvent::ReviewNow, cx))
                        }),
                    self.is_focused("settings.dreamNow"),
                    cx,
                ),
            );
            if let Some(error) = status.last_error.clone() {
                section = section.row(
                    "settings.dreamError",
                    settings_row::content_row(
                        "settings.dreamError",
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(crate::ui::text::paragraph(error)),
                        false,
                        cx,
                    ),
                );
            }
        }
        if let Some(memory) = self
            .overnight
            .memory
            .clone()
            .filter(|m| !m.active_projects.is_empty() || !m.work_goals.is_empty())
        {
            let open = self.overnight.projects_open;
            let page = cx.entity();
            let toggle = settings_row::details(
                "settings-memory-projects",
                lokalbot_i18n::tr("Projects and goals"),
                "",
                false,
                move |_, cx| {
                    page.update(cx, |page, cx| {
                        page.overnight.projects_open = !page.overnight.projects_open;
                        cx.notify();
                    })
                },
                cx,
            );
            let rows = open.then(|| self.memory_rows(&memory, cx));
            section = section.row(
                "settings.dreamMemory",
                settings_row::content_row(
                    "settings.dreamMemory",
                    v_flex()
                        .gap(px(8.))
                        .child(toggle)
                        .when_some(rows, |this, rows| this.child(rows)),
                    self.is_focused("settings.dreamMemory"),
                    cx,
                ),
            );
        }
        if self.overnight.memory.is_some() || self.overnight.has_report {
            section = section.row("settings.clearWorkMemory", self.clear_row(cx));
        }
        section.row(
            "settings.dreamDetails",
            self.details(
                "settings.dreamDetails",
                lokalbot_i18n::tr("What the review uses"),
                lokalbot_i18n::tr(
                    "It compiles meetings, outcomes, the day digest, and time totals, and keeps an evolving memory of active projects and goals. Nights the computer slept through catch up at the next launch. Evidence and generated files stay in the local library. If no model is reachable, a plain evidence summary is written instead. Reviews and memory are kept after screen text expires; deleting or correcting a meeting or capture they used removes what depended on it, and Clear work memory removes all of it.",
                ),
                cx,
            ),
        )
    }

    fn clear_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let page = cx.entity();
        if !self.overnight.confirming_clear {
            return settings_row::row(
                "settings.clearWorkMemory",
                lokalbot_i18n::tr("Work memory"),
                None,
                Button::new("settings-clear-memory")
                    .danger()
                    .small()
                    .label(lokalbot_i18n::tr("Clear work memory…"))
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.overnight.confirming_clear = true;
                            cx.notify();
                        })
                    }),
                self.is_focused("settings.clearWorkMemory"),
                cx,
            )
            .into_any_element();
        }
        let confirm_page = page.clone();
        let cancel_page = page;
        settings_row::stacked_row(
            "settings.clearWorkMemory",
            lokalbot_i18n::tr("Clear work memory?"),
            Some(
                lokalbot_i18n::tr(
                    "Deletes every overnight review and the remembered projects, goals, and patterns, including pinned ones. Reviews start again from today.",
                )
                .into(),
            ),
            h_flex()
                .gap(px(8.))
                .child(
                    Button::new("settings-clear-memory-confirm")
                        .danger()
                        .small()
                        .label(lokalbot_i18n::tr("Clear Work Memory"))
                        .on_click(move |_, _, cx| {
                            confirm_page.update(cx, |page, cx| page.clear_work_memory(cx))
                        }),
                )
                .child(
                    Button::new("settings-clear-memory-cancel")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Cancel"))
                        .on_click(move |_, _, cx| {
                            cancel_page.update(cx, |page, cx| {
                                page.overnight.confirming_clear = false;
                                cx.notify();
                            })
                        }),
                ),
            false,
            cx,
        )
        .into_any_element()
    }

    /// Reviews start again from today, so the week before the clear isn't
    /// reviewed straight back into memory.
    fn clear_work_memory(&mut self, cx: &mut Context<Self>) {
        self.overnight.confirming_clear = false;
        self.overnight.memory = None;
        self.overnight.has_report = false;
        let today = day_key(chrono::Local::now().date_naive());
        self.data.update(cx, |data, cx| {
            data.update_settings(
                |s| {
                    if s.dreaming_enabled {
                        s.set_dreaming_first_eligible_day_key(Some(today));
                    }
                },
                cx,
            );
            data.request(AppEvent::ClearWorkMemory, cx);
        });
        cx.notify();
    }
}
