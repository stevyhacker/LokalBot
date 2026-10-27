//! Today's meetings from the calendar (`UpcomingMeetingView.swift`): the next
//! meeting leads with Join and Record and its preparation context, and the
//! rest of today follows compactly. Setup and access stay in Settings.

use std::time::{Duration, Instant};

use chrono::{DateTime, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_ai::upcoming::{UpcomingProject, UpcomingReference};
use lokalbot_core::calendar::CalendarEvent;
use lokalbot_core::calendar::upcoming::{self as selector, EventStatus, UpcomingKind};
use lokalbot_engine::{CalendarStatus, MeetingPreparation};

use super::TodayPage;
use crate::i18n::h_flex;
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// Later meetings shown before "N more today".
const INLINE_LIMIT: usize = 3;
/// Preparation is gathered again this often, and whenever the library changes.
const PREPARATION_REFRESH: Duration = Duration::from_secs(5 * 60);

pub(super) struct UpcomingState {
    /// The event and library revision preparation was last requested for.
    requested: Option<(String, u64, Instant)>,
    /// Preparation is the reason to look at the next meeting: it starts open.
    preparation_open: bool,
    more_open: bool,
    show_all_later: bool,
}

impl Default for UpcomingState {
    fn default() -> Self {
        Self {
            requested: None,
            preparation_open: true,
            more_open: false,
            show_all_later: false,
        }
    }
}

impl TodayPage {
    pub(super) fn render_upcoming(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let data = self.data.read(cx);
        if !data.settings.calendar_detection_enabled
            || data.calendar.status != CalendarStatus::Ready
        {
            return None;
        }
        let now = Utc::now();
        let schedule = selector::schedule(&data.calendar.events, Local::now().date_naive());
        let recording_event = data
            .recording
            .meeting()
            .and_then(|m| m.calendar_event_id.clone());
        let revision = data.revision;
        let preparation = data.meeting_preparation.clone();
        let recording = data.recording.is_active();
        let upcoming: Vec<CalendarEvent> =
            schedule.iter().filter(|e| e.end > now).cloned().collect();
        let primary = selector::primary(&schedule, now, recording_event.as_deref()).cloned();
        self.request_preparation(primary, revision, cx);
        let next = upcoming.first()?.clone();

        let lb = cx.lb().clone();
        let mut content = v_flex().gap(px(10.)).child(self.meeting_row(
            &next,
            now,
            recording,
            recording_event.as_deref(),
            cx,
        ));
        if let Some(preparation) = preparation
            .filter(|p| p.event_id == next.external_id && p.evidence.has_preparation_context())
        {
            let open = self.upcoming.preparation_open;
            content = content
                .child(disclosure(
                    "today-preparation-toggle",
                    lokalbot_i18n::tr("Preparation context"),
                    open,
                    cx.listener(|this, _, _, cx| {
                        this.upcoming.preparation_open = !this.upcoming.preparation_open;
                        cx.notify();
                    }),
                    cx,
                ))
                .when(open, |this| {
                    this.child(self.preparation_card(&preparation, cx))
                });
        }
        if upcoming.len() > 1 {
            content = content.child(self.later_today(&upcoming[1..], now, cx));
        }
        Some(
            v_flex()
                .gap(px(8.))
                .child(
                    h_flex()
                        .gap(px(6.))
                        .items_center()
                        .child(ui::icon(Ico::Calendar, px(15.), lb.text_secondary))
                        .child(ui::section_title(lokalbot_i18n::tr("Next meeting"), cx)),
                )
                .child(ui::panel(cx).child(content))
                .into_any_element(),
        )
    }

    /// Asks the engine for the primary meeting's evidence when it changes,
    /// when the library changes, and every few minutes.
    fn request_preparation(
        &mut self,
        primary: Option<CalendarEvent>,
        revision: u64,
        cx: &mut Context<Self>,
    ) {
        let Some(primary) = primary else {
            self.upcoming.requested = None;
            return;
        };
        let fresh = self
            .upcoming
            .requested
            .as_ref()
            .is_some_and(|(id, seen, at)| {
                *id == primary.external_id
                    && *seen == revision
                    && at.elapsed() < PREPARATION_REFRESH
            });
        if fresh {
            return;
        }
        self.upcoming.requested = Some((primary.external_id.clone(), revision, Instant::now()));
        let data = self.data.clone();
        cx.defer(move |cx| {
            data.update(cx, |data, cx| {
                data.request(
                    AppEvent::PrepareMeeting {
                        event: Box::new(primary),
                        generate: false,
                    },
                    cx,
                )
            })
        });
    }

    fn meeting_row(
        &self,
        event: &CalendarEvent,
        now: DateTime<Utc>,
        recording: bool,
        recording_event: Option<&str>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let mut row = h_flex()
            .gap(px(12.))
            .items_center()
            .flex_wrap()
            .child(
                div()
                    .w(px(118.))
                    .flex_none()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(time_range(event)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w(px(160.))
                    .gap(px(2.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(event.title.clone()),
                    )
                    .when_some(selector::participant_label(event), |this, people| {
                        this.child(
                            div()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(people),
                        )
                    }),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(if event.end < now {
                        lb.text_tertiary
                    } else {
                        lb.text_secondary
                    })
                    .child(status_label(event, now)),
            );
        // A solo event without a link may not be a call at all; the user can
        // still record from Record Now.
        if event.end >= now && selector::kind(event) == UpcomingKind::Meeting {
            let id = event.external_id.clone();
            if let Some(url) = event.meeting_url.clone() {
                row = row.child(
                    Button::new(SharedString::from(format!("today-meeting-join-{id}")))
                        .primary()
                        .small()
                        .icon(Icon::new(Ico::Video))
                        .label(lokalbot_i18n::tr("Join"))
                        .on_click(move |_, _, cx| cx.open_url(&url)),
                );
            }
            let current = recording_event == Some(id.as_str());
            let data = self.data.clone();
            let target = event.clone();
            row = row.child(
                Button::new(SharedString::from(format!("today-meeting-record-{id}")))
                    .outline()
                    .small()
                    .icon(Icon::new(Ico::CircleDot))
                    .label(if current {
                        lokalbot_i18n::tr("Recording")
                    } else {
                        lokalbot_i18n::tr("Record")
                    })
                    .disabled(recording)
                    .on_click(move |_, _, cx| {
                        let event = Box::new(target.clone());
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::RecordCalendarEvent(event), cx)
                        })
                    }),
            );
        }
        div()
            .px(px(12.))
            .py(px(8.))
            .rounded(px(9.))
            .bg(lb.group_stroke.opacity(0.25))
            .child(row)
            .into_any_element()
    }

    fn later_today(
        &self,
        events: &[CalendarEvent],
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let show_all = self.upcoming.show_all_later;
        let visible = if show_all {
            events.len()
        } else {
            events.len().min(INLINE_LIMIT)
        };
        let mut list = v_flex().gap(px(6.)).px(px(12.)).pt(px(4.)).child(
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr("Later today")),
        );
        for event in &events[..visible] {
            list = list.child(
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(
                        div()
                            .w(px(118.))
                            .flex_none()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(time_range(event)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(event.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(status_label(event, now)),
                    ),
            );
        }
        if events.len() > INLINE_LIMIT {
            let label: SharedString = if show_all {
                lokalbot_i18n::tr("Show fewer").into()
            } else {
                lokalbot_i18n::format(
                    "{count} more today",
                    &[("count", (events.len() - INLINE_LIMIT).to_string())],
                )
                .into()
            };
            list = list.child(
                div()
                    .id("today-meetings-later-more")
                    .cursor_pointer()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.accent_text)
                    .child(label)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.upcoming.show_all_later = !this.upcoming.show_all_later;
                        cx.notify();
                    })),
            );
        }
        list.into_any_element()
    }

    fn preparation_card(
        &self,
        preparation: &MeetingPreparation,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let evidence = &preparation.evidence;
        let generated = preparation.brief.is_some();
        let brief = preparation
            .brief
            .clone()
            .unwrap_or_else(|| evidence.fallback_brief());
        let header_action: AnyElement = if preparation.generating {
            h_flex()
                .gap(px(6.))
                .items_center()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(gpui_kit::component::spinner::Spinner::new().small())
                .child(lokalbot_i18n::tr("Preparing…"))
                .into_any_element()
        } else {
            let data = self.data.clone();
            let event = evidence.event.clone();
            Button::new("today-upcoming-generate")
                .ghost()
                .small()
                .icon(Icon::new(if generated {
                    Ico::RotateCcw
                } else {
                    Ico::Sparkles
                }))
                .label(if generated {
                    lokalbot_i18n::tr("Refresh")
                } else {
                    lokalbot_i18n::tr("Generate brief")
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
        };
        let mut card = v_flex()
            .gap(px(12.))
            .p(px(14.))
            .rounded(px(10.))
            .bg(lb.group_stroke.opacity(0.4))
            .border_1()
            .border_color(lb.accent_text.opacity(0.18))
            .child(
                v_flex()
                    .gap(px(6.))
                    .child(
                        h_flex()
                            .items_center()
                            .gap(px(8.))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(lokalbot_i18n::tr("Brief")),
                            )
                            .child(header_action),
                    )
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(brief)),
                    )
                    .when_some(preparation.error.clone(), |this, error| {
                        this.child(
                            h_flex()
                                .gap(px(6.))
                                .items_center()
                                .text_size(ty::CAPTION)
                                .text_color(lb.attention_text)
                                .child(ui::icon(Ico::TriangleAlert, px(12.), lb.attention_text))
                                .child(translated_error(&error)),
                        )
                    }),
            );

        let mut primary = v_flex().gap(px(9.));
        if let Some(decision) = evidence.decisions.first() {
            primary = primary.child(self.reference_row(
                lokalbot_i18n::tr("Prior decision"),
                Ico::BadgeCheck,
                decision,
                cx,
            ));
        }
        if let Some(commitment) = evidence.commitments.first() {
            primary = primary.child(self.reference_row(
                lokalbot_i18n::tr("Commitment to revisit"),
                Ico::ListChecks,
                commitment,
                cx,
            ));
        }
        if let Some(project) = evidence.projects.first() {
            primary = primary.child(project_row(project, cx));
        }
        if evidence.decisions.is_empty()
            && evidence.commitments.is_empty()
            && evidence.projects.is_empty()
            && let Some(related) = evidence.related_meetings.first()
        {
            let data = self.data.clone();
            let id = related.meeting_id;
            primary = primary.child(
                context_row(
                    SharedString::from(format!("today-upcoming-recent-{id}")),
                    lokalbot_i18n::tr("Recent context"),
                    Ico::Clock,
                    related.title.clone(),
                    abbreviated_date(related.started_at),
                    cx,
                )
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.open_meeting(id, Default::default(), None, cx)
                    })
                }),
            );
        }
        card = card.child(div().h(px(1.)).bg(lb.separator)).child(primary);

        let extra = evidence.decisions.len().saturating_sub(1)
            + evidence.commitments.len().saturating_sub(1)
            + evidence.projects.len().saturating_sub(1);
        if extra > 0 {
            let open = self.upcoming.more_open;
            card = card.child(disclosure(
                "today-upcoming-more",
                lokalbot_i18n::tr("More context"),
                open,
                cx.listener(|this, _, _, cx| {
                    this.upcoming.more_open = !this.upcoming.more_open;
                    cx.notify();
                }),
                cx,
            ));
            if open {
                let mut more = v_flex().gap(px(9.)).pl(px(4.));
                for decision in evidence.decisions.iter().skip(1) {
                    more = more.child(self.reference_row(
                        lokalbot_i18n::tr("Decision"),
                        Ico::BadgeCheck,
                        decision,
                        cx,
                    ));
                }
                for commitment in evidence.commitments.iter().skip(1) {
                    more = more.child(self.reference_row(
                        lokalbot_i18n::tr("Commitment"),
                        Ico::ListChecks,
                        commitment,
                        cx,
                    ));
                }
                for project in evidence.projects.iter().skip(1) {
                    more = more.child(project_row(project, cx));
                }
                card = card.child(more);
            }
        }
        card.into_any_element()
    }

    fn reference_row(
        &self,
        title: &'static str,
        icon_name: Ico,
        reference: &UpcomingReference,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut metadata = Vec::new();
        if let Some(owner) = reference
            .owner
            .as_deref()
            .map(str::trim)
            .filter(|o| !o.is_empty())
        {
            metadata.push(
                if reference.is_for_user || owner.eq_ignore_ascii_case("me") {
                    lokalbot_i18n::tr("You").to_string()
                } else {
                    owner.to_string()
                },
            );
        }
        if let Some(due) = reference.due.as_deref().filter(|d| !d.trim().is_empty()) {
            metadata.push(lokalbot_i18n::format(
                "due {due}",
                &[("due", due.to_string())],
            ));
        }
        if reference.source_meeting_count > 1 {
            metadata.push(lokalbot_i18n::format(
                "{count} meetings",
                &[("count", reference.source_meeting_count.to_string())],
            ));
        }
        let mut source = reference.meeting_title.clone();
        if !metadata.is_empty() {
            source = format!("{source} · {}", metadata.join(" · "));
        }
        let data = self.data.clone();
        let id = reference.meeting_id;
        context_row(
            SharedString::from(format!("today-upcoming-{}", reference.id)),
            title,
            icon_name,
            reference.text.clone(),
            source,
            cx,
        )
        .on_click(move |_, _, cx| {
            data.update(cx, |data, cx| {
                data.open_meeting(id, Default::default(), None, cx)
            })
        })
        .into_any_element()
    }
}

fn project_row(project: &UpcomingProject, cx: &mut Context<TodayPage>) -> AnyElement {
    let active = chrono::NaiveDate::parse_from_str(&project.last_active_day, "%Y-%m-%d")
        .map(|day| {
            day.format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string()
        })
        .unwrap_or_else(|_| project.last_active_day.clone());
    context_row(
        SharedString::from(format!("today-upcoming-project-{}", project.name)),
        lokalbot_i18n::tr("Project context"),
        Ico::Briefcase,
        format!("{} — {}", project.name, project.status),
        lokalbot_i18n::format("Active {date}", &[("date", active)]),
        cx,
    )
    .into_any_element()
}

fn context_row(
    id: SharedString,
    title: &'static str,
    icon_name: Ico,
    text: String,
    source: String,
    cx: &mut Context<TodayPage>,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let lb = cx.lb().clone();
    div().id(id).cursor_pointer().child(
        h_flex()
            .gap(px(9.))
            .items_start()
            .child(
                div()
                    .pt(px(2.))
                    .child(ui::icon(icon_name, px(15.), lb.accent_text)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(text)),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_tertiary)
                            .child(source),
                    ),
            ),
    )
}

fn disclosure(
    id: &'static str,
    title: &'static str,
    open: bool,
    toggle: impl Fn(&gpui_kit::ClickEvent, &mut gpui_kit::Window, &mut gpui_kit::App) + 'static,
    cx: &mut Context<TodayPage>,
) -> AnyElement {
    let lb = cx.lb().clone();
    div()
        .id(id)
        .cursor_pointer()
        .child(
            h_flex()
                .gap(px(6.))
                .items_center()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(ui::icon(
                    if open {
                        Ico::ChevronDown
                    } else {
                        Ico::ChevronRight
                    },
                    px(13.),
                    lb.text_secondary,
                ))
                .child(title),
        )
        .on_click(toggle)
        .into_any_element()
}

/// `10:00 AM–10:30 AM`, local time.
fn time_range(event: &CalendarEvent) -> String {
    format!(
        "{}–{}",
        lokalbot_core::time::clock_time(event.start),
        lokalbot_core::time::clock_time(event.end)
    )
}

/// `UpcomingMeetingPresentation.statusLabel`.
fn status_label(event: &CalendarEvent, now: DateTime<Utc>) -> String {
    match selector::status(event, now) {
        EventStatus::Ended => lokalbot_i18n::tr("Ended").into(),
        EventStatus::InProgress => lokalbot_i18n::tr("In progress").into(),
        EventStatus::StartingNow => lokalbot_i18n::tr("Starting now").into(),
        EventStatus::InMinutes(minutes) => {
            lokalbot_i18n::format("In {minutes} min", &[("minutes", minutes.to_string())])
        }
        EventStatus::InHours { hours, minutes: 0 } => {
            lokalbot_i18n::format("In {hours}h", &[("hours", hours.to_string())])
        }
        EventStatus::InHours { hours, minutes } => lokalbot_i18n::format(
            "In {hours}h {minutes}m",
            &[
                ("hours", hours.to_string()),
                ("minutes", minutes.to_string()),
            ],
        ),
    }
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

fn abbreviated_date(value: DateTime<Utc>) -> String {
    value
        .with_timezone(&Local)
        .format_localized(
            lokalbot_i18n::date_pattern("%b %-d, %Y"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}
