//! Today (`TodayView.swift`): what is live, what is next, and what needs you.
//! A card leads only while it matters (the recording in progress, a meeting
//! within the hour); the rest is the day's panels (Needs attention, Meetings
//! today, So far today, Yesterday), side by side when the page has room, and
//! Get started on the first days. Sessions, the digest's tasks and its menu
//! are on Timeline; planning the open actions is on Actions.

pub(crate) mod brief;
pub(crate) mod digest;
mod getting_started;
mod live;
pub(crate) mod model;
mod panels;
mod upcoming;

use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Disableable as _, Icon, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Div, Entity, Hsla, InteractiveElement as _,
    IntoElement, ParentElement as _, Pixels, Render, SharedString, Styled as _, Subscription, Task,
    Window, canvas, div, px,
};
use lokalbot_core::calendar::CalendarEvent;
use lokalbot_core::calendar::upcoming as selector;
use lokalbot_core::{ActionThread, DayActivity, DayDigest, Meeting};
use lokalbot_engine::CalendarStatus;
use uuid::Uuid;

use crate::i18n::h_flex;
use crate::pages::Page;
use crate::state::{AppData, AskRequest};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::section_panel::{page_surface, panel_column, panel_surface};
use crate::ui::{Ico, action_row};
use model::{AttentionSummary, Entry, EntryStatus, PageLayout, columns};

/// The title of the card at the top (`TodayType.cardTitle`, 20 pt on macOS).
const CARD_TITLE: Pixels = px(21.);
/// The next meeting's title while another one is being recorded, and Get
/// started's title (`TodayType.cardTitleCompact`).
const CARD_TITLE_COMPACT: Pixels = ty::QUESTION;
/// The page's padding at its top and bottom.
const PAGE_TOP: Pixels = px(16.);
const PAGE_BOTTOM: Pixels = px(32.);

/// What Today shows, loaded off the main thread.
struct TodayModel {
    day: NaiveDate,
    activity: DayActivity,
    digest: Option<DayDigest>,
    /// The most urgent of the user's open actions, overdue first: at most
    /// `model::ATTENTION_LIMIT`.
    attention: Vec<ActionThread>,
    summary: AttentionSummary,
    /// "Looks done?" suggestions, by thread.
    hints: HashMap<String, lokalbot_core::action_completion::CompletionHint>,
    /// Yesterday's overnight brief.
    brief: brief::BriefModel,
    /// One line per finished recording of today, from its saved summary.
    recaps: HashMap<Uuid, String>,
}

pub struct TodayPage {
    data: Entity<AppData>,
    model: Option<TodayModel>,
    load_generation: u64,
    loaded_revision: Option<u64>,
    /// The page's size, for the column decision.
    bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// The next meeting's card: its preparation and what is open in it.
    upcoming: upcoming::UpcomingState,
    /// A planted demo library never counts days toward the GitHub star.
    seeded_demo_library: bool,
    tick: Option<Task<()>>,
    _refresh: Task<()>,
    _subscriptions: Vec<Subscription>,
}

/// What the page is built from at one moment: the day's meetings, the card
/// at the top and which panels have something to say.
struct Frame {
    now: DateTime<Utc>,
    live: Option<Meeting>,
    next: Option<CalendarEvent>,
    entries: Vec<Entry>,
    calendar_off: bool,
}

impl TodayPage {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let subscriptions = vec![cx.observe(&data, |this, _, cx| {
            this.on_data_changed(cx);
            cx.notify();
        })];
        let seeded_demo_library = lokalbot_core::github_star::is_seeded_demo_library(
            data.read(cx).library.paths().root(),
        );
        // Today re-anchors after midnight, moves the now line and picks up
        // new activity.
        let refresh = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_secs(30))
                    .await;
                if this.update(cx, |this, cx| this.reload(cx)).is_err() {
                    break;
                }
            }
        });
        let mut this = Self {
            data,
            model: None,
            load_generation: 0,
            loaded_revision: None,
            bounds: Rc::new(Cell::new(None)),
            upcoming: Default::default(),
            seeded_demo_library,
            tick: None,
            _refresh: refresh,
            _subscriptions: subscriptions,
        };
        this.on_data_changed(cx);
        this
    }

    fn on_data_changed(&mut self, cx: &mut Context<Self>) {
        let data = self.data.read(cx);
        if !data.meetings_loaded {
            return;
        }
        let revision = data.revision;
        if self.loaded_revision != Some(revision) {
            self.loaded_revision = Some(revision);
            self.reload(cx);
        }
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        self.record_active_day(cx);
        let data = self.data.read(cx);
        let library = data.library.clone();
        let suggest_done = action_row::suggests_completion(&data.settings);
        let day = Local::now().date_naive();
        // Finished recordings of today, for their recap lines.
        let finished: Vec<Meeting> = data
            .meetings
            .iter()
            .filter(|m| {
                m.is_own_work()
                    && m.ended_at.is_some()
                    && lokalbot_core::time::local_day(m.started_at) == day
            })
            .cloned()
            .collect();
        self.load_generation += 1;
        let generation = self.load_generation;
        cx.spawn(async move |this, cx| {
            let model = cx
                .background_spawn(async move {
                    let activity = library.day_activity(day).unwrap_or_else(|err| {
                        log::warn!("day activity for {day}: {err:#}");
                        DayActivity::default()
                    });
                    let digest = library.day_digest(day).unwrap_or_else(|err| {
                        log::warn!("digest for {day}: {err:#}");
                        None
                    });
                    // Every open action of the user's, in attention order, so
                    // the panel can say how many there are and how many are
                    // overdue.
                    let open = library
                        .needs_attention(None, usize::MAX)
                        .unwrap_or_else(|err| {
                            log::warn!("needs attention: {err:#}");
                            Vec::new()
                        });
                    let summary = AttentionSummary::new(&open, model::ATTENTION_LIMIT, day);
                    let attention: Vec<ActionThread> =
                        open.into_iter().take(summary.shown).collect();
                    // Suggestions only, and only from text kept with consent.
                    let hints = if suggest_done {
                        library.action_completion_hints(&attention, Utc::now())
                    } else {
                        Default::default()
                    };
                    let brief = brief::load(&library, day);
                    let recaps = finished
                        .iter()
                        .filter_map(|meeting| {
                            let summary = library.summary(meeting).ok().flatten()?;
                            Some((meeting.id, model::recap_line(&summary)?))
                        })
                        .collect();
                    TodayModel {
                        day,
                        activity,
                        digest,
                        attention,
                        summary,
                        hints,
                        brief,
                        recaps,
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.load_generation == generation {
                    this.model = Some(model);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// Redraws every second while recording, for the timer.
    fn sync_tick(&mut self, recording: bool, cx: &mut Context<Self>) {
        if recording && self.tick.is_none() {
            self.tick = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(Duration::from_secs(1)).await;
                    if this.update(cx, |_, cx| cx.notify()).is_err() {
                        break;
                    }
                }
            }));
        } else if !recording {
            self.tick = None;
        }
    }

    fn ask_today(&mut self, cx: &mut Context<Self>) {
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question: String::new(),
                    meeting_ids: Vec::new(),
                    submit: false,
                    day: Some(Local::now().date_naive()),
                },
                cx,
            )
        });
    }

    /// Counts today once toward the GitHub star prompt's active days, as the
    /// Mac does at launch. The prompt itself is no longer on Today: the
    /// Mac shows "Star on GitHub" in Settings only.
    fn record_active_day(&mut self, cx: &mut Context<Self>) {
        if self.seeded_demo_library {
            return;
        }
        let key = Local::now().date_naive().format("%Y-%m-%d").to_string();
        let due = lokalbot_core::github_star::should_record_day(
            &key,
            &self.data.read(cx).settings.github_star_active_days,
        );
        if due {
            self.data.update(cx, |data, cx| {
                data.update_settings(|s| s.github_star_active_days.push(key), cx)
            });
        }
    }

    /// The meetings, the card and the calendar's state at `now`.
    fn frame(&self, cx: &App) -> Frame {
        let now = Utc::now();
        let data = self.data.read(cx);
        let live = data.recording.meeting().cloned();
        let calendar = &data.calendar;
        let enabled = data.settings.calendar_detection_enabled;
        let events = if enabled && calendar.status == CalendarStatus::Ready {
            selector::schedule(&calendar.events, lokalbot_core::time::local_day(now))
        } else {
            Vec::new()
        };
        // The recording in progress leads, so it is found even before the
        // library lists it.
        let recordings: Vec<&Meeting> = live.iter().chain(data.meetings.iter()).collect();
        let recorded = model::recorded_event_ids(&recordings, &events);
        let next = model::next_meeting(&events, now, &recorded).cloned();
        let entries = model::agenda_entries(&recordings, &events, live.as_ref().map(|m| m.id), now);
        Frame {
            now,
            live,
            next,
            entries,
            // Off in Settings, or no calendar to read yet.
            calendar_off: !enabled
                || matches!(
                    calendar.status,
                    CalendarStatus::Off | CalendarStatus::NoSources
                ),
        }
    }

    /// The page content's width inside its side padding.
    fn content_width(&self, maximum: f32) -> f32 {
        let page = self
            .bounds
            .get()
            .map(|b| f32::from(b.size.width))
            .unwrap_or(1000.);
        page.min(maximum) - f32::from(metric::DETAIL_PADDING) * 2.
    }
}

/// The raised card at the top of Today and around Get started
/// (`todayCardSurface`): the panel surface, tinted for a recording.
fn card_surface(tint: Option<Hsla>, cx: &App) -> Div {
    let lb = cx.lb();
    let surface = panel_surface(cx);
    match tint {
        Some(tint) => surface
            .border_color(lb.status_stroke(tint))
            .child(
                div()
                    .absolute()
                    .inset_0()
                    .rounded(metric::GROUP_RADIUS)
                    .bg(tint.opacity(0.06)),
            )
            .relative(),
        None => surface,
    }
}

/// A meeting's place in the day in words: "In 12 min", "Recording", "Ended"
/// (`TodayMeetingStatusText`).
fn status_text(status: EntryStatus) -> String {
    model::directional(match status {
        EntryStatus::Recording => lokalbot_i18n::tr("Recording").to_string(),
        // A saved recording's row shows its app and length instead.
        EntryStatus::Recorded | EntryStatus::Ended => lokalbot_i18n::tr("Ended").to_string(),
        EntryStatus::InProgress => lokalbot_i18n::tr("In progress").to_string(),
        EntryStatus::StartingNow => lokalbot_i18n::tr("Starting now").to_string(),
        EntryStatus::Upcoming { minutes } if minutes < 60 => model::fill(
            lokalbot_i18n::tr("In %lld min"),
            &[&lokalbot_i18n::number(minutes.max(0) as usize)],
        ),
        EntryStatus::Upcoming { minutes } => {
            let hours = lokalbot_i18n::number((minutes / 60) as usize);
            match minutes % 60 {
                0 => model::fill(lokalbot_i18n::tr("In %lldh"), &[&hours]),
                rest => model::fill(
                    lokalbot_i18n::tr("In %lldh %lldm"),
                    &[&hours, &lokalbot_i18n::number(rest as usize)],
                ),
            }
        }
    })
}

/// The red dot of Record buttons (`circle.fill` in the recording colour).
fn record_dot(cx: &App) -> Div {
    div()
        .flex_none()
        .size(px(10.))
        .rounded_full()
        .bg(cx.lb().recording)
}

/// A bordered button with the red dot and "Record".
fn record_button(id: impl Into<gpui_kit::ElementId>, cx: &App) -> Button {
    Button::new(id).secondary().child(
        h_flex()
            .gap(px(6.))
            .items_center()
            .child(record_dot(cx))
            .child(lokalbot_i18n::tr("Record")),
    )
}

impl Page for TodayPage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Today").into()
    }

    /// The full date under the title (`navigationSubtitle`).
    fn subtitle(&self, _cx: &App) -> Option<SharedString> {
        Some(
            Local::now()
                .format_localized(
                    lokalbot_i18n::date_pattern("%A, %B %-d, %Y"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string()
                .into(),
        )
    }

    /// Ask About Today and Record. The page has no recording bar: Record
    /// lives here, and the live card holds the only Stop.
    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let data = self.data.clone();
        let recording = self.data.read(cx).recording.is_active();
        Some(
            h_flex()
                .gap_1()
                .child(
                    Button::new("today-ask")
                        .ghost()
                        .icon(Icon::new(Ico::TextSearch))
                        .label(lokalbot_i18n::tr("Ask About Today"))
                        .on_click(cx.listener(|this, _, _, cx| this.ask_today(cx))),
                )
                .child(
                    record_button("today-record", cx)
                        .ghost()
                        .tooltip(lokalbot_i18n::tr("Record Now"))
                        .disabled(recording)
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.start_recording(cx))
                        }),
                )
                .into_any_element(),
        )
    }
}

impl Render for TodayPage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let recording = self.data.read(cx).recording.is_active();
        self.sync_tick(recording, cx);
        let lb = cx.lb().clone();
        let bounds = self.bounds.clone();
        let measure = canvas(
            move |b, window, _| {
                if bounds.get().map(|old| old.size) != Some(b.size) {
                    bounds.set(Some(b));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();

        let frame = self.frame(cx);
        let next = frame.next.clone();
        let revision = self.data.read(cx).revision;
        self.upcoming
            .sync(next.as_ref(), recording, revision, &self.data, cx);

        // The cards on top, then the panels in their columns, then Get
        // started or the placeholder.
        let mut cards: Vec<AnyElement> = Vec::new();
        cards.extend(self.render_live_card(frame.live.as_ref(), cx));
        if let Some(event) = &next {
            cards.push(self.render_next_meeting(event, frame.now, cx));
        }
        let mut leading: Vec<AnyElement> = Vec::new();
        let mut trailing: Vec<AnyElement> = Vec::new();
        let mut below: Vec<AnyElement> = Vec::new();
        let (has_leading, has_trailing) = match self.model.take() {
            Some(model) => {
                let writing = self.data.read(cx).digest_running == Some(model.day);
                let has_day = !model.activity.blocks.is_empty()
                    || model.digest.is_some()
                    || writing
                    || frame
                        .entries
                        .iter()
                        .any(|e| e.status == EntryStatus::Recorded);
                let has_content = frame.live.is_some()
                    || next.is_some()
                    || !model.attention.is_empty()
                    || !frame.entries.is_empty()
                    || has_day
                    || model.brief.has_report();
                let dismissed = self.data.read(cx).settings.getting_started_dismissed;
                let layout = PageLayout::new(has_content, dismissed);
                let shows_meetings = !frame.entries.is_empty() || frame.calendar_off;
                if layout.shows_sections() {
                    leading.extend(self.render_attention(&model, cx));
                    if shows_meetings {
                        let count = frame.entries.len();
                        let rows = model::agenda_rows(frame.entries.clone(), frame.now);
                        leading.push(self.render_meetings(
                            rows,
                            count,
                            &model.recaps,
                            frame.calendar_off,
                            cx,
                        ));
                    }
                    if has_day {
                        trailing.push(self.render_so_far(&model, writing, cx));
                    }
                    trailing.extend(self.render_yesterday(&model.brief, model.day, cx));
                }
                match layout {
                    PageLayout::Sections {
                        getting_started_below: true,
                    }
                    | PageLayout::GettingStarted => below.push(self.render_getting_started(cx)),
                    PageLayout::Sections { .. } => {}
                    PageLayout::Placeholder => below.push(
                        div()
                            .w_full()
                            .py(px(120.))
                            .flex()
                            .justify_center()
                            .text_size(ty::BODY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Meetings, actions and your day show up here.",
                            )))
                            .into_any_element(),
                    ),
                }
                self.model = Some(model);
                (!leading.is_empty(), !trailing.is_empty())
            }
            None => {
                // Nothing is said about the day before it has loaded once.
                below.push(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(gpui_kit::component::spinner::Spinner::new())
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Loading today…",
                        )))
                        .into_any_element(),
                );
                (false, false)
            }
        };

        let maximum = columns::page_maximum_width(has_leading, has_trailing);
        let scale = self.data.read(cx).settings.text_size.scale();
        let two = columns::count(
            self.content_width(maximum),
            scale,
            has_leading,
            has_trailing,
        ) == 2;
        let panels: Option<AnyElement> = (has_leading || has_trailing).then(|| {
            if two {
                h_flex()
                    .w_full()
                    .items_start()
                    .gap(px(columns::GAP))
                    .child(panel_column().flex_1().min_w_0().children(leading))
                    .child(
                        panel_column()
                            .flex_none()
                            .w(px(columns::trailing_width(scale)))
                            .children(trailing),
                    )
                    .into_any_element()
            } else {
                panel_column()
                    .children(leading)
                    .children(trailing)
                    .into_any_element()
            }
        });
        let cards = (!cards.is_empty()).then(|| {
            v_flex()
                .w_full()
                .gap(px(10.))
                .children(cards)
                .into_any_element()
        });

        page_surface(cx)
            .id("today-scroll")
            .relative()
            .size_full()
            .child(measure)
            .child(
                div()
                    .id("today-content")
                    .size_full()
                    .overflow_y_scrollbar()
                    .child(
                        h_flex().w_full().justify_center().child(
                            v_flex()
                                .w_full()
                                .max_w(px(maximum))
                                .px(metric::DETAIL_PADDING)
                                .pt(PAGE_TOP)
                                .pb(PAGE_BOTTOM)
                                .gap(px(columns::GAP))
                                .children(cards)
                                .children(panels)
                                .children(below),
                        ),
                    ),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_words_follow_the_mac_wording() {
        assert_eq!(status_text(EntryStatus::Recording), "Recording");
        assert_eq!(status_text(EntryStatus::Recorded), "Ended");
        assert_eq!(status_text(EntryStatus::Ended), "Ended");
        assert_eq!(status_text(EntryStatus::InProgress), "In progress");
        assert_eq!(status_text(EntryStatus::StartingNow), "Starting now");
        assert_eq!(
            status_text(EntryStatus::Upcoming { minutes: 12 }),
            "In 12 min"
        );
        assert_eq!(status_text(EntryStatus::Upcoming { minutes: 120 }), "In 2h");
        assert_eq!(
            status_text(EntryStatus::Upcoming { minutes: 192 }),
            "In 3h 12m"
        );
    }
}
