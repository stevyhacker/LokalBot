//! The task list (`AgentTaskSidebar.swift`): search and New on top, tasks
//! grouped by day with their status and time, and Archived at the bottom.
//! Refresh, saved sessions, the runtime check and clearing history are in
//! the … menu beside Archived.

use crate::i18n::h_flex;
use chrono::{DateTime, Local};
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use uuid::Uuid;

use lokalbot_agent::SessionState;
use lokalbot_agent::presentation::{ListEntry, TaskListSection, TaskStatus, Tone};

use super::{AgentPage, key as element_key, words};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

pub(super) const SIDEBAR_WIDTH: f32 = 272.;

/// One row as shown.
struct Row {
    id: Uuid,
    title: String,
    line: String,
    workspace: String,
    tone: Tone,
    icon: Ico,
    time: Option<String>,
    pinned: bool,
    archived: bool,
    busy: bool,
}

impl AgentPage {
    pub(super) fn render_sidebar(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let now = Local::now();
        let (rows, sections) = self.task_rows(now, cx);
        let selected = self.selected_id(cx);
        let query = self.task_query.trim().to_string();

        // A search field and New; the list below needs no heading.
        let header = h_flex()
            .gap(px(8.))
            .items_center()
            .px(px(12.))
            .pt(px(10.))
            .pb(px(10.))
            .child(
                div().flex_1().min_w_0().child(
                    Input::new(&self.task_search)
                        .small()
                        .cleanable(true)
                        .prefix(ui::icon(Ico::Search, px(14.), lb.text_secondary)),
                ),
            )
            .child(
                Button::new("agent-new-task")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::SquarePen))
                    .tooltip(lokalbot_i18n::tr("New task (Ctrl+N)"))
                    .on_click(cx.listener(|this, _, window, cx| this.new_task(window, cx))),
            );

        let mut list: Vec<AnyElement> = Vec::new();
        if self.show_archived {
            list.push(
                h_flex()
                    .px(px(14.))
                    .pb(px(6.))
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::Archive, px(13.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr("Archived")),
                    )
                    .child(div().text_size(ty::SECONDARY).child(ui::link(
                        "agent-show-active",
                        lokalbot_i18n::tr("Show Active"),
                        {
                            let page = cx.entity();
                            move |_, cx| {
                                page.update(cx, |page, cx| {
                                    page.show_archived = false;
                                    cx.notify();
                                })
                            }
                        },
                        cx,
                    )))
                    .into_any_element(),
            );
        }
        if rows.is_empty() && !query.is_empty() {
            list.push(
                div()
                    .px(px(18.))
                    .py(px(6.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::format(
                        "No tasks match “{query}”.",
                        &[("query", query.clone())],
                    ))
                    .into_any_element(),
            );
        }
        for section in &sections {
            list.push(section_title(words::section_title(section.kind), &lb));
            for id in &section.ids {
                if let Some(row) = rows.iter().find(|r| r.id == *id) {
                    list.push(self.render_task_row(row, selected == Some(row.id), cx));
                }
            }
        }

        v_flex()
            .size_full()
            .bg(lb.window)
            .child(header)
            .child(
                div()
                    .id("agent-tasks")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .pb(px(12.))
                    .children(list),
            )
            .child(ui::divider(cx))
            .child(self.render_sidebar_footer(cx))
    }

    /// Archived and its count, and the task options.
    fn render_sidebar_footer(&mut self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let tasks = self.model(cx).and_then(|m| m.tasks.as_ref());
        let any_running = tasks.is_some_and(|t| t.any_running());
        let archived_count = tasks.map_or(0, |t| {
            t.tabs.iter().filter(|tab| tab.record.is_archived).count()
        });
        let show_archived = self.show_archived;
        let page = cx.entity();
        let menu = Button::new("agent-task-options")
            .ghost()
            .small()
            .icon(Icon::new(Ico::Ellipsis))
            .tooltip(lokalbot_i18n::tr("Task options"))
            .dropdown_menu(move |menu, _, _| {
                let refresh = page.clone();
                let archived = page.clone();
                let saved = page.clone();
                let verify = page.clone();
                let clear = page.clone();
                menu.min_w(px(230.))
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Refresh tasks")).on_click(
                            move |_, _, cx| {
                                refresh.update(cx, |page, cx| {
                                    if let Some(model) = &page.model {
                                        model.update(cx, |model, cx| model.refresh_history(cx));
                                    }
                                })
                            },
                        ),
                    )
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Show archived tasks"))
                            .checked(show_archived)
                            .on_click(move |_, _, cx| {
                                archived.update(cx, |page, cx| {
                                    page.show_archived = !page.show_archived;
                                    cx.notify();
                                })
                            }),
                    )
                    .separator()
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Saved sessions…")).on_click(
                            move |_, window, cx| {
                                saved.update(cx, |page, cx| page.open_saved_sessions(window, cx))
                            },
                        ),
                    )
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Verify Agent runtime…"))
                            .disabled(any_running)
                            .on_click(move |_, _, cx| {
                                verify.update(cx, |page, cx| {
                                    if let Some(model) = &page.model {
                                        model.update(cx, |model, cx| model.verify(cx));
                                    }
                                })
                            }),
                    )
                    .separator()
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Clear saved Agent history…"))
                            .on_click(move |_, window, cx| {
                                confirm_clear(clear.clone(), window, cx)
                            }),
                    )
            });
        let label = if show_archived {
            lokalbot_i18n::tr("Show Active")
        } else {
            lokalbot_i18n::tr("Archived")
        };
        h_flex()
            .flex_none()
            .gap(px(4.))
            .items_center()
            .px(px(6.))
            .py(px(4.))
            .child(
                h_flex()
                    .id("agent-archived")
                    .flex_1()
                    .min_w_0()
                    .h(px(28.))
                    .px(px(8.))
                    .gap(px(8.))
                    .items_center()
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .hover(|style| style.bg(lb.hover))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(Ico::Archive, px(14.), lb.text_secondary))
                    .child(div().flex_1().min_w_0().truncate().child(label))
                    .when(!show_archived && archived_count > 0, |this| {
                        this.child(lokalbot_i18n::number(archived_count))
                    })
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.show_archived = !this.show_archived;
                        cx.notify();
                    })),
            )
            .child(menu)
    }

    /// The rows in view and how they group.
    fn task_rows(&self, now: DateTime<Local>, cx: &App) -> (Vec<Row>, Vec<TaskListSection>) {
        let Some(tasks) = self.model(cx).and_then(|m| m.tasks.as_ref()) else {
            return (Vec::new(), Vec::new());
        };
        let query = self.task_query.trim().to_lowercase();
        let visible: Vec<_> = tasks
            .ordered()
            .into_iter()
            .filter(|tab| tab.record.is_archived == self.show_archived)
            .filter(|tab| {
                query.is_empty() || {
                    let haystack = format!(
                        "{} {} {}",
                        super::task_title(tab),
                        tab.session.workspace_display_name(),
                        tab.saved.as_ref().map(|s| s.preview.as_str()).unwrap_or("")
                    )
                    .to_lowercase();
                    haystack.contains(&query)
                }
            })
            .collect();
        let entries: Vec<ListEntry> = visible
            .iter()
            .map(|tab| ListEntry {
                id: tab.id,
                modified_at: tab.record.modified_at,
                is_pinned: tab.record.is_pinned,
            })
            .collect();
        let sections = TaskListSection::make(&entries, now);
        let rows = visible
            .into_iter()
            .map(|tab| {
                let status = super::task_status(tab);
                let tone = status.tone();
                let quiet_archive = tab.record.is_archived && tone == Tone::Quiet;
                // The status, or for a task that is doing nothing, where it works.
                let line = if quiet_archive {
                    lokalbot_i18n::tr("Archived").to_string()
                } else {
                    words::status_line(status)
                        .unwrap_or_else(|| tab.session.workspace_display_name())
                };
                Row {
                    id: tab.id,
                    title: super::task_title(tab),
                    line,
                    workspace: tab.session.workspace_display_name(),
                    tone,
                    icon: if quiet_archive {
                        Ico::Archive
                    } else {
                        status_icon(status)
                    },
                    time: words::row_time(tab.record.modified_at, tab.record.is_pinned, now),
                    pinned: tab.record.is_pinned,
                    archived: tab.record.is_archived,
                    busy: matches!(
                        tab.session.state,
                        SessionState::Running | SessionState::Starting
                    ),
                }
            })
            .collect();
        (rows, sections)
    }

    fn render_task_row(&self, row: &Row, selected: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = row.id;
        let tint: Hsla = match row.tone {
            Tone::Attention => lb.attention_text,
            Tone::Working => lb.accent_text,
            Tone::Quiet | Tone::Done => lb.text_secondary,
        };
        let symbol: AnyElement = if row.tone == Tone::Working {
            Spinner::new()
                .xsmall()
                .color(lb.accent_text)
                .into_any_element()
        } else {
            let color = if row.tone == Tone::Attention {
                tint
            } else {
                lb.text_secondary
            };
            ui::icon(row.icon, px(15.), color).into_any_element()
        };
        let page = cx.entity();
        let tooltip =
            SharedString::from(format!("{}\n{} · {}", row.title, row.workspace, row.line));
        let (title, pinned, archived, busy) =
            (row.title.clone(), row.pinned, row.archived, row.busy);
        div()
            .id(("agent-task", element_key(id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(7.))
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|style| style.bg(lb.hover)))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(
                        div()
                            .flex_none()
                            .w(px(16.))
                            .h(px(20.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(symbol),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                h_flex()
                                    .gap(px(6.))
                                    .items_center()
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(ty::BODY)
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(lb.text)
                                            .child(row.title.clone()),
                                    )
                                    .when_some(row.time.clone(), |this, time| {
                                        this.child(
                                            div()
                                                .flex_none()
                                                .text_size(ty::CAPTION)
                                                .text_color(lb.text_secondary)
                                                .child(time),
                                        )
                                    }),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(tint)
                                    .child(row.line.clone()),
                            ),
                    ),
            )
            .on_click(cx.listener(move |this, _, window, cx| this.select_task(id, window, cx)))
            .context_menu(move |menu, _, _| {
                let rename = page.clone();
                let pin = page.clone();
                let archive = page.clone();
                let title = title.clone();
                menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Rename…")).on_click(
                    move |_, window, cx| {
                        rename.update(cx, |page, cx| {
                            page.open_rename(id, title.clone(), window, cx)
                        })
                    },
                ))
                .item(
                    PopupMenuItem::new(if pinned {
                        lokalbot_i18n::tr("Unpin")
                    } else {
                        lokalbot_i18n::tr("Pin")
                    })
                    .on_click(move |_, _, cx| {
                        pin.update(cx, |page, cx| page.with_tasks(cx, |t| t.toggle_pin(id)))
                    }),
                )
                .item(
                    PopupMenuItem::new(if archived {
                        lokalbot_i18n::tr("Restore task")
                    } else {
                        lokalbot_i18n::tr("Archive task")
                    })
                    .disabled(busy)
                    .on_click(move |_, _, cx| {
                        archive.update(cx, |page, cx| {
                            page.with_tasks(cx, |t| t.set_archived(id, !archived))
                        })
                    }),
                )
            })
            .into_any_element()
    }
}

/// `AgentTaskStatus.symbol`.
pub(super) fn status_icon(status: TaskStatus) -> Ico {
    match status {
        TaskStatus::NotStarted | TaskStatus::Saved | TaskStatus::Stopped => Ico::MessageSquareText,
        TaskStatus::Starting | TaskStatus::Working => Ico::CircleEllipsis,
        TaskStatus::NeedsApproval(_) => Ico::Hand,
        TaskStatus::NeedsAttention => Ico::CircleAlert,
        TaskStatus::Done { .. } => Ico::CircleCheck,
    }
}

fn section_title(title: String, lb: &crate::theme::Palette) -> AnyElement {
    div()
        .px(px(18.))
        .pt(px(10.))
        .pb(px(4.))
        .text_size(ty::SECONDARY)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(lb.supporting)
        .child(title)
        .into_any_element()
}

fn confirm_clear(page: gpui_kit::Entity<AgentPage>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let page = page.clone();
        alert
            .title(lokalbot_i18n::tr("Clear all saved Agent history?"))
            .description(lokalbot_i18n::tr("This stops every Agent task and permanently removes its local conversation, draft, and task metadata. Your meeting library is not affected."))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Clear History"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                page.update(cx, |page, cx| {
                    page.with_tasks(cx, |tasks| {
                        if let Err(err) = tasks.clear_saved_history() {
                            tasks.error = Some(format!("{err:#}"));
                        }
                    });
                    page.preview = None;
                    cx.notify();
                });
                true
            })
    });
}
