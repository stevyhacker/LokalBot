//! Timeline: one day at a time. The day column leads with what needs action
//! (the digest's state, open actions, then the digest by task status), a
//! rail holds the day's totals and its sessions on one time line, and a
//! context panel shows the selected session, meeting or screen moment
//! (`CaptureView.swift`, `CaptureDetailView.swift`,
//! `ScreenMomentDetailView.swift`).

mod context;
mod moment;

use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;

use crate::i18n::h_flex;
use chrono::{DateTime, Days, Local, NaiveDate, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::{Calendar, CalendarEvent, CalendarState, Date, Matcher};
use gpui_kit::component::input::InputState;
use gpui_kit::component::popover::Popover;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Div, Entity, FontWeight, Hsla,
    InteractiveElement as _, IntoElement, MouseButton, ParentElement as _, Pixels, Render,
    RenderImage, SharedString, StatefulInteractiveElement as _, Styled as _, Subscription, Window,
    canvas, div, px,
};
use lokalbot_core::timeline::RailRow;
use lokalbot_core::{ActionThread, DayActivity, DayDigest, Meeting, ScreenMoment, WorkSession};
use uuid::Uuid;

use self::context::MeetingPreview;
use crate::pages::Page;
use crate::pages::today::digest;
use crate::pages::today::threads;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, Palette, metric, ty};
use crate::ui::{self, Ico};

/// Below this page width, selections open in a drawer over a single column.
const DRAWER_BREAKPOINT: f32 = 820.;
const DAY_MIN_WIDTH: f32 = 440.;
/// Needs Attention rows shown; the heading counts them all.
const ATTENTION_ROWS: usize = 3;

/// One day's data, loaded off the main thread.
pub(crate) struct DayModel {
    pub activity: DayActivity,
    pub digest: Option<DayDigest>,
    pub attention: Vec<ActionThread>,
    pub meetings: Vec<Meeting>,
    pub moments: Vec<ScreenMoment>,
}

#[derive(Clone, PartialEq)]
pub(crate) enum Selection {
    Session(String),
    Meeting(Uuid),
    /// "Browse Raw Capture": every activity block and screen moment.
    RawCapture,
    /// One screen moment (`ScreenMoment::id`).
    Moment(i64),
}

pub struct TimelinePage {
    data: Entity<AppData>,
    day: NaiveDate,
    model: Option<Rc<DayModel>>,
    load_generation: u64,
    loaded_key: Option<(u64, NaiveDate)>,
    selection: Option<Selection>,
    drawer_open: bool,
    meeting_preview: Option<MeetingPreview>,
    expanded_tasks: HashSet<usize>,
    expanded_titles: HashSet<String>,
    session_details_open: bool,
    calendar: Entity<CalendarState>,
    calendar_open: bool,
    bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// The selected moment's decrypted image.
    moment_image: Option<moment::MomentImage>,
    /// Images no longer shown; their textures are freed on the next frame.
    released_images: Vec<Arc<RenderImage>>,
    moment_text_expanded: bool,
    moment_details_open: bool,
    moment_note: Entity<InputState>,
    /// The moment whose saved note is in `moment_note`.
    moment_note_for: Option<i64>,
    _subscriptions: Vec<Subscription>,
}

impl TimelinePage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let today = Local::now().date_naive();
        let calendar = cx.new(|cx| {
            let mut state = CalendarState::new(window, cx).disabled_matcher(Matcher::custom(
                move |date: &NaiveDate| *date > Local::now().date_naive(),
            ));
            state.set_date(today, window, cx);
            state
        });
        let subscriptions = vec![
            cx.observe(&data, |this, _, cx| {
                this.on_data_changed(cx);
                cx.notify();
            }),
            cx.subscribe(&calendar, |this, _, event: &CalendarEvent, cx| {
                let CalendarEvent::Selected(Date::Single(Some(day))) = event else {
                    return;
                };
                this.calendar_open = false;
                this.set_day(*day, cx);
            }),
        ];
        let moment_note = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Why does this moment matter?",
                window,
                cx,
            ))
        });
        let mut this = Self {
            data,
            day: today,
            model: None,
            load_generation: 0,
            loaded_key: None,
            selection: None,
            drawer_open: false,
            meeting_preview: None,
            expanded_tasks: HashSet::new(),
            expanded_titles: HashSet::new(),
            session_details_open: false,
            calendar,
            calendar_open: false,
            bounds: Rc::new(Cell::new(None)),
            moment_image: None,
            released_images: Vec::new(),
            moment_text_expanded: false,
            moment_details_open: false,
            moment_note,
            moment_note_for: None,
            _subscriptions: subscriptions,
        };
        this.on_data_changed(cx);
        this
    }

    fn on_data_changed(&mut self, cx: &mut Context<Self>) {
        let focus = self.data.update(cx, |data, _| data.timeline_focus.take());
        if let Some(focus) = focus {
            self.set_day(focus.day, cx);
            if let Some(session) = focus.session_id {
                self.select(Some(Selection::Session(session)), cx);
            }
            if let Some(moment) = focus.moment_id {
                self.selection = None;
                self.select(Some(Selection::Moment(moment)), cx);
            }
        }
        let data = self.data.read(cx);
        if !data.meetings_loaded {
            return;
        }
        let key = (data.revision, self.day);
        if self.loaded_key != Some(key) {
            self.loaded_key = Some(key);
            self.reload(cx);
        }
    }

    fn set_day(&mut self, day: NaiveDate, cx: &mut Context<Self>) {
        let day = day.min(Local::now().date_naive());
        if day == self.day {
            return;
        }
        self.day = day;
        self.selection = None;
        self.meeting_preview = None;
        self.drawer_open = false;
        self.expanded_tasks.clear();
        self.loaded_key = None;
        self.reload(cx);
        cx.notify();
    }

    pub(crate) fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        let day = self.day;
        self.load_generation += 1;
        let generation = self.load_generation;
        cx.spawn(async move |this, cx| {
            let model = cx
                .background_spawn(async move {
                    let (start, end) = lokalbot_core::time::local_day_bounds(day);
                    DayModel {
                        activity: library.day_activity(day).unwrap_or_else(|err| {
                            log::warn!("day activity for {day}: {err:#}");
                            DayActivity::default()
                        }),
                        digest: library.day_digest(day).unwrap_or_default(),
                        attention: library
                            .needs_attention(Some(day), usize::MAX)
                            .unwrap_or_default(),
                        meetings: library
                            .list_own_meetings()
                            .unwrap_or_default()
                            .into_iter()
                            .filter(|m| lokalbot_core::time::local_day(m.started_at) == day)
                            .collect(),
                        moments: library.screen_moments(start, end).unwrap_or_default(),
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.load_generation == generation {
                    this.model = Some(Rc::new(model));
                    this.refresh_meeting_preview(cx);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(crate) fn select(&mut self, selection: Option<Selection>, cx: &mut Context<Self>) {
        let toggled_off = selection.is_some() && selection == self.selection;
        self.selection = if toggled_off { None } else { selection };
        if !matches!(self.selection, Some(Selection::Moment(_))) {
            self.release_moment_image();
        }
        self.moment_text_expanded = false;
        self.moment_details_open = false;
        self.drawer_open = self.selection.is_some();
        self.expanded_titles.clear();
        self.session_details_open = false;
        self.meeting_preview = None;
        self.refresh_meeting_preview(cx);
        cx.notify();
    }

    fn refresh_meeting_preview(&mut self, cx: &mut Context<Self>) {
        let Some(Selection::Meeting(id)) = self.selection.clone() else {
            return;
        };
        let Some(meeting) = self
            .model
            .as_ref()
            .and_then(|m| m.meetings.iter().find(|m| m.id == id).cloned())
        else {
            return;
        };
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let preview = cx
                .background_spawn(async move { MeetingPreview::load(&library, meeting) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.selection == Some(Selection::Meeting(preview.meeting.id)) {
                    this.meeting_preview = Some(preview);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn page_width(&self) -> Pixels {
        self.bounds.get().map(|b| b.size.width).unwrap_or(px(1056.))
    }

    fn uses_drawer(&self) -> bool {
        self.page_width() < px(DRAWER_BREAKPOINT)
    }

    fn rail_width(&self) -> Pixels {
        let width = f32::from(self.page_width());
        (width - DAY_MIN_WIDTH).clamp(260., 360.).min(640.).into()
    }

    // --------------------------------------------------------------- header

    fn render_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let is_today = self.day >= today;
        let compact = self.page_width() < px(1000.);
        let day_label = self
            .day
            .format_localized(
                lokalbot_i18n::date_pattern("%a, %b %-d"),
                lokalbot_i18n::date_locale(),
            )
            .to_string();
        let calendar = self.calendar.clone();
        let page = cx.entity().downgrade();
        let date_button = Popover::new("timeline-calendar")
            .open(self.calendar_open)
            .on_open_change(move |open, _, cx| {
                let _ = page.update(cx, |this, cx| {
                    this.calendar_open = *open;
                    cx.notify();
                });
            })
            .trigger(ui::controls::bordered_icon(
                "timeline-day",
                Ico::Calendar,
                day_label,
            ))
            .content(move |_, _, _| {
                div().p(px(4.)).child(
                    Calendar::new(&calendar).first_day_of_week(lokalbot_i18n::first_weekday()),
                )
            });
        // On today the jump back has nowhere to go, so it reads as a label.
        let today_control: AnyElement = if is_today {
            div()
                .pl(px(2.))
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr("Today"))
                .into_any_element()
        } else {
            ui::controls::bordered("timeline-today", lokalbot_i18n::tr("Today"))
                .on_click(cx.listener(|this, _, _, cx| this.set_day(Local::now().date_naive(), cx)))
                .into_any_element()
        };
        let controls = h_flex()
            .gap(px(7.))
            .items_center()
            .child(
                Button::new("timeline-previous")
                    .outline()
                    .icon(Icon::new(Ico::ChevronLeft))
                    .tooltip(lokalbot_i18n::tr("Previous day"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        let day = this.day - Days::new(1);
                        this.set_day(day, cx)
                    })),
            )
            .child(date_button)
            .child(
                Button::new("timeline-next")
                    .outline()
                    .icon(Icon::new(Ico::ChevronRight))
                    .tooltip(lokalbot_i18n::tr("Next day"))
                    .disabled(is_today)
                    .on_click(cx.listener(|this, _, _, cx| {
                        let day = this.day + Days::new(1);
                        this.set_day(day, cx)
                    })),
            )
            .child(today_control);
        let digest_controls = digest::digest_controls(
            self.day,
            self.model.as_ref().and_then(|m| m.digest.as_ref()),
            true,
            true,
            &self.data,
            cx,
        );
        let header = if compact {
            v_flex()
                .gap(px(8.))
                .child(controls)
                .child(digest_controls)
                .into_any_element()
        } else {
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(controls)
                .child(div().flex_1())
                .child(digest_controls)
                .into_any_element()
        };
        v_flex()
            .flex_none()
            .child(div().px(px(16.)).py(px(12.)).child(header))
            .child(div().h(px(1.)).bg(lb.separator))
            .into_any_element()
    }

    // ------------------------------------------------------------------ day

    /// What needs action first: the digest's state, Needs Attention, then
    /// the digest by task status. Narrow layouts add the rail below.
    fn render_day_column(
        &self,
        model: &DayModel,
        include_rail: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let page = cx.entity().downgrade();
        let toggle: digest::TaskToggle = Rc::new(move |ix, _, cx| {
            let _ = page.update(cx, |this, cx| {
                if !this.expanded_tasks.remove(&ix) {
                    this.expanded_tasks.insert(ix);
                }
                cx.notify();
            });
        });
        let status = self.render_digest_status(model, cx);
        let attention = self.render_attention(model, cx);
        let digest = model
            .digest
            .as_ref()
            .map(|digest| digest::timeline_digest(digest, &self.expanded_tasks, toggle, cx));
        div()
            .id("timeline-day")
            .size_full()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .px(px(32.))
                    .py(px(24.))
                    .gap(metric::SECTION_SPACING)
                    .children(status)
                    .children(attention)
                    .children(digest)
                    .when(include_rail, |this| {
                        this.child(ui::divider(cx))
                            .child(self.render_rail_content(model, false, cx))
                    }),
            )
            .into_any_element()
    }

    /// The digest's state in one line: an invitation before the first
    /// digest, progress while one is written, and an Update button once
    /// activity has arrived since the last one. A current digest needs none.
    fn render_digest_status(&self, model: &DayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let busy = self.data.read(cx).digest_running == Some(self.day);
        let strip = || {
            h_flex()
                .w_full()
                .min_h(px(40.))
                .gap(px(10.))
                .items_center()
                .pl(px(12.))
                .pr(px(8.))
                .py(px(7.))
                .rounded(metric::GROUP_RADIUS)
                .bg(lb.accent_text.opacity(0.08))
                .text_size(ty::BODY)
                .text_color(lb.text)
        };
        if busy {
            let message = if model.digest.is_none() {
                lokalbot_i18n::tr("Writing this day's digest…")
            } else {
                lokalbot_i18n::tr("Updating the digest with new activity…")
            };
            return Some(
                strip()
                    .child(Spinner::new().xsmall().color(lb.accent_text))
                    .child(crate::ui::text::paragraph(message))
                    .into_any_element(),
            );
        }
        let Some(digest) = model.digest.as_ref() else {
            return Some(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Your digest brings together this day's meetings and captured activity.",
                    )))
                    .into_any_element(),
            );
        };
        if !digest.is_stale {
            return None;
        }
        let message = match digest::digest_updated_at(digest) {
            Some(at) => lokalbot_i18n::format(
                "New activity since this digest was written at {0}.",
                &[("0", lokalbot_core::time::clock_time(at))],
            ),
            None => lokalbot_i18n::tr("New activity since this digest was written.").to_string(),
        };
        let data = self.data.clone();
        let day = self.day;
        Some(
            strip()
                .child(ui::icon(Ico::RefreshCw, px(14.), lb.accent_text))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(crate::ui::text::paragraph(message)),
                )
                .child(
                    Button::new("timeline-update-digest")
                        .primary()
                        .label(lokalbot_i18n::tr("Update Digest"))
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| {
                                data.request(AppEvent::RegenerateDigest(day), cx)
                            })
                        }),
                )
                .into_any_element(),
        )
    }

    /// Needs Attention as rows on the page, with Review Actions beside the
    /// heading. Nothing to act on means no section at all.
    fn render_attention(&self, model: &DayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        if model.attention.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let shown = &model.attention[..model.attention.len().min(ATTENTION_ROWS)];
        let rows = shown.iter().enumerate().map(|(ix, thread)| {
            v_flex()
                .child(div().py(px(6.)).child(threads::thread_row(
                    format!("timeline-thread-{ix}").into(),
                    thread,
                    false,
                    &self.data,
                    cx,
                )))
                .when(ix + 1 < shown.len(), |this| {
                    this.child(div().h(px(1.)).bg(lb.separator))
                })
        });
        let data = self.data.clone();
        Some(
            v_flex()
                .gap(px(2.))
                .child(
                    h_flex()
                        .pb(px(4.))
                        .gap(px(8.))
                        .items_baseline()
                        .child(digest::counted_heading(
                            lokalbot_i18n::tr("Needs Attention"),
                            model.attention.len(),
                            cx,
                        ))
                        .child(div().flex_1())
                        .child(div().text_size(ty::SECONDARY).child(ui::link(
                            "timeline-review-actions",
                            lokalbot_i18n::tr("Review Actions…"),
                            move |_, cx| data.update(cx, |data, cx| data.open_actions(cx)),
                            cx,
                        ))),
                )
                .children(rows)
                .into_any_element(),
        )
    }

    // ----------------------------------------------------------------- rail

    /// The day's totals above its sessions, so they lead the list. `in_rail`
    /// is false when narrow layouts place this under the digest.
    fn render_rail_content(
        &self,
        model: &DayModel,
        in_rail: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tracking = self.data.read(cx).settings.tracking_enabled;
        let nothing = model.activity.blocks.is_empty()
            && model.meetings.is_empty()
            && model.moments.is_empty();
        if nothing {
            return ui::empty_state(
                Ico::Clock,
                lokalbot_i18n::tr("No activity recorded"),
                if tracking {
                    lokalbot_i18n::tr(
                        "Blocks appear as you use your PC (sampled every 5 s, idle-aware).",
                    )
                } else {
                    lokalbot_i18n::tr("Day tracking is off — enable it in Settings.")
                },
                cx,
            )
            .into_any_element();
        }
        v_flex()
            .gap(metric::SECTION_SPACING)
            .children(self.render_day_totals(model, cx))
            .child(self.render_sessions(model, in_rail, cx))
            .into_any_element()
    }

    /// Tracked time as the one large number, the day's counts beneath it,
    /// and the split by app.
    fn render_day_totals(&self, model: &DayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let activity = &model.activity;
        let shares = digest::app_shares(activity);
        if shares.is_empty() && activity.meeting_count == 0 {
            return None;
        }
        let work_sessions = activity.sessions.iter().filter(|s| !s.is_meeting()).count();
        let mut counts = vec![lokalbot_i18n::count(work_sessions, "work session")];
        if activity.meeting_count > 0 {
            counts.push(lokalbot_i18n::count(activity.meeting_count, "meeting"));
        }
        counts.push(lokalbot_i18n::count(digest::app_count(activity), "app"));
        let segments: Vec<(Hsla, f32)> = shares
            .iter()
            .map(|share| (digest::share_color(share, cx), share.seconds as f32))
            .collect();
        // Two columns, each app's time flush right so the numbers line up.
        let legend = v_flex().gap(px(6.)).children(shares.chunks(2).map(|pair| {
            h_flex()
                .gap(px(20.))
                .children(pair.iter().map(|share| {
                    h_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(7.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .child(ui::status_dot(digest::share_color(share, cx), px(7.)))
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .text_color(lb.text)
                                .child(share.label.clone()),
                        )
                        .child(div().flex_1().min_w(px(6.)))
                        .child(
                            div()
                                .flex_none()
                                .text_color(lb.text_secondary)
                                .child(digest::hm(share.seconds)),
                        )
                }))
                .when(pair.len() == 1, |this| this.child(div().flex_1()))
        }));
        Some(
            v_flex()
                .gap(px(12.))
                .child(
                    v_flex()
                        .gap(px(2.))
                        .child(
                            h_flex()
                                .gap(px(6.))
                                .items_baseline()
                                .child(
                                    div()
                                        .text_size(px(24.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.text)
                                        .child(digest::hm(activity.tracked_seconds)),
                                )
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text_secondary)
                                        .child(lokalbot_i18n::tr("tracked")),
                                ),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.supporting)
                                .child(counts.join(" · ")),
                        ),
                )
                .when(!shares.is_empty(), |this| {
                    this.child(ui::proportion_bar(&segments, cx)).child(legend)
                })
                .into_any_element(),
        )
    }

    /// Work sessions and meetings in order on one time line, with long
    /// stretches of no activity marked, followed by Browse Raw Capture.
    fn render_sessions(
        &self,
        model: &DayModel,
        in_rail: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let sessions = &model.activity.sessions;
        let rows = lokalbot_core::timeline::rail_rows(
            sessions,
            lokalbot_core::timeline::AWAY_MINIMUM_GAP_SECONDS,
        );
        let metrics = RailMetrics::new(if in_rail {
            lb.window.blend(rail_background(&lb))
        } else {
            lb.window
        });
        let list: AnyElement = if rows.is_empty() {
            ui::empty_state(
                Ico::Layers,
                lokalbot_i18n::tr("No meaningful sessions"),
                lokalbot_i18n::tr(
                    "Only system activity or raw context was captured. You can still inspect it below.",
                ),
                cx,
            )
            .into_any_element()
        } else {
            let rows: Vec<AnyElement> = rows
                .iter()
                .map(|row| match row {
                    RailRow::Session(ix) => {
                        let session = &sessions[*ix];
                        if session.is_meeting() {
                            self.render_meeting_row(*ix, session, &metrics, cx)
                        } else {
                            self.render_session_row(*ix, session, &metrics, cx)
                        }
                    }
                    RailRow::Away { start, end } => away_row(*start, *end, &metrics, cx),
                })
                .collect();
            div()
                .relative()
                // One line runs through the dots, so the list reads as a day.
                .child(
                    div()
                        .absolute()
                        .top(px(14.))
                        .bottom(px(14.))
                        .left(px(metrics.dot_center() - 0.75))
                        .w(px(1.5))
                        .bg(lb.text.opacity(0.10)),
                )
                .child(v_flex().children(rows))
                .into_any_element()
        };
        v_flex()
            .gap(px(8.))
            .child(digest::counted_heading(
                lokalbot_i18n::tr("Sessions"),
                sessions.len(),
                cx,
            ))
            .child(list)
            .child(
                div()
                    .pt(px(12.))
                    .child(self.render_raw_capture_row(model, cx)),
            )
            .into_any_element()
    }

    /// The rail's last row, opening raw activity in the context panel.
    fn render_raw_capture_row(&self, model: &DayModel, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = self.selection == Some(Selection::RawCapture);
        h_flex()
            .id("timeline-raw-capture")
            .w_full()
            .px(px(8.))
            .py(px(10.))
            .gap(px(10.))
            .items_center()
            .border_t_1()
            .cursor_pointer()
            .map(|this| {
                if selected {
                    this.border_color(gpui_kit::transparent_black())
                        .rounded(metric::ROW_RADIUS)
                        .bg(lb.accent_text.opacity(0.11))
                } else {
                    this.border_color(lb.separator)
                        .hover(|s| s.bg(lb.text.opacity(0.04)))
                }
            })
            .child(ui::icon(Ico::Activity, px(15.), lb.text_secondary))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Browse Raw Capture",
                            ))),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(context::capture_counts(model)),
                    ),
            )
            .child(ui::icon(Ico::ChevronRight, px(13.), lb.text_tertiary))
            .on_click(cx.listener(|this, _, _, cx| this.select(Some(Selection::RawCapture), cx)))
            .into_any_element()
    }

    /// A work session: start time, a dot in its app's color on the day's
    /// line, its title and active time.
    fn render_session_row(
        &self,
        ix: usize,
        session: &WorkSession,
        metrics: &RailMetrics,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = self.selection == Some(Selection::Session(session.id.clone()));
        let selection = Selection::Session(session.id.clone());
        h_flex()
            .id(("timeline-session", ix))
            .w_full()
            .gap(px(RAIL_SPACING))
            .items_center()
            .py(px(6.))
            .pr(px(8.))
            .rounded(metric::ROW_RADIUS)
            .border_1()
            .cursor_pointer()
            .map(|this| {
                if selected {
                    this.bg(lb.accent_text.opacity(0.11))
                        .border_color(lb.accent_text.opacity(0.8))
                } else {
                    this.border_color(gpui_kit::transparent_black())
                        .hover(|s| s.bg(lb.text.opacity(0.04)))
                }
            })
            .child(metrics.time(session.start, None, cx))
            .child(metrics.dot(lb.app_color(&session.primary_app)))
            // A title that only lists apps stays quieter than one that names
            // what was open.
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(13.))
                    .map(|this| {
                        if session.title_names_apps {
                            this.text_color(lb.supporting)
                        } else {
                            this.font_weight(FontWeight::MEDIUM).text_color(lb.text)
                        }
                    })
                    .child(session.title.clone()),
            )
            .child(
                div()
                    .flex_none()
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(digest::hm(session.active_seconds)),
            )
            .on_click(cx.listener(move |this, _, _, cx| this.select(Some(selection.clone()), cx)))
            .into_any_element()
    }

    /// The one tinted row: meetings are first-class events in the day.
    fn render_meeting_row(
        &self,
        ix: usize,
        session: &WorkSession,
        metrics: &RailMetrics,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(meeting) = session.meeting_id else {
            return self.render_session_row(ix, session, metrics, cx);
        };
        let selected = self.selection == Some(Selection::Meeting(meeting));
        let live = self
            .data
            .read(cx)
            .recording
            .meeting()
            .is_some_and(|m| m.id == meeting);
        let tint = if live {
            lb.recording_text
        } else {
            lb.accent_text
        };
        h_flex()
            .id(("timeline-session", ix))
            .w_full()
            .gap(px(RAIL_SPACING))
            .items_center()
            .py(px(3.))
            .cursor_pointer()
            .child(metrics.time(session.start, Some(tint), cx))
            .child(metrics.dot(if live { lb.recording } else { lb.accent_text }))
            .child(
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(7.))
                    .items_center()
                    .px(px(8.))
                    .py(px(6.))
                    .rounded(metric::ROW_RADIUS)
                    .bg(lb.accent_text.opacity(if selected { 0.16 } else { 0.07 }))
                    .border_1()
                    .border_color(lb.accent_text.opacity(if selected { 0.85 } else { 0.22 }))
                    .child(ui::icon(Ico::AudioLines, px(12.), lb.accent_text))
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(session.title.clone()),
                    )
                    .child(
                        div()
                            .flex_none()
                            .text_size(ty::CAPTION)
                            .text_color(tint)
                            .child(if live {
                                lokalbot_i18n::tr("Recording")
                            } else {
                                lokalbot_i18n::tr("Meeting")
                            }),
                    )
                    .child(div().flex_1().min_w(px(4.)))
                    .child(
                        div()
                            .flex_none()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.accent_text)
                            .child(digest::hm(session.duration_seconds())),
                    ),
            )
            .on_click(
                cx.listener(move |this, _, _, cx| {
                    this.select(Some(Selection::Meeting(meeting)), cx)
                }),
            )
            .into_any_element()
    }

    /// Loads the selected moment's image and note once the day has loaded.
    fn sync_selected_moment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Selection::Moment(id)) = self.selection else {
            return;
        };
        let Some(moment) = self
            .model
            .as_ref()
            .and_then(|model| model.moments.iter().find(|m| m.id == id).cloned())
        else {
            return;
        };
        self.load_moment_image(&moment, cx);
        if self.moment_note_for != Some(id) {
            self.moment_note_for = Some(id);
            let note = moment.saved_note.unwrap_or_default();
            self.moment_note
                .update(cx, |input, cx| input.set_value(note, window, cx));
        }
    }

    fn ask_day(&self, question: String, meeting_ids: Vec<Uuid>, cx: &mut Context<Self>) {
        self.data.update(cx, |data, cx| {
            data.ask(
                crate::state::AskRequest {
                    question,
                    meeting_ids,
                    submit: false,
                },
                cx,
            )
        });
    }
}

impl Page for TimelinePage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Timeline").into()
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (paused, screen_context) = {
            let data = self.data.read(cx);
            (
                data.day_memory_paused,
                data.settings.tracking_enabled
                    && data.settings.screen_context_capture_mode
                        != lokalbot_core::ScreenContextMode::ActivityOnly,
            )
        };
        let data = self.data.clone();
        let capture_data = self.data.clone();
        Some(
            h_flex()
                .gap_1()
                .when(screen_context && !paused, |this| {
                    this.child(
                        ui::controls::toolbar_icon(
                            "timeline-capture",
                            Ico::Camera,
                            lokalbot_i18n::tr(
                                "Capture Screen Now: captures the next window you switch to",
                            ),
                        )
                        .on_click(move |_, _, cx| {
                            capture_data
                                .update(cx, |data, cx| data.request(AppEvent::CaptureScreenNow, cx))
                        }),
                    )
                })
                .child(
                    ui::controls::toolbar_icon(
                        "timeline-pause",
                        if paused { Ico::Play } else { Ico::Pause },
                        if paused {
                            lokalbot_i18n::tr("Resume day memory")
                        } else {
                            lokalbot_i18n::tr("Pause day memory")
                        },
                    )
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::SetDayMemoryPaused(!paused), cx)
                        })
                    }),
                )
                .child(
                    ui::controls::toolbar_icon(
                        "timeline-refresh",
                        Ico::RefreshCw,
                        lokalbot_i18n::tr("Reload the selected day's local activity"),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                )
                .into_any_element(),
        )
    }
}

impl Render for TimelinePage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        for image in std::mem::take(&mut self.released_images) {
            cx.drop_image(image, Some(window));
        }
        self.sync_selected_moment(window, cx);
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

        let header = self.render_header(cx);
        let body: AnyElement = match self.model.clone() {
            None => v_flex()
                .flex_1()
                .items_center()
                .justify_center()
                .child(gpui_kit::component::spinner::Spinner::new())
                .into_any_element(),
            Some(model) if self.uses_drawer() => {
                let day = self.render_day_column(&model, true, cx);
                let drawer = (self.drawer_open && self.selection.is_some()).then(|| {
                    let width = (self.page_width() - px(72.)).max(px(320.)).min(px(520.));
                    let panel = self.render_context(&model, true, window, cx);
                    div()
                        .absolute()
                        .inset_0()
                        .child(
                            div()
                                .id("timeline-backdrop")
                                .absolute()
                                .inset_0()
                                .bg(gpui_kit::black().opacity(0.16))
                                .on_mouse_down(
                                    MouseButton::Left,
                                    cx.listener(|this, _, _, cx| {
                                        this.drawer_open = false;
                                        this.selection = None;
                                        cx.notify();
                                    }),
                                ),
                        )
                        .child(
                            div()
                                .absolute()
                                .top_0()
                                .bottom_0()
                                .right_0()
                                .w(width)
                                .bg(lb.elevated)
                                .border_l_1()
                                .border_color(lb.separator)
                                .shadow_lg()
                                .occlude()
                                .child(panel),
                        )
                });
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .child(day)
                    .children(drawer)
                    .into_any_element()
            }
            Some(model) => {
                let left = if self.selection.is_some() {
                    self.render_context(&model, false, window, cx)
                } else {
                    self.render_day_column(&model, false, cx)
                };
                h_flex()
                    .flex_1()
                    .min_h_0()
                    .child(div().flex_1().min_w(px(DAY_MIN_WIDTH)).h_full().child(left))
                    .child(
                        div()
                            .id("timeline-rail")
                            .w(self.rail_width())
                            .flex_none()
                            .h_full()
                            .bg(rail_background(&lb))
                            .border_l_1()
                            .border_color(lb.separator)
                            .overflow_y_scrollbar()
                            .child(
                                div()
                                    .p(px(16.))
                                    .child(self.render_rail_content(&model, true, cx)),
                            ),
                    )
                    .into_any_element()
            }
        };
        v_flex()
            .relative()
            .size_full()
            .child(measure)
            .child(header)
            .child(body)
    }
}

// ------------------------------------------------------------ rail parts

/// The rail's tint over the window.
fn rail_background(lb: &Palette) -> Hsla {
    lb.sidebar.opacity(if lb.dark { 0.6 } else { 0.55 })
}

const RAIL_SPACING: f32 = 8.;
const RAIL_DOT_COLUMN: f32 = 12.;

/// Column widths of a rail row. The time column follows the clock: "18:45"
/// needs less room than "10:40 AM".
struct RailMetrics {
    time_width: f32,
    /// The background behind the rail, ringing each dot where it crosses
    /// the day's line.
    ring: Hsla,
}

impl RailMetrics {
    fn new(ring: Hsla) -> Self {
        let twelve_hour = lokalbot_i18n::date_pattern("%-I:%M %p").contains("%p");
        Self {
            time_width: if twelve_hour { 58. } else { 38. },
            ring,
        }
    }

    fn dot_center(&self) -> f32 {
        self.time_width + RAIL_SPACING + RAIL_DOT_COLUMN / 2.
    }

    /// A start time, emphasized in `tint` for meetings.
    fn time(&self, at: DateTime<Utc>, tint: Option<Hsla>, cx: &App) -> Div {
        let lb = cx.lb();
        h_flex()
            .w(px(self.time_width))
            .flex_none()
            .justify_end()
            .text_size(ty::CAPTION)
            .whitespace_nowrap()
            .map(|this| match tint {
                Some(tint) => this.font_weight(FontWeight::SEMIBOLD).text_color(tint),
                None => this.text_color(lb.text_secondary),
            })
            .child(lokalbot_core::time::clock_time(at))
    }

    fn dot(&self, color: Hsla) -> Div {
        div()
            .w(px(RAIL_DOT_COLUMN))
            .flex_none()
            .flex()
            .justify_center()
            .child(
                div()
                    .size(px(13.))
                    .flex_none()
                    .rounded_full()
                    .bg(self.ring)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(ui::status_dot(color, px(9.))),
            )
    }
}

/// A stretch with nothing recorded between two rows.
fn away_row(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    metrics: &RailMetrics,
    cx: &App,
) -> AnyElement {
    let seconds = (end - start).num_seconds().max(0) as f64;
    h_flex()
        .gap(px(RAIL_SPACING))
        .py(px(4.))
        .child(
            div()
                .flex_none()
                .w(px(metrics.time_width + RAIL_SPACING + RAIL_DOT_COLUMN)),
        )
        .child(
            div()
                .text_size(ty::CAPTION)
                .text_color(cx.lb().text_tertiary)
                .child(lokalbot_i18n::format(
                    "Away {0}",
                    &[("0", digest::hm(seconds))],
                )),
        )
        .into_any_element()
}
