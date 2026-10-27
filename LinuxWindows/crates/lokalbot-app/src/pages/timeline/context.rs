//! Timeline's context panel: the selected work session or meeting
//! (`TimelineContextPanel`, `TimelineMeetingPreview`).

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lokalbot_core::{ActionReference, ActionStatus, Library, Meeting, WorkSession};

use super::{DayModel, Selection, TimelinePage};
use crate::pages::meetings::model as meeting_model;
use crate::pages::today::threads::open_meeting;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, action_row};

/// What the meeting panel shows, loaded in the background.
pub(crate) struct MeetingPreview {
    pub meeting: Meeting,
    pub recap: Option<String>,
    pub actions: Vec<ActionReference>,
    pub decisions: Vec<String>,
}

impl MeetingPreview {
    pub(crate) fn load(library: &Library, meeting: Meeting) -> Self {
        let recap = library
            .summary(&meeting)
            .ok()
            .flatten()
            .as_deref()
            .and_then(meeting_model::recap);
        let actions = library
            .meeting_actions(&meeting)
            .unwrap_or_default()
            .into_iter()
            .filter(|r| r.is_for_user)
            .take(4)
            .collect();
        let decisions = library
            .outcomes(&meeting)
            .ok()
            .flatten()
            .map(|o| {
                o.decision_records
                    .into_iter()
                    .take(4)
                    .map(|d| d.text)
                    .collect()
            })
            .unwrap_or_default();
        Self {
            meeting,
            recap,
            actions,
            decisions,
        }
    }
}

impl TimelinePage {
    pub(super) fn render_context(
        &self,
        model: &DayModel,
        drawer: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let content = match &self.selection {
            Some(Selection::Session(id)) => model
                .activity
                .sessions
                .iter()
                .find(|s| &s.id == id)
                .map(|session| self.render_session(model, session, drawer, cx)),
            Some(Selection::Meeting(_)) => Some(self.render_meeting(drawer, cx)),
            Some(Selection::RawCapture) => Some(self.render_raw_capture(model, drawer, cx)),
            Some(Selection::Moment(id)) => {
                Some(self.render_moment(model.moments.iter().find(|m| m.id == *id), drawer, cx))
            }
            None => None,
        };
        let content = content.unwrap_or_else(|| {
            v_flex()
                .gap(px(14.))
                .child(self.panel_header(Ico::ScanText, lokalbot_i18n::tr("Details").into(), String::new(), drawer, cx))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(cx.lb().text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Select a work session, meeting, or captured moment to review its details."))),
                )
                .into_any_element()
        });
        div()
            .id("timeline-context")
            .size_full()
            .overflow_y_scrollbar()
            .child(div().p(px(if drawer { 16. } else { 24. })).child(content))
            .into_any_element()
    }

    pub(super) fn panel_header(
        &self,
        icon: Ico,
        title: SharedString,
        subtitle: String,
        drawer: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        v_flex()
            .gap(px(10.))
            .child(
                h_flex()
                    .items_center()
                    .child(
                        h_flex()
                            .id("context-back")
                            .gap(px(4.))
                            .items_center()
                            .cursor_pointer()
                            .text_size(ty::BODY)
                            .text_color(lb.accent_text)
                            .hover(|s| s.underline())
                            .child(ui::icon(Ico::ChevronLeft, px(14.), lb.accent_text))
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Day")))
                            .on_click(cx.listener(|this, _, _, cx| this.select(None, cx))),
                    )
                    .child(div().flex_1())
                    .when(drawer, |this| {
                        this.child(
                            Button::new("context-close")
                                .ghost()
                                .icon(Icon::new(Ico::X))
                                .tooltip(lokalbot_i18n::tr("Close context panel"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.drawer_open = false;
                                    this.selection = None;
                                    cx.notify();
                                })),
                        )
                    }),
            )
            .child(
                h_flex()
                    .gap(px(9.))
                    .items_start()
                    .child(
                        div()
                            .pt(px(3.))
                            .child(ui::icon(icon, px(18.), lb.accent_text)),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .line_clamp(2)
                                    .text_size(ty::QUESTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .when(!subtitle.is_empty(), |this| {
                                this.child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(subtitle),
                                )
                            }),
                    ),
            )
            .into_any_element()
    }

    fn render_session(
        &self,
        model: &DayModel,
        session: &WorkSession,
        drawer: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let subtitle = lokalbot_i18n::format(
            "{0}–{1} · {2} active",
            &[
                (
                    "0",
                    lokalbot_core::time::clock_time(session.start).to_string(),
                ),
                (
                    "1",
                    lokalbot_core::time::clock_time(session.end).to_string(),
                ),
                (
                    "2",
                    crate::pages::today::digest::hm(session.active_seconds).to_string(),
                ),
            ],
        );
        let moments: Vec<_> = model
            .moments
            .iter()
            .filter(|m| m.ts >= session.start && m.ts <= session.end)
            .collect();
        let representative: Vec<_> = moments.iter().take(3).collect();
        let evidence = v_flex()
            .gap(px(9.))
            .when(representative.is_empty(), |this| {
                this.child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("No context moments were captured during this session."))),
                )
            })
            .children(representative.iter().map(|moment| {
                let title = if !moment.document_name.is_empty() {
                    moment.document_name.clone()
                } else if !moment.window_title.is_empty() {
                    moment.window_title.clone()
                } else {
                    moment.app.clone()
                };
                let id = moment.id;
                h_flex()
                    .id(("session-moment", id as u64))
                    .gap(px(10.))
                    .items_center()
                    .cursor_pointer()
                    .rounded(metric::ROW_RADIUS)
                    .hover(|s| s.bg(lb.hover))
                    .on_click(cx.listener(move |this, _, _, cx| this.select(Some(Selection::Moment(id)), cx)))
                    .child(ui::icon_tile(Ico::ScanText, lb.app_color(&moment.app), px(32.)))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(div().truncate().text_size(ty::BODY).text_color(lb.text).child(title))
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(format!("{} · {}", moment.app, lokalbot_core::time::clock_time(moment.ts))),
                            ),
                    )
            }))
            .when(moments.len() > representative.len(), |this| {
                this.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::format("Showing {0} representative scenes from {1}. Browse raw capture for every scene.", &[("0", format!("{}", representative.len())), ("1", format!("{}", moments.len()))]))))
            });

        // Window titles with the blocks behind them, most observed first.
        let blocks: Vec<&lokalbot_core::ActivityBlock> = model
            .activity
            .blocks
            .iter()
            .filter(|b| session.block_ids.contains(&b.id))
            .collect();
        let titles: Vec<(String, Vec<&lokalbot_core::ActivityBlock>, f64)> = session
            .notable_titles
            .iter()
            .map(|title| {
                let matching: Vec<_> = blocks
                    .iter()
                    .copied()
                    .filter(|b| {
                        lokalbot_core::timeline::cleaned_title(&b.title, &b.app).as_deref()
                            == Some(title.as_str())
                    })
                    .collect();
                let observed = lokalbot_core::timeline::merged_duration(&matching);
                (title.clone(), matching, observed)
            })
            .collect();
        let documents = (!titles.is_empty()).then(|| {
            let rows = titles.into_iter().enumerate().map(|(ix, (title, matching, observed))| {
                let expanded = self.expanded_titles.contains(&title);
                let key = title.clone();
                v_flex()
                    .gap(px(6.))
                    .px(px(12.))
                    .py(px(9.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.chip_fill.opacity(0.4))
                    .child(
                        h_flex()
                            .id(("session-title", ix))
                            .gap(px(8.))
                            .items_start()
                            .cursor_pointer()
                            .child(
                                div().pt(px(2.)).child(ui::icon(
                                    if expanded { Ico::ChevronDown } else { Ico::ChevronRight },
                                    px(13.),
                                    lb.text_secondary,
                                )),
                            )
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(3.))
                                    .child(
                                        div()
                                            .line_clamp(2)
                                            .text_size(ty::BODY)
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(lb.text)
                                            .child(title.clone()),
                                    )
                                    .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::format("{duration} observed · Activity entries: {count}", &[("duration", crate::pages::today::digest::hm(observed)), ("count", matching.len().to_string())])))),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !this.expanded_titles.remove(&key) {
                                    this.expanded_titles.insert(key.clone());
                                }
                                cx.notify();
                            })),
                    )
                    .when(expanded, |this| {
                        this.children(matching.iter().map(|block| {
                            v_flex()
                                .pl(px(21.))
                                .gap(px(2.))
                                .child(div().line_clamp(2).text_size(ty::SECONDARY).text_color(lb.text).child(block.title.clone()))
                                .child(div().text_size(ty::CAPTION).text_color(lb.text_secondary).child(format!(
                                    "{} · {}–{}",
                                    block.app,
                                    lokalbot_core::time::clock_time(block.start),
                                    lokalbot_core::time::clock_time(block.end)
                                )))
                        }))
                    })
            });
            context_section(
                Ico::FileText,
                lokalbot_i18n::tr("Documents and windows"),
                v_flex()
                    .gap(px(9.))
                    .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("These are captured window titles. Expand a title to inspect the activity behind it."))))
                    .children(rows),
                cx,
            )
        });

        let details_open = self.session_details_open;
        let apps = session.apps.len();
        let details = v_flex()
            .gap(px(10.))
            .child(
                h_flex()
                    .id("session-details")
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(ui::icon(
                        if details_open {
                            Ico::ChevronDown
                        } else {
                            Ico::ChevronRight
                        },
                        px(13.),
                        lb.text_secondary,
                    ))
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Session details",
                    )))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.session_details_open = !this.session_details_open;
                        cx.notify();
                    })),
            )
            .when(details_open, |this| {
                this.child(
                    v_flex()
                        .gap(px(10.))
                        .p(px(12.))
                        .rounded(metric::GROUP_RADIUS)
                        .bg(lb.app_color(&session.primary_app).opacity(0.10))
                        .child(
                            h_flex()
                                .flex_wrap()
                                .gap(px(8.))
                                .child(ui::stat_chip(
                                    Ico::Clock,
                                    crate::pages::today::digest::hm(session.active_seconds),
                                    lokalbot_i18n::tr("active"),
                                    cx,
                                ))
                                .child(ui::stat_chip(
                                    Ico::LayoutGrid,
                                    lokalbot_i18n::number(apps),
                                    if apps == 1 {
                                        lokalbot_i18n::tr("app")
                                    } else {
                                        lokalbot_i18n::tr("apps")
                                    },
                                    cx,
                                ))
                                .when(session.context_switch_count > 0, |this| {
                                    this.child(ui::stat_chip(
                                        Ico::ArrowRightLeft,
                                        session.context_switch_count.to_string(),
                                        lokalbot_i18n::tr("switches"),
                                        cx,
                                    ))
                                }),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(
                                    session
                                        .apps
                                        .iter()
                                        .take(5)
                                        .cloned()
                                        .collect::<Vec<_>>()
                                        .join(" · "),
                                ),
                        ),
                )
            });
        let title = session.title.clone();
        v_flex()
            .gap(px(16.))
            .child(self.panel_header(
                Ico::Briefcase,
                session.title.clone().into(),
                subtitle,
                drawer,
                cx,
            ))
            .child(context_section(
                Ico::ScanText,
                lokalbot_i18n::tr("Representative evidence"),
                evidence,
                cx,
            ))
            .children(documents)
            .child(details)
            .child(
                h_flex().justify_end().child(
                    ui::controls::bordered_icon(
                        "ask-session",
                        Ico::Sparkles,
                        lokalbot_i18n::tr("Ask about this session"),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.ask_day(
                            lokalbot_i18n::format(
                                "What matters from my work session on {title}?",
                                &[("title", title.to_string())],
                            ),
                            Vec::new(),
                            cx,
                        )
                    })),
                ),
            )
            .into_any_element()
    }

    /// Raw activity blocks by hour, then the day's screen moments.
    fn render_raw_capture(
        &self,
        model: &DayModel,
        drawer: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let mut hours: Vec<(String, Vec<&lokalbot_core::ActivityBlock>)> = Vec::new();
        for block in &model.activity.blocks {
            let hour = block
                .start
                .with_timezone(&chrono::Local)
                .format_localized(
                    lokalbot_i18n::date_pattern("%-I:00 %p"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string();
            match hours.last_mut() {
                Some((label, blocks)) if *label == hour => blocks.push(block),
                _ => hours.push((hour, vec![block])),
            }
        }
        let empty = model.activity.blocks.is_empty() && model.moments.is_empty();
        let activity = (!model.activity.blocks.is_empty()).then(|| {
            context_section(
                Ico::ChartGantt,
                lokalbot_i18n::tr("App activity"),
                v_flex()
                    .gap(px(12.))
                    .children(hours.into_iter().map(|(hour, blocks)| {
                        h_flex()
                            .items_start()
                            .gap(px(10.))
                            .child(
                                div()
                                    .w(px(64.))
                                    .flex_none()
                                    .pt(px(2.))
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(hour),
                            )
                            .child(v_flex().flex_1().min_w_0().gap(px(6.)).children(
                                blocks.into_iter().map(|block| {
                                    let color = lb.app_color(&block.app);
                                    let title = if block.title.trim().is_empty() {
                                        block.app.clone()
                                    } else {
                                        block.title.clone()
                                    };
                                    h_flex()
                                        .gap(px(8.))
                                        .items_start()
                                        .child(
                                            div()
                                                .w(px(4.))
                                                .h(px(34.))
                                                .flex_none()
                                                .rounded(px(2.))
                                                .bg(color.opacity(0.85)),
                                        )
                                        .child(
                                            v_flex()
                                                .flex_1()
                                                .min_w_0()
                                                .gap(px(2.))
                                                .child(
                                                    div()
                                                        .truncate()
                                                        .text_size(ty::BODY)
                                                        .text_color(lb.text)
                                                        .child(title),
                                                )
                                                .child(
                                                    div()
                                                        .truncate()
                                                        .text_size(ty::CAPTION)
                                                        .text_color(lb.text_secondary)
                                                        .child(format!(
                                                            "{} · {}–{} · {}",
                                                            block.app,
                                                            lokalbot_core::time::clock_time(
                                                                block.start
                                                            ),
                                                            lokalbot_core::time::clock_time(
                                                                block.end
                                                            ),
                                                            crate::pages::today::digest::hm(
                                                                block.duration_seconds()
                                                            )
                                                        )),
                                                ),
                                        )
                                }),
                            ))
                    })),
                cx,
            )
        });
        let moments = (!model.moments.is_empty()).then(|| {
            context_section(
                Ico::ScanText,
                lokalbot_i18n::tr("Screen moments"),
                v_flex()
                    .gap(px(9.))
                    .children(model.moments.iter().map(|moment| {
                        let title = if !moment.document_name.is_empty() {
                            moment.document_name.clone()
                        } else if !moment.window_title.is_empty() {
                            moment.window_title.clone()
                        } else {
                            moment.app.clone()
                        };
                        let id = moment.id;
                        h_flex()
                            .id(("raw-moment", id as u64))
                            .gap(px(10.))
                            .items_center()
                            .cursor_pointer()
                            .rounded(metric::ROW_RADIUS)
                            .hover(|s| s.bg(lb.hover))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.select(Some(Selection::Moment(id)), cx)
                            }))
                            .child(ui::icon_tile(
                                if moment.path.is_empty() {
                                    Ico::ScanText
                                } else {
                                    Ico::Camera
                                },
                                lb.app_color(&moment.app),
                                px(28.),
                            ))
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(2.))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(ty::BODY)
                                            .text_color(lb.text)
                                            .child(title),
                                    )
                                    .child(
                                        div()
                                            .text_size(ty::CAPTION)
                                            .text_color(lb.text_secondary)
                                            .child(format!(
                                                "{} · {}",
                                                moment.app,
                                                moment
                                                    .ts
                                                    .with_timezone(&chrono::Local)
                                                    .format_localized(
                                                        lokalbot_i18n::date_pattern("%-I:%M:%S %p"),
                                                        lokalbot_i18n::date_locale()
                                                    )
                                            )),
                                    ),
                            )
                            .when(moment.is_saved, |this| {
                                this.child(ui::icon(Ico::Bookmark, px(14.), lb.attention_text))
                            })
                    })),
                cx,
            )
        });
        v_flex()
            .gap(px(16.))
            .child(self.panel_header(Ico::Activity, lokalbot_i18n::tr("Raw capture").into(), capture_counts(model), drawer, cx))
            .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Individual app activity and retained screen moments. Use this for exact evidence or cleanup."))))
            .when(empty, |this| {
                this.child(ui::empty_state(
                    Ico::Activity,
                    lokalbot_i18n::tr("No raw capture"),
                    lokalbot_i18n::tr("No activity or screen moments were retained for this day."),
                    cx,
                ))
            })
            .children(activity)
            .children(moments)
            .into_any_element()
    }

    fn render_meeting(&self, drawer: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(preview) = self.meeting_preview.as_ref() else {
            return div()
                .child(gpui_kit::component::spinner::Spinner::new())
                .into_any_element();
        };
        let meeting = &preview.meeting;
        let live = meeting.is_live();
        let subtitle = format!(
            "{} · {}",
            meeting_model::date_label(meeting.started_at),
            meeting_model::duration_label(meeting)
        );
        let mut sections: Vec<AnyElement> = Vec::new();
        if live {
            sections.push(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .p(px(12.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.chip_fill.opacity(0.5))
                    .child(ui::status_dot(lb.recording, px(9.)))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.recording_text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Recording in progress",
                            ))),
                    )
                    .into_any_element(),
            );
        }
        if let Some(recap) = preview.recap.clone() {
            sections.push(context_section(
                Ico::FileText,
                lokalbot_i18n::tr("Recap"),
                v_flex().gap(px(6.)).children(
                    meeting_model::recap_points(&recap)
                        .into_iter()
                        .map(|point| div().text_size(ty::BODY).text_color(lb.text).child(point)),
                ),
                cx,
            ));
        }
        if !preview.actions.is_empty() {
            let data = self.data.clone();
            let count = preview.actions.len();
            sections.push(context_section(
                Ico::ListChecks,
                lokalbot_i18n::tr("My actions"),
                v_flex().children(preview.actions.iter().enumerate().map(|(ix, reference)| {
                    let data = data.clone();
                    let (meeting_id, action_id, status) = (
                        reference.meeting_id,
                        reference.action_id.clone(),
                        reference.status,
                    );
                    let done = status == ActionStatus::Done;
                    v_flex()
                        .child(
                            h_flex()
                                .gap(px(9.))
                                .items_start()
                                .py(px(8.))
                                .child(action_row::status_toggle(
                                    ("preview-toggle", ix),
                                    status,
                                    false,
                                    move |_, cx| {
                                        let next = if done {
                                            ActionStatus::Open
                                        } else {
                                            ActionStatus::Done
                                        };
                                        let action_id = action_id.clone();
                                        data.update(cx, |data, cx| {
                                            data.set_action_status(meeting_id, action_id, next, cx)
                                        });
                                    },
                                    cx,
                                ))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .text_size(ty::BODY)
                                        .text_color(if done { lb.text_secondary } else { lb.text })
                                        .when(done, |this| this.line_through())
                                        .child(reference.text.clone()),
                                ),
                        )
                        .when(ix + 1 < count, |this| {
                            this.child(div().h(px(1.)).bg(lb.separator))
                        })
                })),
                cx,
            ));
        }
        if !preview.decisions.is_empty() {
            sections.push(context_section(
                Ico::BadgeCheck,
                lokalbot_i18n::tr("Decisions"),
                v_flex()
                    .gap(px(10.))
                    .children(preview.decisions.iter().map(|decision| {
                        h_flex()
                            .gap(px(8.))
                            .items_start()
                            .child(div().pt(px(2.)).child(ui::icon(
                                Ico::Check,
                                px(14.),
                                lb.accent_text,
                            )))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(decision.clone()),
                            )
                    })),
                cx,
            ));
        }
        if sections.is_empty() && !live {
            sections.push(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "No outcome summary has been extracted for this meeting yet.",
                    )))
                    .into_any_element(),
            );
        }
        let meeting_id = meeting.id;
        let title = meeting.display_title();
        let open_data = self.data.clone();
        v_flex()
            .gap(px(16.))
            .child(self.panel_header(
                Ico::AudioLines,
                meeting.display_title().into(),
                subtitle,
                drawer,
                cx,
            ))
            .children(sections)
            .child(
                h_flex()
                    .gap(px(8.))
                    .justify_end()
                    .child(
                        ui::controls::bordered_icon(
                            "ask-meeting",
                            Ico::Sparkles,
                            lokalbot_i18n::tr("Ask about this meeting"),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.ask_day(
                                lokalbot_i18n::format(
                                    "What matters from {title}?",
                                    &[("title", title.to_string())],
                                ),
                                vec![meeting_id],
                                cx,
                            )
                        })),
                    )
                    .child(
                        Button::new("open-meeting")
                            .primary()
                            .icon(Icon::new(Ico::ArrowUpRight))
                            .label(lokalbot_i18n::tr("Open meeting"))
                            .on_click(move |_, _, cx| {
                                open_meeting(&open_data, meeting_id, None, cx)
                            }),
                    ),
            )
            .into_any_element()
    }
}

/// "12 activity entries · 6 screen moments".
pub(super) fn capture_counts(model: &DayModel) -> String {
    let blocks = model.activity.blocks.len();
    let moments = model.moments.len();
    lokalbot_i18n::format(
        "Activity entries: {blocks} · Screen moments: {moments}",
        &[
            ("blocks", lokalbot_i18n::number(blocks)),
            ("moments", lokalbot_i18n::number(moments)),
        ],
    )
}

/// `TimelineContextSection`: icon + headline over grouped content.
fn context_section(
    icon: Ico,
    title: &'static str,
    content: impl IntoElement,
    cx: &mut Context<TimelinePage>,
) -> AnyElement {
    let lb = cx.lb().clone();
    ui::grouped_surface(cx)
        .p(px(12.))
        .flex()
        .flex_col()
        .gap(px(10.))
        .child(
            h_flex()
                .gap(px(8.))
                .items_center()
                .text_size(ty::SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(ui::icon(icon, px(15.), lb.text))
                .child(title),
        )
        .child(content)
        .into_any_element()
}
