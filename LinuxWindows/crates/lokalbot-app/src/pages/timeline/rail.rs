//! Timeline's rail, on the trailing side of the day's page
//! (`TimelineRail.swift`): the paused line, the tracked total with the hour
//! strip and its legend, then the day's sessions and meetings in time order
//! under Morning, Afternoon and Evening, with All captured activity pinned
//! as its bottom row. Choosing a row, or a bar of the strip, shows it on the
//! page beside; choosing it again returns to the day.

use chrono::{DateTime, Utc};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement as _,
    KeyDownEvent, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    canvas, div, px,
};

use super::day_list::{self, DayStrip, Entry, ListSelection, Row};
use super::{DayModel, TimelinePage, agent_work};
use crate::i18n::h_flex;
use crate::pages::today::digest::{self, hm};
use crate::theme::{LbThemeExt as _, Palette, metric, ty};
use crate::ui::section_panel::{PillTone, pill};
use crate::ui::{self, Ico};
use lokalbot_i18n::{mac, mac_count};

/// From the rail's edge to its text, the panels' own inset.
const INSET: f32 = 16.;
/// The row's padding before its time, and the column the dots sit in.
const ROW_LEADING: f32 = 4.;
const AXIS_WIDTH: f32 = 24.;
/// Rows sit this far in from the rail's edges, so their selection floats.
const ROW_MARGIN: f32 = 8.;
/// A row's title and second line, and from its top to the centre of its dot.
const TITLE_LINE: f32 = 18.;
const DETAIL_LINE: f32 = 16.;
const DOT_CENTER: f32 = 5. + TITLE_LINE / 2.;

/// The strip's lanes: meetings above, work below, then the hour labels.
const MEETING_LANE_HEIGHT: f32 = 9.;
const WORK_LANE_TOP: f32 = 13.;
const WORK_LANE_HEIGHT: f32 = 20.;
const LABEL_TOP: f32 = 37.;
const STRIP_HEIGHT: f32 = LABEL_TOP + 16.;
/// About one hour label every 44 points keeps "12 PM" clear of its neighbours.
const LABEL_WIDTH: f32 = 44.;

/// What the legend lists: a project's or app's time, the folded rest, or the
/// meetings' total.
struct LegendRow {
    label: String,
    seconds: f64,
    mark: Hsla,
    meetings: bool,
}

/// A rail row's time: "9:10" on a 12-hour clock, without AM or PM (the list
/// is under Morning, Afternoon and Evening), the locale's own form otherwise.
pub(super) fn list_clock(at: DateTime<Utc>) -> String {
    let twelve_hour = lokalbot_i18n::date_pattern("%-I:%M %p").contains("%p");
    at.with_timezone(&chrono::Local)
        .format_localized(
            if twelve_hour { "%-I:%M" } else { "%H:%M" },
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

/// "9 AM" for the first hour and noon, "10" for the rest; a 24-hour clock
/// shows the hour either way.
fn hour_label(at: DateTime<Utc>, names_day_period: bool) -> String {
    let twelve_hour = lokalbot_i18n::date_pattern("%-I:%M %p").contains("%p");
    let pattern = match (twelve_hour, names_day_period) {
        (true, true) => "%-I %p",
        (true, false) => "%-I",
        (false, _) => "%-H",
    };
    at.with_timezone(&chrono::Local)
        .format_localized(pattern, lokalbot_i18n::date_locale())
        .to_string()
}

/// A colour key's colour: a project's or app's own, neutral for other activity.
fn key_color(key: Option<&str>, lb: &Palette) -> Hsla {
    key.map_or(lb.text_tertiary.opacity(0.8), |key| lb.app_color(key))
}

impl TimelinePage {
    pub(super) fn render_rail(&mut self, model: &DayModel, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let has_day = model.has_day();
        let paused = self.data.read(cx).day_memory_paused;
        let selection = self.list_selection();
        let banner = paused.then(|| self.paused_banner(cx));
        let mut rail = v_flex()
            .id("timeline-rail")
            .size_full()
            .bg(lb.window)
            .track_focus(&self.rail_focus)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                match event.keystroke.key.as_str() {
                    "up" => this.step(-1, cx),
                    "down" => this.step(1, cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .children(banner);
        if !has_day {
            return rail
                .child(
                    div()
                        .w_full()
                        .py(px(28.))
                        .flex()
                        .justify_center()
                        .text_size(ty::BODY)
                        .text_color(lb.supporting)
                        .child(lokalbot_i18n::tr("Nothing recorded")),
                )
                .into_any_element();
        }
        if let Some(tracked) = self.tracked_block(model, cx) {
            rail = rail.child(tracked).child(ui::divider(cx));
        }
        let rows = self.session_rows(model, &selection, cx);
        rail.child(
            h_flex()
                .flex_none()
                .gap(px(8.))
                .items_center()
                .px(px(INSET))
                .pt(px(12.))
                .pb(px(2.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::PANEL_TITLE)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Sessions")),
                )
                .child(pill(
                    lokalbot_i18n::number(model.list.row_count()),
                    PillTone::Count,
                    cx,
                )),
        )
        .child(
            div()
                .id("timeline-sessions")
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .overflow_y_scroll()
                .track_scroll(&self.rail_scroll)
                .pb(px(6.))
                .children(rows),
        )
        .child(ui::divider(cx))
        .child(self.raw_capture_row(model, selection == ListSelection::Raw, cx))
        .into_any_element()
    }

    /// "Day memory is paused" with Resume, above everything else.
    fn paused_banner(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        div()
            .flex_none()
            .px(px(12.))
            .pt(px(10.))
            .child(
                ui::status_surface(lb.attention, cx)
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(10.))
                    .py(px(7.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(ui::icon(Ico::Pause, px(12.), lb.attention_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(ui::text::paragraph(lokalbot_i18n::tr(
                                "Day memory is paused",
                            ))),
                    )
                    .child(ui::link(
                        "timeline-resume",
                        lokalbot_i18n::tr("Resume"),
                        move |_, cx| super::set_day_memory_paused(&data, false, cx),
                        cx,
                    )),
            )
            .into_any_element()
    }

    // ---------------------------------------------------------- tracked

    /// The day's total in large type, the meetings and what the agents
    /// recorded, the hour strip, and where the time went as rows. Left out
    /// on a day with no tracked time and no meetings.
    fn tracked_block(&self, model: &DayModel, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let activity = &model.activity;
        let shares = digest::app_shares(activity);
        let meeting_count = model.meetings.len();
        if shares.is_empty() && meeting_count == 0 {
            return None;
        }
        let tracked: f64 = activity
            .app_usage
            .iter()
            .filter(|u| !lokalbot_core::timeline::is_system_app(&u.app))
            .map(|u| u.seconds)
            .sum();
        let mut detail: Vec<String> = Vec::new();
        if meeting_count > 0 {
            detail.push(mac_count(meeting_count, "%lld meeting", "%lld meetings"));
        }
        detail.extend(agent_work::outcome_text(&agent_work::day_outcomes(
            &activity.agent_bursts,
        )));
        let (day_start, day_end) = lokalbot_core::time::local_day_bounds(self.day);
        let strip = DayStrip::new(model.list.rows(), day_start, day_end);
        // By project when the day's agents name them, else by app.
        let mut legend: Vec<LegendRow> = if activity.project_split.projects.is_empty() {
            shares
                .iter()
                .map(|share| LegendRow {
                    label: share.label.clone(),
                    seconds: share.seconds,
                    mark: digest::share_color(share, cx),
                    meetings: false,
                })
                .collect()
        } else {
            agent_work::project_rows(&activity.project_split)
                .iter()
                .map(|row| LegendRow {
                    label: row.label.clone(),
                    seconds: row.seconds,
                    mark: agent_work::row_color(row, cx),
                    meetings: false,
                })
                .collect()
        };
        let meeting_seconds: f64 = model
            .list
            .rows()
            .filter(|row| row.is_meeting())
            .map(|row| row.duration)
            .sum();
        if meeting_seconds > 0. {
            legend.push(LegendRow {
                label: lokalbot_i18n::tr("Meetings").to_string(),
                seconds: meeting_seconds,
                mark: lb.accent_fill,
                meetings: true,
            });
        }
        let legend_rows =
            legend.into_iter().map(|row| {
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(div().w(px(8.)).flex_none().flex().justify_center().child(
                        if row.meetings {
                            div().w(px(8.)).h(px(4.)).rounded(px(2.)).bg(row.mark)
                        } else {
                            ui::status_dot(row.mark, px(8.))
                        },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(lb.text)
                            .child(row.label),
                    )
                    .child(
                        div()
                            .flex_none()
                            .text_color(lb.supporting)
                            .child(hm(row.seconds)),
                    )
            });
        Some(
            v_flex()
                .id("timeline-tracked")
                .flex_none()
                .w_full()
                .gap(px(11.))
                .px(px(INSET))
                .pt(px(14.))
                .pb(px(13.))
                .child(
                    v_flex()
                        .gap(px(1.))
                        .child(
                            h_flex()
                                .gap(px(6.))
                                .items_baseline()
                                .child(
                                    div()
                                        .text_size(px(24.))
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(hm(tracked)),
                                )
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.supporting)
                                        .child(lokalbot_i18n::tr("tracked")),
                                ),
                        )
                        .when(!detail.is_empty(), |this| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(ui::text::paragraph(detail.join(" · "))),
                            )
                        }),
                )
                .children(strip.map(|strip| self.day_strip(&strip, model, cx)))
                .child(
                    v_flex()
                        .gap(px(4.))
                        .text_size(ty::SECONDARY)
                        .line_height(px(DETAIL_LINE + 1.))
                        .children(legend_rows),
                )
                .into_any_element(),
        )
    }

    /// The day strip: hour lines and labels, a thin lane of meetings above
    /// the lane of work. A bar chooses its row in the list under it. Hours
    /// run left to right in every language, like a clock's day.
    fn day_strip(&self, strip: &DayStrip, model: &DayModel, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let measured = self.strip_width.clone();
        let width = measured.get();
        let measure = canvas(
            move |bounds, window, _| {
                let next = f32::from(bounds.size.width);
                if (measured.get() - next).abs() > 0.5 {
                    measured.set(next);
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        let ticks = strip.ticks.iter().map(|tick| {
            div()
                .absolute()
                .top_0()
                .left(px(tick.position as f32 * width))
                .w(px(1.))
                .h(px(WORK_LANE_TOP + WORK_LANE_HEIGHT))
                .bg(lb.text.opacity(0.07))
        });
        let fitting = ((width / LABEL_WIDTH) as usize).max(1);
        let labels = strip.labelled_ticks(fitting).into_iter().map(|tick| {
            div()
                .absolute()
                .top(px(LABEL_TOP))
                .left(px(tick.position as f32 * width + 3.))
                .whitespace_nowrap()
                .text_size(ty::CAPTION)
                .text_color(lb.supporting)
                .child(hour_label(tick.at, tick.names_day_period))
        });
        let bar = |bar: &day_list::Bar, top: f32, height: f32, color: Hsla| -> AnyElement {
            let (x, drawn) = day_list::bar_frame(bar, width, 3.);
            let (hit_x, hit_width) = day_list::bar_hit_frame(bar, width);
            let row = model.list.row(&bar.id);
            let tooltip: SharedString = row
                .map(|row| format!("{} · {}", row.title, hm(row.duration)))
                .unwrap_or_default()
                .into();
            let target = bar.id.clone();
            div()
                .id(SharedString::from(format!("timeline-bar-{}", bar.id)))
                .absolute()
                .top(px(top))
                .left(px(hit_x))
                .w(px(hit_width))
                .h(px(height))
                .cursor_pointer()
                .child(
                    div()
                        .absolute()
                        .top_0()
                        .left(px(x - hit_x))
                        .w(px((drawn - 1.).max(1.)))
                        .h(px(height))
                        .rounded(px(3.))
                        .bg(color),
                )
                .when(!tooltip.is_empty(), |this| {
                    this.tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.rail_focus.focus(window, cx);
                    this.rail_reveal = Some(target.clone());
                    this.choose(ListSelection::Row(target.clone()), cx);
                }))
                .into_any_element()
        };
        let meeting_bars: Vec<AnyElement> = day_list::hit_order(&strip.meetings)
            .into_iter()
            .map(|b| bar(b, 0., MEETING_LANE_HEIGHT, lb.accent_fill))
            .collect();
        let work_bars: Vec<AnyElement> = day_list::hit_order(&strip.work)
            .into_iter()
            .map(|b| {
                bar(
                    b,
                    WORK_LANE_TOP,
                    WORK_LANE_HEIGHT,
                    key_color(b.color_key.as_deref(), &lb),
                )
            })
            .collect();
        div()
            .id("timeline-strip")
            .relative()
            .w_full()
            .h(px(STRIP_HEIGHT))
            .child(measure)
            .when(width > 0., |this| {
                this.child(
                    div()
                        .absolute()
                        .top(px(WORK_LANE_TOP))
                        .left_0()
                        .w(px(width))
                        .h(px(WORK_LANE_HEIGHT))
                        .rounded(px(4.))
                        .bg(lb.quiet_fill),
                )
                .children(ticks)
                .children(labels)
                .children(meeting_bars)
                .children(work_bars)
            })
            .into_any_element()
    }

    // --------------------------------------------------------- sessions

    /// The sessions and meetings under their part of the day, every entry a
    /// direct child so a chosen row can be scrolled into view.
    fn session_rows(
        &mut self,
        model: &DayModel,
        selection: &ListSelection,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let mut children: Vec<AnyElement> = Vec::new();
        let mut reveal: Option<usize> = None;
        for (index, section) in model.list.sections.iter().enumerate() {
            if index > 0 {
                children.push(
                    div()
                        .px(px(INSET))
                        .pt(px(5.))
                        .child(ui::divider(cx))
                        .into_any_element(),
                );
            }
            children.push(
                div()
                    .px(px(INSET))
                    .pt(px(8.))
                    .pb(px(3.))
                    .text_size(ty::PILL)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.supporting)
                    .child(lokalbot_i18n::tr(section.part.title()))
                    .into_any_element(),
            );
            let is_row = |at: Option<&Entry>| -> bool { matches!(at, Some(Entry::Row(_))) };
            for (position, entry) in section.entries.iter().enumerate() {
                match entry {
                    Entry::Row(row) => {
                        if self.rail_reveal.as_deref() == Some(row.id.as_str()) {
                            reveal = Some(children.len());
                        }
                        let joins_above = position > 0 && is_row(section.entries.get(position - 1));
                        let joins_below = is_row(section.entries.get(position + 1));
                        let selected = *selection == ListSelection::Row(row.id.clone());
                        children.push(self.session_row(
                            row,
                            selected,
                            joins_above,
                            joins_below,
                            cx,
                        ));
                    }
                    Entry::Away { start, end } => children.push(away_row(*start, *end, cx)),
                }
            }
        }
        if let Some(index) = reveal {
            self.rail_scroll.scroll_to_item(index);
            self.rail_reveal = None;
        }
        children
    }

    /// A session or meeting: its time, its dot or waveform on the day's
    /// line, its title over a second line, and how long it ran.
    fn session_row(
        &self,
        row: &Row,
        selected: bool,
        joins_above: bool,
        joins_below: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let rtl = lokalbot_i18n::current().rtl;
        let ground = if selected {
            lb.sidebar_selection
        } else {
            lb.window
        };
        let time_width = 42.;
        let marker: AnyElement = if row.is_meeting() {
            div()
                .size(px(16.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(4.))
                .bg(ground)
                .child(ui::icon(
                    Ico::AudioLines,
                    px(12.),
                    if row.is_live() {
                        lb.recording_text
                    } else {
                        lb.accent_text
                    },
                ))
                .into_any_element()
        } else {
            div()
                .size(px(14.))
                .flex()
                .items_center()
                .justify_center()
                .rounded_full()
                .bg(ground)
                .child(ui::status_dot(
                    key_color(row.color_key.as_deref(), &lb),
                    px(9.),
                ))
                .into_any_element()
        };
        // One line runs through the dots of neighbouring rows, so the list
        // reads as a day. It starts at the first dot and ends at the last.
        let spine_x = ROW_LEADING + time_width + AXIS_WIDTH / 2. - 0.75;
        let spine = (joins_above || joins_below).then(|| {
            let top = if joins_above { 0. } else { DOT_CENTER };
            div()
                .absolute()
                .map(|this| {
                    if rtl {
                        this.right(px(spine_x))
                    } else {
                        this.left(px(spine_x))
                    }
                })
                .top(px(top))
                .w(px(1.5))
                .map(|this| {
                    if joins_below {
                        this.bottom_0()
                    } else {
                        this.h(px(DOT_CENTER - top))
                    }
                })
                .bg(lb.text.opacity(0.10))
        });
        let detail_color = if row.is_meeting() {
            if row.is_live() {
                lb.recording_text
            } else {
                lb.accent_text
            }
        } else {
            lb.supporting
        };
        let target = row.id.clone();
        let tooltip: SharedString = if row.detail.is_empty() {
            format!("{}\n{}", row.title, time_range(row.start, row.end))
        } else {
            format!(
                "{}\n{}\n{}",
                row.title,
                row.detail,
                time_range(row.start, row.end)
            )
        }
        .into();
        div()
            .px(px(ROW_MARGIN))
            .child(
                h_flex()
                    .id(SharedString::from(format!("timeline-row-{}", row.id)))
                    .relative()
                    .w_full()
                    .items_start()
                    .py(px(5.))
                    // The time's side gets the small inset, in either direction.
                    .map(|this| {
                        if rtl {
                            this.pr(px(ROW_LEADING)).pl(px(10.))
                        } else {
                            this.pl(px(ROW_LEADING)).pr(px(10.))
                        }
                    })
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .map(|this| {
                        if selected {
                            this.bg(lb.sidebar_selection)
                        } else {
                            this.hover(|s| s.bg(lb.text.opacity(0.04)))
                        }
                    })
                    .children(spine)
                    .child(
                        h_flex()
                            .w(px(time_width))
                            .flex_none()
                            .justify_end()
                            .line_height(px(TITLE_LINE))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .whitespace_nowrap()
                            .child(list_clock(row.start)),
                    )
                    .child(
                        div()
                            .w(px(AXIS_WIDTH))
                            .h(px((DOT_CENTER - 5.) * 2.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(marker),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .line_height(px(TITLE_LINE))
                                    .map(|this| {
                                        if row.quiet {
                                            this.text_color(lb.supporting)
                                        } else {
                                            this.font_weight(FontWeight::MEDIUM).text_color(lb.text)
                                        }
                                    })
                                    .child(row.title.clone()),
                            )
                            .when(!row.detail.is_empty(), |this| {
                                this.child(
                                    div()
                                        .truncate()
                                        .text_size(ty::SECONDARY)
                                        .line_height(px(DETAIL_LINE))
                                        .text_color(detail_color)
                                        .child(row.detail.clone()),
                                )
                            }),
                    )
                    .child(
                        div()
                            .flex_none()
                            .pl(px(10.))
                            .line_height(px(TITLE_LINE))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .whitespace_nowrap()
                            .child(hm(row.duration)),
                    )
                    .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.rail_focus.focus(window, cx);
                        this.choose(ListSelection::Row(target.clone()), cx);
                    })),
            )
            .into_any_element()
    }

    /// The rail's bottom row, opening every activity block and screen moment.
    fn raw_capture_row(
        &self,
        model: &DayModel,
        selected: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let forward = if lokalbot_i18n::current().rtl {
            Ico::ChevronLeft
        } else {
            Ico::ChevronRight
        };
        div()
            .flex_none()
            .px(px(ROW_MARGIN))
            .pt(px(5.))
            .pb(px(6.))
            .child(
                h_flex()
                    .id("timeline-raw-capture")
                    .w_full()
                    .gap(px(10.))
                    .items_center()
                    .px(px(10.))
                    .py(px(7.))
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .map(|this| {
                        if selected {
                            this.bg(lb.sidebar_selection)
                        } else {
                            this.hover(|s| s.bg(lb.text.opacity(0.04)))
                        }
                    })
                    .child(div().w(px(18.)).flex_none().child(ui::icon(
                        Ico::Activity,
                        px(15.),
                        lb.supporting,
                    )))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .line_height(px(TITLE_LINE))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(lb.text)
                                    .child(lokalbot_i18n::tr("All captured activity")),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .line_height(px(DETAIL_LINE))
                                    .text_color(lb.supporting)
                                    .child(capture_counts(model)),
                            ),
                    )
                    .child(ui::icon(forward, px(12.), lb.supporting))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.rail_focus.focus(window, cx);
                        this.choose(ListSelection::Raw, cx);
                    })),
            )
            .into_any_element()
    }
}

/// "3 activity entries · 0 screen moments", each count its own catalog entry.
pub(super) fn capture_counts(model: &DayModel) -> String {
    format!(
        "{} · {}",
        mac_count(
            model.activity.blocks.len(),
            "%lld activity entry",
            "%lld activity entries"
        ),
        mac_count(
            model.moments.len(),
            "%lld screen moment",
            "%lld screen moments"
        )
    )
}

/// "9:00 AM–10:30 AM".
pub(super) fn time_range(start: DateTime<Utc>, end: DateTime<Utc>) -> String {
    format!(
        "{}–{}",
        lokalbot_core::time::clock_time(start),
        lokalbot_core::time::clock_time(end.max(start))
    )
}

/// A stretch with nothing recorded between two rows: a dotted piece of the
/// line through the dots, and how long it lasted.
fn away_row(start: DateTime<Utc>, end: DateTime<Utc>, cx: &App) -> AnyElement {
    let lb = cx.lb();
    let seconds = (end - start).num_seconds().max(0) as f64;
    let dots = (0..4).map(|_| div().size(px(1.5)).rounded_full().bg(lb.text.opacity(0.25)));
    h_flex()
        .h(px(24.))
        .px(px(ROW_MARGIN))
        .items_center()
        .child(div().w(px(ROW_LEADING + 42.)).flex_none())
        .child(
            v_flex()
                .w(px(AXIS_WIDTH))
                .h_full()
                .flex_none()
                .items_center()
                .justify_center()
                .gap(px(3.))
                .children(dots),
        )
        .child(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.supporting)
                .child(mac("Away %@", &[&hm(seconds)])),
        )
        .into_any_element()
}
