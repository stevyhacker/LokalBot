//! Yesterday's brief on Today (`YesterdayDigestLine`, `DreamBriefText`,
//! `BriefContextView`): the overnight review's narrative, priorities with their
//! real checkable actions, and the projects and goals it keeps, which can be
//! pinned. Reads what the review saved; never starts one by itself.

use std::collections::HashMap;

use chrono::NaiveDate;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, HighlightStyle,
    InteractiveElement as _, InteractiveText, IntoElement, ParentElement as _, SharedString,
    StatefulInteractiveElement as _, Styled as _, StyledText, UnderlineStyle, div, px,
};
use lokalbot_ai::dream::{is_retryable_failure, today_report};
use lokalbot_core::dream::presentation::{BriefPiece, brief_pieces, brief_plain};
use lokalbot_core::dream::{
    DreamMemory, DreamReport, DreamStore, FallbackReason, InferenceLocation, MemoryEntry,
    day_from_key, day_key,
};
use lokalbot_core::{ActionThread, Library, Meeting};

use super::TodayPage;
use crate::i18n::h_flex;
use crate::state::{AppData, AppEvent, SettingsCategory};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// What Today reads for the brief, off the main thread.
#[derive(Default)]
pub(super) struct BriefModel {
    report: Option<DreamReport>,
    memory: Option<DreamMemory>,
    /// Action threads a top action can point at, by id.
    threads: HashMap<String, ActionThread>,
}

/// What stays open across reloads.
#[derive(Default)]
pub(super) struct BriefState {
    expanded: bool,
    context_expanded: bool,
}

pub(super) fn load(library: &Library, today: NaiveDate) -> BriefModel {
    let report = today_report(library, today);
    let memory = DreamStore::new(library.paths().root())
        .load_memory()
        .unwrap_or_else(|err| {
            log::warn!("reading work memory: {err:#}");
            None
        });
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
    BriefModel {
        report,
        memory,
        threads,
    }
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
    /// The card below the day's digest, when there is a brief to show. A brief
    /// older than yesterday is labeled with its own day.
    pub(super) fn render_brief(
        &self,
        model: &BriefModel,
        today: NaiveDate,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let mut sections = Vec::new();
        let lb = cx.lb().clone();
        if let Some(report) = &model.report {
            let current = report.day == day_key(today - chrono::Duration::days(1));
            let label: String = if current {
                lokalbot_i18n::tr("Yesterday").to_string()
            } else {
                day_from_key(&report.day)
                    .map(|day| {
                        day.format_localized(
                            lokalbot_i18n::date_pattern("%b %-d, %Y"),
                            lokalbot_i18n::date_locale(),
                        )
                        .to_string()
                    })
                    .unwrap_or_else(|| lokalbot_i18n::tr("Previous workday").to_string())
            };
            let expanded = self.brief.expanded;
            let header = h_flex()
                .id("today-brief-toggle")
                .gap(px(8.))
                .items_baseline()
                .cursor_pointer()
                .child(ui::icon(
                    if expanded {
                        Ico::ChevronDown
                    } else {
                        Ico::ChevronRight
                    },
                    px(12.),
                    lb.text_secondary,
                ))
                .child(
                    div()
                        .flex_none()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(label),
                )
                .when(!expanded, |this| {
                    this.child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text_secondary)
                            .child(brief_plain(&report.narrative, &self.data.read(cx).meetings)),
                    )
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.brief.expanded = !this.brief.expanded;
                    cx.notify();
                }));
            let mut card = ui::panel(cx).child(header);
            if expanded {
                let meetings = self.data.read(cx).meetings.clone();
                let mut body = v_flex().gap(px(10.)).pt(px(8.)).child(brief_text(
                    "today-brief-narrative".into(),
                    &report.narrative,
                    &meetings,
                    &self.data,
                    cx,
                ));
                for (index, action) in report.top_actions.iter().enumerate() {
                    // A top action taken from the recorded candidates is the real
                    // thread: it can be checked off here and stays in sync.
                    let thread = report
                        .top_action_thread_id(index)
                        .and_then(|id| model.threads.get(id));
                    body = body.child(match thread {
                        Some(thread) => crate::ui::action_row::thread_row(
                            format!("today-brief-action-{index}").into(),
                            thread,
                            crate::ui::action_row::ThreadRowOptions::default(),
                            &self.data,
                            cx,
                        ),
                        None => brief_text(
                            format!("today-brief-top-{index}").into(),
                            &format!("• {action}"),
                            &meetings,
                            &self.data,
                            cx,
                        ),
                    });
                }
                for (index, text) in report
                    .attention
                    .iter()
                    .chain(&report.repeated_work)
                    .chain(&report.suggested_checks)
                    .chain(&report.frictions)
                    .enumerate()
                {
                    body = body.child(brief_text(
                        format!("today-brief-item-{index}").into(),
                        &format!("• {text}"),
                        &meetings,
                        &self.data,
                        cx,
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
                                lokalbot_i18n::tr(
                                    "Previous-day summary used approved remote inference",
                                ),
                                cx,
                            )),
                    );
                }
                body = body.child(note(provenance_line(report), cx));
                if is_retryable_failure(report, today) {
                    let dreaming = self.data.read(cx).dream.is_dreaming;
                    let data = self.data.clone();
                    body = body.child(
                        Button::new("today-brief-retry")
                            .outline()
                            .small()
                            .label(if dreaming {
                                lokalbot_i18n::tr("Updating…")
                            } else {
                                lokalbot_i18n::tr("Retry previous-day summary")
                            })
                            .disabled(dreaming)
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| data.request(AppEvent::ReviewNow, cx))
                            }),
                    );
                }
                card = card.child(body);
            }
            sections.push(card.into_any_element());
        }
        if let Some(context) = self.render_brief_context(model, cx) {
            sections.push(context);
        }
        sections
    }

    /// `BriefContextView`: what the review reads besides the day's evidence.
    fn render_brief_context(
        &self,
        model: &BriefModel,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.data.read(cx).settings.dreaming_enabled && model.memory.is_none() {
            return None;
        }
        let lb = cx.lb().clone();
        let expanded = self.brief.context_expanded;
        let header = h_flex()
            .id("today-brief-context")
            .gap(px(6.))
            .items_center()
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .font_weight(FontWeight::MEDIUM)
            .text_color(lb.text_secondary)
            .hover(|s| s.text_color(lb.text))
            .child(ui::icon(
                if expanded {
                    Ico::ChevronDown
                } else {
                    Ico::ChevronRight
                },
                px(12.),
                lb.text_secondary,
            ))
            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                "Context used for the morning brief",
            )))
            .on_click(cx.listener(|this, _, _, cx| {
                this.brief.context_expanded = !this.brief.context_expanded;
                cx.notify();
            }));
        let mut column = v_flex().gap(px(8.)).child(header);
        if expanded {
            let dreaming = self.data.read(cx).dream.is_dreaming;
            let mut body = v_flex().gap(px(10.)).pl(px(18.)).child(note(
                lokalbot_i18n::tr(
                    "Overnight review uses your recorded evidence and the projects and goals below. Pin an item to keep it in future reviews.",
                ),
                cx,
            ));
            let rows = model
                .memory
                .as_ref()
                .map(|memory| {
                    let projects = memory.active_projects.iter().map(|project| {
                        (
                            project.name.clone(),
                            project.status.clone(),
                            project.pinned,
                            MemoryEntry::Project(project.name.clone()),
                        )
                    });
                    let goals = memory.work_goals.iter().map(|goal| {
                        (
                            goal.text.clone(),
                            goal.horizon.clone(),
                            goal.pinned,
                            MemoryEntry::Goal(goal.text.clone()),
                        )
                    });
                    projects.chain(goals).collect::<Vec<_>>()
                })
                .unwrap_or_default();
            if rows.is_empty() {
                body = body.child(note(
                    lokalbot_i18n::tr("No projects or goals have been identified yet."),
                    cx,
                ));
            }
            for (index, (title, detail, pinned, entry)) in rows.into_iter().enumerate() {
                let data = self.data.clone();
                body = body.child(
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            Switch::new(("today-brief-pin", index))
                                .checked(pinned)
                                .disabled(dreaming)
                                .on_click(move |checked, _, cx| {
                                    set_pinned(&data, *checked, entry.clone(), cx);
                                }),
                        )
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(title)),
                                )
                                .child(note(detail, cx)),
                        ),
                );
            }
            let data = self.data.clone();
            body = body.child(
                Button::new("today-brief-configure")
                    .ghost()
                    .small()
                    .label(lokalbot_i18n::tr("Configure overnight review"))
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.open_settings(SettingsCategory::DayMemory, cx)
                        })
                    }),
            );
            column = column.child(body);
        }
        Some(column.pb(metric::HEADER_TO_CONTENT).into_any_element())
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
