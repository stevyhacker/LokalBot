//! The day's page, Timeline's main area while nothing is chosen in the rail
//! (`TimelineDigestPage.swift`): Highlights, the actions from the day's
//! meetings, the work summary and the decisions, each on its own panel.

use std::collections::HashMap;
use std::rc::Rc;

use chrono::{DateTime, Local, Utc};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement as _, ParentElement as _, Styled as _, div, px,
};

use super::day_list::{
    self, ActionsPill, DigestLine, actions_pill, actions_show_rows, actions_summary,
};
use super::work_summary::{self, OpenSession, TaskToggle, WorkSummary};
use super::{DayModel, Selection, TimelinePage};
use crate::i18n::h_flex;
use crate::pages::today::digest::digest_updated_at;
use crate::state::{AppEvent, Section};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row::{self, ThreadRowOptions};
use crate::ui::section_panel::{PillTone, SectionPanel, footer_text, panel_link};
use crate::ui::{self, Ico};
use lokalbot_i18n::mac;

impl TimelinePage {
    pub(super) fn render_day_page(
        &mut self,
        model: &DayModel,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut panels: Vec<AnyElement> = Vec::new();
        panels.extend(self.highlights_panel(model, cx));
        panels.extend(self.day_actions_panel(model, cx));
        if let Some(digest) = model
            .digest
            .as_ref()
            .filter(|d| work_summary::has_body_below_highlights(d))
        {
            let page = cx.entity().downgrade();
            let on_toggle: TaskToggle = Rc::new(move |ix, _, cx| {
                let _ = page.update(cx, |this, cx| {
                    if !this.expanded_tasks.remove(&ix) {
                        this.expanded_tasks.insert(ix);
                    }
                    cx.notify();
                });
            });
            let page = cx.entity().downgrade();
            let open_session: OpenSession = Rc::new(move |session, _, cx| {
                let _ = page.update(cx, |this, cx| {
                    this.select(Some(Selection::Session(session)), cx)
                });
            });
            // An older digest's "09:00–10:30" opens the session it covers.
            let sessions: HashMap<String, String> = digest
                .tasks
                .iter()
                .chain(&digest.follow_up_tasks)
                .filter_map(|task| task.time_range.clone())
                .filter_map(|range| {
                    let row = model.list.work_row_in_time_range(&range, self.day)?;
                    let day_list::RowKind::Work(session) = &row.kind else {
                        return None;
                    };
                    Some((range, session.clone()))
                })
                .collect();
            let summary = WorkSummary {
                digest,
                expanded: &self.expanded_tasks,
                on_toggle,
                sessions: &sessions,
                open_session,
            };
            panels.extend(work_summary::work_summary_panel(&summary, cx));
            panels.extend(work_summary::decisions_panel(&digest.decisions, cx));
        }
        self.page_column("timeline-day-page", panels, cx)
    }

    /// The digest's highlights as the page's first panel. Its footer says
    /// when the digest was written and offers Update once there is newer
    /// activity. A day without a digest, and one being written, say so here.
    fn highlights_panel(&self, model: &DayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let (writing, writes_each_evening) = {
            let data = self.data.read(cx);
            (
                data.digest_running == Some(self.day),
                data.settings.day_digest_auto_enabled,
            )
        };
        let digest = model.digest.as_ref();
        let has_digest = digest.is_some();
        let state = DigestLine::state(
            has_digest,
            digest.and_then(digest_updated_at),
            digest.is_some_and(|d| d.is_stale),
            writing,
        );
        let highlights = digest
            .map(|d| d.at_a_glance_markdown.trim().to_string())
            .filter(|text| !text.is_empty());
        let writing_first = state == DigestLine::Writing && !has_digest;
        let shows_content = highlights.is_some() || state == DigestLine::Missing || writing_first;
        let shows_footer = state.shows_footer(has_digest);
        // A digest with no highlights and no date has nothing to say here.
        if !shows_content && !shows_footer {
            return None;
        }
        let data = self.data.clone();
        let day = self.day;
        let write = move |_: &mut gpui_kit::Window, cx: &mut gpui_kit::App| {
            data.update(cx, |data, cx| {
                data.request(AppEvent::RegenerateDigest(day), cx)
            })
        };
        let mut panel = SectionPanel::new("timeline-highlights", lokalbot_i18n::tr("Highlights"))
            .icon(Ico::FileText);
        if shows_content {
            let lead = |text: &'static str| {
                div()
                    .text_size(ty::READING)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(text)))
            };
            let supporting = |text: &'static str| {
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.supporting)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(text)))
            };
            let missing = (state == DigestLine::Missing).then(|| {
                let write = write.clone();
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(lead("No digest for this day yet"))
                            .child(supporting(if writes_each_evening {
                                "LokalBot writes one each evening from the day's meetings and work."
                            } else {
                                "Your digest brings together this day's meetings and captured activity."
                            })),
                    )
                    .child(
                        ui::controls::bordered(
                            "timeline-write-digest",
                            lokalbot_i18n::tr("Write Digest"),
                        )
                        .on_click(move |_, window, cx| write(window, cx)),
                    )
            });
            let writing_line = writing_first.then(|| {
                h_flex()
                    .gap(px(12.))
                    .items_center()
                    .child(Spinner::new().small().color(lb.accent_text))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(lead("Writing this day's digest…"))
                            .child(supporting("The day below is already up to date.")),
                    )
            });
            panel = panel.child(
                v_flex()
                    .px(metric::PANEL_INSET)
                    .py(px(14.))
                    .gap(px(10.))
                    .when_some(highlights, |this, text| {
                        this.child(
                            div().text_size(ty::READING).text_color(lb.text).child(
                                crate::ui::markdown_view::markdown(
                                    "timeline-highlights-text",
                                    text,
                                )
                                .selectable(true),
                            ),
                        )
                    })
                    .children(missing)
                    .children(writing_line),
            );
        }
        if shows_footer {
            panel = match state {
                DigestLine::Writing => panel
                    .footer(Spinner::new().xsmall().color(lb.accent_text))
                    .footer(footer_text(lokalbot_i18n::tr(
                        "Updating the digest with new activity…",
                    ))),
                DigestLine::Current(Some(at)) => panel.footer(footer_text(self.written(at))),
                DigestLine::Stale(at) => {
                    let since = lokalbot_i18n::tr("New activity since");
                    let text = match at {
                        Some(at) => format!("{} · {since}", self.written(at)),
                        None => since.to_string(),
                    };
                    panel.footer(footer_text(text)).footer(panel_link(
                        "timeline-update-digest",
                        lokalbot_i18n::tr("Update"),
                        write,
                        cx,
                    ))
                }
                DigestLine::Current(None) | DigestLine::Missing => panel,
            };
        }
        Some(panel.into_any_element())
    }

    /// "Digest written 6:02 PM": the time alone on the day itself, the date
    /// too once it was written later.
    fn written(&self, at: DateTime<Utc>) -> String {
        let local = at.with_timezone(&Local);
        let text = if local.date_naive() == self.day {
            lokalbot_core::time::clock_time(at)
        } else {
            local
                .format_localized(
                    lokalbot_i18n::date_pattern("%b %-d, %Y, %-I:%M %p"),
                    lokalbot_i18n::date_locale(),
                )
                .to_string()
        };
        mac("Digest written %@", &[&text])
    }

    /// The user's actions from the day's meetings, as the shared action rows
    /// under a header that counts the open ones and leads to Actions. With
    /// none open the panel is its header, "All done".
    fn day_actions_panel(
        &mut self,
        model: &DayModel,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let summary = actions_summary(&model.threads)?;
        if matches!(summary, day_list::ActionsSummary::Open(_)) {
            self.actions_had_open = true;
        }
        let (status, tone) = match actions_pill(summary) {
            ActionsPill::Open(count) => (
                mac("%lld open", &[&lokalbot_i18n::number(count)]),
                PillTone::Count,
            ),
            ActionsPill::AllDone => (lokalbot_i18n::tr("All done").to_string(), PillTone::Done),
        };
        let data = self.data.clone();
        let mut panel = SectionPanel::new(
            "timeline-day-actions",
            lokalbot_i18n::tr("Actions from this day’s meetings"),
        )
        .section(Section::Actions)
        .status(status, tone)
        // The longest panel title on the page, beside a badge and a link.
        .title_lines(2)
        .trailing_link(
            "timeline-all-actions",
            lokalbot_i18n::tr("All actions"),
            move |_, cx| data.update(cx, |data, cx| data.open_actions(cx)),
        );
        if actions_show_rows(summary, self.actions_had_open) {
            panel = panel.rows(model.threads.iter().enumerate().map(|(ix, thread)| {
                action_row::thread_row(
                    format!("timeline-thread-{ix}").into(),
                    thread,
                    ThreadRowOptions {
                        hint: model.hints.get(&thread.id),
                        ..Default::default()
                    },
                    &self.data,
                    cx,
                )
            }));
        }
        Some(panel.into_any_element())
    }
}
