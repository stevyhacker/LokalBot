//! The Day Digest and the day's activity overview, shared by Today and
//! Timeline (`DayDigestCard.swift`, `DayDigestView.swift`,
//! `DayActivityOverview.swift`).

use std::collections::HashSet;
use std::rc::Rc;

use crate::i18n::h_flex;
use chrono::{DateTime, NaiveDate, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClipboardItem, Div, Entity, FontWeight, Hsla,
    InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, Window, div, px,
};
use lokalbot_core::digest::{BRIEF_ROW_LIMIT, TASK_GROUP_ORDER, folds_brief_rows, title_and_tag};
use lokalbot_core::{DayActivity, DayDigest, DigestTask, TaskStatus};

use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// Toggles a task's details by index, or one of the keys below.
pub(crate) type TaskToggle = Rc<dyn Fn(usize, &mut Window, &mut App)>;

/// Toggle keys past the task indices: follow-up rows, a Timeline section's
/// "Show N more" (plus the section's place in `TASK_GROUP_ORDER`), and
/// Timeline's Done line.
const FOLLOW_UP_KEY: usize = 10_000;
const SHOW_ALL_KEY: usize = 20_000;
const DONE_KEY: usize = 30_000;
/// The status column of a task row plus its gap; details align to it.
const TASK_TEXT_INSET: f32 = 26.;

// --------------------------------------------------------------- overview

/// `CaptureStyle.hm`: "3h 50m", "48m", "<1m" (and "0m" for nothing).
pub(crate) fn hm(seconds: f64) -> String {
    if seconds <= 0. {
        lokalbot_i18n::tr("0m").into()
    } else {
        crate::i18n::compact_duration(seconds)
    }
}

/// One proportion-bar segment: label, seconds, whether it is "Other".
pub(crate) struct AppShare {
    pub label: String,
    pub seconds: f64,
    pub is_other: bool,
}

/// Top five apps with at least a minute, then "Other" (`ProportionBarMath`).
pub(crate) fn app_shares(activity: &DayActivity) -> Vec<AppShare> {
    let mut shares = Vec::new();
    let mut other = 0.;
    for usage in activity
        .app_usage
        .iter()
        .filter(|u| !lokalbot_core::timeline::is_system_app(&u.app))
    {
        if shares.len() < 5 && usage.seconds >= 60. {
            shares.push(AppShare {
                label: usage.app.clone(),
                seconds: usage.seconds,
                is_other: false,
            });
        } else {
            other += usage.seconds;
        }
    }
    if other > 0. {
        shares.push(AppShare {
            label: lokalbot_i18n::tr("Other").into(),
            seconds: other,
            is_other: true,
        });
    }
    shares
}

pub(crate) fn app_count(activity: &DayActivity) -> usize {
    activity
        .app_usage
        .iter()
        .filter(|u| !lokalbot_core::timeline::is_system_app(&u.app))
        .count()
}

pub(crate) fn share_color(share: &AppShare, cx: &App) -> Hsla {
    let lb = cx.lb();
    if share.is_other {
        lb.text_tertiary.opacity(0.8)
    } else {
        lb.app_color(&share.label)
    }
}

/// "Day So Far" / "Day Overview": stat chips, proportion bar, optional legend.
pub(crate) fn day_overview(
    title: &'static str,
    activity: &DayActivity,
    legend: bool,
    narrow: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let apps = app_count(activity);
    let mut chips = vec![
        ui::stat_chip(
            Ico::Clock,
            crate::pages::today::digest::hm(activity.tracked_seconds),
            lokalbot_i18n::tr("tracked"),
            cx,
        )
        .into_any_element(),
        ui::stat_chip(
            Ico::LayoutGrid,
            lokalbot_i18n::number(apps),
            lokalbot_i18n::tr(if apps == 1 { "app" } else { "apps" }),
            cx,
        )
        .into_any_element(),
        ui::stat_chip(
            Ico::ScanText,
            lokalbot_i18n::number(activity.moment_count),
            lokalbot_i18n::tr(if activity.moment_count == 1 {
                "moment"
            } else {
                "moments"
            }),
            cx,
        )
        .into_any_element(),
    ];
    if activity.meeting_count > 0 || narrow {
        chips.push(
            ui::stat_chip(
                Ico::AudioLines,
                lokalbot_i18n::number(activity.meeting_count),
                lokalbot_i18n::tr(if activity.meeting_count == 1 {
                    "meeting"
                } else {
                    "meetings"
                }),
                cx,
            )
            .into_any_element(),
        );
    }
    let shares = app_shares(activity);
    let segments: Vec<(Hsla, f32)> = shares
        .iter()
        .map(|s| (share_color(s, cx), s.seconds as f32))
        .collect();
    v_flex()
        .gap(px(10.))
        .child(
            div()
                .text_size(ty::SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(title),
        )
        .child(h_flex().flex_wrap().gap(px(8.)).children(chips))
        .when(!shares.is_empty(), |this| {
            this.child(ui::proportion_bar(&segments, cx))
                .when(legend, |this| {
                    this.child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_y(px(8.))
                            .children(shares.iter().map(|share| {
                                h_flex()
                                    .w(px(150.))
                                    .gap(px(6.))
                                    .items_center()
                                    .text_size(ty::SECONDARY)
                                    .child(ui::status_dot(share_color(share, cx), px(6.)))
                                    .child(
                                        div()
                                            .min_w_0()
                                            .truncate()
                                            .text_color(lb.text)
                                            .child(share.label.clone()),
                                    )
                                    .child(
                                        div()
                                            .flex_none()
                                            .text_color(lb.text_secondary)
                                            .child(crate::pages::today::digest::hm(share.seconds)),
                                    )
                            })),
                    )
                })
        })
        .into_any_element()
}

// --------------------------------------------------------------- controls

/// Generate button and the "Digest actions" menu (and Ask on Timeline).
/// With `regenerates_from_menu` (Timeline), a current digest offers
/// Regenerate in the menu beside Copy and Export; the button shows only
/// before the first digest and while one is written.
pub(crate) fn digest_controls(
    day: NaiveDate,
    digest: Option<&DayDigest>,
    show_ask: bool,
    regenerates_from_menu: bool,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let busy = data.read(cx).digest_running == Some(day);
    let label = if busy {
        lokalbot_i18n::tr("Writing Digest…")
    } else if digest.is_none() {
        lokalbot_i18n::tr("Write Digest")
    } else {
        lokalbot_i18n::tr("Regenerate")
    };
    let generate = (!regenerates_from_menu || busy || digest.is_none()).then(|| {
        let data = data.clone();
        Button::new("digest-generate")
            .outline()
            .icon(Icon::new(if busy {
                Ico::Hourglass
            } else {
                Ico::RefreshCw
            }))
            .label(label)
            .disabled(busy)
            .on_click(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.request(AppEvent::RegenerateDigest(day), cx)
                })
            })
    });
    let actions = digest.map(|digest| {
        let markdown = digest.markdown.clone();
        let data = data.clone();
        let button = if regenerates_from_menu {
            Button::new("digest-actions")
                .ghost()
                .icon(Icon::new(Ico::Ellipsis))
                .tooltip(lokalbot_i18n::tr("Digest actions"))
        } else {
            Button::new("digest-actions")
                .ghost()
                .icon(Icon::new(Ico::CircleEllipsis))
                .label(lokalbot_i18n::tr("Digest actions"))
                .dropdown_caret(true)
        };
        button.dropdown_menu(move |menu, _, _| {
            let copy = markdown.clone();
            let export = markdown.clone();
            let copy_data = data.clone();
            let export_data = data.clone();
            let menu = if regenerates_from_menu {
                let regenerate_data = data.clone();
                menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Regenerate Digest"))
                        .icon(Icon::new(Ico::RefreshCw))
                        .disabled(busy)
                        .on_click(move |_, _, cx| {
                            regenerate_data.update(cx, |data, cx| {
                                data.request(AppEvent::RegenerateDigest(day), cx)
                            })
                        }),
                )
                .separator()
            } else {
                menu
            };
            menu.item(
                PopupMenuItem::new(lokalbot_i18n::tr("Copy Digest"))
                    .icon(Icon::new(Ico::Copy))
                    .on_click(move |_, _, cx| {
                        cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()));
                        copy_data.update(cx, |data, cx| {
                            data.show_message(lokalbot_i18n::tr("Digest copied."), cx)
                        });
                    }),
            )
            .item(
                PopupMenuItem::new(lokalbot_i18n::tr("Export Markdown"))
                    .icon(Icon::new(Ico::Share))
                    .on_click(move |_, _, cx| {
                        export_markdown(export_data.clone(), day, export.clone(), cx)
                    }),
            )
        })
    });
    let ask = show_ask.then(|| {
        let data = data.clone();
        ui::controls::bordered_icon(
            "digest-ask",
            Ico::TextSearch,
            lokalbot_i18n::tr("Ask About This Day"),
        )
        .on_click(move |_, _, cx| {
            let question = lokalbot_i18n::format(
                "What happened on {0}?",
                &[(
                    "0",
                    format!(
                        "{}",
                        day.format_localized(
                            lokalbot_i18n::date_pattern("%A, %B %-d"),
                            lokalbot_i18n::date_locale()
                        )
                    ),
                )],
            );
            data.update(cx, |data, cx| {
                data.ask(
                    crate::state::AskRequest {
                        question,
                        meeting_ids: Vec::new(),
                        submit: false,
                    },
                    cx,
                )
            })
        })
    });
    h_flex()
        .gap(px(8.))
        .items_center()
        .children(ask)
        .children(generate)
        .children(actions)
        .into_any_element()
}

fn export_markdown(data: Entity<AppData>, day: NaiveDate, markdown: String, cx: &mut App) {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let name = format!("{}.md", day.format("%Y-%m-%d"));
    let receiver = cx.prompt_for_new_path(&home, Some(&name));
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(path))) = receiver.await else {
            return;
        };
        let result = cx
            .background_spawn(async move { std::fs::write(&path, markdown) })
            .await;
        data.update(cx, |data, cx| match result {
            Ok(()) => data.show_message(lokalbot_i18n::tr("Digest exported as Markdown."), cx),
            Err(err) => data.show_error(
                lokalbot_i18n::format(
                    "Digest export failed: {err}",
                    &[("err", format!("{}", err))],
                ),
                cx,
            ),
        });
    })
    .detach();
}

// ------------------------------------------------------------------- body

/// When the digest was written: its sidecar's time, else the file's.
pub(crate) fn digest_updated_at(digest: &DayDigest) -> Option<DateTime<Utc>> {
    digest
        .meta
        .as_ref()
        .map(|m| m.generated_at)
        .or(digest.modified_at)
}

/// Today's digest, its freshness line, or the empty text.
pub(crate) fn digest_card(
    digest: Option<&DayDigest>,
    width: gpui_kit::Pixels,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let Some(digest) = digest else {
        return div()
            .text_size(ty::BODY)
            .text_color(lb.text_secondary)
            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                "Your digest brings together this day's meetings and captured activity.",
            )))
            .into_any_element();
    };
    let updated = digest_updated_at(digest);
    v_flex()
        .gap(px(14.))
        .child(digest_view(digest, width, expanded, on_toggle, cx))
        .when(updated.is_some() || digest.is_stale, |this| {
            this.child(
                h_flex()
                    .flex_wrap()
                    .gap_x(px(8.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .when_some(updated, |this, at| {
                        this.child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "Updated {0}",
                            &[("0", lokalbot_core::time::clock_time(at).to_string())],
                        )))
                    })
                    .when(digest.is_stale, |this| {
                        this.child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "New activity available · Update digest to include it",
                        )))
                    }),
            )
        })
        .into_any_element()
}

fn digest_section(icon: Ico, title: &str, content: impl IntoElement, cx: &App) -> AnyElement {
    let lb = cx.lb();
    v_flex()
        .gap(px(8.))
        .child(
            h_flex()
                .gap(px(8.))
                .items_center()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(ui::icon(icon, px(15.), lb.text))
                .child(title.to_string()),
        )
        .child(content)
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
                .line_height(px(21.))
                .text_color(lb.text)
                .child(div().flex_none().text_color(lb.text_tertiary).child("•"))
                .child(div().flex_1().min_w_0().child(item.clone()))
        }))
        .into_any_element()
}

/// Blockers lead the digest: they are what stops the day's open work.
fn blockers_callout(digest: &DayDigest, cx: &App) -> Option<AnyElement> {
    if digest.blockers.is_empty() {
        return None;
    }
    let lb = cx.lb();
    let title = if digest.blockers.len() == 1 {
        lokalbot_i18n::tr("Blocker")
    } else {
        lokalbot_i18n::tr("Blockers")
    };
    Some(
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
            .into_any_element(),
    )
}

fn highlights(digest: &DayDigest, cx: &App) -> Option<AnyElement> {
    if digest.at_a_glance_markdown.trim().is_empty() {
        return None;
    }
    let lb = cx.lb();
    Some(digest_section(
        Ico::Sparkles,
        lokalbot_i18n::tr("Highlights"),
        div()
            .max_w(metric::READING_MAX_WIDTH)
            .text_size(ty::BODY)
            .text_color(lb.text)
            .child(
                crate::ui::markdown_view::markdown(
                    "digest-highlights",
                    digest.at_a_glance_markdown.clone(),
                )
                .selectable(true),
            ),
        cx,
    ))
}

fn follow_ups(
    digest: &DayDigest,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> Option<AnyElement> {
    if !digest.follow_up_tasks.is_empty() {
        Some(digest_section(
            Ico::CornerDownRight,
            lokalbot_i18n::tr("Follow-ups"),
            task_rows(
                &digest.follow_up_tasks,
                FOLLOW_UP_KEY,
                expanded,
                on_toggle,
                cx,
            ),
            cx,
        ))
    } else if !digest.follow_ups.is_empty() {
        Some(digest_section(
            Ico::CornerDownRight,
            lokalbot_i18n::tr("Follow-ups"),
            bullet_list(&digest.follow_ups, cx),
            cx,
        ))
    } else {
        None
    }
}

/// `DayDigestView` in its Today mode.
fn digest_view(
    digest: &DayDigest,
    width: gpui_kit::Pixels,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let mut parts: Vec<AnyElement> = Vec::new();
    parts.extend(blockers_callout(digest, cx));
    parts.extend(highlights(digest, cx));
    if !digest.decisions.is_empty() {
        parts.push(digest_section(
            Ico::BadgeCheck,
            lokalbot_i18n::tr("Decisions"),
            div()
                .max_w(metric::READING_MAX_WIDTH)
                .child(bullet_list(&digest.decisions, cx)),
            cx,
        ));
    }
    if !digest.tasks.is_empty() {
        parts.push(
            v_flex()
                .gap(px(12.))
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(ui::icon(Ico::Briefcase, px(16.), lb.text))
                        .child(lokalbot_i18n::tr("Tasks")),
                )
                .child(task_grid(
                    &digest.tasks,
                    width,
                    expanded,
                    on_toggle.clone(),
                    cx,
                ))
                .into_any_element(),
        );
    }
    parts.extend(follow_ups(digest, expanded, on_toggle, cx));
    v_flex().gap(px(20.)).children(parts).into_any_element()
}

/// `DayDigestView` in its Timeline mode, below Needs Attention: blockers,
/// highlights, decisions, one section per task status and follow-ups, then
/// when a current digest was written.
pub(crate) fn timeline_digest(
    digest: &DayDigest,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let mut parts: Vec<AnyElement> = Vec::new();
    parts.extend(blockers_callout(digest, cx));
    parts.extend(highlights(digest, cx));
    if !digest.decisions.is_empty() {
        parts.push(timeline_decisions(&digest.decisions, cx));
    }
    if !digest.tasks.is_empty() {
        parts.push(timeline_task_sections(
            digest,
            expanded,
            on_toggle.clone(),
            cx,
        ));
    }
    parts.extend(follow_ups(digest, expanded, on_toggle, cx));
    // A stale digest says when it was written in the status line instead.
    let updated = digest_updated_at(digest).filter(|_| !digest.is_stale);
    v_flex()
        .gap(px(20.))
        .children(parts)
        .when_some(updated, |this, at| {
            this.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_tertiary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "Updated {0}",
                        &[("0", lokalbot_core::time::clock_time(at))],
                    ))),
            )
        })
        .into_any_element()
}

/// A Timeline heading with its count: "In Progress 3".
pub(crate) fn counted_heading(
    title: impl Into<gpui_kit::SharedString>,
    count: usize,
    cx: &App,
) -> Div {
    h_flex()
        .gap(px(8.))
        .items_baseline()
        .child(ui::section_title(title, cx))
        .child(
            div()
                .text_size(ty::SECONDARY)
                .text_color(cx.lb().text_secondary)
                .child(lokalbot_i18n::number(count)),
        )
}

fn timeline_decisions(decisions: &[String], cx: &App) -> AnyElement {
    let lb = cx.lb();
    v_flex()
        .gap(px(6.))
        .child(ui::section_title(lokalbot_i18n::tr("Decisions"), cx))
        .children(decisions.iter().map(|decision| {
            h_flex()
                .gap(px(8.))
                .items_start()
                .child(
                    div()
                        .w(px(TASK_TEXT_INSET - 8.))
                        .flex_none()
                        .pt(px(3.))
                        .flex()
                        .justify_center()
                        .child(ui::icon(Ico::BadgeCheck, px(14.), lb.accent_text)),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .line_height(px(21.))
                        .text_color(lb.text)
                        .child(decision.clone()),
                )
        }))
        .into_any_element()
}

/// Each status gets its own section. Tasks with a next step stay in full,
/// the rest of the open work becomes one-line rows, and finished work folds
/// into a single Done line.
fn timeline_task_sections(
    digest: &DayDigest,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let task_first = digest.is_task_first();
    let sections = digest.task_groups().into_iter().map(|group| {
        let rows = digest.timeline_rows(&group);
        if group.status == TaskStatus::Completed && task_first {
            return done_section(digest, &rows.brief, expanded, on_toggle.clone(), cx);
        }
        let title = match group.status {
            TaskStatus::Blocked => lokalbot_i18n::tr("Blocked"),
            TaskStatus::InProgress => lokalbot_i18n::tr("In Progress"),
            TaskStatus::Unknown if task_first => lokalbot_i18n::tr("Other Work"),
            TaskStatus::Unknown => lokalbot_i18n::tr("Work Summary"),
            TaskStatus::Completed => lokalbot_i18n::tr("Done"),
        };
        let show_all_key = SHOW_ALL_KEY
            + TASK_GROUP_ORDER
                .iter()
                .position(|status| *status == group.status)
                .unwrap_or(0);
        v_flex()
            .gap(px(2.))
            .child(counted_heading(title, group.tasks.len(), cx).pb(px(2.)))
            .child(indexed_task_rows(
                digest,
                &rows.full,
                expanded,
                on_toggle.clone(),
                cx,
            ))
            .when(!rows.brief.is_empty(), |this| {
                this.child(brief_task_list(
                    digest,
                    &rows.brief,
                    !rows.full.is_empty(),
                    show_all_key,
                    expanded,
                    on_toggle.clone(),
                    cx,
                ))
            })
            .into_any_element()
    });
    v_flex().gap(px(22.)).children(sections).into_any_element()
}

/// Full task rows with tags, by index into `digest.tasks`.
fn indexed_task_rows(
    digest: &DayDigest,
    indices: &[usize],
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let count = indices.len();
    v_flex()
        .children(indices.iter().enumerate().map(|(pos, &ix)| {
            v_flex()
                .child(div().py(px(7.)).child(task_row(
                    &digest.tasks[ix],
                    ix,
                    expanded.contains(&ix),
                    true,
                    on_toggle.clone(),
                    cx,
                )))
                .when(pos + 1 < count, |this| {
                    this.child(div().ml(px(TASK_TEXT_INSET)).h(px(1.)).bg(lb.separator))
                })
        }))
        .into_any_element()
}

/// One-line rows for open tasks without a next step. A long list shows its
/// first rows until asked for the rest.
fn brief_task_list(
    digest: &DayDigest,
    indices: &[usize],
    follows_full_rows: bool,
    show_all_key: usize,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let folds = folds_brief_rows(indices.len());
    let shows_all = expanded.contains(&show_all_key);
    let visible = if folds && !shows_all {
        &indices[..BRIEF_ROW_LIMIT]
    } else {
        indices
    };
    let toggle = on_toggle.clone();
    v_flex()
        .when(follows_full_rows, |this| {
            // Below full rows, a heading says what these rows are.
            this.child(
                div()
                    .pt(px(12.))
                    .pb(px(2.))
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "{count} more without a next step",
                        &[("count", lokalbot_i18n::number(indices.len()))],
                    ))),
            )
        })
        .children(visible.iter().map(|&ix| {
            brief_task_row(
                &digest.tasks[ix],
                ix,
                false,
                expanded.contains(&ix),
                on_toggle.clone(),
                cx,
            )
        }))
        .when(folds, |this| {
            let label = if shows_all {
                lokalbot_i18n::tr("Show fewer").to_string()
            } else {
                lokalbot_i18n::format(
                    "Show {count} more",
                    &[(
                        "count",
                        lokalbot_i18n::number(indices.len() - BRIEF_ROW_LIMIT),
                    )],
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
        .text_color(lb.text_secondary)
        .whitespace_nowrap()
        .child(tag.to_string())
}

/// One line for a task without a next step; what was done opens in place.
fn brief_task_row(
    task: &DigestTask,
    ix: usize,
    is_done: bool,
    expanded: bool,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
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
    let group = gpui_kit::SharedString::from(format!("brief-task-{ix}"));
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
            let toggle = on_toggle.clone();
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
                    .text_color(lb.text_secondary)
                    .child(task.summary.clone()),
            )
        })
        .into_any_element()
}

/// Finished tasks fold into one line that names them; opening it lists each.
fn done_section(
    digest: &DayDigest,
    indices: &[usize],
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let open = expanded.contains(&DONE_KEY);
    let preview = indices
        .iter()
        .map(|&ix| title_and_tag(&digest.tasks[ix].title).0)
        .collect::<Vec<_>>()
        .join(", ");
    let toggle = on_toggle.clone();
    v_flex()
        .pt(px(12.))
        .gap(px(2.))
        .border_t_1()
        .border_color(lb.separator)
        .child(
            h_flex()
                .id("digest-done")
                .w_full()
                .gap(px(8.))
                .items_center()
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
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Done")),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::number(indices.len())),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .when(!open, |this| this.child(preview)),
                )
                .child(ui::icon(
                    if open {
                        Ico::ChevronDown
                    } else {
                        Ico::ChevronRight
                    },
                    px(13.),
                    lb.text_tertiary,
                ))
                .on_click(move |_, window, cx| toggle(DONE_KEY, window, cx)),
        )
        .when(open, |this| {
            this.child(v_flex().pt(px(4.)).children(indices.iter().map(|&ix| {
                brief_task_row(
                    &digest.tasks[ix],
                    ix,
                    true,
                    expanded.contains(&ix),
                    on_toggle.clone(),
                    cx,
                )
            })))
        })
        .into_any_element()
}

/// Card grid of 1/2/3 columns at widths below 560 / from 560 / from 900.
fn task_grid(
    tasks: &[DigestTask],
    width: gpui_kit::Pixels,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let columns = if width >= px(900.) {
        3
    } else if width >= px(560.) {
        2
    } else {
        1
    };
    let rows = tasks.chunks(columns).enumerate().map(|(row_ix, row)| {
        h_flex()
            .gap(px(12.))
            .items_stretch()
            .children(row.iter().enumerate().map(|(col, task)| {
                let ix = row_ix * columns + col;
                div()
                    .flex_1()
                    .min_w_0()
                    .p(metric::PANEL_PADDING)
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.chip_fill.opacity(0.5))
                    .border_1()
                    .border_color(lb.separator.opacity(0.9))
                    .child(task_row(
                        task,
                        ix,
                        expanded.contains(&ix),
                        false,
                        on_toggle.clone(),
                        cx,
                    ))
                    .into_any_element()
            }))
            .children((row.len()..columns).map(|_| div().flex_1().into_any_element()))
    });
    v_flex().gap(px(12.)).children(rows).into_any_element()
}

fn task_rows(
    tasks: &[DigestTask],
    offset: usize,
    expanded: &HashSet<usize>,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let count = tasks.len();
    v_flex()
        .children(tasks.iter().enumerate().map(|(pos, task)| {
            let ix = offset + pos;
            v_flex()
                .child(div().py(px(7.)).child(task_row(
                    task,
                    ix,
                    expanded.contains(&ix),
                    false,
                    on_toggle.clone(),
                    cx,
                )))
                .when(pos + 1 < count, |this| {
                    this.child(div().ml(px(TASK_TEXT_INSET)).h(px(1.)).bg(lb.separator))
                })
        }))
        .into_any_element()
}

/// Status mark, title, "Next" step and collapsible details. Timeline shows a
/// title's trailing "(Project)" as a tag.
fn task_row(
    task: &DigestTask,
    ix: usize,
    expanded: bool,
    shows_tag: bool,
    on_toggle: TaskToggle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
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
        let (heading, tag) = if shows_tag {
            title_and_tag(&task.title)
        } else {
            (task.title.as_str(), None)
        };
        h_flex()
            .flex_wrap()
            .gap_x(px(8.))
            .items_baseline()
            .when_some(task.time_range.clone(), |this, range| {
                this.child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(range),
                )
            })
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
    let toggle = on_toggle.clone();
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
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Next"))),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_color(lb.text_secondary)
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
