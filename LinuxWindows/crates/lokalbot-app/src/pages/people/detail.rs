//! One person's page (`PersonDetailView`). The next calendar meeting with
//! them leads when there is one, then what is open between you, what the last
//! meeting said, and what you decided together. Projects, meetings and other
//! names sit in a side column, so a long history fits one screen and someone
//! met once has a short page. A section with nothing in it is not shown.

use chrono::{DateTime, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, ElementId, FontWeight, HighlightStyle, IntoElement, ParentElement as _,
    SharedString, Styled as _, StyledText, div, px,
};
use lokalbot_core::people::upcoming::PersonUpcomingMeeting;
use lokalbot_core::{ActionThread, PersonProfile};

use super::PeoplePage;
use super::model::{self, Occasion, Series};
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::action_row::{self, ThreadRowOptions};
use crate::ui::section_panel::SectionPanelLead;
use crate::ui::side_column::{
    self, Disclosure, decision_row, label_chip, meeting_link_row, section_heading, side_block,
};
use crate::ui::{self, Ico};

/// "Show 3 more" / "Show fewer" under a list.
fn more_link(
    id: impl Into<ElementId>,
    expanded: bool,
    hidden: usize,
    toggle: impl Fn(&mut PeoplePage, &mut Context<PeoplePage>) + 'static,
    cx: &mut Context<PeoplePage>,
) -> AnyElement {
    let page = cx.entity();
    ui::profile::link(
        id,
        model::show_more(expanded, hidden),
        move |_, cx| {
            page.update(cx, |page, cx| {
                toggle(page, cx);
                cx.notify();
            })
        },
        cx,
    )
    .into_any_element()
}

impl PeoplePage {
    pub(super) fn render_detail(
        &self,
        person: &PersonProfile,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let now = Utc::now();
        let next = self.upcoming.get(&person.id).cloned();
        let series = model::series(model::occasions(person));
        let has_notes = !person.recent_notes.is_empty();

        let mut main: Vec<AnyElement> = Vec::new();
        if let Some(next) = &next {
            main.push(self.next_meeting_card(person, next, now, cx));
        }
        if person.open_count() > 0 {
            main.push(self.open_work(person, cx));
        }
        if has_notes {
            main.push(self.last_time(person, now, cx));
        }
        if !person.decisions.is_empty() {
            main.push(self.decisions(person, now, cx));
        }
        let mut side: Vec<AnyElement> = Vec::new();
        if !person.project_links.is_empty() {
            side.push(self.projects(person, cx));
        }
        if !series.is_empty() {
            side.push(self.meetings(person, &series, now, cx));
        }
        if !person.other_names.is_empty() {
            side.push(self.names(person, cx));
        }

        // Beside the page while the pane has room for both, under it
        // otherwise (`PageWithSideColumn`).
        let scale = self.data.read(cx).settings.text_size.scale();
        let pane = self
            .detail_bounds
            .get()
            .map_or(1000., |b| f32::from(b.size.width));
        side_column::page(
            "person-detail",
            main,
            side,
            pane,
            scale,
            &self.detail_scroll,
            cx,
        )
    }

    /// The next calendar meeting with the person (`PersonNextMeetingCard`):
    /// when, its title, who else is invited, and Prepare, which hands the
    /// person's notes and open work to Agent. Prepare goes under the words
    /// when the card is too narrow for both.
    fn next_meeting_card(
        &self,
        person: &PersonProfile,
        meeting: &PersonUpcomingMeeting,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let prompt = lokalbot_core::people::preparation_prompt(person);
        // As wide as its longest line (`ViewThatFits`): when that and Prepare
        // do not fit one row, Prepare wraps under the words.
        let summary = v_flex()
            .flex_auto()
            .min_w_0()
            .gap(px(3.))
            .child(
                div()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.accent_text)
                    .child(model::next_meeting_line(meeting, now)),
            )
            .child(
                div()
                    .truncate()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(meeting.title.clone()),
            )
            .child(
                div()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(model::invited(&meeting.others)),
            );
        let prepare = Button::new("person-prepare")
            .primary()
            .large()
            .icon(Icon::new(Ico::WandSparkles))
            .label(lokalbot_i18n::tr("Prepare"))
            .tooltip(lokalbot_i18n::tr("Prepare in Agent…"))
            .on_click(move |_, _, cx| {
                let prompt = prompt.clone();
                data.update(cx, |data, cx| data.open_agent(prompt, cx));
            });
        SectionPanelLead::new("person-next-meeting")
            .child(
                h_flex()
                    .w_full()
                    .flex_wrap()
                    .items_center()
                    .gap_x(px(16.))
                    .gap_y(px(12.))
                    .child(summary)
                    .child(div().flex_none().child(prepare)),
            )
            .into_any_element()
    }

    /// One section, two labelled parts: what the user owes, then what the
    /// person owes. Stale work keeps its "Still open?" line.
    fn open_work(&self, person: &PersonProfile, cx: &mut Context<Self>) -> AnyElement {
        let first = model::first_name(person).to_string();
        let mut column = v_flex().w_full().child(
            section_heading(
                lokalbot_i18n::tr("Open between you"),
                Some(person.open_count()),
                None,
                cx,
            )
            .pb(px(6.)),
        );
        if !person.my_actions.is_empty() {
            column = column.child(self.owed(
                lokalbot_i18n::fill(lokalbot_i18n::tr("You owe %@"), &[&first]),
                true,
                &person.my_actions,
                "person-you-owe",
                cx,
            ));
        }
        if !person.their_actions.is_empty() {
            column = column.child(
                div()
                    .when(!person.my_actions.is_empty(), |this| this.pt(px(10.)))
                    .child(self.owed(
                        lokalbot_i18n::fill(lokalbot_i18n::tr("%@ owes you"), &[&first]),
                        false,
                        &person.their_actions,
                        "person-owes-you",
                        cx,
                    )),
            );
        }
        column.into_any_element()
    }

    fn owed(
        &self,
        label: String,
        attention: bool,
        threads: &[ActionThread],
        prefix: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        v_flex()
            .w_full()
            .child(
                h_flex()
                    .py(px(2.))
                    .child(label_chip(label, attention, false, cx)),
            )
            .children(threads.iter().map(|thread| {
                action_row::thread_row(
                    SharedString::from(format!("{prefix}-{}", thread.id)),
                    thread,
                    ThreadRowOptions {
                        show_staleness: true,
                        plays_evidence: true,
                        hint: self.hints.get(&thread.id),
                        ..Default::default()
                    },
                    &self.data,
                    cx,
                )
            }))
            .into_any_element()
    }

    /// "Last time" (or "Last mentioned" when the notes come from an older
    /// meeting), the meeting as a link, and up to three lines from its notes.
    fn last_time(
        &self,
        person: &PersonProfile,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = if person.notes_is_latest_meeting {
            lokalbot_i18n::tr("Last time")
        } else {
            lokalbot_i18n::tr("Last mentioned")
        };
        let link = person.notes_meeting.clone().map(|meeting| {
            let page = cx.entity();
            ui::profile::link(
                "person-notes-meeting",
                model::meeting_link(&meeting.title, meeting.started_at, now),
                move |_, cx| page.update(cx, |page, cx| page.open_meeting(meeting.id, None, cx)),
                cx,
            )
            .truncate()
            .into_any_element()
        });
        v_flex()
            .w_full()
            .gap(px(9.))
            .child(section_heading(title, None, link, cx))
            .children(
                person
                    .recent_notes
                    .iter()
                    .enumerate()
                    .map(|(index, point)| self.note_point(index, point, cx)),
            )
            .into_any_element()
    }

    /// One line from meeting notes, with who said it when that is not the
    /// person, and the moment in the call, which plays from there
    /// (`NotePointRow`).
    fn note_point(
        &self,
        index: usize,
        point: &lokalbot_core::NotePoint,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let meeting_id = point.meeting_id;
        // Who said it in semibold before the line (`NotePointRow`).
        let text: AnyElement = match &point.speaker {
            Some(speaker) => {
                let lead = format!("{speaker}:");
                let full = format!("{lead} {}", point.text);
                let bold = HighlightStyle {
                    font_weight: Some(FontWeight::SEMIBOLD),
                    ..Default::default()
                };
                div()
                    .text_align(crate::i18n::content_alignment(&full))
                    .child(StyledText::new(full.clone()).with_highlights([(0..lead.len(), bold)]))
                    .into_any_element()
            }
            None => ui::text::paragraph(point.text.clone()),
        };
        h_flex()
            .w_full()
            .gap(px(12.))
            .items_start()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(text),
            )
            .children(point.seek.map(|seek| {
                action_row::play_time(
                    ("person-note", index),
                    seek,
                    None,
                    move |_, cx| {
                        page.update(cx, |page, cx| page.open_meeting(meeting_id, Some(seek), cx))
                    },
                    cx,
                )
            }))
            .into_any_element()
    }

    /// "Decided together": three, then Show more. Each names the meeting it
    /// came from quietly at the trailing edge (`PageDecisionRow`).
    fn decisions(
        &self,
        person: &PersonProfile,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let total = person.decisions.len();
        let hidden = model::hidden_count(total, model::VISIBLE_DECISIONS);
        let shown = if self.shows_all_decisions {
            total
        } else {
            model::VISIBLE_DECISIONS
        };
        let rows = person
            .decisions
            .iter()
            .take(shown)
            .enumerate()
            .map(|(index, (meeting, decision))| {
                let page = cx.entity();
                let id = meeting.id;
                decision_row(
                    ("person-decision", index),
                    decision.text.clone(),
                    meeting.title.clone(),
                    model::meeting_link(&meeting.title, meeting.started_at, now),
                    false,
                    move |_, cx| page.update(cx, |page, cx| page.open_meeting(id, None, cx)),
                    cx,
                )
            })
            .collect::<Vec<_>>();
        v_flex()
            .w_full()
            .gap(px(2.))
            .child(
                section_heading(lokalbot_i18n::tr("Decided together"), Some(total), None, cx)
                    .pb(px(4.)),
            )
            .children(rows)
            .when(hidden > 0, |this| {
                let expanded = self.shows_all_decisions;
                this.child(div().pl(px(24.)).pt(px(4.)).child(more_link(
                    "person-decisions-more",
                    expanded,
                    hidden,
                    |page, _| page.shows_all_decisions = !page.shows_all_decisions,
                    cx,
                )))
            })
            .into_any_element()
    }

    /// Projects named around the person; a suggested one says so.
    fn projects(&self, person: &PersonProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        side_block(lokalbot_i18n::tr("Projects"), None, cx)
            .children(person.project_links.iter().map(|project| {
                let target = project.id.clone();
                let data = self.data.clone();
                h_flex()
                    .gap(px(8.))
                    .items_baseline()
                    .child(
                        ui::profile::link(
                            SharedString::from(format!("person-project-{}", project.id)),
                            project.name.clone(),
                            move |_, cx| {
                                let target = target.clone();
                                data.update(cx, |data, cx| data.open_project(target, cx));
                            },
                            cx,
                        )
                        .min_w_0()
                        .truncate()
                        .text_size(ty::BODY),
                    )
                    .when(!project.is_tracked, |this| {
                        this.child(
                            div()
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("suggested")),
                        )
                    })
            }))
            .into_any_element()
    }

    /// Meeting titles, a series opening to list each date; eight, then Show
    /// more.
    fn meetings(
        &self,
        person: &PersonProfile,
        series: &[Series],
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let hidden = model::hidden_count(series.len(), model::VISIBLE_SERIES);
        let shown = if self.shows_all_series {
            series.len()
        } else {
            model::VISIBLE_SERIES
        };
        let expanded = self.shows_all_series;
        side_block(
            lokalbot_i18n::tr("Meetings"),
            Some(person.meeting_count()),
            cx,
        )
        .child(
            v_flex().w_full().children(
                series
                    .iter()
                    .take(shown)
                    .map(|item| self.series_row(item, now, cx)),
            ),
        )
        .when(hidden > 0, |this| {
            this.child(more_link(
                "person-meetings-more",
                expanded,
                hidden,
                |page, _| page.shows_all_series = !page.shows_all_series,
                cx,
            ))
        })
        .into_any_element()
    }

    /// A single meeting opens; a series opens to list each date. A call
    /// recorded in parts is one meeting that opens its longest recording
    /// (`MeetingSeriesRow`).
    fn series_row(
        &self,
        series: &Series,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let detail = model::series_detail(series, now);
        let page = cx.entity();
        if series.occasions.len() == 1 {
            let occasion = series.latest();
            let detail = match model::recordings_note(occasion) {
                Some(note) => format!("{detail} · {note}"),
                None => detail,
            };
            let id = occasion.primary().id;
            return meeting_link_row(
                SharedString::from(format!("person-series-{}", series.key())),
                series.title.clone(),
                Some(detail),
                Disclosure::None,
                false,
                move |_, cx| page.update(cx, |page, cx| page.open_meeting(id, None, cx)),
                cx,
            );
        }
        let key = series.key();
        let expanded = self.expanded_series.contains(&key);
        let toggle_key = key.clone();
        let row = meeting_link_row(
            SharedString::from(format!("person-series-{key}")),
            series.title.clone(),
            Some(detail),
            if expanded {
                Disclosure::Expanded
            } else {
                Disclosure::Collapsed
            },
            false,
            move |_, cx| {
                let key = toggle_key.clone();
                page.update(cx, |page, cx| {
                    if !page.expanded_series.remove(&key) {
                        page.expanded_series.insert(key);
                    }
                    cx.notify();
                })
            },
            cx,
        );
        if !expanded {
            return row;
        }
        v_flex()
            .w_full()
            .child(row)
            .children(series.occasions.iter().map(|occasion: &Occasion| {
                let page = cx.entity();
                let id = occasion.primary().id;
                meeting_link_row(
                    SharedString::from(format!("person-occasion-{id}")),
                    model::occasion_day(occasion),
                    model::recordings_note(occasion),
                    Disclosure::None,
                    true,
                    move |_, cx| page.update(cx, |page, cx| page.open_meeting(id, None, cx)),
                    cx,
                )
            }))
            .into_any_element()
    }

    /// Other names the person appears as.
    fn names(&self, person: &PersonProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        side_block(lokalbot_i18n::tr("Names"), None, cx)
            .child(
                h_flex()
                    .gap(px(7.))
                    .items_start()
                    .child(div().flex_none().pt(px(2.)).child(ui::icon(
                        Ico::User,
                        px(13.),
                        lb.text_secondary,
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(lokalbot_i18n::fill(
                                lokalbot_i18n::tr("Also appears as %@"),
                                &[&person.other_names.join(", ")],
                            ))),
                    ),
            )
            .into_any_element()
    }
}
