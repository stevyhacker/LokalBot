//! Today's day panels: Needs attention (`NeedsAttentionSection`), Meetings
//! today (`TodayMeetingsSection.swift`) and So far today
//! (`TodaySoFarSection.swift`).

use std::collections::HashMap;

use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px, relative,
};
use uuid::Uuid;

use super::model::{self, AgendaRow, AttentionSummary, DigestLine, Entry, EntryStatus};
use super::{TodayModel, TodayPage, status_text};
use crate::i18n::h_flex;
use crate::state::{AppEvent, Section, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::section_panel::{SectionPanel, footer_text, panel_label, panel_link};
use crate::ui::{self, action_row};

/// The time column of Meetings today, at the standard text size.
const TIME_COLUMN_WIDTH: f32 = 76.;
/// So far today's name and duration columns, which grow with the text size
/// like the time column. 100 pt fits "Google Chrome".
const APP_NAME_WIDTH: f32 = 108.;
const APP_DURATION_WIDTH: f32 = 56.;
/// "2h 25m" over the bars (22 pt on macOS).
const TRACKED_TOTAL: gpui_kit::Pixels = px(24.);
/// "Now · 10:48 AM" (11 pt bold on macOS).
const NOW_LINE: gpui_kit::Pixels = px(12.);

impl TodayPage {
    /// The most urgent of the user's open actions, overdue first, with how
    /// many are overdue and how many more wait in Actions. Nothing to act on
    /// means no panel at all.
    pub(super) fn render_attention(
        &self,
        model: &TodayModel,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if model.attention.is_empty() {
            return None;
        }
        let summary: AttentionSummary = model.summary;
        let all = self.data.clone();
        let more = self.data.clone();
        let rows = model.attention.iter().enumerate().map(|(ix, thread)| {
            action_row::thread_row(
                format!("today-thread-{ix}").into(),
                thread,
                action_row::ThreadRowOptions {
                    hint: model.hints.get(&thread.id),
                    ..Default::default()
                },
                &self.data,
                cx,
            )
        });
        let footer = summary.shows_footer();
        Some(
            SectionPanel::new("today-attention", lokalbot_i18n::tr("Needs attention"))
                .section(Section::Actions)
                .count(summary.open)
                .when(summary.overdue > 0, |panel| {
                    panel.alert(lokalbot_i18n::directional(lokalbot_i18n::fill(
                        lokalbot_i18n::tr("%lld overdue"),
                        &[&lokalbot_i18n::number(summary.overdue)],
                    )))
                })
                .trailing_link(
                    "today-all-actions",
                    lokalbot_i18n::tr("All actions"),
                    move |_, cx| all.update(cx, |data, cx| data.open_actions(cx)),
                )
                .rows(rows)
                .when(footer, |panel| {
                    panel
                        .footer(footer_text(lokalbot_i18n::fill(
                            lokalbot_i18n::tr("Showing the %lld most urgent"),
                            &[&lokalbot_i18n::number(summary.shown)],
                        )))
                        .footer(panel_link(
                            "today-attention-more",
                            lokalbot_i18n::directional(lokalbot_i18n::fill(
                                lokalbot_i18n::tr("%lld more in Actions"),
                                &[&lokalbot_i18n::number(summary.remainder)],
                            )),
                            move |_, cx| more.update(cx, |data, cx| data.open_actions(cx)),
                            cx,
                        ))
                })
                .into_any_element(),
        )
    }

    /// The day's meetings as one panel: what was recorded, with a line saying
    /// what it was about, and what the calendar still holds, with a line at
    /// now. Work sessions and apps are on Timeline.
    pub(super) fn render_meetings(
        &self,
        rows: Vec<AgendaRow>,
        count: usize,
        recaps: &HashMap<Uuid, String>,
        offers_calendar: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let mut list = v_flex().w_full();
        for (index, row) in rows.iter().enumerate() {
            match row {
                AgendaRow::Entry(entry) => {
                    let recap = entry
                        .meeting
                        .as_ref()
                        .and_then(|m| recaps.get(&m.id))
                        .cloned();
                    list = list.child(self.meeting_row(index, entry, recap, cx));
                    if model::has_hairline_after(index, &rows) {
                        list = list.child(ui::divider(cx));
                    }
                }
                AgendaRow::Now(at) => {
                    // The rule above the words; above the first meeting it
                    // takes the place of the header's hairline.
                    list = list.child(
                        v_flex()
                            .w_full()
                            .when(index == 0, |this| this.mt(px(-1.)))
                            .child(div().w_full().h(px(1.)).bg(lb.recording.opacity(0.6)))
                            .child(
                                h_flex()
                                    .w_full()
                                    .min_h(px(20.))
                                    .px(metric::PANEL_INSET)
                                    .items_center()
                                    .text_size(NOW_LINE)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.recording_text)
                                    .child(lokalbot_i18n::fill(
                                        lokalbot_i18n::tr("Now · %@"),
                                        &[&lokalbot_core::time::clock_time(*at)],
                                    )),
                            ),
                    );
                }
            }
        }
        let all = self.data.clone();
        let calendar = self.data.clone();
        let calendar_enabled = self.data.read(cx).settings.calendar_detection_enabled;
        SectionPanel::new("today-meetings", lokalbot_i18n::tr("Meetings today"))
            .section(Section::Meetings)
            .count(count)
            .trailing_link(
                "today-all-meetings",
                lokalbot_i18n::tr("All meetings"),
                move |_, cx| all.update(cx, |data, cx| data.navigate(Section::Meetings, cx)),
            )
            .when(!rows.is_empty(), |panel| panel.child(list))
            .when(offers_calendar, |panel| {
                panel
                    .footer(footer_text(lokalbot_i18n::tr(
                        "Upcoming meetings can show here too",
                    )))
                    .footer(panel_link(
                        "today-connect-calendar",
                        lokalbot_i18n::tr("Connect Calendar…"),
                        move |_, cx| {
                            // Calendar use and its sources are set up in
                            // Settings: the switch while it is off, else the
                            // calendar links it reads.
                            let focus = if calendar_enabled {
                                "settings.calendarLinks"
                            } else {
                                "settings.calendarDetectionEnabled"
                            };
                            calendar.update(cx, |data, cx| {
                                data.open_settings(SettingsCategory::Meetings, cx);
                                data.settings_focus = Some(focus.to_string());
                                cx.notify();
                            })
                        },
                        cx,
                    ))
            })
            .into_any_element()
    }

    /// One meeting: its time, title and where it stands, with the recap line
    /// under a recorded one. A recording opens; a calendar event does not.
    fn meeting_row(
        &self,
        index: usize,
        entry: &Entry,
        recap: Option<String>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let scale = self.data.read(cx).settings.text_size.scale();
        let (status, status_color, status_weight): (String, _, _) = match entry.status {
            EntryStatus::Recorded => {
                let meeting = entry.meeting.as_ref();
                let parts: Vec<String> = meeting
                    .map(|m| {
                        [
                            if m.is_merged_meeting() {
                                String::new()
                            } else {
                                m.app_name.clone()
                            },
                            crate::pages::meetings::model::duration_label(m),
                        ]
                        .into_iter()
                        .filter(|p| !p.is_empty())
                        .collect()
                    })
                    .unwrap_or_default();
                (
                    lokalbot_i18n::directional(parts.join(" · ")),
                    lb.text_secondary,
                    FontWeight::NORMAL,
                )
            }
            EntryStatus::Recording => (
                status_text(entry.status),
                lb.recording_text,
                FontWeight::SEMIBOLD,
            ),
            other if entry.is_soon => (status_text(other), lb.accent_text, FontWeight::SEMIBOLD),
            other => (status_text(other), lb.text_secondary, FontWeight::NORMAL),
        };
        let content = h_flex()
            .w_full()
            .items_start()
            .gap(px(12.))
            .px(metric::PANEL_INSET)
            .py(px(10.))
            .child(
                div()
                    .flex_none()
                    .w(px(TIME_COLUMN_WIDTH * scale))
                    .pt(px(1.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_core::time::clock_time(entry.start)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(12.))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(entry.title.clone()),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(ty::SECONDARY)
                                    .font_weight(status_weight)
                                    .text_color(status_color)
                                    .child(status),
                            ),
                    )
                    .when_some(recap, |this, recap| {
                        this.child(
                            div()
                                .w_full()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(recap),
                        )
                    }),
            );
        let id: SharedString = format!("today-meeting-{index}").into();
        match entry.meeting.as_ref().map(|m| m.id) {
            Some(meeting) => {
                let data = self.data.clone();
                let hover = lb.hover;
                div()
                    .id(id)
                    .w_full()
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover))
                    .child(content)
                    .on_click(move |_, _, cx| action_row::open_meeting(&data, meeting, None, cx))
                    .into_any_element()
            }
            None => div().id(id).w_full().child(content).into_any_element(),
        }
    }

    /// The day up to now: the tracked total, a bar per app, the digest's
    /// highlights, and a footer saying where the digest stands, with Update
    /// when there is newer activity. Sessions, tasks and the full digest are
    /// on Timeline.
    pub(super) fn render_so_far(
        &self,
        model: &TodayModel,
        writing: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let scale = self.data.read(cx).settings.text_size.scale();
        let per_app: Vec<(String, f64)> = model
            .activity
            .app_usage
            .iter()
            .filter(|u| !lokalbot_core::timeline::is_system_app(&u.app))
            .map(|u| (u.app.clone(), u.seconds))
            .collect();
        let total: f64 = per_app.iter().map(|(_, s)| s).sum();
        let bars = model::app_bars(&per_app, model::APP_LIMIT);
        let highlights = model::highlights_markdown(model.digest.as_ref());
        let line = DigestLine::new(
            model.digest.is_some(),
            model
                .digest
                .as_ref()
                .and_then(super::digest::digest_updated_at),
            model.digest.as_ref().is_some_and(|d| d.is_stale),
            writing,
        );
        let rtl = lokalbot_i18n::current().rtl;

        let tracked = (!per_app.is_empty()).then(|| {
            v_flex()
                .w_full()
                .gap(px(7.))
                .child(
                    h_flex()
                        .items_baseline()
                        .gap(px(6.))
                        .child(
                            div()
                                .text_size(TRACKED_TOTAL)
                                .font_weight(FontWeight::BOLD)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::directional(super::digest::hm(total))),
                        )
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.supporting)
                                .child(lokalbot_i18n::tr("tracked")),
                        ),
                )
                .children(bars.iter().map(|bar| {
                    let color = if bar.is_other {
                        lb.text_tertiary.opacity(0.8)
                    } else {
                        lb.app_color(&bar.label)
                    };
                    let label: SharedString = if bar.is_other {
                        lokalbot_i18n::tr("Other").into()
                    } else {
                        bar.label.clone().into()
                    };
                    let fraction = bar.fraction as f32;
                    h_flex()
                        .w_full()
                        .gap(px(10.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .child(
                            h_flex()
                                .flex_none()
                                .w(px(APP_NAME_WIDTH * scale))
                                .gap(px(6.))
                                .items_center()
                                .child(ui::status_dot(color, px(7.)))
                                .child(div().min_w_0().truncate().text_color(lb.text).child(label)),
                        )
                        // The name and the time say everything; the bar only
                        // shows it, growing from the leading edge.
                        .child(
                            h_flex()
                                .flex_1()
                                .h(px(6.))
                                .rounded_full()
                                .bg(lb.quiet_fill)
                                .child(
                                    div()
                                        .h_full()
                                        .w(relative(fraction))
                                        .when(fraction > 0., |this| this.min_w(px(3.)))
                                        .rounded_full()
                                        .bg(color),
                                ),
                        )
                        .child(
                            h_flex()
                                .flex_none()
                                .w(px(APP_DURATION_WIDTH * scale))
                                .when(!rtl, |this| this.justify_end())
                                .text_color(lb.supporting)
                                .child(lokalbot_i18n::directional(super::digest::hm(bar.seconds))),
                        )
                }))
        });
        let highlights = (!highlights.is_empty()).then(|| {
            v_flex()
                .w_full()
                .gap(px(6.))
                .child(panel_label(lokalbot_i18n::tr("Highlights"), cx))
                .child(
                    div()
                        .w_full()
                        .max_w(metric::READING_MAX_WIDTH)
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(
                            crate::ui::markdown_view::markdown("today-highlights", highlights)
                                .selectable(true),
                        ),
                )
        });
        let has_body = tracked.is_some() || highlights.is_some();
        let timeline = self.data.clone();
        let mut panel = SectionPanel::new("today-so-far", lokalbot_i18n::tr("So far today"))
            .section(Section::Timeline)
            .trailing_link(
                "today-open-timeline",
                lokalbot_i18n::tr("Open Timeline"),
                move |_, cx| timeline.update(cx, |data, cx| data.navigate(Section::Timeline, cx)),
            )
            .when(has_body, |panel| {
                panel.child(
                    v_flex()
                        .w_full()
                        .px(metric::PANEL_INSET)
                        .py(px(14.))
                        .gap(px(14.))
                        .children(tracked)
                        .children(highlights),
                )
            });
        if line.shows_footer() {
            panel = self.digest_line(panel, line, model, cx);
        }
        panel.into_any_element()
    }

    /// Where the digest stands, in So far today's footer.
    fn digest_line(
        &self,
        panel: SectionPanel,
        line: DigestLine,
        model: &TodayModel,
        cx: &mut Context<Self>,
    ) -> SectionPanel {
        let day = model.day;
        let data = self.data.clone();
        let write = move |label: &'static str, cx: &mut Context<Self>| {
            let data = data.clone();
            panel_link(
                "today-digest-write",
                label,
                move |_, cx| {
                    data.update(cx, |data, cx| {
                        data.request(AppEvent::RegenerateDigest(day), cx)
                    })
                },
                cx,
            )
        };
        let written = |at: chrono::DateTime<chrono::Utc>| {
            lokalbot_i18n::fill(
                lokalbot_i18n::tr("Digest written %@"),
                &[&lokalbot_core::time::clock_time(at)],
            )
        };
        match line {
            DigestLine::Writing => panel
                .footer(gpui_kit::component::spinner::Spinner::new().small())
                .footer(footer_text(lokalbot_i18n::tr("Writing Digest…"))),
            DigestLine::Missing => panel
                .footer(footer_text(lokalbot_i18n::tr(
                    "Your digest brings together this day's meetings and captured activity.",
                )))
                .footer(write(lokalbot_i18n::tr("Write Digest"), cx)),
            DigestLine::Current(Some(at)) => panel.footer(footer_text(written(at))),
            DigestLine::Current(None) => panel,
            DigestLine::Stale(at) => {
                let since = lokalbot_i18n::tr("New activity since");
                let text = match at {
                    Some(at) => format!("{} · {since}", written(at)),
                    None => since.to_string(),
                };
                panel
                    .footer(footer_text(text))
                    .footer(write(lokalbot_i18n::tr("Update"), cx))
            }
        }
    }
}
