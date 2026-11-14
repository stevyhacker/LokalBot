//! Looking closer at a day: the session's moments with Find and an app filter
//! (`SessionMomentBrowser.swift`), one activity block with its related moments
//! (`activityPreview`), and the hour-indexed day track (`CaptureTrackView`).
//! Thumbnails are decrypted in memory only and released with the day.

use chrono::{DateTime, Local, Timelike as _, Utc};
use gpui_kit::component::button::Button;
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, ElementId, FontWeight, Hsla, InteractiveElement as _,
    IntoElement as _, ObjectFit, ParentElement as _, SharedString, StatefulInteractiveElement as _,
    Styled as _, StyledImage as _, div, img, px, relative,
};
use lokalbot_core::{ActivityBlock, Meeting, ScreenMoment, WorkSession};

use super::context::page_header;
use super::{DayModel, Selection, TimelinePage};
use crate::i18n::h_flex;
use crate::pages::today::digest::hm;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::section_panel::{SectionPanel, SectionPanelLead};
use crate::ui::{self, Ico};
use crate::windows::screen_image::{self, ScreenImage};

const THUMBNAIL_PIXELS: u32 = 240;
/// Decrypted thumbnails kept for a day; later rows show an icon instead.
const MAX_THUMBNAILS: usize = 32;
const POINTS_PER_HOUR: f32 = 108.;
const GUTTER: f32 = 56.;
/// Related moments an activity block lists.
const RELATED_MOMENTS: usize = 6;

impl TimelinePage {
    /// A moment's small image, loading it the first time it is asked for.
    pub(super) fn thumbnail(
        &self,
        moment: &ScreenMoment,
        cx: &mut Context<Self>,
    ) -> Option<ScreenImage> {
        if moment.path.is_empty() {
            return None;
        }
        {
            let thumbnails = self.thumbnails.borrow();
            if let Some(entry) = thumbnails.get(&moment.id) {
                return entry.clone();
            }
            if thumbnails.len() >= MAX_THUMBNAILS {
                return None;
            }
        }
        self.thumbnails.borrow_mut().insert(moment.id, None);
        let library = self.data.read(cx).library.clone();
        let loading = moment.clone();
        let id = moment.id;
        let day = self.day;
        cx.spawn(async move |this, cx| {
            let image = cx
                .background_spawn(async move {
                    screen_image::load(&library, &loading, THUMBNAIL_PIXELS)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.day == day {
                    this.thumbnails.borrow_mut().insert(id, Some(image));
                    cx.notify();
                }
            });
        })
        .detach();
        None
    }

    /// Forgets the day's thumbnails; their textures are freed on the next frame.
    pub(super) fn release_thumbnails(&mut self) {
        let thumbnails = std::mem::take(&mut *self.thumbnails.borrow_mut());
        for image in thumbnails.into_values().flatten() {
            if let ScreenImage::Ready(image) = image {
                self.released_images.push(image);
            }
        }
    }

    /// A moment's row: thumbnail, what it shows, when (`relatedMomentRow`).
    pub(super) fn moment_row(
        &self,
        id: impl Into<ElementId>,
        moment: &ScreenMoment,
        with_app: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let title = if !moment.document_name.is_empty() {
            moment.document_name.clone()
        } else if !moment.window_title.is_empty() {
            moment.window_title.clone()
        } else {
            moment.app.clone()
        };
        let when = lokalbot_core::time::clock_time(moment.ts);
        let detail = if with_app {
            format!("{} · {when}", moment.app)
        } else {
            when.to_string()
        };
        let thumbnail = match self.thumbnail(moment, cx) {
            Some(ScreenImage::Ready(image)) => div()
                .w(px(74.))
                .h(px(46.))
                .flex_none()
                .rounded(metric::ROW_RADIUS)
                .overflow_hidden()
                .bg(gpui_kit::black().opacity(0.82))
                .child(img(image).size_full().object_fit(ObjectFit::Contain))
                .into_any_element(),
            _ => div()
                .w(px(74.))
                .h(px(46.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(metric::ROW_RADIUS)
                .bg(lb.chip_fill)
                .child(ui::icon(
                    if moment.path.is_empty() {
                        Ico::ScanText
                    } else {
                        Ico::Camera
                    },
                    px(16.),
                    lb.app_color(&moment.app),
                ))
                .into_any_element(),
        };
        let moment_id = moment.id;
        h_flex()
            .id(id)
            .gap(px(10.))
            .items_center()
            .cursor_pointer()
            .rounded(metric::ROW_RADIUS)
            .hover(|s| s.bg(lb.hover))
            .on_click(
                cx.listener(move |this, _, _, cx| {
                    this.open_child(Selection::Moment(moment_id), cx)
                }),
            )
            .child(thumbnail)
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .line_clamp(2)
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(detail),
                    ),
            )
            .when(moment.is_saved, |this| {
                this.child(ui::icon(Ico::Bookmark, px(14.), lb.attention_text))
            })
            .child(ui::icon(Ico::ChevronRight, px(12.), lb.text_tertiary))
            .into_any_element()
    }

    /// Every moment of the session, findable by window, document or retained
    /// text, and by app (`SessionMomentBrowser`). "Show all N" in the Screen
    /// moments panel opens it.
    pub(super) fn render_moment_browser(
        &self,
        moments: &[&ScreenMoment],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let query = self.moment_search.read(cx).value().to_string();
        let filtered =
            lokalbot_core::timeline::moments_matching(moments, self.moment_app.as_deref(), &query);
        let mut apps: Vec<String> = moments.iter().map(|m| m.app.clone()).collect();
        apps.sort();
        apps.dedup();
        let current = self.moment_app.clone();
        let page = cx.entity().downgrade();
        let app_label = current
            .clone()
            .unwrap_or_else(|| lokalbot_i18n::tr("All apps").to_string());
        let rows: Vec<AnyElement> = filtered
            .iter()
            .map(|moment| {
                self.moment_row(
                    ("session-browse-moment", moment.id as u64),
                    moment,
                    true,
                    cx,
                )
            })
            .collect();
        v_flex()
            .gap(px(10.))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::format(
                        "Retained moments · {shown} of {total}",
                        &[
                            ("shown", filtered.len().to_string()),
                            ("total", moments.len().to_string()),
                        ],
                    )),
            )
            .child(Input::new(&self.moment_search).small().cleanable(true))
            .child(
                h_flex().child(
                    Button::new("session-browse-app")
                        .outline()
                        .small()
                        .label(app_label)
                        .dropdown_caret(true)
                        .dropdown_menu(move |menu, _, _| {
                            let mut menu = menu.scrollable(true).max_h(px(320.));
                            let options =
                                std::iter::once(None).chain(apps.iter().cloned().map(Some));
                            for option in options {
                                let page = page.clone();
                                let label: SharedString = option
                                    .clone()
                                    .unwrap_or_else(|| lokalbot_i18n::tr("All apps").to_string())
                                    .into();
                                let checked = option == current;
                                menu =
                                    menu.item(PopupMenuItem::new(label).checked(checked).on_click(
                                        move |_, _, cx| {
                                            let option = option.clone();
                                            let _ = page.update(cx, |this, cx| {
                                                this.moment_app = option;
                                                cx.notify();
                                            });
                                        },
                                    ));
                            }
                            menu
                        }),
                ),
            )
            .children(rows)
            .into_any_element()
    }

    /// One activity block (`activityPreview`): its app, time and title with
    /// the app's day in two figures, then the moments kept during it.
    pub(super) fn render_block(
        &self,
        model: &DayModel,
        block: &ActivityBlock,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let scoped: Vec<&ScreenMoment> = model
            .moments
            .iter()
            .filter(|m| m.ts >= block.start && m.ts <= block.end)
            .collect();
        let same_app: Vec<&ActivityBlock> = model
            .activity
            .blocks
            .iter()
            .filter(|b| b.app == block.app)
            .collect();
        let app_total: f64 = same_app.iter().map(|b| b.duration_seconds()).sum();
        let subtitle = format!(
            "{} · {}",
            super::rail::time_range(block.start, block.end),
            hm(block.duration_seconds())
        );
        let tile = |value: String, label: SharedString| {
            v_flex()
                .min_w(px(96.))
                .gap(px(1.))
                .px(px(12.))
                .py(px(8.))
                .rounded(metric::ROW_RADIUS)
                .bg(lb.group_fill)
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(value),
                )
                .child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.supporting)
                        .child(label),
                )
        };
        let related: Vec<AnyElement> = scoped
            .iter()
            .take(RELATED_MOMENTS)
            .map(|moment| self.moment_row(("block-moment", moment.id as u64), moment, false, cx))
            .collect();
        let question = lokalbot_i18n::format(
            "What matters from my {app} activity, {title}?",
            &[("app", block.app.clone()), ("title", block.title.clone())],
        );
        let lead = SectionPanelLead::new("timeline-block-lead").child(
            v_flex()
                .gap(px(12.))
                .child(page_header(
                    div()
                        .pt(px(7.))
                        .child(ui::status_dot(lb.app_color(&block.app), px(12.)))
                        .into_any_element(),
                    block.app.clone().into(),
                    subtitle,
                    cx,
                ))
                .when(!block.title.is_empty(), |this| {
                    this.child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(block.title.clone()),
                    )
                })
                .child(
                    h_flex()
                        .gap(px(8.))
                        .child(tile(hm(app_total), lokalbot_i18n::tr("today").into()))
                        .child(tile(
                            lokalbot_i18n::number(same_app.len()),
                            if same_app.len() == 1 {
                                lokalbot_i18n::tr("block").into()
                            } else {
                                lokalbot_i18n::tr("blocks").into()
                            },
                        )),
                ),
        );
        let moments = SectionPanel::new(
            "timeline-block-moments",
            lokalbot_i18n::tr("Related moments"),
        )
        .icon(Ico::Image)
        .count(scoped.len())
        .child(
            v_flex()
                .px(metric::PANEL_INSET)
                .py(px(12.))
                .gap(px(8.))
                .when(scoped.is_empty(), |this| {
                    this.child(div().text_size(ty::BODY).text_color(lb.supporting).child(
                        crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "No context moments were captured during this activity.",
                        )),
                    ))
                })
                .children(related),
        );
        v_flex()
            .gap(metric::PANEL_SPACING)
            .child(self.back_link(cx))
            .child(lead)
            .child(moments)
            .child(
                h_flex().child(
                    ui::controls::bordered_icon(
                        "ask-activity",
                        Ico::Search,
                        lokalbot_i18n::tr("Ask about this activity"),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.ask_day(question.clone(), Vec::new(), cx)
                    })),
                ),
            )
            .into_any_element()
    }

    /// The day on an hour-indexed track, with meetings in a lane of their own
    /// so they never hide the activity they overlap (`CaptureTrackView`).
    pub(super) fn render_track(&self, model: &DayModel, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let now = Utc::now();
        let meetings: Vec<(&Meeting, DateTime<Utc>)> = model
            .meetings
            .iter()
            .map(|m| (m, m.ended_at.unwrap_or(now).max(m.started_at)))
            .collect();
        let ranges: Vec<(DateTime<Utc>, DateTime<Utc>)> = model
            .activity
            .blocks
            .iter()
            .map(|b| (b.start, b.end))
            .chain(meetings.iter().map(|(m, end)| (m.started_at, *end)))
            .collect();
        let (start, hours) = track_extent(&ranges, now);
        let y = |at: DateTime<Utc>| (at - start).num_seconds() as f32 / 3600. * POINTS_PER_HOUR;
        let height = hours as f32 * POINTS_PER_HOUR;
        let rules = (0..hours).map(|hour| {
            let top = hour as f32 * POINTS_PER_HOUR;
            div()
                .absolute()
                .top(px(top))
                .left_0()
                .right_0()
                .h(px(1.))
                .bg(lb.separator.opacity(0.6))
        });
        let labels = (0..hours).map(|hour| {
            let top = hour as f32 * POINTS_PER_HOUR;
            let at = start + chrono::Duration::hours(hour as i64);
            div()
                .absolute()
                .top(px((top - 6.).max(0.)))
                .right(px(8.))
                .text_size(ty::CAPTION)
                .text_color(lb.text_tertiary)
                .child(lokalbot_core::time::clock_time(at))
        });
        let blocks: Vec<AnyElement> = model
            .activity
            .blocks
            .iter()
            .map(|block| {
                let height = (block.duration_seconds() as f32 / 3600. * POINTS_PER_HOUR).max(8.);
                let selected = self.selection == Some(Selection::Block(block.id));
                track_block(
                    ("track-block", block.id as u64),
                    y(block.start),
                    height,
                    lb.app_color(&block.app)
                        .opacity(if selected { 1. } else { 0.85 }),
                    selected.then_some(lb.accent_text),
                    block.app.clone(),
                    block.title.clone(),
                    format!(
                        "{}{}\n{}–{} · {}",
                        block.app,
                        if block.title.is_empty() {
                            String::new()
                        } else {
                            format!(" — {}", block.title)
                        },
                        lokalbot_core::time::clock_time(block.start),
                        lokalbot_core::time::clock_time(block.end),
                        hm(block.duration_seconds())
                    ),
                    lb.text,
                )
                .on_click({
                    let id = block.id;
                    cx.listener(move |this, _, _, cx| {
                        this.open_child(Selection::Block(id), cx);
                    })
                })
                .into_any_element()
            })
            .collect();
        let meeting_rows: Vec<AnyElement> = meetings
            .iter()
            .map(|(meeting, end)| {
                let seconds = (*end - meeting.started_at).num_seconds() as f32;
                let height = (seconds / 3600. * POINTS_PER_HOUR).max(24.);
                let selected = self.selection == Some(Selection::Meeting(meeting.id));
                let duration = hm(f64::from(seconds));
                track_block(
                    SharedString::from(format!("track-meeting-{}", meeting.id)),
                    y(meeting.started_at),
                    height,
                    lb.accent_fill.opacity(if selected { 1. } else { 0.85 }),
                    selected.then_some(gpui_kit::white().opacity(0.9)),
                    meeting.display_title(),
                    duration.clone(),
                    format!(
                        "{}\n{} · {duration}",
                        meeting.display_title(),
                        lokalbot_core::time::clock_time(meeting.started_at)
                    ),
                    gpui_kit::white(),
                )
                .on_click({
                    let id = meeting.id;
                    cx.listener(move |this, _, _, cx| {
                        this.select(Some(Selection::Meeting(id)), cx);
                    })
                })
                .into_any_element()
            })
            .collect();
        let has_meetings = !meeting_rows.is_empty();
        h_flex()
            .id("timeline-track")
            .w_full()
            .h(px(height))
            .items_start()
            .child(
                div()
                    .relative()
                    .w(px(GUTTER))
                    .flex_none()
                    .h_full()
                    .children(labels),
            )
            .child(
                h_flex()
                    .relative()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .items_start()
                    .gap(px(6.))
                    .children(rules)
                    .when(has_meetings, |this| {
                        this.child(
                            div()
                                .relative()
                                .w(relative(0.28))
                                .min_w(px(96.))
                                .flex_none()
                                .h_full()
                                .children(meeting_rows),
                        )
                    })
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_w(px(40.))
                            .h_full()
                            .children(blocks),
                    ),
            )
            .into_any_element()
    }

    /// Representative moments of a session, spaced evenly across its scenes.
    pub(super) fn session_scenes<'a>(
        model: &'a DayModel,
        session: &WorkSession,
    ) -> Vec<&'a ScreenMoment> {
        lokalbot_core::timeline::rewind_frames(&model.moments)
            .into_iter()
            .filter_map(|frame| frame.last().copied())
            .filter(|moment| moment.ts >= session.start && moment.ts <= session.end)
            .collect()
    }
}

/// Where the track starts (the first item's hour) and how many hours it covers.
fn track_extent(
    ranges: &[(DateTime<Utc>, DateTime<Utc>)],
    now: DateTime<Utc>,
) -> (DateTime<Utc>, usize) {
    let first = ranges.iter().map(|(start, _)| *start).min().unwrap_or(now);
    let start = first
        .with_timezone(&Local)
        .with_minute(0)
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_nanosecond(0))
        .map_or(first, |t| t.with_timezone(&Utc));
    let last = ranges
        .iter()
        .map(|(_, end)| *end)
        .max()
        .unwrap_or(start + chrono::Duration::hours(1));
    let hours = ((last - start).num_seconds() as f64 / 3600.).ceil() as usize;
    (start, hours.max(1))
}

/// A positioned block on the track; its text fits its height.
#[allow(clippy::too_many_arguments)]
fn track_block(
    id: impl Into<ElementId>,
    top: f32,
    height: f32,
    fill: Hsla,
    outline: Option<Hsla>,
    title: String,
    detail: String,
    tooltip: String,
    text: Hsla,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let tooltip: SharedString = tooltip.into();
    div()
        .id(id)
        .absolute()
        .top(px(top))
        .left_0()
        .right_0()
        .h(px(height))
        .overflow_hidden()
        .rounded(px(4.))
        .bg(fill)
        .cursor_pointer()
        .when_some(outline, |this, color| this.border_2().border_color(color))
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .when(height >= 20., |this| {
            this.child(
                v_flex()
                    .px(px(6.))
                    .pt(px(3.))
                    .gap(px(1.))
                    .text_color(text)
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::MEDIUM)
                            .child(title),
                    )
                    .when(height >= 38. && !detail.is_empty(), |this| {
                        this.child(div().truncate().text_size(ty::SMALL).child(detail))
                    }),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    #[test]
    fn the_track_starts_on_the_first_hour() {
        let at = |h, m| {
            Local
                .with_ymd_and_hms(2026, 10, 2, h, m, 0)
                .unwrap()
                .with_timezone(&Utc)
        };
        let (start, hours) = track_extent(
            &[(at(9, 40), at(10, 5)), (at(11, 0), at(11, 30))],
            at(23, 0),
        );
        assert_eq!(start, at(9, 0));
        assert_eq!(hours, 3);
        let (_, hours) = track_extent(&[(at(9, 0), at(9, 0))], at(23, 0));
        assert_eq!(hours, 1, "never empty");
    }
}
