//! The pane beside the list (`ActionDetailsPane`, `ActionEvidencePassages`).
//! One selected action shows what the app knows about it: its status, its due
//! date with what was said about it, the people and project it belongs to,
//! and each meeting's quotes, which play in place. Several selected actions
//! show the changes that apply to all of them.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use crate::i18n::h_flex;
use chrono::{Local, NaiveDate};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::{Calendar, CalendarEvent, CalendarState, Date};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lokalbot_audio::Player;
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ActionReference, ActionStatus, ActionThread, OutcomeSourceCitation};
use uuid::Uuid;

use super::model::{self, ListContent, MAXIMUM_LINKS, STATUSES, state_key};
use super::{ActionsPage, DuePicker, Passages};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::action_row::{self, open_meeting};
use crate::ui::{self, Ico, controls};
use lokalbot_i18n::{directional, fill};

impl ActionsPage {
    pub(super) fn render_details(
        &mut self,
        content: &ListContent,
        current: Vec<ActionThread>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let body: AnyElement = match current.len() {
            0 => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr("No action selected"))
                .into_any_element(),
            1 => self.render_thread(&current[0], window, cx),
            _ => self.render_batch(content, current, cx),
        };
        div()
            .size_full()
            .bg(lb.window)
            .child(body)
            .into_any_element()
    }

    // ------------------------------------------------------------ one action

    fn render_thread(
        &mut self,
        thread: &ActionThread,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let hint = self.loaded.hints.get(&thread.id).cloned();
        let mentions = v_flex()
            .child(
                div()
                    .pb(px(8.))
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(directional(model::mentions_heading(thread))),
            )
            .children(thread.references.iter().enumerate().map(|(ix, reference)| {
                v_flex().child(ui::divider(cx)).child(
                    div()
                        .py(px(10.))
                        .child(self.render_passages(ix, reference, cx)),
                )
            }));
        let hand_off = {
            let thread = thread.clone();
            let data = self.data.clone();
            Button::new("actions-details-hand-off")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Hand off"))
                .dropdown_caret(true)
                .dropdown_menu(move |menu, _, _| {
                    action_row::hand_off_items(
                        menu.label(lokalbot_i18n::tr("Hand off to")),
                        &thread,
                        &data,
                    )
                })
        };
        v_flex()
            .size_full()
            .child(
                div()
                    .id("actions-details")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .child(
                        v_flex()
                            .px(px(20.))
                            .py(px(18.))
                            .gap(px(18.))
                            .child(
                                div()
                                    .text_size(ty::PANEL_TITLE)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(ui::text::paragraph(thread.text.clone())),
                            )
                            .children(hint.map(|hint| self.render_hint(thread, hint, cx)))
                            .child(self.render_properties(thread, window, cx))
                            .child(mentions),
                    ),
            )
            .child(ui::divider(cx))
            .child(
                h_flex()
                    .flex_none()
                    .px(px(20.))
                    .py(px(12.))
                    .gap(px(8.))
                    .child(hand_off),
            )
            .into_any_element()
    }

    /// "Looks done? Mail showed “Message sent” on Mon 5:48 PM, after this
    /// was said." with Mark Done, Show the screen and Not Yet. A suggestion
    /// only; nothing changes until Mark Done.
    fn render_hint(
        &self,
        thread: &ActionThread,
        hint: CompletionHint,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let page = cx.entity().downgrade();
        let (done_page, done_thread) = (page.clone(), thread.clone());
        let view_data = self.data.clone();
        let (snapshot, at) = (hint.snapshot_id, hint.captured_at);
        let dismiss_data = self.data.clone();
        let dismissed = hint.clone();
        ui::status_surface(lb.accent_text, cx).p(px(10.)).child(
            h_flex()
                .items_start()
                .gap(px(8.))
                .text_size(ty::SECONDARY)
                .child(ui::icon(Ico::CircleCheck, px(14.), lb.accent_text))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(6.))
                        .child(
                            h_flex()
                                .flex_wrap()
                                .items_start()
                                .gap_x(px(4.))
                                .child(
                                    div()
                                        .flex_none()
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(lokalbot_i18n::tr("Looks done?")),
                                )
                                .child(div().flex_1().min_w_0().text_color(lb.text).child(
                                    ui::text::paragraph(model::completion_hint_sentence(&hint)),
                                )),
                        )
                        .child(
                            h_flex()
                                .flex_wrap()
                                .gap(px(12.))
                                .child(ui::link(
                                    "actions-hint-done",
                                    lokalbot_i18n::tr("Mark Done"),
                                    move |window, cx| {
                                        let thread = done_thread.clone();
                                        let _ = done_page.update(cx, |this, cx| {
                                            this.request_status(
                                                ActionStatus::Done,
                                                vec![thread],
                                                window,
                                                cx,
                                            )
                                        });
                                    },
                                    cx,
                                ))
                                .child(ui::link(
                                    "actions-hint-view",
                                    lokalbot_i18n::tr("Show the screen"),
                                    move |_, cx| {
                                        view_data.update(cx, |data, cx| {
                                            data.open_screen_moment(snapshot, at, cx)
                                        });
                                    },
                                    cx,
                                ))
                                .child(ui::link(
                                    "actions-hint-not-yet",
                                    lokalbot_i18n::tr("Not Yet"),
                                    move |_, cx| {
                                        let library = dismiss_data.read(cx).library.clone();
                                        if let Err(err) =
                                            library.dismiss_completion_hint(&dismissed)
                                        {
                                            log::warn!("completion hint not dismissed: {err:#}");
                                        }
                                        dismiss_data
                                            .update(cx, |data, cx| data.mark_library_changed(cx));
                                    },
                                    cx,
                                )),
                        ),
                ),
        )
    }

    /// Status, Due with what was said, With and Project, labels in a column
    /// as wide as the widest of them.
    fn render_properties(
        &mut self,
        thread: &ActionThread,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let people: Vec<model::Link> = self
            .links
            .people_for(thread)
            .into_iter()
            .take(MAXIMUM_LINKS)
            .cloned()
            .collect();
        let projects: Vec<model::Link> = self
            .links
            .projects_for(thread)
            .into_iter()
            .take(MAXIMUM_LINKS)
            .cloned()
            .collect();
        let mut labels = vec![lokalbot_i18n::tr("Status"), lokalbot_i18n::tr("Due")];
        if !people.is_empty() {
            labels.push(lokalbot_i18n::tr("With"));
        }
        if !projects.is_empty() {
            labels.push(lokalbot_i18n::tr("Project"));
        }
        let label_width = super::list::text_width(&labels, ty::SECONDARY, window) + px(2.);
        let label_color = lb.text_secondary;
        let label = move |text: &'static str| {
            div()
                .flex_none()
                .w(label_width)
                .pt(px(4.))
                .text_size(ty::SECONDARY)
                .text_color(label_color)
                .child(text)
        };
        let row = |name: &'static str, value: AnyElement| {
            h_flex()
                .items_start()
                .gap(px(12.))
                .child(label(name))
                .child(div().flex_1().min_w_0().child(value))
        };

        let status = {
            let page = cx.entity().downgrade();
            let thread = thread.clone();
            let mixed = thread.is_mixed();
            let current = thread.status();
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(
                    Button::new("actions-details-status")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr(state_key(current)))
                        .dropdown_caret(true)
                        .dropdown_menu(move |mut menu, _, _| {
                            for status in STATUSES {
                                let page = page.clone();
                                let thread = thread.clone();
                                menu = menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr(state_key(status)))
                                        .checked(!mixed && current == status)
                                        .on_click(move |_, window, cx| {
                                            let thread = thread.clone();
                                            let _ = page.update(cx, |this, cx| {
                                                this.request_status(
                                                    status,
                                                    vec![thread],
                                                    window,
                                                    cx,
                                                )
                                            });
                                        }),
                                );
                            }
                            menu
                        }),
                )
                .when(mixed, |this| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(lokalbot_i18n::tr("Mixed status")),
                    )
                })
        };

        // What was said about the date, led by "Overdue." while it is.
        let today = Local::now().date_naive();
        let said = model::due_note(thread);
        let late = thread.is_overdue(today);
        let note = (late || said.is_some()).then(|| {
            h_flex()
                .flex_wrap()
                .items_start()
                .gap_x(px(4.))
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .when(late, |this| {
                    this.child(
                        div()
                            .flex_none()
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.overdue_text)
                            .child(lokalbot_i18n::tr("Overdue.")),
                    )
                })
                .children(
                    said.map(|said| div().flex_1().min_w_0().child(ui::text::paragraph(said))),
                )
        });
        let due = v_flex()
            .gap(px(5.))
            .items_start()
            .child(self.due_control(thread, cx))
            .children(note);

        let people = (!people.is_empty()).then(|| self.link_column(people, true, cx));
        let projects = (!projects.is_empty()).then(|| self.link_column(projects, false, cx));

        v_flex()
            .gap(px(9.))
            .child(row(lokalbot_i18n::tr("Status"), status.into_any_element()))
            .child(row(lokalbot_i18n::tr("Due"), due.into_any_element()))
            .when_some(people, |this, people| {
                this.child(row(lokalbot_i18n::tr("With"), people))
            })
            .when_some(projects, |this, projects| {
                this.child(row(lokalbot_i18n::tr("Project"), projects))
            })
    }

    /// People or projects as links that open their page.
    fn link_column(
        &self,
        items: Vec<model::Link>,
        person: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let kind = if person { "person" } else { "project" };
        v_flex()
            .gap(px(4.))
            .pt(px(4.))
            .text_size(ty::SECONDARY)
            .children(items.into_iter().enumerate().map(|(ix, item)| {
                let data = self.data.clone();
                let id = item.id;
                ui::link(
                    SharedString::from(format!("actions-details-{kind}-{ix}")),
                    item.name,
                    move |_, cx| {
                        let id = id.clone();
                        data.update(cx, |data, cx| {
                            if person {
                                data.open_person(id, cx)
                            } else {
                                data.open_project(id, cx)
                            }
                        });
                    },
                    cx,
                )
                .truncate()
            }))
            .into_any_element()
    }

    /// The Due control: the day, which opens a calendar with No date, Cancel
    /// and Save. The day is saved on the newest mention as a correction.
    fn due_control(
        &self,
        thread: &ActionThread,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let page = cx.entity().downgrade();
        let picker = self
            .due_picker
            .as_ref()
            .filter(|p| p.thread_id == thread.id)
            .map(|p| (p.calendar.clone(), p.day));
        let open = picker.is_some();
        let has_due = thread.due.is_some();
        let toggle_thread = thread.clone();
        let toggle_page = page.clone();
        Popover::new("actions-details-due")
            .open(open)
            .on_open_change(move |open, window, cx| {
                let open = *open;
                let thread = toggle_thread.clone();
                let _ = toggle_page.update(cx, |this, cx| {
                    if open {
                        this.open_due_picker(&thread, window, cx);
                    } else {
                        this.due_picker = None;
                        cx.notify();
                    }
                });
            })
            .trigger(
                Button::new("actions-details-due-button")
                    .outline()
                    .small()
                    .label(model::due_title(thread))
                    .dropdown_caret(true),
            )
            .content(move |_, _, _| {
                let Some((calendar, day)) = picker.clone() else {
                    return div().into_any_element();
                };
                let (clear_page, cancel_page, save_page) =
                    (page.clone(), page.clone(), page.clone());
                v_flex()
                    .gap(px(12.))
                    .child(
                        Calendar::new(&calendar)
                            .small()
                            .first_day_of_week(lokalbot_i18n::first_weekday()),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(
                                Button::new("actions-due-none")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("No date"))
                                    .disabled(!has_due)
                                    .on_click(move |_, _, cx| {
                                        let _ = clear_page
                                            .update(cx, |this, cx| this.save_due(None, cx));
                                    }),
                            )
                            .child(div().flex_1().min_w(px(16.)))
                            .child(
                                Button::new("actions-due-cancel")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Cancel"))
                                    .on_click(move |_, _, cx| {
                                        let _ = cancel_page.update(cx, |this, cx| {
                                            this.due_picker = None;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .child(
                                Button::new("actions-due-save")
                                    .primary()
                                    .small()
                                    .label(lokalbot_i18n::tr("Save"))
                                    .disabled(day.is_none())
                                    .on_click(move |_, _, cx| {
                                        let _ = save_page.update(cx, |this, cx| {
                                            let day = this.due_picker.as_ref().and_then(|p| p.day);
                                            if day.is_some() {
                                                this.save_due(day, cx);
                                            }
                                        });
                                    }),
                            ),
                    )
                    .text_color(lb.text)
                    .into_any_element()
            })
    }

    fn open_due_picker(
        &mut self,
        thread: &ActionThread,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let day = thread
            .resolved_due_date
            .unwrap_or_else(|| Local::now().date_naive());
        let calendar = cx.new(|cx| {
            let mut calendar = CalendarState::new(window, cx);
            calendar.set_date(Date::Single(Some(day)), window, cx);
            calendar
        });
        let subscription = cx.subscribe(&calendar, |this, _, event: &CalendarEvent, cx| {
            if let CalendarEvent::Selected(Date::Single(day)) = event
                && let Some(picker) = this.due_picker.as_mut()
            {
                picker.day = *day;
                cx.notify();
            }
        });
        self.due_picker = Some(DuePicker {
            thread_id: thread.id.clone(),
            calendar,
            day: Some(day),
            _subscription: subscription,
        });
        cx.notify();
    }

    /// Saves the chosen day, or no day, on the selected action.
    fn save_due(&mut self, day: Option<NaiveDate>, cx: &mut Context<Self>) {
        let Some(picker) = self.due_picker.take() else {
            return;
        };
        let Some(thread) = self.thread(&picker.thread_id).cloned() else {
            return;
        };
        self.save_corrections(vec![model::due_correction(day, &thread)], cx);
        cx.notify();
    }

    /// One meeting's mention: the meeting and its day, then what was said.
    /// The meeting name opens the meeting at the quote; a time plays the
    /// quote here.
    fn render_passages(
        &self,
        ix: usize,
        reference: &ActionReference,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let citations = &reference.citations;
        let meeting_id = reference.meeting_id;
        let first_start = citations.first().map(|c| c.start);
        let open_page = cx.entity().downgrade();
        let data = self.data.clone();
        let title = div()
            .id(("actions-passage-meeting", ix))
            .min_w_0()
            .truncate()
            .cursor_pointer()
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(lb.accent_text)
            .hover(|style| style.underline())
            .child(reference.meeting_title.clone())
            .tooltip(|window, cx| {
                Tooltip::new(lokalbot_i18n::tr("Show Passage in Meeting")).build(window, cx)
            })
            .on_click(move |_, _, cx| {
                let _ = open_page.update(cx, |this, _| this.stop_passage());
                open_meeting(&data, meeting_id, first_start, cx);
            });
        v_flex()
            .gap(px(4.))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .child(title)
                    .child(
                        div()
                            .flex_none()
                            .text_color(lb.text_secondary)
                            .child(model::day(reference.meeting_started_at, today)),
                    )
                    .child(div().flex_1().min_w(px(4.)))
                    .children(
                        citations
                            .first()
                            .map(|citation| self.play_button(ix, 0, reference, citation, cx)),
                    ),
            )
            .when(citations.is_empty(), |this| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::tr("No supporting passage was stored.")),
                )
            })
            .children(citations.iter().enumerate().map(|(cite, citation)| {
                h_flex()
                    .items_start()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(format!(
                                "“{}”",
                                citation.excerpt.trim()
                            ))),
                    )
                    .when(cite > 0, |this| {
                        this.child(self.play_button(ix, cite, reference, citation, cx))
                    })
            }))
            .when(reference.text_was_corrected, |this| {
                // A correction never replaces what was extracted.
                this.child(
                    v_flex()
                        .pt(px(2.))
                        .gap(px(1.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(
                            div()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(lokalbot_i18n::tr("Original Wording")),
                        )
                        .child(ui::text::paragraph(reference.original_text.clone())),
                )
            })
    }

    /// "▶ 0:24": plays the quote here, or pauses it.
    fn play_button(
        &self,
        ix: usize,
        cite: usize,
        reference: &ActionReference,
        citation: &OutcomeSourceCitation,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let passages = self.passages.as_ref();
        let loaded = passages
            .and_then(|p| p.players.get(&reference.meeting_id))
            .is_some_and(Option::is_some);
        let playing = passages.is_some_and(|p| {
            p.playing.as_ref() == Some(&(reference.id.clone(), cite))
                && p.players
                    .get(&reference.meeting_id)
                    .and_then(Option::as_ref)
                    .is_some_and(|player| player.is_playing())
        });
        let (start, end) = (citation.start, citation.end);
        let enabled = loaded && end > start;
        let stamp = action_row::short_stamp(start);
        let tooltip: SharedString = format!("“{}”", citation.excerpt.trim()).into();
        let hover = lb.accent_wash;
        let reference_id = reference.id.clone();
        let meeting_id = reference.meeting_id;
        crate::i18n::h_flex()
            .id(SharedString::from(format!("actions-play-{ix}-{cite}")))
            .flex_none()
            .gap(px(4.))
            .items_center()
            .px(px(4.))
            .py(px(2.))
            .rounded(px(5.))
            .text_size(ty::SECONDARY)
            .text_color(lb.accent_text)
            .child(ui::icon(
                if playing { Ico::Pause } else { Ico::Play },
                px(9.),
                lb.accent_text,
            ))
            .child(stamp)
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .when(enabled, |this| {
                this.cursor_pointer()
                    .hover(move |style| style.bg(hover))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.toggle_passage(&reference_id, meeting_id, cite, start, end, cx)
                    }))
            })
            .when(!enabled, |this| this.opacity(0.5))
            .into_any_element()
    }

    // ------------------------------------------------------------ several

    fn render_batch(
        &mut self,
        content: &ListContent,
        threads: Vec<ActionThread>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let listing = self.filter.status;
        let page = cx.entity().downgrade();
        let (first_label, first_status) = if listing == ActionStatus::Done {
            (lokalbot_i18n::tr("Mark open"), ActionStatus::Open)
        } else {
            (lokalbot_i18n::tr("Mark Done"), ActionStatus::Done)
        };
        let (second_label, second_status) = if listing == ActionStatus::Deferred {
            (lokalbot_i18n::tr("Move back to open"), ActionStatus::Open)
        } else {
            (lokalbot_i18n::tr("Defer"), ActionStatus::Deferred)
        };
        let button = |id: &'static str, label: &'static str, status: ActionStatus| {
            let page = page.clone();
            let threads = threads.clone();
            controls::bordered(id, label)
                .small()
                .on_click(move |_, window, cx| {
                    let threads = threads.clone();
                    let _ = page.update(cx, |this, cx| {
                        this.request_status(status, threads, window, cx)
                    });
                })
        };
        let listed = content.order.len();
        let select_page = page.clone();
        let rows = threads.iter().filter_map(|thread| {
            let row = content.row(&thread.id)?;
            let source = if row.source.is_empty() {
                model::source(thread)
            } else {
                row.source.clone()
            };
            Some(
                v_flex().child(ui::divider(cx)).child(
                    v_flex()
                        .py(px(8.))
                        .gap(px(1.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(ui::text::paragraph(thread.text.clone())),
                        )
                        .child(
                            div()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(source),
                        ),
                ),
            )
        });
        div()
            .id("actions-batch")
            .size_full()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .px(px(20.))
                    .py(px(18.))
                    .gap(px(18.))
                    .child(
                        div()
                            .text_size(ty::PANEL_TITLE)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(directional(fill(
                                lokalbot_i18n::tr("%lld actions selected"),
                                &[&lokalbot_i18n::number(threads.len())],
                            ))),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .child(button("actions-batch-done", first_label, first_status))
                            .child(button("actions-batch-defer", second_label, second_status)),
                    )
                    .child(v_flex().children(rows))
                    .child(
                        h_flex()
                            .flex_wrap()
                            .gap_x(px(6.))
                            .gap_y(px(2.))
                            .text_size(ty::SECONDARY)
                            .child(
                                div().text_color(lb.text_secondary).child(lokalbot_i18n::tr(
                                    "Ctrl-click rows to add or remove them.",
                                )),
                            )
                            .when(threads.len() < listed, |this| {
                                this.child(ui::link(
                                    "actions-batch-select-all",
                                    fill(
                                        lokalbot_i18n::tr("Select all %lld"),
                                        &[&lokalbot_i18n::number(listed)],
                                    ),
                                    move |_, cx| {
                                        let _ = select_page.update(cx, |this, cx| {
                                            if let Some((_, content)) = &this.content {
                                                let order = content.order.clone();
                                                this.selection.select_all(&order);
                                                cx.notify();
                                            }
                                        });
                                    },
                                    cx,
                                ))
                            }),
                    ),
            )
            .into_any_element()
    }

    // ------------------------------------------------------------- audio

    pub(super) fn stop_passage(&mut self) {
        if let Some(passages) = self.passages.take() {
            for player in passages.players.values().flatten() {
                player.pause();
            }
        }
    }

    /// Opens the audio of each meeting the selected action was said in, off
    /// the UI thread, when the details show a different action.
    pub(super) fn sync_passages(&mut self, thread: Option<&ActionThread>, cx: &mut Context<Self>) {
        if self.passages.as_ref().map(|p| p.thread_id.as_str()) == thread.map(|t| t.id.as_str()) {
            return;
        }
        self.stop_passage();
        let Some(thread) = thread else {
            return;
        };
        let thread_id = thread.id.clone();
        self.passages = Some(Passages {
            thread_id: thread_id.clone(),
            players: HashMap::new(),
            playing: None,
            poll: None,
        });
        let mut meetings: Vec<Uuid> = thread.references.iter().map(|r| r.meeting_id).collect();
        meetings.sort();
        meetings.dedup();
        for meeting_id in meetings {
            let data = self.data.read(cx);
            let Some(meeting) = data.meeting(meeting_id).cloned() else {
                continue;
            };
            let library = data.library.clone();
            let thread_id = thread_id.clone();
            cx.spawn(async move |this, cx| {
                let opened = cx
                    .background_spawn(async move {
                        let audio = library.audio(&meeting);
                        if audio.mic.is_none() && audio.system.is_none() {
                            return None;
                        }
                        Player::open(audio.mic.as_deref(), audio.system.as_deref())
                            .inspect_err(|err| log::warn!("passage audio not opened: {err:#}"))
                            .ok()
                    })
                    .await;
                let _ = this.update(cx, |this, cx| {
                    if let Some(passages) = this.passages.as_mut()
                        && passages.thread_id == thread_id
                    {
                        passages.players.insert(meeting_id, opened.map(Arc::new));
                        cx.notify();
                    }
                });
            })
            .detach();
        }
    }

    /// Plays one quote, or pauses it (`player.playExcerpt`).
    fn toggle_passage(
        &mut self,
        reference_id: &str,
        meeting_id: Uuid,
        cite: usize,
        start: f64,
        end: f64,
        cx: &mut Context<Self>,
    ) {
        let Some(passages) = self.passages.as_mut() else {
            return;
        };
        let Some(player) = passages.players.get(&meeting_id).cloned().flatten() else {
            return;
        };
        let key = (reference_id.to_string(), cite);
        if passages.playing.as_ref() == Some(&key) && player.is_playing() {
            player.pause();
            passages.playing = None;
            cx.notify();
            return;
        }
        // One quote at a time, whichever meeting it is from.
        for other in passages.players.values().flatten() {
            other.pause();
        }
        if let Err(err) = player.play_range(start, end) {
            let message = format!("{err:#}");
            self.data
                .update(cx, |data, cx| data.show_error(message, cx));
            return;
        }
        passages.playing = Some(key);
        passages.poll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
                let playing = this
                    .update(cx, |this, cx| {
                        let Some(passages) = this.passages.as_mut() else {
                            return false;
                        };
                        let playing = player.is_playing();
                        if !playing && passages.playing.take().is_some() {
                            cx.notify();
                        }
                        playing
                    })
                    .unwrap_or(false);
                if !playing {
                    break;
                }
            }
        }));
        cx.notify();
    }
}
