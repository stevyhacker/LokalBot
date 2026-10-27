//! Action-thread rows for Today, Timeline and the Actions workspace
//! (`ActionThreadRow` in `OutcomeOverviewViews.swift`).

use crate::i18n::h_flex;
use chrono::Local;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::PopupMenuItem;
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lokalbot_core::{ActionStatus, ActionThread};

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
fn set_excluded(
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

/// One `ActionThreadRow`.
pub(crate) fn thread_row(
    id: SharedString,
    thread: &ActionThread,
    show_owner: bool,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb().clone();
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
    } else if show_owner && status == ActionStatus::Deferred {
        meta.push(
            action_row::meta_text(lokalbot_i18n::tr("Deferred"), lb.text_secondary)
                .into_any_element(),
        );
    }
    if multiple {
        meta.push(sources_popover(
            SharedString::from(format!("{id}-sources")),
            thread,
            data,
            cx,
        ));
    } else {
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
        let overdue = thread.is_overdue(today);
        meta.push(
            action_row::meta_text(
                lokalbot_core::due::label(due, spoken),
                if overdue {
                    lb.attention_text
                } else {
                    lb.text_secondary
                },
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
        meta.push(
            action_row::evidence_pill(
                SharedString::from(format!("{id}-evidence")),
                start,
                Some(citation.excerpt.into()),
                move |_, cx| open_meeting(&data, meeting_id, Some(start), cx),
                cx,
            )
            .into_any_element(),
        );
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
                if thread.meeting_count() > 1 {
                    let data = data.clone();
                    let latest = thread.latest().clone();
                    menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Review source meetings")).on_click(
                            move |_, _, cx| open_meeting(&data, latest.meeting_id, None, cx),
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
                }
            },
        )
    };

    action_row::action_row(toggle, thread.text.clone(), done, meta, None, menu, cx)
        .into_any_element()
}

/// "Mentioned in N meetings": a teal link opening the thread's sources.
fn sources_popover(
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
    let trigger = Button::new(SharedString::from(format!("{id}-trigger")))
        .text()
        .small()
        .icon(gpui_kit::component::Icon::new(Ico::Link))
        .label(label)
        .text_size(ty::SECONDARY)
        .text_color(lb.accent_text);
    Popover::new(id)
        .trigger(trigger)
        .content(move |_, _, cx| {
            let lb = cx.lb().clone();
            let data = data.clone();
            v_flex()
                .w(px(440.))
                .max_h(px(420.))
                .gap(px(12.))
                .p(px(16.))
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
                .children(thread.references.iter().enumerate().map(|(ix, reference)| {
                    let open_data = data.clone();
                    let meeting_id = reference.meeting_id;
                    let mut details = Vec::new();
                    if let Some(owner) = reference.owner.as_deref() {
                        details.push(lokalbot_i18n::format(
                            "Owner: {0}",
                            &[(
                                "0",
                                crate::pages::meetings::model::display_label(
                                    owner,
                                    reference.is_for_user,
                                )
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
                                .on_click(move |_, _, cx| {
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
                        .into_any_element()
                }))
        })
        .into_any_element()
}
