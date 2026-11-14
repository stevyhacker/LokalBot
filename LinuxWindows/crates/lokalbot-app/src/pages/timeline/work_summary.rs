//! The day's work and decisions as panels on Timeline's page
//! (`DayDigestView` in its timeline mode). A digest that gives its tasks a
//! status groups them: Blocked and In progress in full where a task has a
//! next step, the rest of the open work as one-line rows, and finished work
//! folded into a single Done line across the panel. An older digest lists
//! its entries.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Div, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lokalbot_core::digest::{BRIEF_ROW_LIMIT, folds_brief_rows, title_and_tag};
use lokalbot_core::{DayDigest, DigestTask, TaskStatus};

use super::day_list::mac;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::section_panel::SectionPanel;
use crate::ui::{self, Ico};

/// Toggles a task's details by index, or one of the keys below.
pub(super) type TaskToggle = Rc<dyn Fn(usize, &mut Window, &mut App)>;
/// Opens the session (`WorkSession::id`) a task's time range covers.
pub(super) type OpenSession = Rc<dyn Fn(String, &mut Window, &mut App)>;

/// Toggle keys past the task indices: follow-up rows, a group's "Show N
/// more" (plus the group's status), and the Done line.
const FOLLOW_UP_KEY: usize = 10_000;
const SHOW_ALL_KEY: usize = 20_000;
const DONE_KEY: usize = 30_000;
/// The status column of a task row plus its gap; details align to it.
const TASK_TEXT_INSET: f32 = 26.;

/// What the panels need besides the digest.
pub(super) struct WorkSummary<'a> {
    pub digest: &'a DayDigest,
    pub expanded: &'a HashSet<usize>,
    pub on_toggle: TaskToggle,
    /// A task's "09:00–10:30" and the session it covers most.
    pub sessions: &'a HashMap<String, String>,
    pub open_session: OpenSession,
}

/// Anything the page shows under the highlights and the day's actions.
pub(super) fn has_body_below_highlights(digest: &DayDigest) -> bool {
    !digest.blockers.is_empty()
        || !digest.decisions.is_empty()
        || !digest.tasks.is_empty()
        || !digest.follow_ups.is_empty()
        || !digest.follow_up_tasks.is_empty()
}

/// The day's work as one panel; `None` when the digest has none.
pub(super) fn work_summary_panel(summary: &WorkSummary, cx: &App) -> Option<AnyElement> {
    let digest = summary.digest;
    let has_follow_ups = !digest.follow_up_tasks.is_empty() || !digest.follow_ups.is_empty();
    let has_blockers = !digest.blockers.is_empty();
    if digest.tasks.is_empty() && !has_blockers && !has_follow_ups {
        return None;
    }
    let mut panel = SectionPanel::new("timeline-work-summary", lokalbot_i18n::tr("Work Summary"))
        .icon(Ico::List);
    if !digest.tasks.is_empty() {
        panel = panel.count(digest.tasks.len());
    }
    if has_blockers {
        panel = panel.child(
            div()
                .px(metric::PANEL_INSET)
                .py(px(12.))
                .child(blockers_callout(digest, cx)),
        );
    }
    let groups = digest.task_groups();
    let task_first = digest.is_task_first();
    for (index, group) in groups.iter().enumerate() {
        let rows = digest.timeline_rows(group);
        let follows_content = has_blockers || index > 0;
        let closes_panel = index + 1 == groups.len() && !has_follow_ups;
        if group.status == TaskStatus::Completed && task_first {
            panel = panel.child(done_section(summary, &rows.brief, closes_panel, cx));
            continue;
        }
        if follows_content {
            panel = panel.child(ui::divider(cx));
        }
        let show_all_key = SHOW_ALL_KEY
            + lokalbot_core::digest::TASK_GROUP_ORDER
                .iter()
                .position(|status| *status == group.status)
                .unwrap_or(0);
        panel = panel.child(
            v_flex()
                .px(metric::PANEL_INSET)
                .py(px(4.))
                .when(task_first, |this| {
                    this.child(group_label(group.status, group.tasks.len(), cx))
                })
                .child(full_rows(summary, &rows.full, cx))
                .when(!rows.brief.is_empty(), |this| {
                    this.child(brief_list(
                        summary,
                        &rows.brief,
                        !rows.full.is_empty(),
                        show_all_key,
                        cx,
                    ))
                }),
        );
    }
    if has_follow_ups {
        panel = panel
            .band(
                lokalbot_i18n::tr("Follow-ups"),
                has_blockers || !groups.is_empty(),
            )
            .child(
                div()
                    .px(metric::PANEL_INSET)
                    .py(px(4.))
                    .child(follow_up_rows(summary, cx)),
            );
    }
    Some(panel.into_any_element())
}

/// The day's decisions, one per row under a check.
pub(super) fn decisions_panel(decisions: &[String], cx: &App) -> Option<AnyElement> {
    if decisions.is_empty() {
        return None;
    }
    let lb = cx.lb();
    Some(
        SectionPanel::new("timeline-decisions", lokalbot_i18n::tr("Decisions"))
            .icon(Ico::Flag)
            .count(decisions.len())
            .rows(decisions.iter().map(|decision| {
                h_flex()
                    .py(px(10.))
                    .gap(px(10.))
                    .items_start()
                    .child(
                        div()
                            .w(px(TASK_TEXT_INSET - 8.))
                            .flex_none()
                            .pt(px(2.))
                            .flex()
                            .justify_center()
                            .child(ui::icon(Ico::Check, px(14.), lb.accent_text)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .line_height(px(21.))
                            .text_color(lb.text)
                            .child(ui::text::paragraph(decision.clone())),
                    )
            }))
            .into_any_element(),
    )
}

/// "Blocked 2": a small bold label over a group of tasks.
fn group_label(status: TaskStatus, count: usize, cx: &App) -> Div {
    let lb = cx.lb();
    let title = match status {
        TaskStatus::Blocked => "Blocked",
        TaskStatus::InProgress => "In progress",
        TaskStatus::Unknown => "Other work",
        TaskStatus::Completed => "Done",
    };
    h_flex()
        .pt(px(7.))
        .gap(px(6.))
        .items_baseline()
        .text_size(ty::PILL)
        .text_color(lb.supporting)
        .child(
            div()
                .font_weight(FontWeight::BOLD)
                .child(lokalbot_i18n::tr(title)),
        )
        .child(lokalbot_i18n::number(count))
}

/// Blockers lead the work: they are what stops the day's open tasks.
fn blockers_callout(digest: &DayDigest, cx: &App) -> AnyElement {
    let lb = cx.lb();
    let title = if digest.blockers.len() == 1 {
        lokalbot_i18n::tr("Blocker")
    } else {
        lokalbot_i18n::tr("Blockers")
    };
    ui::status_surface(lb.attention, cx)
        .px(px(12.))
        .py(px(10.))
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            h_flex()
                .gap(px(6.))
                .items_center()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.attention_text)
                .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                .child(title),
        )
        .child(bullet_list(&digest.blockers, cx))
        .into_any_element()
}

fn bullet_list(items: &[String], cx: &App) -> AnyElement {
    let lb = cx.lb();
    v_flex()
        .gap(px(4.))
        .children(items.iter().map(|item| {
            h_flex()
                .gap(px(8.))
                .items_start()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(div().flex_none().text_color(lb.text_tertiary).child("•"))
                .child(div().flex_1().min_w_0().child(item.clone()))
        }))
        .into_any_element()
}

/// Full task rows with tags, by index into `digest.tasks`.
fn full_rows(summary: &WorkSummary, indices: &[usize], cx: &App) -> AnyElement {
    let lb = cx.lb();
    let count = indices.len();
    v_flex()
        .children(indices.iter().enumerate().map(|(position, &ix)| {
            v_flex()
                .child(
                    div()
                        .py(px(7.))
                        .child(task_row(summary, &summary.digest.tasks[ix], ix, cx)),
                )
                .when(position + 1 < count, |this| {
                    this.child(div().ml(px(TASK_TEXT_INSET)).h(px(1.)).bg(lb.separator))
                })
        }))
        .into_any_element()
}

/// Follow-ups as task rows, or as bullets when they have no rows.
fn follow_up_rows(summary: &WorkSummary, cx: &App) -> AnyElement {
    let digest = summary.digest;
    if digest.follow_up_tasks.is_empty() {
        return div()
            .py(px(6.))
            .child(bullet_list(&digest.follow_ups, cx))
            .into_any_element();
    }
    let lb = cx.lb();
    let count = digest.follow_up_tasks.len();
    v_flex()
        .children(
            digest
                .follow_up_tasks
                .iter()
                .enumerate()
                .map(|(position, task)| {
                    v_flex()
                        .child(div().py(px(7.)).child(task_row(
                            summary,
                            task,
                            FOLLOW_UP_KEY + position,
                            cx,
                        )))
                        .when(position + 1 < count, |this| {
                            this.child(div().ml(px(TASK_TEXT_INSET)).h(px(1.)).bg(lb.separator))
                        })
                }),
        )
        .into_any_element()
}

/// One-line rows for open tasks without a next step. A long list shows its
/// first rows until asked for the rest.
fn brief_list(
    summary: &WorkSummary,
    indices: &[usize],
    follows_full_rows: bool,
    show_all_key: usize,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let folds = folds_brief_rows(indices.len());
    let shows_all = summary.expanded.contains(&show_all_key);
    let visible = if folds && !shows_all {
        &indices[..BRIEF_ROW_LIMIT]
    } else {
        indices
    };
    let toggle = summary.on_toggle.clone();
    v_flex()
        .when(follows_full_rows, |this| {
            // Below full rows, a heading says what these rows are.
            this.child(
                div()
                    .pt(px(12.))
                    .pb(px(2.))
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(ui::text::paragraph(mac(
                        "%lld more without a next step",
                        &[&lokalbot_i18n::number(indices.len())],
                    ))),
            )
        })
        .children(
            visible
                .iter()
                .map(|&ix| brief_row(summary, &summary.digest.tasks[ix], ix, false, cx)),
        )
        .when(folds, |this| {
            let label = if shows_all {
                lokalbot_i18n::tr("Show fewer").to_string()
            } else {
                mac(
                    "Show %lld more",
                    &[&lokalbot_i18n::number(indices.len() - BRIEF_ROW_LIMIT)],
                )
            };
            this.child(
                div()
                    .pl(px(TASK_TEXT_INSET))
                    .pt(px(4.))
                    .text_size(ty::SECONDARY)
                    .child(ui::link(
                        ("digest-show-all", show_all_key),
                        label,
                        move |window, cx| toggle(show_all_key, window, cx),
                        cx,
                    )),
            )
        })
        .into_any_element()
}

/// Finished tasks fold into one line across the panel that names them;
/// opening it lists each.
fn done_section(
    summary: &WorkSummary,
    indices: &[usize],
    closes_panel: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let open = summary.expanded.contains(&DONE_KEY);
    let preview = indices
        .iter()
        .map(|&ix| title_and_tag(&summary.digest.tasks[ix].title).0)
        .collect::<Vec<_>>()
        .join(", ");
    let toggle = summary.on_toggle.clone();
    let chevron = if open {
        Ico::ChevronDown
    } else if lokalbot_i18n::current().rtl {
        Ico::ChevronLeft
    } else {
        Ico::ChevronRight
    };
    v_flex()
        .child(ui::divider(cx))
        .child(
            h_flex()
                .id("digest-done")
                .w_full()
                .min_h(px(40.))
                .gap(px(10.))
                .items_center()
                .pl(metric::PANEL_INSET)
                .pr(metric::PANEL_INSET - px(2.))
                // The footer strip's fill: the supporting colour stays above
                // 4.5:1 on it.
                .bg(lb.group_fill)
                .when(closes_panel && !open, |this| {
                    this.rounded_b(metric::GROUP_RADIUS - px(1.))
                })
                .cursor_pointer()
                .child(
                    div()
                        .w(px(TASK_TEXT_INSET - 8.))
                        .flex_none()
                        .flex()
                        .justify_center()
                        .child(ui::icon(Ico::CircleCheck, px(16.), lb.success_text)),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Done")),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(lokalbot_i18n::number(indices.len())),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .when(!open, |this| this.child(preview)),
                )
                .child(ui::icon(chevron, px(13.), lb.supporting))
                .on_click(move |_, window, cx| toggle(DONE_KEY, window, cx)),
        )
        .when(open, |this| {
            let count = indices.len();
            this.child(ui::divider(cx))
                .child(v_flex().px(metric::PANEL_INSET).py(px(2.)).children(
                    indices.iter().enumerate().map(|(position, &ix)| {
                        v_flex()
                            .py(px(3.))
                            .child(brief_row(summary, &summary.digest.tasks[ix], ix, true, cx))
                            .when(position + 1 < count, |this| this.child(ui::divider(cx)))
                    }),
                ))
        })
        .into_any_element()
}

/// A project or pull request split off a task title.
fn task_tag(tag: &str, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .flex_none()
        .px(px(6.))
        .py(px(1.))
        .rounded(px(5.))
        .bg(lb.text.opacity(0.06))
        .text_size(ty::CAPTION)
        .text_color(lb.supporting)
        .whitespace_nowrap()
        .child(tag.to_string())
}

/// One line for a task without a next step; what was done opens in place.
fn brief_row(
    summary: &WorkSummary,
    task: &DigestTask,
    ix: usize,
    is_done: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let expanded = summary.expanded.contains(&ix);
    let has_details = task.has_heading && !task.summary.trim().is_empty();
    let (title, tag) = title_and_tag(&task.title);
    let marker: AnyElement = if is_done {
        ui::icon(Ico::Check, px(14.), lb.success_text).into_any_element()
    } else {
        div()
            .text_size(ty::BODY)
            .text_color(lb.text_tertiary)
            .child("•")
            .into_any_element()
    };
    let group = SharedString::from(format!("brief-task-{ix}"));
    let toggle = summary.on_toggle.clone();
    let line = h_flex()
        .id(("brief-task", ix))
        .group(group.clone())
        .w_full()
        .gap(px(8.))
        .items_center()
        .child(
            div()
                .w(px(TASK_TEXT_INSET - 8.))
                .flex_none()
                .flex()
                .justify_center()
                .child(marker),
        )
        .child(
            div()
                .min_w_0()
                .when(!expanded, |this| this.truncate())
                .text_size(ty::BODY)
                .line_height(px(20.))
                .text_color(lb.text)
                .child(title.to_string()),
        )
        .when_some(tag, |this, tag| this.child(task_tag(tag, cx)))
        .child(div().flex_1())
        .when(has_details, |this| {
            this.cursor_pointer()
                .child(
                    div()
                        .flex_none()
                        .when(!expanded, |this| {
                            this.opacity(0.)
                                .group_hover(group, |style| style.opacity(1.))
                        })
                        .child(ui::icon(
                            if expanded {
                                Ico::ChevronDown
                            } else {
                                Ico::ChevronRight
                            },
                            px(13.),
                            lb.text_tertiary,
                        )),
                )
                .on_click(move |_, window, cx| toggle(ix, window, cx))
        });
    v_flex()
        .py(px(4.))
        .gap(px(4.))
        .child(line)
        .when(has_details && expanded, |this| {
            this.child(
                div()
                    .pl(px(TASK_TEXT_INSET))
                    .text_size(ty::SECONDARY)
                    .line_height(px(19.))
                    .text_color(lb.supporting)
                    .child(task.summary.clone()),
            )
            .child(
                v_flex()
                    .pl(px(TASK_TEXT_INSET))
                    .children(source_links(task, ix, cx)),
            )
        })
        .into_any_element()
}

/// The screens a task cites, each opening on Timeline (`DayDigestSourceLinks`).
fn source_links(task: &DigestTask, ix: usize, cx: &App) -> Vec<AnyElement> {
    let lb = cx.lb();
    let data = crate::state::AppData::global(cx);
    task.source_moments
        .iter()
        .enumerate()
        .map(|(source, moment)| match moment {
            Some(moment) => {
                let name = if moment.document_name.is_empty() {
                    &moment.app
                } else {
                    &moment.document_name
                };
                let label = format!("{name} · {}", lokalbot_core::time::clock_time(moment.ts));
                let data = data.clone();
                let (id, ts) = (moment.id, moment.ts);
                crate::ui::action_row::meta_link(
                    SharedString::from(format!("digest-source-{ix}-{source}")),
                    label,
                    Some(Ico::ScanText),
                    move |_, cx| data.update(cx, |data, cx| data.open_screen_moment(id, ts, cx)),
                    cx,
                )
                .into_any_element()
            }
            None => div()
                .text_size(ty::SECONDARY)
                .text_color(lb.supporting)
                .child(ui::text::paragraph(lokalbot_i18n::tr(
                    "Source moment unavailable",
                )))
                .into_any_element(),
        })
        .collect()
}

/// Status mark, title with its time range and tag, the "Next" step and the
/// details. An older digest's "09:00–10:30" opens the session it covers.
fn task_row(summary: &WorkSummary, task: &DigestTask, ix: usize, cx: &App) -> AnyElement {
    let lb = cx.lb();
    let expanded = summary.expanded.contains(&ix);
    let mark: AnyElement = match task.status {
        TaskStatus::Completed => {
            ui::icon(Ico::CircleCheck, px(16.), lb.success_text).into_any_element()
        }
        TaskStatus::InProgress => {
            ui::icon(Ico::Contrast, px(16.), lb.accent_text).into_any_element()
        }
        TaskStatus::Blocked => {
            ui::icon(Ico::CircleAlert, px(16.), lb.attention_text).into_any_element()
        }
        TaskStatus::Unknown => div()
            .text_size(ty::BODY)
            .text_color(lb.text_tertiary)
            .child("•")
            .into_any_element(),
    };
    let collapsible = task.has_heading && task.summary.chars().count() > 160;
    let show_summary =
        task.has_heading && !task.summary.trim().is_empty() && (!collapsible || expanded);
    let title: AnyElement = if task.has_heading {
        let (heading, tag) = title_and_tag(&task.title);
        let range = task
            .time_range
            .clone()
            .map(|range| match summary.sessions.get(&range) {
                Some(session) => {
                    let session = session.clone();
                    let open = summary.open_session.clone();
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .child(ui::link(
                            ("digest-task-session", ix),
                            range,
                            move |window, cx| open(session.clone(), window, cx),
                            cx,
                        ))
                        .into_any_element()
                }
                None => div()
                    .flex_none()
                    .text_size(ty::CAPTION)
                    .text_color(lb.supporting)
                    .child(range)
                    .into_any_element(),
            });
        h_flex()
            .flex_wrap()
            .gap_x(px(8.))
            .items_baseline()
            .children(range)
            .child(
                div()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .line_height(px(20.))
                    .text_color(lb.text)
                    .child(heading.to_string()),
            )
            .when_some(tag, |this, tag| this.child(task_tag(tag, cx)))
            .into_any_element()
    } else {
        div()
            .text_size(ty::BODY)
            .line_height(px(20.))
            .text_color(lb.text)
            .child(task.title.clone())
            .into_any_element()
    };
    let toggle = summary.on_toggle.clone();
    h_flex()
        .w_full()
        .items_start()
        .gap(px(8.))
        .child(
            div()
                .w(px(TASK_TEXT_INSET - 8.))
                .flex_none()
                .pt(px(2.))
                .flex()
                .justify_center()
                .child(mark),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(3.))
                .child(title)
                .when_some(task.next_step.clone(), |this, next| {
                    this.child(
                        h_flex()
                            .gap(px(5.))
                            .items_start()
                            .text_size(ty::SECONDARY)
                            .child(
                                div()
                                    .flex_none()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.accent_text)
                                    .child(ui::text::paragraph(lokalbot_i18n::tr("Next"))),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_color(lb.supporting)
                                    .child(next),
                            ),
                    )
                })
                .when(show_summary, |this| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .line_height(px(19.))
                            .text_color(lb.text)
                            .child(task.summary.clone()),
                    )
                })
                .children(source_links(task, ix, cx))
                .when(collapsible, |this| {
                    this.child(
                        div()
                            .id(("task-more", ix))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.accent_text)
                            .cursor_pointer()
                            .hover(|s| s.underline())
                            .child(if expanded {
                                lokalbot_i18n::tr("Show less")
                            } else {
                                lokalbot_i18n::tr("Show more")
                            })
                            .on_click(move |_, window, cx| toggle(ix, window, cx)),
                    )
                }),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_has_a_body_below_highlights_only_with_work_or_decisions() {
        let mut digest = lokalbot_core::digest::parse_digest("## At a glance\n- Shipped it.\n");
        assert!(!has_body_below_highlights(&digest));
        digest.decisions = vec!["Ship on Friday.".into()];
        assert!(has_body_below_highlights(&digest));
        digest.decisions.clear();
        digest.follow_ups = vec!["Ask Ana.".into()];
        assert!(has_body_below_highlights(&digest));
    }
}
