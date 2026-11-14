//! One project's page (`ProjectDetailView`). A tracked project leads with
//! "Where it stands", the only block a model wrote, marked with the sparkle
//! and one line saying when, by which model and where. Everything outside
//! that card is a fact from the library: your actions, what is waiting on
//! others, decisions, and the meetings with the line that names the project.
//! Window time, people and names sit in a side column. A suggestion opens on
//! the decision instead, and a project nothing names yet is one message.

use chrono::{DateTime, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::DropdownMenu as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, ElementId, FontWeight, HighlightStyle, InteractiveElement as _,
    InteractiveText, IntoElement, ParentElement as _, SharedString,
    StatefulInteractiveElement as _, Styled as _, StyledText, UnderlineStyle, div, px,
};
use lokalbot_ai::project_status;
use lokalbot_core::{ActionThread, ProjectKind, ProjectProfile, ProjectSummary, ReviewNote};
use uuid::Uuid;

use super::model::{self, Home};
use super::{ProjectsPage, add_name_items};
use crate::i18n::h_flex;
use crate::pages::people::model::{hidden_count, initials, meeting_link, short_date, show_more};
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::action_row::{self, ThreadRowOptions};
use crate::ui::section_panel::SectionPanelLead;
use crate::ui::side_column::{self, decision_row, label_chip, section_heading, side_block};
use crate::ui::{self, Ico, profile};
use lokalbot_i18n::fill;

/// "Show 3 more" / "Show all 12" / "Show fewer" under a list.
fn more_link(
    id: impl Into<ElementId>,
    label: String,
    toggle: impl Fn(&mut ProjectsPage) + 'static,
    cx: &mut Context<ProjectsPage>,
) -> AnyElement {
    let page = cx.entity();
    profile::link(
        id,
        label,
        move |_, cx| {
            page.update(cx, |page, cx| {
                toggle(page);
                cx.notify();
            })
        },
        cx,
    )
    .into_any_element()
}

/// The sparkle that marks what a model wrote; it says so on hover.
fn sparkle(id: impl Into<ElementId>, cx: &App) -> AnyElement {
    let lb = cx.lb();
    div()
        .id(id)
        .flex_none()
        .child(ui::icon(Ico::Sparkles, px(13.), lb.accent_text))
        .tooltip(|window, cx| {
            Tooltip::new(lokalbot_i18n::tr("Written by a model")).build(window, cx)
        })
        .into_any_element()
}

/// A bulleted line of the note.
fn bulleted(content: AnyElement, cx: &App) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .child(
            div()
                .flex_none()
                .text_size(ty::BODY)
                .text_color(lb.text_tertiary)
                .child("•"),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(content),
        )
        .into_any_element()
}

impl ProjectsPage {
    pub(super) fn render_detail(
        &self,
        project: &ProjectProfile,
        settling: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if project.is_tracked() && model::is_empty(project) {
            return self.empty_project(project, cx);
        }
        let now = Utc::now();
        let scale = self.data.read(cx).settings.text_size.scale();
        let pane = self
            .detail_bounds
            .get()
            .map_or(1000., |b| f32::from(b.size.width));
        let shows_time = project.week_seconds >= model::MINIMUM_SECONDS;
        let has_side = shows_time || !project.people.is_empty() || project.is_tracked();

        let mut main: Vec<AnyElement> = Vec::new();
        if project.is_tracked() {
            let width = side_column::main_width(pane, scale, has_side);
            main.push(self.where_it_stands(project, settling, width, scale, now, cx));
            if !project.my_actions.is_empty() {
                main.push(self.my_actions(project, cx));
            }
            if let Some(others) = self.others_actions(project, cx) {
                main.push(others);
            }
            if !project.decisions.is_empty() {
                main.push(self.decisions(project, now, cx));
            }
            if let Some(meetings) = self.meetings(project, lokalbot_i18n::tr("Meetings"), now, cx) {
                main.push(meetings);
            }
        } else {
            let shown = model::list_projects(&self.projects, None);
            let home = model::suggestion_home(project, &shown);
            main.push(self.suggestion_card(project, home.as_ref(), now, cx));
            if let Some(meetings) =
                self.meetings(project, lokalbot_i18n::tr("Where it came up"), now, cx)
            {
                main.push(meetings);
            }
        }
        let mut side: Vec<AnyElement> = Vec::new();
        if shows_time {
            side.push(self.time(project, cx));
        }
        if !project.people.is_empty() {
            side.push(self.people(project, cx));
        }
        if project.is_tracked() {
            side.push(self.names(project, settling, cx));
        }
        // Beside the page while the pane has room for both, under it
        // otherwise (`PageWithSideColumn`).
        side_column::page(
            "project-detail",
            main,
            side,
            pane,
            scale,
            &self.detail_scroll,
            cx,
        )
    }

    /// Nothing names the project yet: one centred message and the way to
    /// give it the names the work goes by.
    fn empty_project(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let names = project.clone();
        v_flex()
            .id("project-empty")
            .size_full()
            .items_center()
            .justify_center()
            .gap(px(8.))
            .px(px(48.))
            .pb(px(60.))
            .child(
                div()
                    .pb(px(6.))
                    .child(ui::icon(Ico::Folder, px(30.), lb.text_secondary)),
            )
            .child(
                div()
                    .w_full()
                    .text_center()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(fill(
                        lokalbot_i18n::tr("Nothing mentions %@ yet"),
                        &[&project.name],
                    ))),
            )
            .child(
                div()
                    .w_full()
                    .max_w(px(390.))
                    .text_center()
                    .text_size(ty::BODY)
                    .text_color(lb.supporting)
                    .child(ui::text::paragraph(fill(
                        lokalbot_i18n::tr(
                            "Meetings, actions and window titles that say “%@” will show up here. If the work goes by another name, like a codename or a client, add it.",
                        ),
                        &[&project.name],
                    ))),
            )
            .child(
                div().pt(px(8.)).child(
                    Button::new("project-add-other-names")
                        .outline()
                        .label(lokalbot_i18n::tr("Add other names…"))
                        .on_click(move |_, window, cx| {
                            let project = names.clone();
                            page.update(cx, |page, cx| page.edit_names(&project, window, cx))
                        }),
                ),
            )
            .into_any_element()
    }

    // ------------------------------------------------------- the card

    /// The tracked project's "Where it stands" note, the only model-written
    /// text on the page: overview, points with the meeting each comes from,
    /// and open questions. Its heading says when it was written, by which
    /// model and where that ran. A note whose evidence has changed stays,
    /// marked, until the person updates it or an approved automatic update
    /// replaces it.
    fn where_it_stands(
        &self,
        project: &ProjectProfile,
        settling: bool,
        width: f32,
        scale: f32,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let evidence = project_status::evidence(project);
        let summary = project.summary.as_ref();
        let writing = self
            .data
            .read(cx)
            .project_notes_running
            .contains(&project.id);
        let can_write = !evidence.is_empty() && !settling;

        // Who wrote the note and the button.
        let control_label: &str = if writing {
            if summary.is_some() {
                lokalbot_i18n::tr("Updating…")
            } else {
                ""
            }
        } else if can_write {
            if summary.is_none() {
                lokalbot_i18n::tr("Write note")
            } else {
                lokalbot_i18n::tr("Update")
            }
        } else {
            ""
        };
        let control: Option<AnyElement> = if writing {
            Some(
                h_flex()
                    .flex_none()
                    .gap(px(6.))
                    .items_center()
                    .child(Spinner::new().xsmall().color(lb.text_secondary))
                    .when(summary.is_some(), |this| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(control_label.to_string()),
                        )
                    })
                    .into_any_element(),
            )
        } else if settling {
            Some(
                Spinner::new()
                    .xsmall()
                    .color(lb.text_secondary)
                    .into_any_element(),
            )
        } else if can_write {
            let data = self.data.clone();
            let id = project.id.clone();
            Some(
                Button::new("project-write-note")
                    .outline()
                    .small()
                    .label(control_label.to_string())
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::WriteProjectNote(id.clone()), cx)
                        })
                    })
                    .into_any_element(),
            )
        } else {
            None
        };
        let provenance = summary.map(|summary| model::provenance(summary, now));
        let title_text = lokalbot_i18n::tr("Where it stands");
        let title = h_flex()
            .flex_none()
            .gap(px(7.))
            .items_center()
            .child(sparkle("project-summary-sparkle", cx))
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(title_text),
            );
        let beside = provenance.as_deref().is_none_or(|line| {
            model::provenance_fits_beside(width, title_text, line, control_label, scale)
        });
        let heading: AnyElement = if beside {
            h_flex()
                .w_full()
                .min_h(px(24.))
                .gap(px(8.))
                .items_center()
                .child(title)
                .child(div().flex_1().min_w(px(12.)))
                .when_some(provenance, |this, line| {
                    this.child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(line),
                    )
                })
                .children(control)
                .into_any_element()
        } else {
            // Too narrow for one line: the provenance goes under the title.
            v_flex()
                .w_full()
                .gap(px(4.))
                .child(
                    h_flex()
                        .w_full()
                        .min_h(px(24.))
                        .gap(px(8.))
                        .items_center()
                        .child(title)
                        .child(div().flex_1().min_w(px(12.)))
                        .children(control),
                )
                .when_some(provenance, |this, line| {
                    this.child(
                        div()
                            .w_full()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(line)),
                    )
                })
                .into_any_element()
        };

        let quiet = |text: &str| {
            div()
                .w_full()
                .text_size(ty::BODY)
                .text_color(lb.supporting)
                .child(ui::text::paragraph(text.to_string()))
                .into_any_element()
        };
        let body: AnyElement = match summary {
            Some(summary) => {
                let stale = summary.evidence_fingerprint != project_status::fingerprint(&evidence);
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .when(stale, |this| {
                        this.child(
                            div()
                                .w_full()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.attention_text)
                                .child(ui::text::paragraph(lokalbot_i18n::tr(
                                    "Newer evidence since this was written.",
                                ))),
                        )
                    })
                    // The note being replaced stays readable while the new
                    // one is written.
                    .child(
                        self.note_text(summary, now, cx)
                            .when(writing, |this| this.opacity(0.5)),
                    )
                    .into_any_element()
            }
            None if writing => {
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(Spinner::new().xsmall().color(lb.text_secondary))
                    .child(div().text_size(ty::BODY).text_color(lb.supporting).child(
                        model::writing(evidence.meetings.len(), !evidence.review_notes.is_empty()),
                    ))
                    .into_any_element()
            }
            None if !evidence.is_empty() => quiet(lokalbot_i18n::tr("No note yet.")),
            None => quiet(lokalbot_i18n::tr(
                "Nothing names this project yet. A note can be written once meetings or overnight reviews mention it.",
            )),
        };
        SectionPanelLead::new("project-summary")
            .child(v_flex().w_full().gap(px(10.)).child(heading).child(body))
            .into_any_element()
    }

    /// The note's text. Each point ends with the meeting it comes from as a
    /// link; a point from the overnight review says so and links nowhere.
    fn note_text(
        &self,
        summary: &ProjectSummary,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Div {
        let lb = cx.lb().clone();
        let mut column = v_flex().w_full().gap(px(7.)).child(
            div()
                .w_full()
                .pb(px(2.))
                .text_size(ty::READING)
                .line_height(px(22.))
                .text_color(lb.text)
                .child(ui::text::paragraph(summary.overview.clone())),
        );
        for (index, point) in summary.points.iter().enumerate() {
            let meeting = point
                .meeting_id
                .as_deref()
                .and_then(|id| Uuid::parse_str(id).ok())
                .zip(point.meeting_title.as_deref());
            let citation = match meeting {
                Some((_, title)) => {
                    model::point_citation(title, point.meeting_date.as_deref(), now)
                }
                None => lokalbot_i18n::tr("Overnight review").to_string(),
            };
            let text = format!("{}  ", point.text.trim());
            let full = format!("{text}{citation}");
            let range = text.len()..full.len();
            let style = HighlightStyle {
                color: Some(if meeting.is_some() {
                    lb.accent_text
                } else {
                    lb.text_secondary
                }),
                ..Default::default()
            };
            let link_style = HighlightStyle {
                underline: Some(UnderlineStyle {
                    thickness: px(1.),
                    color: Some(lb.accent_text.opacity(0.4)),
                    wavy: false,
                }),
                ..style
            };
            let styled = StyledText::new(full.clone()).with_highlights([(
                range.clone(),
                if meeting.is_some() { link_style } else { style },
            )]);
            let line: AnyElement = match meeting {
                Some((id, _)) => {
                    let page = cx.entity();
                    div()
                        .w_full()
                        .text_align(crate::i18n::content_alignment(&full))
                        .child(
                            InteractiveText::new(("project-point", index), styled).on_click(
                                vec![range],
                                move |_, _, cx| {
                                    page.update(cx, |page, cx| page.open_meeting(id, None, cx))
                                },
                            ),
                        )
                        .into_any_element()
                }
                None => div()
                    .w_full()
                    .text_align(crate::i18n::content_alignment(&full))
                    .child(styled)
                    .into_any_element(),
            };
            column = column.child(bulleted(line, cx));
        }
        if !summary.open_questions.is_empty() {
            column = column.child(
                div()
                    .pt(px(4.))
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(if summary.open_questions.len() == 1 {
                        lokalbot_i18n::tr("Open question")
                    } else {
                        lokalbot_i18n::tr("Open questions")
                    }),
            );
            for question in &summary.open_questions {
                column = column.child(bulleted(ui::text::paragraph(question.clone()), cx));
            }
        }
        column
    }

    // ------------------------------------------------------- the facts

    fn thread_rows(
        &self,
        threads: &[&ActionThread],
        prefix: &str,
        show_owner: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rows: Vec<AnyElement> = threads
            .iter()
            .map(|thread| {
                action_row::thread_row(
                    SharedString::from(format!("{prefix}-{}", thread.id)),
                    thread,
                    ThreadRowOptions {
                        show_owner,
                        hint: self.hints.get(&thread.id),
                        ..Default::default()
                    },
                    &self.data,
                    cx,
                )
            })
            .collect();
        profile::divided(rows, cx).into_any_element()
    }

    fn my_actions(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let threads: Vec<&ActionThread> = project.my_actions.iter().collect();
        v_flex()
            .w_full()
            .child(
                section_heading(
                    lokalbot_i18n::tr("Your actions"),
                    Some(threads.len()),
                    None,
                    cx,
                )
                .pb(px(2.)),
            )
            .child(self.thread_rows(&threads, "project-mine", false, cx))
            .into_any_element()
    }

    /// Other people's open work, recent first: three rows, then the rest on
    /// request.
    fn others_actions(
        &self,
        project: &ProjectProfile,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let threads = model::others_actions(project);
        if threads.is_empty() {
            return None;
        }
        let total = threads.len();
        let hidden = hidden_count(total, model::VISIBLE_OTHERS_ACTIONS);
        let shown: Vec<&ActionThread> = if self.shows_all_others {
            threads
        } else {
            threads
                .into_iter()
                .take(model::VISIBLE_OTHERS_ACTIONS)
                .collect()
        };
        let expanded = self.shows_all_others;
        Some(
            v_flex()
                .w_full()
                .child(
                    section_heading(
                        lokalbot_i18n::tr("Waiting on others"),
                        Some(total),
                        None,
                        cx,
                    )
                    .pb(px(2.)),
                )
                .child(self.thread_rows(&shown, "project-others", true, cx))
                .when(hidden > 0, |this| {
                    this.child(div().pt(px(4.)).child(more_link(
                        "project-others-more",
                        show_more(expanded, hidden),
                        |page| page.shows_all_others = !page.shows_all_others,
                        cx,
                    )))
                })
                .into_any_element(),
        )
    }

    /// Decisions from the project's meetings that name it, each with its
    /// meeting and date as a link.
    fn decisions(
        &self,
        project: &ProjectProfile,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rows: Vec<AnyElement> = project
            .decisions
            .iter()
            .enumerate()
            .map(|(index, (meeting, decision))| {
                let page = cx.entity();
                let id = meeting.id;
                let link = meeting_link(&meeting.title, meeting.started_at, now);
                decision_row(
                    ("project-decision", index),
                    decision.text.clone(),
                    link.clone(),
                    link,
                    true,
                    move |_, cx| page.update(cx, |page, cx| page.open_meeting(id, None, cx)),
                    cx,
                )
            })
            .collect();
        v_flex()
            .w_full()
            .gap(px(2.))
            .child(
                section_heading(
                    lokalbot_i18n::tr("Decisions"),
                    Some(project.decisions.len()),
                    None,
                    cx,
                )
                .pb(px(4.)),
            )
            .children(rows)
            .into_any_element()
    }

    /// Each meeting with the line that names the project, so it is clear why
    /// it is linked. A line from the transcript plays from its moment.
    fn meetings(
        &self,
        project: &ProjectProfile,
        title: &str,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if project.meetings.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let total = project.meetings.len();
        let hidden = hidden_count(total, model::VISIBLE_MEETINGS);
        let shown = if self.shows_all_meetings {
            total
        } else {
            model::VISIBLE_MEETINGS
        };
        let rows: Vec<AnyElement> = project
            .meetings
            .iter()
            .take(shown)
            .enumerate()
            .map(|(index, meeting)| {
                let id = meeting.id;
                let mention = project
                    .mentions
                    .iter()
                    .find(|m| m.meeting_id == id)
                    .cloned();
                let seek = mention.as_ref().and_then(|m| m.seek);
                let hover: SharedString = mention
                    .as_ref()
                    .map(|m| m.text.clone())
                    .unwrap_or_else(|| meeting.title.clone())
                    .into();
                let group: SharedString = format!("project-meeting-{index}").into();
                let open_page = cx.entity();
                let play_page = cx.entity();
                h_flex()
                    .w_full()
                    .gap(px(10.))
                    .items_start()
                    .py(px(7.))
                    .child(
                        v_flex()
                            .id(("project-meeting", index))
                            .group(group.clone())
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .cursor_pointer()
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .group_hover(group, |s| s.underline())
                                    .child(meeting.title.clone()),
                            )
                            .when_some(mention.clone(), |this, mention| {
                                this.child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.supporting)
                                        .line_clamp(2)
                                        .child(mention.text),
                                )
                            })
                            .tooltip(move |window, cx| {
                                Tooltip::new(hover.clone()).build(window, cx)
                            })
                            .on_click(move |_, _, cx| {
                                open_page.update(cx, |page, cx| page.open_meeting(id, seek, cx))
                            }),
                    )
                    .child(
                        v_flex()
                            .flex_none()
                            .items_end()
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(short_date(meeting.started_at, now)),
                            )
                            .when_some(mention.zip(seek), |this, (mention, seek)| {
                                this.child(action_row::play_time(
                                    ("project-meeting-play", index),
                                    seek,
                                    Some(mention.text.into()),
                                    move |_, cx| {
                                        play_page.update(cx, |page, cx| {
                                            page.open_meeting(id, Some(seek), cx)
                                        })
                                    },
                                    cx,
                                ))
                            }),
                    )
                    .into_any_element()
            })
            .collect();
        let expanded = self.shows_all_meetings;
        Some(
            v_flex()
                .w_full()
                .child(section_heading(title.to_string(), Some(total), None, cx).pb(px(2.)))
                .child(profile::divided(rows, cx))
                .when(hidden > 0, |this| {
                    this.child(div().pt(px(6.)).child(more_link(
                        "project-meetings-more",
                        model::show_all(expanded, total),
                        |page| page.shows_all_meetings = !page.shows_all_meetings,
                        cx,
                    )))
                })
                .into_any_element(),
        )
    }

    // ------------------------------------------------------- suggestion

    /// A suggestion's page opens on the decision: where it came up, then the
    /// answers. When a tracked project already has at least half of its
    /// meetings, adding it there is the first answer; otherwise tracking is.
    fn suggestion_card(
        &self,
        project: &ProjectProfile,
        home: Option<&Home>,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let mut answers: Vec<AnyElement> = Vec::new();
        match home {
            Some(home) => {
                let add_page = page.clone();
                let (name, target) = (project.name.clone(), home.tracked_id);
                answers.push(
                    Button::new("project-add-to-home")
                        .primary()
                        .label(fill(lokalbot_i18n::tr("Add to %@"), &[&home.name]))
                        .on_click(move |_, _, cx| {
                            add_page.update(cx, |page, cx| page.add_name(&name, target, cx))
                        })
                        .into_any_element(),
                );
                let track_page = page.clone();
                let name = project.name.clone();
                answers.push(
                    Button::new("project-track")
                        .outline()
                        .label(lokalbot_i18n::tr("Track as its own project"))
                        .on_click(move |_, _, cx| {
                            track_page.update(cx, |page, cx| page.track(&name, Vec::new(), cx))
                        })
                        .into_any_element(),
                );
            }
            None => {
                let track_page = page.clone();
                let name = project.name.clone();
                answers.push(
                    Button::new("project-track")
                        .primary()
                        .label(lokalbot_i18n::tr("Track"))
                        .on_click(move |_, _, cx| {
                            track_page.update(cx, |page, cx| page.track(&name, Vec::new(), cx))
                        })
                        .into_any_element(),
                );
                if !self.curation.tracked.is_empty() {
                    let add_page = page.clone();
                    let name = project.name.clone();
                    let tracked = self.curation.tracked.clone();
                    answers.push(
                        Button::new("project-add-to")
                            .outline()
                            .label(lokalbot_i18n::tr("Add to a project"))
                            .dropdown_caret(true)
                            .dropdown_menu(move |menu, _, _| {
                                add_name_items(menu, &add_page, &name, &tracked)
                            })
                            .into_any_element(),
                    );
                }
            }
        }
        let hide_page = page.clone();
        let hide_project = project.clone();
        answers.push(
            Button::new("project-hide")
                .ghost()
                .label(lokalbot_i18n::tr("Not a project"))
                .on_click(move |_, _, cx| {
                    let project = hide_project.clone();
                    hide_page.update(cx, |page, cx| page.hide_suggestion(&project, cx))
                })
                .into_any_element(),
        );
        let notes: Vec<AnyElement> = if project.kind == ProjectKind::SuggestedReview {
            project
                .review_notes
                .iter()
                .enumerate()
                .map(|(index, note)| review_note(index, note, now, cx))
                .collect()
        } else {
            Vec::new()
        };
        SectionPanelLead::new("project-suggestion")
            .child(
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .child(
                        div()
                            .w_full()
                            .text_size(ty::PANEL_TITLE)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(model::suggestion_title(project, now))),
                    )
                    .children(notes)
                    .child(
                        div()
                            .w_full()
                            .text_size(ty::BODY)
                            .text_color(lb.supporting)
                            .child(ui::text::paragraph(model::suggestion_reason(home))),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .flex_wrap()
                            .gap(px(8.))
                            .pt(px(4.))
                            .items_center()
                            .children(answers),
                    ),
            )
            .into_any_element()
    }

    // ------------------------------------------------------- side column

    /// Window time over the last seven days: the total, a bar a day, and the
    /// longest windows.
    fn time(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let today = lokalbot_core::time::local_day(Utc::now());
        let days = model::days(&project.days, today);
        let source: SharedString = model::time_source(project).into();
        let bars = h_flex()
            .w_full()
            .items_end()
            .gap(px(6.))
            .pt(px(4.))
            .children(days.iter().enumerate().map(|(index, day)| {
                let label: SharedString = model::day_time(day).into();
                let height = (46. * model::fraction(day, &days)).max(2.);
                let fill = if day.is_today {
                    lb.accent_fill
                } else {
                    lb.accent_fill.opacity(0.4)
                };
                v_flex()
                    .id(("project-day", index))
                    .flex_1()
                    .min_w_0()
                    .items_center()
                    .gap(px(4.))
                    .child(
                        div()
                            .w_full()
                            .max_w(px(20.))
                            .h(px(height))
                            .rounded(px(2.))
                            .bg(fill),
                    )
                    .child(
                        div()
                            .text_size(ty::SMALL)
                            .text_color(lb.text_secondary)
                            .child(model::weekday_letter(day.date)),
                    )
                    .tooltip(move |window, cx| Tooltip::new(label.clone()).build(window, cx))
            }));
        let mut windows: Vec<AnyElement> = project
            .windows
            .iter()
            .take(model::VISIBLE_WINDOWS)
            .map(|window| {
                time_row(
                    window.app.clone(),
                    Some(window.title.clone()),
                    model::duration(window.seconds),
                    false,
                    cx,
                )
            })
            .collect();
        if let Some((count, seconds)) = model::rest(project) {
            windows.push(time_row(
                model::more_windows(count),
                None,
                model::duration(seconds),
                true,
                cx,
            ));
        }
        side_block(lokalbot_i18n::tr("Last 7 days"), None, cx)
            .child(
                div()
                    .id("project-time-total")
                    .text_size(px(22.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(model::duration(project.week_seconds))
                    .tooltip(move |window, cx| Tooltip::new(source.clone()).build(window, cx)),
            )
            .child(bars)
            .when(!windows.is_empty(), |this| {
                this.child(div().pt(px(6.)).child(profile::divided(windows, cx)))
            })
            .into_any_element()
    }

    /// Up to eight people from the project's meetings, each opening their
    /// page.
    fn people(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        side_block(lokalbot_i18n::tr("People"), None, cx)
            .child(
                v_flex()
                    .w_full()
                    .gap(px(2.))
                    .children(project.people.iter().enumerate().map(|(index, name)| {
                        let data = self.data.clone();
                        let target = lokalbot_core::people::person_id_for_name(name);
                        let group: SharedString = format!("project-person-{index}").into();
                        h_flex()
                            .id(("project-person", index))
                            .group(group.clone())
                            .w_full()
                            .gap(px(8.))
                            .items_center()
                            .py(px(3.))
                            .cursor_pointer()
                            .child(ui::avatar(
                                initials(name),
                                profile::name_tint(name, cx),
                                px(22.),
                            ))
                            .child(
                                div()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .group_hover(group, |s| s.underline())
                                    .child(name.clone()),
                            )
                            .on_click(move |_, _, cx| {
                                let target = target.clone();
                                data.update(cx, |data, cx| data.open_person(target, cx));
                            })
                    })),
            )
            .into_any_element()
    }

    /// The name and other names the project is matched by.
    fn names(
        &self,
        project: &ProjectProfile,
        settling: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let chips = std::iter::once(&project.name)
            .chain(&project.other_names)
            .map(|name| label_chip(name.clone(), false, true, cx));
        let edit: AnyElement = if settling {
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_tertiary)
                .child(lokalbot_i18n::tr("Edit names…"))
                .into_any_element()
        } else {
            let page = cx.entity();
            let project = project.clone();
            profile::link(
                "project-edit-names",
                lokalbot_i18n::tr("Edit names…"),
                move |window, cx| {
                    let project = project.clone();
                    page.update(cx, |page, cx| page.edit_names(&project, window, cx))
                },
                cx,
            )
            .into_any_element()
        };
        side_block(lokalbot_i18n::tr("Names"), None, cx)
            .child(h_flex().w_full().flex_wrap().gap(px(6.)).children(chips))
            .child(div().pt(px(2.)).child(edit))
            .into_any_element()
    }
}

/// The overnight review's own words about a suggestion, which a model
/// wrote, so they carry the sparkle too.
fn review_note(index: usize, note: &ReviewNote, now: DateTime<Utc>, cx: &App) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .px(px(12.))
        .py(px(9.))
        .rounded(px(8.))
        .bg(lb.group_fill)
        .child(
            div()
                .pt(px(2.))
                .child(sparkle(("project-review-sparkle", index), cx)),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .w_full()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(ui::text::paragraph(note.status.clone())),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(model::review_citation(&note.last_active_day, now)),
                ),
        )
        .into_any_element()
}

/// A window and its time, or the line that sums the windows not listed.
fn time_row(
    title: String,
    detail: Option<String>,
    time: String,
    quiet: bool,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .py(px(5.))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(1.))
                .child(
                    div()
                        .truncate()
                        .text_size(if quiet { ty::SECONDARY } else { ty::BODY })
                        .text_color(if quiet { lb.text_secondary } else { lb.text })
                        .child(title),
                )
                .when_some(detail.filter(|d| !d.is_empty()), |this, detail| {
                    this.child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(detail),
                    )
                }),
        )
        .child(
            div()
                .flex_none()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(time),
        )
        .into_any_element()
}
