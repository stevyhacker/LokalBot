//! Timeline's main area when something other than the day is chosen in the
//! rail (`TimelineContextPanel`): a work session, a meeting's short preview,
//! all captured activity, or one activity block or screen moment opened from
//! those. Each is a title panel, then one panel per section it has; "‹ Day
//! digest" above goes back.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, ElementId, FontWeight, InteractiveElement as _, IntoElement, ObjectFit,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    StyledImage as _, Window, div, img, px,
};
use lokalbot_core::{Library, Meeting, ScreenMoment, WorkSession};

use super::day_list;
use super::rail::{capture_counts, time_range};
use super::{DayModel, Selection, TimelinePage};
use crate::pages::meetings::model as meeting_model;
use crate::pages::today::digest::hm;
use crate::state::Section;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row::{self, ThreadRowOptions, open_meeting};
use crate::ui::section_panel::{SectionPanel, SectionPanelLead};
use crate::ui::{self, Ico};
use crate::windows::screen_image::ScreenImage;
use lokalbot_i18n::mac;

/// A meeting preview stays short; the meeting has the rest.
const PREVIEW_ROWS: usize = 6;
/// Representative moments a session shows before "Show all".
const REPRESENTATIVE_MOMENTS: usize = 3;

/// What the meeting page shows, loaded in the background.
pub(crate) struct MeetingPreview {
    pub meeting: Meeting,
    pub recap: Option<String>,
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
        let decisions = library
            .outcomes(&meeting)
            .ok()
            .flatten()
            .map(|o| o.decision_records.into_iter().map(|d| d.text).collect())
            .unwrap_or_default();
        Self {
            meeting,
            recap,
            decisions,
        }
    }
}

impl TimelinePage {
    pub(super) fn render_context(
        &self,
        model: &DayModel,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let page: Option<Vec<AnyElement>> = match &self.selection {
            Some(Selection::Session(id)) => model
                .activity
                .sessions
                .iter()
                .find(|s| &s.id == id)
                .map(|session| self.session_page(model, session, cx)),
            Some(Selection::Meeting(_)) => Some(self.meeting_page(model, cx)),
            Some(Selection::RawCapture) => Some(self.raw_capture_page(model, cx)),
            Some(Selection::Moment(id)) => {
                Some(vec![self.render_moment(
                    model.moments.iter().find(|m| m.id == *id),
                    cx,
                )])
            }
            Some(Selection::Block(id)) => model
                .activity
                .blocks
                .iter()
                .find(|b| b.id == *id)
                .map(|block| vec![self.render_block(model, block, cx)]),
            None => None,
        };
        // A selection still loading, or one the day no longer has.
        let page = page.unwrap_or_else(|| {
            vec![
                SectionPanelLead::new("timeline-details")
                    .child(
                        v_flex()
                            .gap(px(10.))
                            .child(page_header(
                                header_icon(Ico::ScanText, cx),
                                lokalbot_i18n::tr("Details").into(),
                                String::new(),
                                cx,
                            ))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(cx.lb().supporting)
                                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                                        "Select a work session, meeting, or captured moment to review its details.",
                                    ))),
                            ),
                    )
                    .into_any_element(),
            ]
        });
        // Pages opened inside another have their own way back.
        let opened_inside = !self.selection_trail.is_empty()
            || matches!(
                self.selection,
                Some(Selection::Moment(_) | Selection::Block(_))
            );
        let mut children = Vec::new();
        if !opened_inside {
            children.push(self.digest_link(cx));
        }
        children.extend(page);
        self.page_column("timeline-context", children, cx)
    }

    /// The way back from a page opened inside another: an activity block to
    /// its session, a moment to its activity. The destination alone is the
    /// visible text.
    pub(super) fn back_link(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let label = match self.selection_trail.last() {
            Some(Selection::Session(_)) => lokalbot_i18n::tr("Work session"),
            Some(Selection::RawCapture) => lokalbot_i18n::tr("All captured activity"),
            Some(Selection::Block(_)) => lokalbot_i18n::tr("Activity"),
            Some(Selection::Meeting(_)) => lokalbot_i18n::tr("Meeting"),
            _ => lokalbot_i18n::tr("Day digest"),
        };
        let back = if lokalbot_i18n::current().rtl {
            Ico::ChevronRight
        } else {
            Ico::ChevronLeft
        };
        h_flex()
            .child(
                h_flex()
                    .id("context-back")
                    .gap(px(4.))
                    .items_center()
                    .cursor_pointer()
                    .text_size(ty::BODY)
                    .text_color(lb.accent_text)
                    .hover(|s| s.underline())
                    .child(ui::icon(back, px(14.), lb.accent_text))
                    .child(label)
                    .on_click(cx.listener(|this, _, _, cx| this.go_back(cx))),
            )
            .into_any_element()
    }

    // ------------------------------------------------------- a session

    fn session_page(
        &self,
        model: &DayModel,
        session: &WorkSession,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let used_apps = day_list::used_apps(session, &model.activity.blocks);
        let outcomes = super::agent_work::outcome_text(
            &lokalbot_core::coding_agents::attribution::Outcomes::of(&session.agent_bursts),
        );
        let text = day_list::work_text(session, &used_apps, outcomes);
        // The dot the session has in the rail and the hour strip.
        let color_key = model
            .list
            .row(&session.id)
            .map(|row| row.color_key.clone())
            .unwrap_or_else(|| {
                Some(
                    day_list::session_project(session)
                        .map_or_else(|| session.primary_app.clone(), str::to_string),
                )
            });
        let color = color_key.map_or(lb.text_tertiary.opacity(0.8), |key| lb.app_color(&key));
        let mut parts: Vec<String> = Vec::new();
        if session.title_names_project
            && let (project, Some(_)) = day_list::project_and_task(session)
        {
            parts.push(project);
        }
        parts.push(time_range(session.start, session.end));
        parts.push(mac("%@ active", &[&hm(session.active_seconds)]));
        let apps = used_apps
            .iter()
            .take(4)
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        if !apps.is_empty() {
            parts.push(apps);
        }
        let mut panels = vec![
            SectionPanelLead::new("timeline-session-lead")
                .child(page_header(
                    div()
                        .pt(px(7.))
                        .child(ui::status_dot(color, px(12.)))
                        .into_any_element(),
                    text.title.into(),
                    parts.join(" · "),
                    cx,
                ))
                .into_any_element(),
        ];

        if let Some(work) = self.render_agent_work(&session.agent_bursts, cx) {
            panels.push(
                SectionPanel::new("timeline-session-agent", lokalbot_i18n::tr("Coding agent"))
                    .section(Section::Agent)
                    .child(div().px(metric::PANEL_INSET).py(px(14.)).child(work))
                    .into_any_element(),
            );
        }

        let moments: Vec<&ScreenMoment> = model
            .moments
            .iter()
            .filter(|m| m.ts >= session.start && m.ts <= session.end)
            .collect();
        let scenes = Self::session_scenes(model, session);
        let representative =
            lokalbot_core::timeline::representative(&scenes, REPRESENTATIVE_MOMENTS);
        let mut moments_panel = SectionPanel::new(
            "timeline-session-moments",
            lokalbot_i18n::tr("Screen moments"),
        )
        .icon(Ico::Image)
        .count(moments.len());
        if moments.len() > representative.len() {
            let label = if self.moments_browsing {
                lokalbot_i18n::tr("Show fewer").to_string()
            } else {
                mac("Show all %lld", &[&lokalbot_i18n::number(moments.len())])
            };
            let page = cx.entity().downgrade();
            moments_panel =
                moments_panel.trailing_link("timeline-browse-moments", label, move |_, cx| {
                    let _ = page.update(cx, |this, cx| {
                        this.moments_browsing = !this.moments_browsing;
                        this.moment_app = None;
                        cx.notify();
                    });
                });
        }
        let body: AnyElement = if moments.is_empty() {
            div()
                .text_size(ty::BODY)
                .text_color(lb.supporting)
                .child(ui::text::paragraph(lokalbot_i18n::tr(
                    "None were kept for this session.",
                )))
                .into_any_element()
        } else if self.moments_browsing {
            self.render_moment_browser(&moments, cx)
        } else {
            h_flex()
                .flex_wrap()
                .gap(px(14.))
                .children(
                    representative
                        .iter()
                        .map(|moment| self.moment_card(moment, cx)),
                )
                .into_any_element()
        };
        panels.push(
            moments_panel
                .child(div().px(metric::PANEL_INSET).py(px(14.)).child(body))
                .into_any_element(),
        );

        if let Some(open) = self.what_was_open(model, session, cx) {
            panels.push(open);
        }

        let title = session.title.clone();
        let session_moments: Vec<ScreenMoment> = moments.iter().map(|m| (*m).clone()).collect();
        panels.push(
            h_flex()
                .child(
                    ui::controls::bordered_icon(
                        "ask-session",
                        Ico::Search,
                        lokalbot_i18n::tr("Ask about this session"),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.ask_session(
                            lokalbot_i18n::format(
                                "What matters from my work session on {title}?",
                                &[("title", title.to_string())],
                            ),
                            session_moments.clone(),
                            cx,
                        )
                    })),
                )
                .into_any_element(),
        );
        panels
    }

    /// A moment as a picture with what it shows and when, opening the moment.
    fn moment_card(&self, moment: &ScreenMoment, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let title = if !moment.window_title.is_empty() {
            moment.window_title.clone()
        } else {
            moment.app.clone()
        };
        let picture: AnyElement = match self.thumbnail(moment, cx) {
            Some(ScreenImage::Ready(image)) => div()
                .size_full()
                .bg(gpui_kit::black().opacity(0.82))
                .child(img(image).size_full().object_fit(ObjectFit::Contain))
                .into_any_element(),
            _ => v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap(px(4.))
                .bg(lb.chip_fill)
                .child(ui::icon(
                    if moment.path.is_empty() {
                        Ico::ScanText
                    } else {
                        Ico::Camera
                    },
                    px(16.),
                    lb.supporting,
                ))
                .into_any_element(),
        };
        let id = moment.id;
        v_flex()
            .id(ElementId::from(("timeline-session-moment", id as u64)))
            .w(px(170.))
            .gap(px(2.))
            .cursor_pointer()
            .child(
                div()
                    .w_full()
                    .h(px(106.))
                    .mb(px(4.))
                    .rounded(px(8.))
                    .overflow_hidden()
                    .child(picture),
            )
            .child(
                div()
                    .truncate()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(title),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(lokalbot_core::time::clock_time(moment.ts)),
            )
            .on_click(cx.listener(move |this, _, _, cx| this.open_child(Selection::Moment(id), cx)))
            .into_any_element()
    }

    /// The windows and documents the session had open, with their time.
    /// Opening a row lists the activity behind the title, which stays
    /// inspectable.
    fn what_was_open(
        &self,
        model: &DayModel,
        session: &WorkSession,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if session.notable_titles.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let blocks: Vec<&lokalbot_core::ActivityBlock> = model
            .activity
            .blocks
            .iter()
            .filter(|b| session.block_ids.contains(&b.id))
            .collect();
        let rows = session
            .notable_titles
            .iter()
            .enumerate()
            .map(|(ix, title)| {
                let matching: Vec<&lokalbot_core::ActivityBlock> = blocks
                    .iter()
                    .copied()
                    .filter(|b| {
                        lokalbot_core::timeline::cleaned_title(&b.title, &b.app).as_deref()
                            == Some(title.as_str())
                    })
                    .collect();
                let observed = lokalbot_core::timeline::merged_duration(&matching);
                let expanded = self.expanded_titles.contains(title);
                let key = title.clone();
                let chevron = if expanded {
                    Ico::ChevronDown
                } else if lokalbot_i18n::current().rtl {
                    Ico::ChevronLeft
                } else {
                    Ico::ChevronRight
                };
                v_flex()
                    .child(
                        h_flex()
                            .id(("timeline-open-title", ix))
                            .gap(px(12.))
                            .items_center()
                            .py(px(9.))
                            .cursor_pointer()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .when(!expanded, |this| this.truncate())
                                    .child(title.clone()),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(hm(observed)),
                            )
                            .child(ui::icon(chevron, px(12.), lb.supporting))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !this.expanded_titles.remove(&key) {
                                    this.expanded_titles.insert(key.clone());
                                }
                                cx.notify();
                            })),
                    )
                    .when(expanded, |this| {
                        this.child(v_flex().pl(px(14.)).pb(px(9.)).gap(px(8.)).children(
                            matching.iter().map(|block| {
                                let id = block.id;
                                v_flex()
                                    .id(ElementId::from(("timeline-title-source", id as u64)))
                                    .gap(px(2.))
                                    .cursor_pointer()
                                    .child(
                                        div()
                                            .line_clamp(2)
                                            .text_size(ty::BODY)
                                            .text_color(lb.text)
                                            .child(block.title.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.supporting)
                                            .child(format!(
                                                "{} · {}",
                                                block.app,
                                                time_range(block.start, block.end)
                                            )),
                                    )
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.open_child(Selection::Block(id), cx)
                                    }))
                            }),
                        ))
                    })
            });
        Some(
            SectionPanel::new("timeline-session-open", lokalbot_i18n::tr("What was open"))
                .icon(Ico::AppWindow)
                .rows(rows)
                .into_any_element(),
        )
    }

    // ------------------------------------------------- all captured activity

    /// Its title and the way to delete screen moments on top, the hour track
    /// under them.
    fn raw_capture_page(&self, model: &DayModel, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let empty = model.activity.blocks.is_empty() && model.moments.is_empty();
        let has_track = !model.activity.blocks.is_empty() || !model.meetings.is_empty();
        let lead = SectionPanelLead::new("timeline-raw-lead").child(
            v_flex()
                .gap(px(10.))
                .child(
                    h_flex()
                        .gap(px(12.))
                        .items_start()
                        .child(div().flex_1().min_w_0().child(page_header(
                            header_icon(Ico::Activity, cx),
                            lokalbot_i18n::tr("All captured activity").into(),
                            capture_counts(model),
                            cx,
                        )))
                        .children(self.range_deletion_toggle(&model.moments, cx)),
                )
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.supporting)
                        .child(ui::text::paragraph(lokalbot_i18n::tr(
                            "Every app and window LokalBot saw, hour by hour. Use it to check exact times.",
                        ))),
                )
                .children(self.render_range_deletion(&model.moments, cx))
                .when(empty, |this| {
                    this.child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.supporting)
                            .child(ui::text::paragraph(lokalbot_i18n::tr(
                                "No activity or screen moments were retained for this day.",
                            ))),
                    )
                }),
        );
        let lead = if has_track {
            lead.below(
                div()
                    .px(metric::PANEL_INSET)
                    .pt(px(16.))
                    .pb(px(8.))
                    .child(self.render_track(model, cx)),
            )
        } else {
            lead
        };
        vec![lead.into_any_element()]
    }

    // -------------------------------------------------------- a meeting

    fn meeting_page(&self, model: &DayModel, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let Some(preview) = self.meeting_preview.as_ref() else {
            return vec![
                div()
                    .child(gpui_kit::component::spinner::Spinner::new())
                    .into_any_element(),
            ];
        };
        let meeting = &preview.meeting;
        let live = meeting.is_live();
        let end = lokalbot_core::timeline::meeting_end(meeting, chrono::Utc::now());
        let facts: Vec<String> = [
            time_range(meeting.started_at, end),
            hm((end - meeting.started_at).num_seconds().max(0) as f64),
            meeting.app_name.trim().to_string(),
        ]
        .into_iter()
        .filter(|fact| !fact.is_empty())
        .collect();
        let threads: Vec<&lokalbot_core::ActionThread> = model
            .threads
            .iter()
            .filter(|t| t.references.iter().any(|r| r.meeting_id == meeting.id))
            .collect();
        let no_outcomes =
            preview.recap.is_none() && threads.is_empty() && preview.decisions.is_empty() && !live;

        let mut lead = v_flex().gap(px(12.)).child(page_header(
            header_icon(Ico::AudioLines, cx),
            meeting.display_title().into(),
            facts.join(" · "),
            cx,
        ));
        if live {
            lead = lead.child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::status_dot(lb.recording, px(9.)))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.recording_text)
                            .child(lokalbot_i18n::tr("Recording in progress")),
                    ),
            );
        }
        // The recap only: decisions and actions follow as their own panels.
        if let Some(recap) = preview.recap.clone() {
            lead = lead.child(ui::divider(cx)).child(
                v_flex()
                    .max_w(metric::READING_MAX_WIDTH)
                    .gap(px(6.))
                    .children(
                        meeting_model::recap_points(&recap)
                            .into_iter()
                            .map(|point| {
                                div()
                                    .text_size(ty::READING)
                                    .line_height(px(22.))
                                    .text_color(lb.text)
                                    .child(point)
                            }),
                    ),
            );
        } else if no_outcomes {
            lead = lead.child(ui::divider(cx)).child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.supporting)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "No outcome summary has been extracted for this meeting yet.",
                    ))),
            );
        }
        let mut panels = vec![
            SectionPanelLead::new("timeline-meeting-lead")
                .child(lead)
                .into_any_element(),
        ];

        if !threads.is_empty() {
            panels.push(
                SectionPanel::new(
                    "timeline-meeting-actions",
                    lokalbot_i18n::tr("Your actions"),
                )
                .section(Section::Actions)
                .count(threads.len())
                .rows(
                    threads
                        .iter()
                        .take(PREVIEW_ROWS)
                        .enumerate()
                        .map(|(ix, thread)| {
                            action_row::thread_row(
                                format!("timeline-meeting-thread-{ix}").into(),
                                thread,
                                ThreadRowOptions {
                                    hide_single_meeting_link: true,
                                    hint: model.hints.get(&thread.id),
                                    ..Default::default()
                                },
                                &self.data,
                                cx,
                            )
                        }),
                )
                .into_any_element(),
            );
        }
        if !preview.decisions.is_empty() {
            let shown: Vec<String> = preview
                .decisions
                .iter()
                .take(PREVIEW_ROWS)
                .cloned()
                .collect();
            panels.push(decisions_panel_counted(&shown, preview.decisions.len(), cx));
        }

        let meeting_id = meeting.id;
        let title = meeting.display_title();
        let open_data = self.data.clone();
        panels.push(
            h_flex()
                .gap(px(8.))
                .child(
                    Button::new("open-meeting")
                        .primary()
                        .icon(Icon::new(Ico::ArrowUpRight))
                        .label(lokalbot_i18n::tr("Open meeting"))
                        .on_click(move |_, _, cx| open_meeting(&open_data, meeting_id, None, cx)),
                )
                .child(
                    ui::controls::bordered(
                        "ask-meeting",
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
                .into_any_element(),
        );
        panels
    }
}

/// A meeting's decisions panel: the first few, counted in all.
fn decisions_panel_counted(
    decisions: &[String],
    count: usize,
    cx: &Context<TimelinePage>,
) -> AnyElement {
    let lb = cx.lb();
    SectionPanel::new("timeline-meeting-decisions", lokalbot_i18n::tr("Decisions"))
        .icon(Ico::Flag)
        .count(count)
        .rows(decisions.iter().map(|decision| {
            h_flex()
                .py(px(10.))
                .gap(px(10.))
                .items_start()
                .child(
                    div()
                        .w(px(18.))
                        .flex_none()
                        .pt(px(2.))
                        .flex()
                        .justify_center()
                        .child(ui::icon(Ico::Check, px(14.), lb.accent_text)),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(ui::text::paragraph(decision.clone())),
                )
        }))
        .into_any_element()
}

/// A page's mark: an icon in the accent.
pub(super) fn header_icon(icon: Ico, cx: &Context<TimelinePage>) -> AnyElement {
    div()
        .pt(px(4.))
        .child(ui::icon(icon, px(20.), cx.lb().accent_text))
        .into_any_element()
}

/// A page's heading: its mark (a colour dot or an icon), the title, and one
/// quiet line under it (`TimelinePageHeader`).
pub(super) fn page_header(
    mark: AnyElement,
    title: SharedString,
    subtitle: String,
    cx: &Context<TimelinePage>,
) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .gap(px(12.))
        .items_start()
        .child(div().flex_none().child(mark))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .line_clamp(3)
                        .text_size(px(21.))
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(title),
                )
                .when(!subtitle.is_empty(), |this| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(ui::text::paragraph(subtitle)),
                    )
                }),
        )
        .into_any_element()
}
