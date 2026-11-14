//! The meeting that starts within the hour, at the top of Today
//! (`TodayNextMeetingCard` in `UpcomingMeetingView.swift`): when it is, who
//! is in it, Join and Record, and what to know before joining. Calendar setup
//! and access stay in Settings.

use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::calendar::CalendarEvent;
use lokalbot_core::calendar::upcoming::{self as selector, UpcomingKind};
use lokalbot_engine::MeetingPreparation;

use super::model::{self, PreparationKind, PreparationRow};
use super::{CARD_TITLE, CARD_TITLE_COMPACT, TodayPage, card_surface, record_button, status_text};
use crate::i18n::h_flex;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, action_row};

/// Preparation is gathered again this often, and whenever the library changes.
const PREPARATION_REFRESH: Duration = Duration::from_secs(5 * 60);

#[derive(Default)]
pub(super) struct UpcomingState {
    /// The event and library revision preparation was last requested for.
    requested: Option<(String, u64, Instant)>,
    /// The reader's own choice for "Before you join". Without one it is open,
    /// and folds to a count while another meeting is being recorded.
    preparation_choice: Option<bool>,
    shows_more: bool,
    /// What the choice above was made for: the event and whether a meeting
    /// was being recorded. A change of either forgets it.
    seen: Option<(String, bool)>,
}

impl UpcomingState {
    /// Follows the card's event: forgets choices made for another event or
    /// recording state, and asks the engine for the event's evidence when it
    /// changes, when the library changes, and every few minutes.
    pub(super) fn sync(
        &mut self,
        next: Option<&CalendarEvent>,
        recording: bool,
        revision: u64,
        data: &Entity<AppData>,
        cx: &mut Context<TodayPage>,
    ) {
        let Some(next) = next else {
            self.requested = None;
            self.seen = None;
            return;
        };
        let seen = Some((next.external_id.clone(), recording));
        if self.seen != seen {
            if self.seen.as_ref().map(|(id, _)| id) != Some(&next.external_id) {
                self.shows_more = false;
            }
            self.preparation_choice = None;
            self.seen = seen;
        }
        let fresh = self.requested.as_ref().is_some_and(|(id, seen, at)| {
            *id == next.external_id && *seen == revision && at.elapsed() < PREPARATION_REFRESH
        });
        if fresh {
            return;
        }
        self.requested = Some((next.external_id.clone(), revision, Instant::now()));
        let data = data.clone();
        let event = next.clone();
        cx.defer(move |cx| {
            data.update(cx, |data, cx| {
                data.request(
                    AppEvent::PrepareMeeting {
                        event: Box::new(event),
                        generate: false,
                    },
                    cx,
                )
            })
        });
    }
}

impl TodayPage {
    pub(super) fn render_next_meeting(
        &self,
        event: &CalendarEvent,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let recording = data.recording.is_active();
        let preparation = data
            .meeting_preparation
            .clone()
            .filter(|p| p.event_id == event.external_id && p.evidence.has_preparation_context());

        let heading = format!(
            "{} · {}",
            status_text(model::event_status(event, now)),
            interval(event)
        );
        let summary = v_flex()
            .flex_1()
            .min_w(px(240.))
            .gap(px(3.))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.accent_text)
                    .child(heading),
            )
            .child(
                div()
                    .w_full()
                    .truncate()
                    .text_size(if recording {
                        CARD_TITLE_COMPACT
                    } else {
                        CARD_TITLE
                    })
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(event.title.clone()),
            )
            .when_some(selector::participant_label(event), |this, people| {
                this.child(
                    div()
                        .w_full()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(people),
                )
            });

        // A solo event without a link may not be a call at all; the toolbar's
        // Record is still there for it. Record leaves the card while
        // something else is being recorded: the live card holds the only Stop.
        let actions = (selector::kind(event) == UpcomingKind::Meeting).then(|| {
            let id = event.external_id.clone();
            h_flex()
                .flex_none()
                .gap(px(8.))
                .items_center()
                .when_some(event.meeting_url.clone(), |this, url| {
                    this.child(
                        Button::new(SharedString::from(format!("today-join-{id}")))
                            .primary()
                            .icon(Icon::new(Ico::Video))
                            .label(lokalbot_i18n::tr("Join"))
                            .on_click(move |_, _, cx| cx.open_url(&url)),
                    )
                })
                .when(!recording, |this| {
                    let data = self.data.clone();
                    let target = event.clone();
                    this.child(
                        record_button(SharedString::from(format!("today-record-{id}")), cx)
                            .on_click(move |_, _, cx| {
                                let event = Box::new(target.clone());
                                data.update(cx, |data, cx| {
                                    data.request(AppEvent::RecordCalendarEvent(event), cx)
                                })
                            }),
                    )
                })
        });

        card_surface(None, cx)
            .child(
                v_flex()
                    .w_full()
                    .gap(px(12.))
                    .px(px(18.))
                    .py(px(16.))
                    .child(
                        h_flex()
                            .w_full()
                            .flex_wrap()
                            .items_center()
                            .gap(px(12.))
                            .child(summary)
                            .children(actions),
                    )
                    .when_some(preparation, |this, preparation| {
                        this.child(ui::divider(cx)).child(self.preparation(
                            &preparation,
                            recording,
                            cx,
                        ))
                    }),
            )
            .into_any_element()
    }

    /// "Before you join": the brief when the model wrote one (or when there is
    /// nothing else), and one row of each kind of evidence, the rest a click
    /// away.
    fn preparation(
        &self,
        preparation: &MeetingPreparation,
        recording: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let evidence = &preparation.evidence;
        let rows = model::preparation_rows(evidence);
        let more = model::more_preparation_rows(evidence);
        let count = rows.len() + more.len();
        let open = self.upcoming.preparation_choice.unwrap_or(!recording);
        let shows_more = self.upcoming.shows_more;
        let generated = preparation.brief.is_some();
        let chevron = if open {
            Ico::ChevronDown
        } else if lokalbot_i18n::current().rtl {
            Ico::ChevronLeft
        } else {
            Ico::ChevronRight
        };
        let toggle = Button::new("today-before-you-join")
            .ghost()
            .small()
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(chevron, px(12.), lb.text_secondary))
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(lokalbot_i18n::tr("Before you join")),
                    )
                    .when(!open && count > 0, |this| {
                        let words = if count == 1 {
                            lokalbot_i18n::tr("%lld item")
                        } else {
                            lokalbot_i18n::tr("%lld items")
                        };
                        this.child(lokalbot_i18n::directional(lokalbot_i18n::fill(
                            words,
                            &[&lokalbot_i18n::number(count)],
                        )))
                    }),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.upcoming.preparation_choice = Some(!open);
                cx.notify();
            }));

        let header = h_flex()
            .w_full()
            .items_center()
            .gap(px(8.))
            .child(toggle)
            .child(div().flex_1())
            .when(open, |this| this.child(self.brief_control(preparation, cx)));
        let mut section = v_flex().w_full().gap(px(9.)).child(header);
        if !open {
            return section.into_any_element();
        }
        if model::shows_brief(generated, count) {
            let brief = preparation
                .brief
                .clone()
                .unwrap_or_else(|| evidence.fallback_brief());
            section = section.child(
                div()
                    .w_full()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(brief)),
            );
        }
        if let Some(error) = preparation.error.clone() {
            section = section.child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.recording_text)
                    .child(ui::icon(Ico::TriangleAlert, px(12.), lb.recording_text))
                    .child(translated_error(&error)),
            );
        }
        if count > 0 {
            let mut list = v_flex().w_full().gap(px(2.));
            for (index, row) in rows.iter().enumerate() {
                list = list.child(self.preparation_row(index, row, cx));
            }
            if shows_more {
                for (index, row) in more.iter().enumerate() {
                    list = list.child(self.preparation_row(rows.len() + index, row, cx));
                }
            }
            if !more.is_empty() {
                let label: SharedString = if shows_more {
                    lokalbot_i18n::tr("Show fewer").into()
                } else {
                    lokalbot_i18n::directional(lokalbot_i18n::fill(
                        lokalbot_i18n::tr("Show %lld more"),
                        &[&lokalbot_i18n::number(more.len())],
                    ))
                    .into()
                };
                list = list.child(
                    h_flex().pt(px(3.)).child(
                        Button::new("today-preparation-more")
                            .text()
                            .small()
                            .text_color(lb.accent_text)
                            .label(label)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.upcoming.shows_more = !this.upcoming.shows_more;
                                cx.notify();
                            })),
                    ),
                );
            }
            section = section.child(list);
        }
        section.into_any_element()
    }

    /// The model's brief is on request: it may load the Think model, and the
    /// engine writes it only with a Think model on this computer.
    fn brief_control(
        &self,
        preparation: &MeetingPreparation,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        if preparation.generating {
            return h_flex()
                .gap(px(6.))
                .items_center()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(gpui_kit::component::spinner::Spinner::new().small())
                .child(lokalbot_i18n::tr("Preparing…"))
                .into_any_element();
        }
        let data = self.data.clone();
        let event = preparation.evidence.event.clone();
        Button::new("today-write-brief")
            .text()
            .small()
            .text_color(lb.accent_text)
            .label(if preparation.brief.is_some() {
                lokalbot_i18n::tr("Rewrite brief")
            } else {
                lokalbot_i18n::tr("Write brief")
            })
            .tooltip(lokalbot_i18n::tr(
                "Generate from these sources using the Think model on this PC",
            ))
            .on_click(move |_, _, cx| {
                let event = Box::new(event.clone());
                data.update(cx, |data, cx| {
                    data.request(
                        AppEvent::PrepareMeeting {
                            event,
                            generate: true,
                        },
                        cx,
                    )
                })
            })
            .into_any_element()
    }

    /// One thing to know: what it is, the words, and where it comes from. A
    /// row with a meeting opens it.
    fn preparation_row(&self, index: usize, row: &PreparationRow, cx: &App) -> AnyElement {
        let lb = cx.lb().clone();
        let (label, icon) = match row.kind {
            PreparationKind::Decision => (lokalbot_i18n::tr("Decided"), Ico::Check),
            PreparationKind::Commitment => (lokalbot_i18n::tr("To revisit"), Ico::Clock),
            PreparationKind::Project => (lokalbot_i18n::tr("Project"), Ico::Folder),
            PreparationKind::RecentMeeting => (lokalbot_i18n::tr("Recent"), Ico::RotateCcwClock),
        };
        let mut detail: Vec<String> = Vec::new();
        if row.source_is_user {
            detail.push(lokalbot_i18n::tr("You").to_string());
        } else if let Some(source) = row.source.as_ref().filter(|s| !s.is_empty()) {
            detail.push(source.clone());
        }
        if let Some(date) = row.date {
            detail.push(
                date.format_localized(
                    lokalbot_i18n::date_pattern("%b %-d"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string(),
            );
        }
        let content = h_flex()
            .w_full()
            .items_start()
            .gap(px(9.))
            .py(px(2.))
            .child(
                div()
                    .flex_none()
                    .w(px(16.))
                    .pt(px(3.))
                    .flex()
                    .justify_center()
                    .child(ui::icon(icon, px(12.), lb.accent_text)),
            )
            .child(
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .flex_wrap()
                    .items_baseline()
                    .gap_x(px(12.))
                    .child(
                        h_flex()
                            .flex_1()
                            .min_w(px(200.))
                            .items_baseline()
                            .gap(px(6.))
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(
                                div()
                                    .flex_none()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(label),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .line_clamp(2)
                                    .child(row.text.clone()),
                            ),
                    )
                    .when(!detail.is_empty(), |this| {
                        this.child(
                            div()
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(detail.join(" · ")),
                        )
                    }),
            );
        let id = SharedString::from(format!("today-preparation-{index}"));
        match row.target {
            Some(meeting) => {
                let data = self.data.clone();
                let hover = lb.hover;
                div()
                    .id(id)
                    .w_full()
                    .rounded(px(6.))
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover))
                    .child(content)
                    .on_click(move |_, _, cx| action_row::open_meeting(&data, meeting, None, cx))
                    .into_any_element()
            }
            None => div().id(id).w_full().child(content).into_any_element(),
        }
    }
}

/// "11:00 AM – 11:30 AM", local time.
pub(crate) fn interval(event: &CalendarEvent) -> String {
    if event.end <= event.start {
        return lokalbot_core::time::clock_time(event.start);
    }
    format!(
        "{} – {}",
        lokalbot_core::time::clock_time(event.start),
        lokalbot_core::time::clock_time(event.end)
    )
}

/// The engine reports these two fixed messages; show them in the interface language.
fn translated_error(error: &str) -> String {
    match error {
        "Choose an on-device Think model to generate this brief." => {
            lokalbot_i18n::tr("Choose an on-device Think model to generate this brief.").into()
        }
        "AI brief unavailable; showing saved context." => {
            lokalbot_i18n::tr("AI brief unavailable; showing saved context.").into()
        }
        other => other.to_string(),
    }
}
