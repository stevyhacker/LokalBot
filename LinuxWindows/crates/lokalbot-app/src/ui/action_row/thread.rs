//! The action-thread row every page draws (`ActionThreadRow` in
//! `OutcomeOverviewViews.swift`) and what it does: status changes (asking
//! first when a thread spans meetings), the sources dialog, the "Looks
//! done?" and "Still open?" lines, and the hand-off menu items. Use it
//! through `ui::action_row::thread_row`.

use crate::i18n::h_flex;
use chrono::Local;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ActionReference, ActionStatus, ActionThread};

use crate::state::{AppData, MeetingTab};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{Ico, action_row};

/// Opens a meeting, optionally at a transcript moment.
pub(crate) fn open_meeting(
    data: &Entity<AppData>,
    meeting_id: uuid::Uuid,
    at: Option<f64>,
    cx: &mut App,
) {
    let tab = if at.is_some() {
        MeetingTab::Transcript
    } else {
        MeetingTab::Summary
    };
    data.update(cx, |data, cx| data.open_meeting(meeting_id, tab, at, cx));
}

/// "Looks done?" reads only text kept with consent, and only when asked to
/// (`refreshActionCompletionHints`).
pub(crate) fn suggests_completion(settings: &lokalbot_core::Settings) -> bool {
    settings.suggest_action_completion
        && settings.tracking_enabled
        && settings.screen_context_capture_mode != lokalbot_core::ScreenContextMode::ActivityOnly
}

/// "Looks done?" for `thread`, with Not Yet remembering the dismissal.
pub(crate) fn hint_line(
    id: SharedString,
    thread: &ActionThread,
    hint: &CompletionHint,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let library = data.read(cx).library.clone();
    let dismiss_data = data.clone();
    let dismissed = hint.clone();
    completion_hint_line(
        id,
        thread,
        hint,
        data,
        move |cx| {
            if let Err(err) = library.dismiss_completion_hint(&dismissed) {
                log::warn!("completion hint not dismissed: {err:#}");
            }
            dismiss_data.update(cx, |data, cx| data.mark_library_changed(cx));
        },
        cx,
    )
}

/// "3 weeks ago", as `RelativeDateTimeFormatter` says it for old work.
fn age_label(days: i64) -> String {
    let (count, one, many) = match days {
        ..=0 => return lokalbot_i18n::tr("today").to_string(),
        1..=6 => (days, "1 day ago", "{count} days ago"),
        7..=29 => (days / 7, "1 week ago", "{count} weeks ago"),
        30..=364 => (days / 30, "1 month ago", "{count} months ago"),
        _ => (days / 365, "1 year ago", "{count} years ago"),
    };
    if count == 1 {
        lokalbot_i18n::tr(one).to_string()
    } else {
        lokalbot_i18n::format(many, &[("count", count.to_string())])
    }
}

/// "Still open?": open work nobody has mentioned for weeks. Either answer
/// goes through the normal status path; deferred work stops asking
/// (`StillOpenLine`).
pub(crate) fn still_open_line(
    id: SharedString,
    thread: &ActionThread,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let today = Local::now().date_naive();
    let age = lokalbot_i18n::format(
        "Last mentioned {age}",
        &[("age", age_label(thread.days_since_last_mention(today)))],
    );
    let (done_data, defer_data) = (data.clone(), data.clone());
    let (done_thread, defer_thread) = (thread.clone(), thread.clone());
    h_flex()
        .id(id.clone())
        .gap(px(8.))
        .pl(px(30.))
        .pb(px(6.))
        .items_center()
        .tooltip(|window, cx| {
            gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::tr(
                "Nobody has mentioned this in a meeting for a while. Mark it done, or defer it to stop this question.",
            ))
            .build(window, cx)
        })
        .child(crate::ui::icon(Ico::Clock, px(13.), lb.attention_text))
        .child(
            div()
                .flex_none()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.attention_text)
                .child(lokalbot_i18n::tr("Still open?")),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(age),
        )
        .child(
            Button::new(SharedString::from(format!("{id}-done")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Mark Done"))
                .on_click(move |_, window, cx| {
                    set_thread_status(
                        done_data.clone(),
                        done_thread.clone(),
                        ActionStatus::Done,
                        window,
                        cx,
                    );
                }),
        )
        .child(
            Button::new(SharedString::from(format!("{id}-defer")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Defer"))
                .on_click(move |_, window, cx| {
                    set_thread_status(
                        defer_data.clone(),
                        defer_thread.clone(),
                        ActionStatus::Deferred,
                        window,
                        cx,
                    );
                }),
        )
        .into_any_element()
}

/// "Open in Agent", then each coding agent installed on this computer.
pub(crate) fn agent_menu_items_for_thread(
    menu: PopupMenu,
    thread: &ActionThread,
    data: &Entity<AppData>,
) -> PopupMenu {
    let prompt = lokalbot_core::agent_handoff::agent_prompt_for_thread(thread);
    let agent_data = data.clone();
    let mut menu = menu.item(
        PopupMenuItem::new(lokalbot_i18n::tr("Open in Agent")).on_click(move |_, _, cx| {
            let prompt = prompt.clone();
            agent_data.update(cx, |data, cx| data.open_agent(prompt, cx));
        }),
    );
    for target in crate::agent_handoff::for_actions() {
        let data = data.clone();
        let thread = thread.clone();
        menu = menu.item(
            PopupMenuItem::new(open_in_label(target)).on_click(move |_, _, cx| {
                crate::agent_handoff::hand_off_thread(&data, &thread, target, cx)
            }),
        );
    }
    menu
}

/// "Open in Claude Code".
pub(crate) fn open_in_label(target: crate::agent_handoff::Target) -> SharedString {
    lokalbot_i18n::format("Open in {target}", &[("target", target.name().to_string())]).into()
}

/// "Looks done?": a later capture shows the action's words with a completion
/// phrase. A suggestion only; nothing changes until Mark Done
/// (`ActionCompletionHintLine`).
pub(crate) fn completion_hint_line(
    id: SharedString,
    thread: &ActionThread,
    hint: &lokalbot_core::action_completion::CompletionHint,
    data: &Entity<AppData>,
    on_dismiss: impl Fn(&mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let time = hint
        .captured_at
        .with_timezone(&Local)
        .format("%a %-I:%M %p")
        .to_string();
    let title = if hint.title.is_empty() {
        String::new()
    } else {
        format!(" · {}", hint.title)
    };
    let evidence = lokalbot_i18n::format(
        "“{cue}” in {app} · {time}{title}",
        &[
            ("cue", hint.cue.clone()),
            ("app", hint.app.clone()),
            ("time", time),
            ("title", title),
        ],
    );
    let help = lokalbot_i18n::format(
        "A later screen capture shows “{cue}” with this action's words. Nothing changes until you choose Mark Done.",
        &[("cue", hint.cue.clone())],
    );
    let done_data = data.clone();
    let done_thread = thread.clone();
    let view_data = data.clone();
    let (snapshot, at) = (hint.snapshot_id, hint.captured_at);
    h_flex()
        .id(id.clone())
        .gap(px(8.))
        .pl(px(30.))
        .pb(px(6.))
        .items_center()
        .tooltip(move |window, cx| {
            gpui_kit::component::tooltip::Tooltip::new(help.clone()).build(window, cx)
        })
        .child(crate::ui::icon(Ico::CircleCheck, px(13.), lb.accent_text))
        .child(
            div()
                .flex_none()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.accent_text)
                .child(lokalbot_i18n::tr("Looks done?")),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(evidence),
        )
        .child(
            Button::new(SharedString::from(format!("{id}-done")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Mark Done"))
                .on_click(move |_, window, cx| {
                    set_thread_status(
                        done_data.clone(),
                        done_thread.clone(),
                        ActionStatus::Done,
                        window,
                        cx,
                    );
                }),
        )
        .child(
            Button::new(SharedString::from(format!("{id}-view")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("View"))
                .on_click(move |_, _, cx| {
                    view_data.update(cx, |data, cx| data.open_screen_moment(snapshot, at, cx));
                }),
        )
        .child(
            Button::new(SharedString::from(format!("{id}-not-yet")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Not Yet"))
                .on_click(move |_, _, cx| on_dismiss(cx)),
        )
        .into_any_element()
}

/// Sets a thread's status, asking first when it spans several meetings.
pub(crate) fn set_thread_status(
    data: Entity<AppData>,
    thread: ActionThread,
    status: ActionStatus,
    window: &mut Window,
    cx: &mut App,
) {
    if thread.meeting_count() <= 1 {
        apply_thread_status(data, thread, status, cx);
        return;
    }
    let title: SharedString = lokalbot_i18n::format(
        "Update actions in {0} meetings?",
        &[("0", format!("{}", thread.meeting_count()))],
    )
    .into();
    let titles: Vec<String> = {
        let mut seen = Vec::new();
        for reference in &thread.references {
            if !seen.contains(&reference.meeting_title) {
                seen.push(reference.meeting_title.clone());
            }
        }
        seen
    };
    let confirm: SharedString = lokalbot_i18n::format(
        "Mark all {0}",
        &[(
            "0",
            lokalbot_i18n::tr(status.label()).to_lowercase().to_string(),
        )],
    )
    .into();
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let data = data.clone();
        let thread = thread.clone();
        dialog
            .w(px(420.))
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(title.clone()),
            )
            .child(
                v_flex()
                    .gap(px(2.))
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .children(titles.iter().map(|t| div().child(t.clone()))),
            )
            .footer(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_end()
                    .child(
                        crate::ui::controls::bordered("thread-cancel", lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| {
                                window.close_dialog(cx);
                            }),
                    )
                    .child(
                        Button::new("thread-confirm")
                            .primary()
                            .label(confirm.clone())
                            .on_click(move |_, window, cx| {
                                apply_thread_status(data.clone(), thread.clone(), status, cx);
                                window.close_dialog(cx);
                            }),
                    ),
            )
    });
}

fn apply_thread_status(
    data: Entity<AppData>,
    thread: ActionThread,
    status: ActionStatus,
    cx: &mut App,
) {
    let library = data.read(cx).library.clone();
    cx.spawn(async move |cx| {
        let result = cx
            .background_spawn(async move { library.set_thread_status(&thread, status) })
            .await;
        data.update(cx, |data, cx| {
            if let Err(err) = result {
                data.show_error(
                    lokalbot_i18n::format(
                        "Could not update this action thread. {err}",
                        &[("err", format!("{:#}", err))],
                    ),
                    cx,
                );
            }
            data.mark_library_changed(cx);
        });
    })
    .detach();
}

/// Keeps an action out of (or back in) cross-meeting threads.
pub(super) fn set_excluded(
    data: Entity<AppData>,
    meeting_id: uuid::Uuid,
    action_id: String,
    excluded: bool,
    cx: &mut App,
) {
    let library = data.read(cx).library.clone();
    let Some(meeting) = data.read(cx).meeting(meeting_id).cloned() else {
        return;
    };
    cx.spawn(async move |cx| {
        let result = cx
            .background_spawn(
                async move { library.set_thread_excluded(&meeting, &action_id, excluded) },
            )
            .await;
        data.update(cx, |data, cx| {
            if let Err(err) = result {
                data.show_error(
                    lokalbot_i18n::format(
                        "Could not update this action. {err}",
                        &[("err", format!("{:#}", err))],
                    ),
                    cx,
                );
            }
            data.mark_library_changed(cx);
        });
    })
    .detach();
}

/// What a row adds beyond the action (`ActionThreadRow`'s options).
#[derive(Clone, Copy, Default)]
pub(crate) struct ThreadRowOptions<'a> {
    /// Projects show whose work it is when it is someone else's.
    pub show_owner: bool,
    /// People show deferred work as deferred and ask about open work nobody
    /// has mentioned for weeks.
    pub show_staleness: bool,
    /// Timeline's meeting preview lists that meeting's actions, so a row
    /// from one meeting does not name it again.
    pub hide_single_meeting_link: bool,
    /// People show the moment as a ▶ time that opens the meeting at that
    /// moment, like the notes beside it, instead of the quote pill.
    pub plays_evidence: bool,
    /// A "Looks done?" suggestion for this thread.
    pub hint: Option<&'a CompletionHint>,
}

/// The shared action row (`ActionThreadRow` on Today, Timeline, People and
/// Projects): completion circle, the action, a meta line (owner, mixed or
/// deferred status, source meeting link or "Mentioned in N meetings", due
/// text red when overdue and amber when due within a week, "Deadline
/// updated", the time it was said) and the "…" menu; then a "Looks done?" or
/// "Still open?" line. `id` must be unique on the page.
pub(crate) fn thread_row(
    id: SharedString,
    thread: &ActionThread,
    options: ThreadRowOptions<'_>,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let show_owner = options.show_owner;
    let today = Local::now().date_naive();
    let status = thread.status();
    let mixed = thread.is_mixed();
    let done = status == ActionStatus::Done && !mixed;
    let latest = thread.latest().clone();
    let multiple = thread.meeting_count() > 1;

    let toggle = {
        let data = data.clone();
        let thread = thread.clone();
        action_row::status_toggle(
            SharedString::from(format!("{id}-toggle")),
            status,
            mixed,
            move |window, cx| {
                let next = if thread.status() == ActionStatus::Done {
                    ActionStatus::Open
                } else {
                    ActionStatus::Done
                };
                set_thread_status(data.clone(), thread.clone(), next, window, cx);
            },
            cx,
        )
    };

    let mut meta: Vec<AnyElement> = Vec::new();
    if show_owner {
        let owner = thread
            .owner
            .as_deref()
            .map(|o| crate::pages::meetings::model::display_label(o, latest.is_for_user))
            .unwrap_or_else(|| lokalbot_i18n::tr("Owner unclear").into());
        meta.push(action_row::meta_text(owner, lb.text_secondary).into_any_element());
    }
    if mixed {
        meta.push(
            action_row::meta_text(lokalbot_i18n::tr("Mixed status"), lb.text_secondary)
                .into_any_element(),
        );
    } else if options.show_staleness && status == ActionStatus::Deferred {
        meta.push(
            action_row::meta_text(lokalbot_i18n::tr("Deferred"), lb.text_secondary)
                .into_any_element(),
        );
    }
    if multiple {
        meta.push(sources_link(
            SharedString::from(format!("{id}-sources")),
            thread,
            data,
            cx,
        ));
    } else if !options.hide_single_meeting_link {
        let data = data.clone();
        let meeting_id = latest.meeting_id;
        meta.push(
            action_row::meta_link(
                SharedString::from(format!("{id}-meeting")),
                latest.meeting_title.clone(),
                None,
                move |_, cx| open_meeting(&data, meeting_id, None, cx),
                cx,
            )
            .into_any_element(),
        );
    }
    if let (Some(due), Some(spoken)) = (thread.due.as_deref(), thread.due_reference_date) {
        let tone = action_row::DueTone::of_thread(thread, today);
        meta.push(
            action_row::due_text(
                SharedString::from(format!("{id}-due")),
                lokalbot_core::due::label(due, spoken),
                tone,
                cx,
            )
            .into_any_element(),
        );
    }
    if thread.due_history().len() > 1 {
        meta.push(
            action_row::meta_text(lokalbot_i18n::tr("Deadline updated"), lb.text_secondary)
                .into_any_element(),
        );
    }
    if !multiple && let Some(citation) = latest.first_citation().cloned() {
        let data = data.clone();
        let meeting_id = latest.meeting_id;
        let start = citation.start;
        let open =
            move |_: &mut Window, cx: &mut App| open_meeting(&data, meeting_id, Some(start), cx);
        meta.push(if options.plays_evidence {
            action_row::play_time(
                SharedString::from(format!("{id}-play")),
                start,
                Some(citation.excerpt.into()),
                open,
                cx,
            )
            .into_any_element()
        } else {
            action_row::evidence_pill(
                SharedString::from(format!("{id}-evidence")),
                start,
                Some(citation.excerpt.into()),
                open,
                cx,
            )
            .into_any_element()
        });
    }

    let menu = {
        let data = data.clone();
        let thread = thread.clone();
        action_row::options_menu(
            SharedString::from(format!("{id}-menu")),
            move |menu, _, _| {
                let mut menu = menu;
                for option in [
                    ActionStatus::Open,
                    ActionStatus::Done,
                    ActionStatus::Deferred,
                ] {
                    let data = data.clone();
                    let thread = thread.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                            .checked(!thread.is_mixed() && thread.status() == option)
                            .on_click(move |_, window, cx| {
                                set_thread_status(data.clone(), thread.clone(), option, window, cx)
                            }),
                    );
                }
                let latest = thread.latest().clone();
                let open_data = data.clone();
                menu = menu.separator().item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Open latest meeting")).on_click(
                        move |_, _, cx| open_meeting(&open_data, latest.meeting_id, None, cx),
                    ),
                );
                let menu = if thread.meeting_count() > 1 {
                    let data = data.clone();
                    let thread = thread.clone();
                    menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Review source meetings")).on_click(
                            move |_, window, cx| {
                                open_sources(thread.clone(), data.clone(), window, cx)
                            },
                        ),
                    )
                } else {
                    let data = data.clone();
                    let latest = thread.latest().clone();
                    let excluded = latest.is_thread_excluded;
                    let label = if excluded {
                        lokalbot_i18n::tr("Allow matching across meetings")
                    } else {
                        lokalbot_i18n::tr("Keep as separate action")
                    };
                    menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                        set_excluded(
                            data.clone(),
                            latest.meeting_id,
                            latest.action_id.clone(),
                            !excluded,
                            cx,
                        )
                    }))
                };
                agent_menu_items_for_thread(menu, &thread, &data)
            },
        )
    };

    let today = Local::now().date_naive();
    let line = match options.hint {
        Some(hint) => Some(hint_line(
            SharedString::from(format!("{id}-hint")),
            thread,
            hint,
            data,
            cx,
        )),
        None if options.show_staleness && thread.is_stale(today) => Some(still_open_line(
            SharedString::from(format!("{id}-stale")),
            thread,
            data,
            cx,
        )),
        None => None,
    };
    v_flex()
        .w_full()
        .child(action_row::action_row(
            toggle,
            thread.text.clone(),
            done,
            meta,
            None,
            menu,
            cx,
        ))
        .children(line)
        .into_any_element()
}

/// "Mentioned in N meetings": a teal link opening the thread's sources.
fn sources_link(
    id: SharedString,
    thread: &ActionThread,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let label = lokalbot_i18n::format(
        "Mentioned in {0} meetings",
        &[("0", format!("{}", thread.meeting_count()))],
    );
    let thread = thread.clone();
    let data = data.clone();
    Button::new(id)
        .text()
        .small()
        .icon(gpui_kit::component::Icon::new(Ico::Link))
        .label(label)
        .text_size(ty::SECONDARY)
        .text_color(lb.accent_text)
        .on_click(move |_, window, cx| open_sources(thread.clone(), data.clone(), window, cx))
        .into_any_element()
}

/// Every meeting a thread came up in (`ActionThreadSourcesView`). Each source
/// stays attached to its meeting, and can be split off the thread.
fn open_sources(thread: ActionThread, data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_dialog(cx, move |dialog, _, cx| {
        let lb = cx.lb().clone();
        let data = data.clone();
        let sources = thread
            .references
            .iter()
            .enumerate()
            .map(|(ix, reference)| source_row(ix, reference, &data, cx));
        dialog.w(px(480.)).child(
            v_flex()
                .gap(px(12.))
                .child(
                    v_flex()
                        .gap(px(3.))
                        .child(
                            div()
                                .text_size(ty::SECTION)
                                .font_weight(FontWeight::BOLD)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Action thread",
                                ))),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Every source remains attached to its original meeting.",
                                ))),
                        ),
                )
                .child(div().h(px(1.)).bg(lb.separator))
                .child(
                    v_flex()
                        .id("thread-sources")
                        .max_h(px(420.))
                        .overflow_y_scrollbar()
                        .gap(px(12.))
                        .children(sources),
                ),
        )
    });
}

fn source_row(
    ix: usize,
    reference: &ActionReference,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let open_data = data.clone();
    let split_data = data.clone();
    let meeting_id = reference.meeting_id;
    let action_id = reference.action_id.clone();
    let mut details = Vec::new();
    if let Some(owner) = reference.owner.as_deref() {
        details.push(lokalbot_i18n::format(
            "Owner: {0}",
            &[(
                "0",
                crate::pages::meetings::model::display_label(owner, reference.is_for_user)
                    .to_string(),
            )],
        ));
    }
    if let Some(due) = reference.due.as_deref() {
        details.push(lokalbot_i18n::format(
            "Due: {due}",
            &[("due", due.to_string())],
        ));
    }
    details.push(lokalbot_i18n::tr(reference.status.label()).to_string());
    v_flex()
        .gap(px(4.))
        .child(
            h_flex()
                .id(("thread-source", ix))
                .gap(px(8.))
                .cursor_pointer()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(reference.meeting_title.clone()),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::pages::meetings::model::date_label(
                            reference.meeting_started_at,
                        )),
                )
                .on_click(move |_, window, cx| {
                    window.close_dialog(cx);
                    open_meeting(&open_data, meeting_id, None, cx)
                }),
        )
        .child(
            div()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(reference.original_text.clone()),
        )
        .when(reference.text_was_corrected, |this| {
            this.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "Corrected to: {0}",
                        &[("0", reference.text.to_string())],
                    ))),
            )
        })
        .child(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_tertiary)
                .child(details.join("  ")),
        )
        .child(
            h_flex().child(
                Button::new(("thread-separate", ix))
                    .ghost()
                    .small()
                    .label(lokalbot_i18n::tr("Keep as separate action"))
                    .on_click(move |_, window, cx| {
                        set_excluded(split_data.clone(), meeting_id, action_id.clone(), true, cx);
                        window.close_dialog(cx);
                    }),
            ),
        )
        .children(
            reference
                .citations
                .iter()
                .enumerate()
                .map(|(cite, citation)| {
                    let data = data.clone();
                    let start = citation.start;
                    h_flex()
                        .id(SharedString::from(format!("thread-source-{ix}-{cite}")))
                        .gap(px(6.))
                        .items_start()
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.accent_text)
                        .child(crate::ui::icon(
                            Ico::MessageSquareQuote,
                            px(13.),
                            lb.accent_text,
                        ))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .line_clamp(2)
                                .child(citation.excerpt.clone()),
                        )
                        .on_click(move |_, window, cx| {
                            window.close_dialog(cx);
                            open_meeting(&data, meeting_id, Some(start), cx)
                        })
                }),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_work_says_how_old_like_the_mac() {
        assert_eq!(age_label(21), "3 weeks ago");
        assert_eq!(age_label(7), "1 week ago");
        assert_eq!(age_label(45), "1 month ago");
        assert_eq!(age_label(90), "3 months ago");
        assert_eq!(age_label(800), "2 years ago");
    }
}
