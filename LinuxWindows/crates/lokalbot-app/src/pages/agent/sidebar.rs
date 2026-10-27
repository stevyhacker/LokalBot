//! The task list (`AgentTaskSidebar.swift`): pinned and recent tasks with
//! their status, search, archive, and the Tasks menu.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use uuid::Uuid;

use lokalbot_agent::SessionState;

use super::{AgentPage, key as element_key};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const SIDEBAR_WIDTH: f32 = 272.;

/// One row as shown.
struct Row {
    id: Uuid,
    title: String,
    detail: Option<String>,
    icon: Ico,
    attention: bool,
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
        let rows = self.task_rows(cx);
        let selected = self.selected_id(cx);
        let any_running = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref())
            .is_some_and(|t| t.any_running());
        let query = self.task_query.trim().to_string();

        let page = cx.entity();
        let show_archived = self.show_archived;
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

        let header = v_flex()
            .gap(px(8.))
            .px(px(10.))
            .pt(px(14.))
            .pb(px(10.))
            .child(
                h_flex()
                    .gap(px(4.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .pl(px(4.))
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Tasks"))),
                    )
                    .child(
                        Button::new("agent-new-task")
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::SquarePen))
                            .tooltip(lokalbot_i18n::tr("New task (Ctrl+N)"))
                            .on_click(cx.listener(|this, _, window, cx| this.new_task(window, cx))),
                    )
                    .child(menu),
            )
            .child(
                Input::new(&self.task_search)
                    .cleanable(true)
                    .prefix(ui::icon(Ico::Search, px(14.), lb.text_secondary)),
            )
            .when(self.show_archived, |this| {
                this.child(
                    h_flex()
                        .px(px(4.))
                        .gap(px(6.))
                        .items_center()
                        .child(ui::icon(Ico::Archive, px(12.), lb.text_secondary))
                        .child(
                            div()
                                .flex_1()
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Archived"))),
                        )
                        .child(div().text_size(ty::CAPTION).child(ui::link(
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
                        ))),
                )
            });

        let mut list: Vec<AnyElement> = Vec::new();
        let (pinned, recent): (Vec<&Row>, Vec<&Row>) = rows.iter().partition(|r| r.pinned);
        if rows.is_empty() {
            let message = if query.is_empty() {
                lokalbot_i18n::tr("No tasks yet.").to_string()
            } else {
                lokalbot_i18n::format("No tasks match “{query}”.", &[("query", query.to_string())])
            };
            list.push(
                div()
                    .px(px(18.))
                    .py(px(6.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(message)
                    .into_any_element(),
            );
        }
        if !pinned.is_empty() {
            list.push(section_title(lokalbot_i18n::tr("Pinned"), cx));
            for row in pinned {
                list.push(self.render_task_row(row, selected == Some(row.id), cx));
            }
        }
        if !recent.is_empty() {
            list.push(section_title(
                if self.show_archived {
                    lokalbot_i18n::tr("Archived tasks")
                } else {
                    lokalbot_i18n::tr("Recent")
                },
                cx,
            ));
            for row in recent {
                list.push(self.render_task_row(row, selected == Some(row.id), cx));
            }
        }

        v_flex()
            .w(px(SIDEBAR_WIDTH))
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
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
    }

    fn task_rows(&self, cx: &App) -> Vec<Row> {
        let Some(tasks) = self.model(cx).and_then(|m| m.tasks.as_ref()) else {
            return Vec::new();
        };
        let query = self.task_query.trim().to_lowercase();
        tasks
            .ordered()
            .into_iter()
            .filter(|tab| tab.record.is_archived == self.show_archived)
            .filter(|tab| {
                query.is_empty() || {
                    let haystack = format!(
                        "{} {} {}",
                        tab.title(),
                        tab.session.workspace_display_name(),
                        tab.saved.as_ref().map(|s| s.preview.as_str()).unwrap_or("")
                    )
                    .to_lowercase();
                    haystack.contains(&query)
                }
            })
            .map(|tab| {
                let session = &tab.session;
                let approvals = !session.pending_approvals().is_empty();
                let failed = session.is_failed();
                let attention = approvals || failed;
                let running = session.state == SessionState::Running;
                let busy = matches!(
                    session.state,
                    SessionState::Running | SessionState::Starting
                );
                let detail = if attention || busy {
                    Some(session.task_status().to_string())
                } else if tab.record.is_archived {
                    Some(lokalbot_i18n::tr("Archived").into())
                } else {
                    Some(session.workspace_display_name())
                };
                let icon = if approvals {
                    Ico::Hand
                } else if running {
                    Ico::CircleEllipsis
                } else if failed {
                    Ico::CircleAlert
                } else if tab.record.is_archived {
                    Ico::Archive
                } else {
                    Ico::MessageSquareText
                };
                Row {
                    id: tab.id,
                    title: tab.title(),
                    detail,
                    icon,
                    attention,
                    pinned: tab.record.is_pinned,
                    archived: tab.record.is_archived,
                    busy,
                }
            })
            .collect()
    }

    fn render_task_row(&self, row: &Row, selected: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = row.id;
        let tint: Hsla = if row.attention {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        let page = cx.entity();
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
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(div().pt(px(2.)).child(ui::icon(row.icon, px(15.), tint)))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(
                                div()
                                    .line_clamp(2)
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(row.title.clone()),
                            )
                            .when_some(row.detail.clone(), |this, detail| {
                                this.child(
                                    div()
                                        .truncate()
                                        .text_size(ty::SECONDARY)
                                        .text_color(tint)
                                        .child(detail),
                                )
                            }),
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

fn section_title(title: &'static str, cx: &App) -> AnyElement {
    div()
        .px(px(18.))
        .pt(px(10.))
        .pb(px(4.))
        .text_size(ty::SECONDARY)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(cx.lb().supporting)
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
