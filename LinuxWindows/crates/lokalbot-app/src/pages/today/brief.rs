//! Yesterday's brief on Today (`YesterdayBriefPanel`, `DreamBriefText`): the
//! overnight review's narrative, its priorities with their real checkable
//! actions, and its notes. Reads what the review saved; never starts one by
//! itself. Pinning the projects and goals it keeps is in Settings › Day
//! memory, as on the Mac.

use std::collections::HashMap;

use chrono::NaiveDate;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, HighlightStyle, InteractiveText,
    IntoElement, ParentElement as _, SharedString, Styled as _, StyledText, UnderlineStyle, div,
    px,
};
use lokalbot_ai::dream::{is_retryable_failure, today_report};
use lokalbot_core::dream::presentation::{BriefPiece, brief_pieces};
use lokalbot_core::dream::{
    DreamReport, DreamStore, FallbackReason, InferenceLocation, MemoryEntry, day_from_key,
};
use lokalbot_core::{ActionThread, Library, Meeting};

use super::TodayPage;
use crate::i18n::h_flex;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::section_panel::{SectionPanel, footer_text, panel_label};
use crate::ui::{self, Ico};

/// What Today reads for the brief, off the main thread.
#[derive(Default)]
pub(super) struct BriefModel {
    report: Option<DreamReport>,
    /// Action threads a top action can point at, by id.
    threads: HashMap<String, ActionThread>,
}

impl BriefModel {
    /// There is a brief to show.
    pub(super) fn has_report(&self) -> bool {
        self.report.is_some()
    }
}

pub(super) fn load(library: &Library, today: NaiveDate) -> BriefModel {
    let report = today_report(library, today);
    let threads = if report
        .as_ref()
        .is_some_and(|r| r.top_action_thread_ids.is_some())
    {
        library
            .action_threads(None)
            .unwrap_or_default()
            .into_iter()
            .filter(|thread| {
                thread
                    .references
                    .iter()
                    .any(|reference| reference.is_for_user)
            })
            .map(|thread| (thread.id.clone(), thread))
            .collect()
    } else {
        HashMap::new()
    };
    BriefModel { report, threads }
}

/// `DreamReport.provenanceDescription`, translated for the page. The saved
/// Markdown keeps the English.
fn provenance_line(report: &DreamReport) -> String {
    if let Some(engine) = &report.engine_name {
        return match report.inference_provenance.as_ref().map(|p| p.location) {
            Some(InferenceLocation::Local) => {
                lokalbot_i18n::format("Dreamed by {0} on this computer.", &[("0", engine.clone())])
            }
            Some(InferenceLocation::Remote) => {
                match report
                    .inference_provenance
                    .as_ref()
                    .and_then(|p| p.origin.clone())
                {
                    Some(origin) => lokalbot_i18n::format(
                        "Dreamed by {0} using approved remote inference at {1}. The report was saved in your local library.",
                        &[("0", engine.clone()), ("1", origin)],
                    ),
                    None => lokalbot_i18n::format(
                        "Dreamed by {0} using approved remote inference. The report was saved in your local library.",
                        &[("0", engine.clone())],
                    ),
                }
            }
            None => lokalbot_i18n::format(
                "Dreamed by {0} using your configured Think model. The report was saved in your local library.",
                &[("0", engine.clone())],
            ),
        };
    }
    match report.fallback_reason {
        Some(FallbackReason::EngineUnavailable) => lokalbot_i18n::tr(
            "No model was reachable overnight; this evidence-only brief was saved locally.",
        ),
        Some(FallbackReason::UnparseableResponse) => lokalbot_i18n::tr(
            "The model replied, but its response could not be read; this evidence-only brief was saved locally.",
        ),
        Some(FallbackReason::EmptyDay) => lokalbot_i18n::tr(
            "Nothing substantive was recorded that day, so no model ran; this placeholder just keeps the record complete.",
        ),
        None => lokalbot_i18n::tr("Written as an evidence-only fallback and saved locally."),
    }
    .to_string()
}

/// One section of a brief: selectable-looking text whose cited meetings open.
fn brief_text(
    id: SharedString,
    text: &str,
    meetings: &[Meeting],
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let mut flat = String::new();
    let mut highlights = Vec::new();
    let mut ranges = Vec::new();
    let mut targets = Vec::new();
    for piece in brief_pieces(text, meetings) {
        match piece {
            BriefPiece::Text(text) => flat.push_str(&text),
            BriefPiece::Meeting { id, title } => {
                let start = flat.len();
                flat.push_str(&title);
                let range = start..flat.len();
                highlights.push((
                    range.clone(),
                    HighlightStyle {
                        color: Some(lb.accent_text),
                        underline: Some(UnderlineStyle {
                            thickness: px(1.),
                            color: Some(lb.accent_text.opacity(0.5)),
                            wavy: false,
                        }),
                        ..Default::default()
                    },
                ));
                ranges.push(range);
                targets.push(id);
            }
        }
    }
    let data = data.clone();
    div()
        .w_full()
        .text_size(ty::BODY)
        .line_height(px(21.))
        .text_color(lb.text)
        .text_align(crate::i18n::content_alignment(&flat))
        .child(
            InteractiveText::new(id, StyledText::new(flat).with_highlights(highlights)).on_click(
                ranges,
                move |index, _, cx| {
                    if let Some(meeting) = targets.get(index) {
                        crate::ui::action_row::open_meeting(&data, *meeting, None, cx);
                    }
                },
            ),
        )
        .into_any_element()
}

fn note(text: impl Into<SharedString>, cx: &App) -> gpui_kit::Div {
    div()
        .text_size(ty::SECONDARY)
        .text_color(cx.lb().text_secondary)
        .child(crate::ui::text::paragraph(text))
}

impl TodayPage {
    /// Yesterday's overnight brief as a panel (`YesterdayBriefPanel`): what
    /// happened, the priorities it leaves and its notes without a click,
    /// "Open day", and the brief's own account of how it was written in the
    /// footer. A brief older than yesterday is titled with its own day.
    pub(super) fn render_yesterday(
        &self,
        model: &BriefModel,
        today: NaiveDate,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let report = model.report.as_ref()?;
        let lb = cx.lb().clone();
        let current = super::model::brief_is_current(&report.day, today);
        let report_day = day_from_key(&report.day);
        let title: String = if current {
            lokalbot_i18n::tr("Yesterday").to_string()
        } else {
            report_day
                .map(abbreviated)
                .unwrap_or_else(|| report.day.clone())
        };
        let meetings = self.data.read(cx).meetings.clone();
        let mut body = v_flex()
            .w_full()
            .px(metric::PANEL_INSET)
            .py(px(14.))
            .gap(px(14.));
        if !report.narrative.is_empty() {
            body = body.child(brief_text(
                "today-brief-narrative".into(),
                &report.narrative,
                &meetings,
                &self.data,
                cx,
            ));
        }
        if !report.top_actions.is_empty() {
            let mut list = v_flex().w_full().gap(px(3.));
            for (index, action) in report.top_actions.iter().enumerate() {
                // A top action taken from the recorded candidates is the real
                // thread: it can be checked off here and stays in sync. The
                // rest are numbered advice.
                let thread = report
                    .top_action_thread_id(index)
                    .and_then(|id| model.threads.get(id));
                list = list.child(match thread {
                    Some(thread) => crate::ui::action_row::thread_row(
                        format!("today-brief-action-{index}").into(),
                        thread,
                        crate::ui::action_row::ThreadRowOptions::default(),
                        &self.data,
                        cx,
                    ),
                    None => h_flex()
                        .w_full()
                        .items_start()
                        .gap(px(6.))
                        .child(
                            div()
                                .flex_none()
                                .text_size(ty::BODY)
                                .line_height(px(21.))
                                .text_color(lb.text)
                                .child(format!("{}.", lokalbot_i18n::number(index + 1))),
                        )
                        .child(div().flex_1().min_w_0().child(brief_text(
                            format!("today-brief-top-{index}").into(),
                            action,
                            &meetings,
                            &self.data,
                            cx,
                        )))
                        .into_any_element(),
                });
            }
            body = body.child(
                v_flex()
                    .w_full()
                    .gap(px(6.))
                    .child(panel_label(priorities_label(&report.day, today), cx))
                    .child(list),
            );
        }
        let notes: Vec<&String> = report
            .attention
            .iter()
            .chain(&report.repeated_work)
            .chain(&report.suggested_checks)
            .chain(&report.frictions)
            .collect();
        if !notes.is_empty() {
            body = body.child(v_flex().w_full().gap(px(4.)).children(
                notes.into_iter().enumerate().map(|(index, text)| {
                    brief_text(
                        format!("today-brief-item-{index}").into(),
                        &format!("• {text}"),
                        &meetings,
                        &self.data,
                        cx,
                    )
                }),
            ));
        }
        if report.is_fallback() {
            body = body.child(note(
                lokalbot_i18n::tr("Previous-day summary uses captured evidence only."),
                cx,
            ));
        }
        if report.inference_provenance.as_ref().map(|p| p.location)
            == Some(InferenceLocation::Remote)
        {
            body = body.child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::Network, px(13.), lb.attention_text))
                    .child(note(
                        lokalbot_i18n::tr("Previous-day summary used approved remote inference"),
                        cx,
                    )),
            );
        }
        if is_retryable_failure(report, today) {
            let data = self.data.read(cx);
            let dreaming = data.dream.is_dreaming;
            let ready = data.meetings_loaded;
            let data = self.data.clone();
            body = body.child(
                h_flex().child(
                    Button::new("today-brief-retry")
                        .outline()
                        .small()
                        .label(if dreaming {
                            lokalbot_i18n::tr("Updating…")
                        } else {
                            lokalbot_i18n::tr("Retry previous-day summary")
                        })
                        .disabled(dreaming || !ready)
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.request(AppEvent::ReviewNow, cx))
                        }),
                ),
            );
        }
        let open_day = self.data.clone();
        Some(
            SectionPanel::new("today-yesterday", title)
                .icon(Ico::Moon)
                .when_some(report_day, |panel, day| {
                    panel.trailing_link(
                        "today-open-day",
                        lokalbot_i18n::tr("Open day"),
                        move |_, cx| {
                            open_day.update(cx, |data, cx| data.open_timeline(day, None, cx))
                        },
                    )
                })
                .child(body)
                // The report's own account of which model wrote it and where.
                .footer(footer_text(provenance_line(report)))
                .into_any_element(),
        )
    }
}

/// "Nov 12, 2026".
fn abbreviated(day: NaiveDate) -> String {
    day.format_localized(
        lokalbot_i18n::date_pattern("%b %-d, %Y"),
        lokalbot_i18n::date_locale(),
    )
    .to_string()
}

/// Whose priorities the brief holds: today's for yesterday's brief, an older
/// day's by its weekday within the week and its date beyond.
fn priorities_label(report_day: &str, today: NaiveDate) -> String {
    use super::model::{DayNaming, PrioritiesSource};
    match super::model::priorities_source(report_day, today) {
        PrioritiesSource::Today => lokalbot_i18n::tr("Priorities for today").to_string(),
        PrioritiesSource::PreviousWorkday => {
            lokalbot_i18n::tr("Priorities from a previous workday").to_string()
        }
        PrioritiesSource::Day(day, naming) => {
            let name = match naming {
                DayNaming::Weekday => day
                    .format_localized("%A", lokalbot_i18n::date_locale())
                    .to_string(),
                DayNaming::Date => abbreviated(day),
            };
            lokalbot_i18n::fill(lokalbot_i18n::tr("Priorities from %@"), &[&name])
        }
    }
}

/// Reloads before changing, so a page can't overwrite what a review wrote since.
pub(crate) fn set_pinned(data: &Entity<AppData>, pinned: bool, entry: MemoryEntry, cx: &mut App) {
    if data.read(cx).dream.is_dreaming {
        data.update(cx, |data, cx| {
            data.show_error(
                lokalbot_i18n::tr("Wait for the current dream to finish before changing pins."),
                cx,
            )
        });
        return;
    }
    let root = data.read(cx).library.paths().root().to_path_buf();
    let data = data.clone();
    cx.spawn(async move |cx| {
        let result = cx
            .background_spawn(async move {
                DreamStore::new(root).set_pinned(pinned, &entry, chrono::Utc::now())
            })
            .await;
        data.update(cx, |data, cx| {
            match result {
                Ok(Some(_)) => {}
                Ok(None) => data.show_error(
                    lokalbot_i18n::tr("That dream memory item is no longer available."),
                    cx,
                ),
                Err(err) => data.show_error(
                    lokalbot_i18n::format(
                        "Could not update dream memory: {0}",
                        &[("0", err.to_string())],
                    ),
                    cx,
                ),
            }
            data.mark_library_changed(cx);
        });
    })
    .detach();
}
