//! Today: what is recording, what needs attention, the day digest and the
//! day's sessions (`TodayView.swift`, `TodaySessionsSection.swift`,
//! `GettingStartedCard.swift`). "Review Actions…" opens the Actions workspace.

mod actions;
pub(crate) mod digest;
pub(crate) mod threads;
mod upcoming;

use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use crate::i18n::h_flex;
use chrono::{Local, NaiveDate};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Pixels, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Task, Window, canvas, div, px,
};
use lokalbot_core::{ActionThread, DayActivity, DayDigest, WorkSession};

use self::actions::ActionsWorkspace;
use crate::pages::Page;
use crate::state::{AppData, AskRequest, RecordingState, Section};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// What Today shows, loaded off the main thread.
struct TodayModel {
    day: NaiveDate,
    activity: DayActivity,
    digest: Option<DayDigest>,
    attention: Vec<ActionThread>,
}

pub struct TodayPage {
    data: Entity<AppData>,
    model: Option<TodayModel>,
    loading: bool,
    load_generation: u64,
    loaded_revision: Option<u64>,
    sessions_expanded: bool,
    expanded_tasks: HashSet<usize>,
    showing_actions: bool,
    /// "Review Actions…" from another page; opened on the next render.
    pending_actions: bool,
    actions: Entity<ActionsWorkspace>,
    bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// Today's calendar meetings and the next one's preparation.
    upcoming: upcoming::UpcomingState,
    tick: Option<Task<()>>,
    _refresh: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl TodayPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let actions = cx.new(|cx| ActionsWorkspace::new(window, cx));
        let subscriptions = vec![
            cx.observe(&data, |this, _, cx| {
                this.on_data_changed(cx);
                cx.notify();
            }),
            cx.observe(&actions, |_, _, cx| cx.notify()),
            cx.subscribe(&actions, |this, _, _: &actions::BackToToday, cx| {
                this.showing_actions = false;
                cx.notify();
            }),
        ];
        // Today re-anchors after midnight and picks up new activity.
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
            loading: false,
            load_generation: 0,
            loaded_revision: None,
            sessions_expanded: false,
            expanded_tasks: HashSet::new(),
            showing_actions: false,
            pending_actions: false,
            actions,
            bounds: Rc::new(Cell::new(None)),
            upcoming: Default::default(),
            tick: None,
            _refresh: refresh,
            _subscriptions: subscriptions,
        };
        this.on_data_changed(cx);
        this
    }

    fn on_data_changed(&mut self, cx: &mut Context<Self>) {
        if self
            .data
            .update(cx, |data, _| std::mem::take(&mut data.actions_requested))
        {
            self.pending_actions = true;
            cx.notify();
        }
        let data = self.data.read(cx);
        if data.section != Section::Today && self.showing_actions {
            // Leaving Today closes the Actions workspace, as on macOS.
            self.showing_actions = false;
        }
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
        let library = self.data.read(cx).library.clone();
        let day = Local::now().date_naive();
        self.load_generation += 1;
        let generation = self.load_generation;
        self.loading = self.model.is_none();
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
                    let attention = library.needs_attention(None, 3).unwrap_or_else(|err| {
                        log::warn!("needs attention: {err:#}");
                        Vec::new()
                    });
                    TodayModel {
                        day,
                        activity,
                        digest,
                        attention,
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.load_generation == generation {
                    this.model = Some(model);
                    this.loading = false;
                    cx.notify();
                }
            });
        })
        .detach();
    }

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

    pub(crate) fn show_actions(&mut self, show: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.showing_actions = show;
        if show {
            self.actions
                .update(cx, |actions, cx| actions.reload(window, cx));
        }
        cx.notify();
    }

    fn ask_today(&mut self, cx: &mut Context<Self>) {
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question: lokalbot_i18n::tr("What happened today?").into(),
                    meeting_ids: Vec::new(),
                    submit: false,
                },
                cx,
            )
        });
    }

    /// Content width inside the page column, for the task grid.
    fn content_width(&self) -> Pixels {
        let page = self.bounds.get().map(|b| b.size.width).unwrap_or(px(1000.));
        page.min(metric::TODAY_MAX_WIDTH) - metric::DETAIL_PADDING * 2. - px(32.)
    }

    // --------------------------------------------------------------- render

    fn render_now(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        if let RecordingState::Recording {
            meeting, started, ..
        } = &data.recording
        {
            let id = meeting.id;
            let title = meeting.display_title();
            let elapsed = started.elapsed().as_secs_f64();
            let open = self.data.clone();
            let stop = self.data.clone();
            return ui::status_surface(lb.recording, cx)
                .p(metric::PANEL_PADDING)
                .flex()
                .items_center()
                .gap(px(10.))
                .child(ui::status_dot(lb.recording, px(8.)))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(3.))
                        .child(
                            div()
                                .truncate()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "Recording — {title}",
                                    &[("title", title.to_string())],
                                ))),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.recording_text)
                                .child(lokalbot_core::time::timer(elapsed)),
                        ),
                )
                .child(
                    ui::controls::bordered("now-live", lokalbot_i18n::tr("Live Meeting Notes"))
                        .on_click(move |_, _, cx| {
                            open.update(cx, |data, cx| {
                                data.open_meeting(id, Default::default(), None, cx)
                            })
                        }),
                )
                .child(
                    ui::controls::bordered("now-stop", lokalbot_i18n::tr("Stop Recording"))
                        .text_color(lb.recording_text)
                        .on_click(move |_, _, cx| {
                            stop.update(cx, |data, cx| data.stop_recording(cx))
                        }),
                )
                .into_any_element();
        }
        let start = self.data.clone();
        ui::panel(cx)
            .flex()
            .items_center()
            .gap(px(10.))
            .child(ui::icon(Ico::AudioLines, px(16.), lb.text_secondary))
            .child(
                div()
                    .flex_1()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Nothing recording right now",
                    ))),
            )
            .child(
                ui::controls::bordered("now-record", lokalbot_i18n::tr("Record Now")).on_click(
                    move |_, _, cx| start.update(cx, |data, cx| data.start_recording(cx)),
                ),
            )
            .into_any_element()
    }

    fn render_attention(&self, model: &TodayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        if model.attention.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let count = model.attention.len();
        let rows = model.attention.iter().enumerate().map(|(ix, thread)| {
            v_flex()
                .child(threads::thread_row(
                    format!("today-thread-{ix}").into(),
                    thread,
                    false,
                    &self.data,
                    cx,
                ))
                .when(ix + 1 < count, |this| {
                    this.child(div().h(px(1.)).bg(lb.separator))
                })
        });
        let content = v_flex().children(rows).child(
            h_flex().pt(px(8.)).gap(px(8.)).child(
                ui::controls::bordered("review-actions", lokalbot_i18n::tr("Review Actions…"))
                    .on_click(
                        cx.listener(|this, _, window, cx| this.show_actions(true, window, cx)),
                    ),
            ),
        );
        Some(ui::section(lokalbot_i18n::tr("Needs Attention"), content, cx).into_any_element())
    }

    fn render_digest(&self, model: &TodayModel, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let header = h_flex()
            .gap(px(12.))
            .items_center()
            .flex_wrap()
            .child(
                h_flex()
                    .flex_1()
                    .gap(px(10.))
                    .items_center()
                    .child(ui::icon(Ico::Sparkles, px(16.), lb.accent_text))
                    .child(
                        div()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Day Digest"))),
                    ),
            )
            .child(digest::digest_controls(
                model.day,
                model.digest.as_ref(),
                false,
                false,
                &self.data,
                cx,
            ));

        let page = cx.entity().downgrade();
        let toggle: digest::TaskToggle = Rc::new(move |ix, _, cx| {
            let _ = page.update(cx, |this, cx| {
                if !this.expanded_tasks.remove(&ix) {
                    this.expanded_tasks.insert(ix);
                }
                cx.notify();
            });
        });
        let sessions: Vec<&WorkSession> = model
            .activity
            .sessions
            .iter()
            .filter(|s| !s.is_meeting())
            .collect();
        let panel = ui::grouped_surface(cx)
            .p(px(16.))
            .flex()
            .flex_col()
            .gap(px(18.))
            .child(digest::day_overview(
                lokalbot_i18n::tr("Day So Far"),
                &model.activity,
                false,
                false,
                cx,
            ))
            .child(ui::divider(cx))
            .child(digest::digest_card(
                model.digest.as_ref(),
                self.content_width(),
                &self.expanded_tasks,
                toggle,
                cx,
            ))
            .when(!sessions.is_empty(), |this| {
                this.child(ui::divider(cx))
                    .child(self.render_sessions(model.day, &sessions, cx))
            });
        v_flex()
            .gap(px(16.))
            .child(header)
            .child(panel)
            .into_any_element()
    }

    fn render_sessions(
        &self,
        day: NaiveDate,
        sessions: &[&WorkSession],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let total = sessions.len();
        let shown = if self.sessions_expanded {
            total
        } else {
            total.min(4)
        };
        let open_timeline = self.data.clone();
        let cards = sessions
            .iter()
            .take(shown)
            .enumerate()
            .map(|(ix, session)| {
                let data = self.data.clone();
                let session_id = session.id.clone();
                let hover = lb.hover;
                h_flex()
                    .id(("today-session", ix))
                    .items_start()
                    .gap(px(12.))
                    .p(px(12.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.group_fill)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover))
                    .child(div().pt(px(2.)).child(ui::icon(
                        Ico::Briefcase,
                        px(16.),
                        lb.accent_text,
                    )))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(5.))
                            .child(
                                div()
                                    .line_clamp(2)
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(session.title.clone()),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(session.apps.join(" · ")),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_none()
                            .items_end()
                            .gap(px(5.))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(lokalbot_core::time::clock_time(session.start))
                            .child(crate::pages::today::digest::hm(session.active_seconds)),
                    )
                    .on_click(move |_, _, cx| {
                        let session_id = session_id.clone();
                        data.update(cx, |data, cx| data.open_timeline(day, Some(session_id), cx))
                    })
            });
        let more = (total > 4).then(|| {
            let label = if self.sessions_expanded {
                lokalbot_i18n::tr("Show Fewer Sessions").to_string()
            } else {
                lokalbot_i18n::format(
                    "Show All {total} Sessions",
                    &[("total", format!("{}", total))],
                )
            };
            ui::link(
                "sessions-more",
                label,
                {
                    let page = cx.entity().downgrade();
                    move |_, cx| {
                        let _ = page.update(cx, |this, cx| {
                            this.sessions_expanded = !this.sessions_expanded;
                            cx.notify();
                        });
                    }
                },
                cx,
            )
            .text_size(ty::SECONDARY)
        });
        v_flex()
            .gap(px(12.))
            .child(
                h_flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Sessions"))),
                    )
                    .child(
                        ui::link(
                            "sessions-timeline",
                            lokalbot_i18n::tr("Open Timeline"),
                            move |_, cx| {
                                open_timeline
                                    .update(cx, |data, cx| data.navigate(Section::Timeline, cx))
                            },
                            cx,
                        )
                        .text_size(ty::SECONDARY),
                    ),
            )
            .children(cards)
            .children(more)
            .into_any_element()
    }

    fn render_getting_started(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let data = self.data.read(cx);
        let own_meetings = data.meetings.iter().filter(|m| m.is_own_work()).count();
        if data.settings.getting_started_dismissed || own_meetings >= 3 {
            return None;
        }
        let lb = cx.lb().clone();
        let tracking = data.settings.tracking_enabled;
        let transcription_ready = data.models.transcription_ready;
        let has_meeting = own_meetings > 0;
        let has_sample = data.sample_meeting().is_some();
        let pillar = |icon: Ico, title: &'static str, text: &'static str| {
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(4.))
                .p(px(12.))
                .rounded(metric::GROUP_RADIUS)
                .bg(lb.chip_fill.opacity(0.6))
                .child(
                    h_flex()
                        .gap(px(6.))
                        .items_center()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(ui::icon(icon, px(15.), lb.accent_text))
                        .child(title),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(text),
                )
        };
        let step = |done: bool, content: AnyElement| {
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(if done {
                    ui::icon(Ico::CircleCheck, px(16.), lb.success_text).into_any_element()
                } else {
                    ui::icon(Ico::Circle, px(16.), lb.accent_text).into_any_element()
                })
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(content),
                )
        };
        let models = self.data.clone();
        let sample = self.data.clone();
        let tracking_data = self.data.clone();
        let dictation = self.data.clone();
        let dismiss = self.data.clone();
        let link_step = |id: &'static str,
                         label: &'static str,
                         rest: &'static str,
                         on_click: Box<dyn Fn(&mut App)>| {
            h_flex()
                .flex_wrap()
                .gap(px(5.))
                .child(ui::link(id, label, move |_, cx| on_click(cx), cx))
                .child(div().text_color(lb.text_secondary).child(rest))
                .into_any_element()
        };
        Some(
            ui::panel(cx)
                .max_w(px(560.))
                .p(px(28.))
                .flex()
                .flex_col()
                .gap(px(18.))
                .child(
                    h_flex()
                        .gap(px(14.))
                        .items_start()
                        .child(ui::icon_tile(Ico::AudioLines, lb.accent_text, px(48.)))
                        .child(
                            v_flex()
                                .flex_1()
                                .gap(px(4.))
                                .child(
                                    div()
                                        .text_size(ty::QUESTION)
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Welcome to LokalBot"))),
                                )
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text_secondary)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Your private AI memory for work — on-device by default."))),
                                ),
                        )
                        .child(
                            Button::new("getting-started-dismiss")
                                .ghost()
                                .icon(Icon::new(Ico::X))
                                .tooltip(lokalbot_i18n::tr("Dismiss"))
                                .on_click(move |_, _, cx| {
                                    dismiss.update(cx, |data, cx| {
                                        data.update_settings(|s| s.getting_started_dismissed = true, cx)
                                    })
                                }),
                        ),
                )
                .child(
                    v_flex()
                        .gap(px(10.))
                        .child(
                            h_flex()
                                .gap(px(10.))
                                .child(pillar(Ico::AudioLines, lokalbot_i18n::tr("Remember"), lokalbot_i18n::tr("Capture meetings and the day context you choose.")))
                                .child(pillar(Ico::TextSearch, lokalbot_i18n::tr("Ask"), lokalbot_i18n::tr("Search, ask, and open the evidence behind an answer."))),
                        )
                        .child(
                            h_flex()
                                .gap(px(10.))
                                .child(pillar(Ico::Keyboard, lokalbot_i18n::tr("Write"), lokalbot_i18n::tr("Dictate text into the app where you're working.")))
                                .child(pillar(
                                    Ico::SquareArrowOutUpRight,
                                    lokalbot_i18n::tr("Act"),
                                    lokalbot_i18n::tr("Create inspectable drafts and exports, and share meetings with your coding agent."),
                                )),
                        ),
                )
                .child(div().text_size(ty::SECTION).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Get started"))))
                .child(
                    v_flex()
                        .gap(px(10.))
                        .child(step(
                            transcription_ready,
                            if transcription_ready {
                                div().child(crate::ui::text::paragraph(lokalbot_i18n::tr("Transcription model ready — recaps run entirely on-device."))).into_any_element()
                            } else {
                                link_step(
                                    "gs-download",
                                    lokalbot_i18n::tr("Download the transcription model"),
                                    lokalbot_i18n::tr("one-time — or it downloads with your first recap."),
                                    Box::new(move |cx| {
                                        models.update(cx, |data, cx| data.request(crate::state::AppEvent::PrepareModels, cx))
                                    }),
                                )
                            },
                        ))
                        .child(step(
                            has_sample,
                            link_step(
                                "gs-sample",
                                if has_sample {
                                    lokalbot_i18n::tr("Open the sample meeting")
                                } else {
                                    lokalbot_i18n::tr("Try a sample meeting")
                                },
                                lokalbot_i18n::tr("— a made-up call, to try Ask before you record."),
                                Box::new(move |cx| sample.update(cx, |data, cx| data.try_sample(cx))),
                            ),
                        ))
                        .child(step(has_meeting, div().child(crate::ui::text::paragraph(lokalbot_i18n::tr("Record a meeting — it appears in the list automatically."))).into_any_element()))
                        .child(step(
                            tracking,
                            link_step(
                                "gs-tracking",
                                lokalbot_i18n::tr("Turn on day tracking"),
                                lokalbot_i18n::tr("to see where your time goes."),
                                Box::new(move |cx| {
                                    tracking_data.update(cx, |data, cx| data.update_settings(|s| s.tracking_enabled = true, cx))
                                }),
                            ),
                        ))
                        .child(step(
                            false,
                            link_step(
                                "gs-dictation",
                                lokalbot_i18n::tr("Try dictation"),
                                lokalbot_i18n::tr("— speak, and LokalBot types it in the app you're using."),
                                Box::new(move |cx| {
                                    dictation.update(cx, |data, cx| {
                                        data.open_settings(crate::state::SettingsCategory::Dictation, cx)
                                    })
                                }),
                            ),
                        )),
                )
                .into_any_element(),
        )
    }
}

impl Page for TodayPage {
    fn title(&self, _cx: &App) -> SharedString {
        if self.showing_actions {
            lokalbot_i18n::tr("Actions").into()
        } else {
            lokalbot_i18n::tr("Today").into()
        }
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.showing_actions {
            return None;
        }
        let data = self.data.clone();
        Some(
            h_flex()
                .gap_1()
                .child(
                    ui::controls::toolbar_icon(
                        "today-ask",
                        Ico::TextSearch,
                        lokalbot_i18n::tr("Ask About Today"),
                    )
                    .on_click(cx.listener(|this, _, _, cx| this.ask_today(cx))),
                )
                .child(
                    ui::controls::toolbar_icon(
                        "today-timeline",
                        Ico::ChartGantt,
                        lokalbot_i18n::tr("Open Timeline"),
                    )
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| data.navigate(Section::Timeline, cx))
                    }),
                )
                .into_any_element(),
        )
    }
}

impl Render for TodayPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if std::mem::take(&mut self.pending_actions) {
            self.show_actions(true, window, cx);
        }
        let recording = self.data.read(cx).recording.is_active();
        self.sync_tick(recording, cx);
        if self.showing_actions {
            return div()
                .size_full()
                .child(self.actions.clone())
                .into_any_element();
        }
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

        let date = Local::now()
            .format_localized(
                lokalbot_i18n::date_pattern("%A, %B %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string();
        let mut sections: Vec<AnyElement> = vec![
            div()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(date)
                .into_any_element(),
            self.render_now(cx),
        ];
        sections.extend(self.render_upcoming(cx));
        match self.model.take() {
            Some(model) => {
                sections.extend(self.render_attention(&model, cx));
                sections.push(self.render_digest(&model, cx));
                self.model = Some(model);
            }
            None => sections.push(
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
            ),
        }
        sections.extend(self.render_getting_started(cx));

        div()
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
                                .max_w(metric::TODAY_MAX_WIDTH)
                                .px(metric::DETAIL_PADDING)
                                .pt(px(8.))
                                .pb(metric::DETAIL_PADDING)
                                .gap(metric::SECTION_SPACING)
                                .children(sections),
                        ),
                    ),
            )
            .into_any_element()
    }
}
