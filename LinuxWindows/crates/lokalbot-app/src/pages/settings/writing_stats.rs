//! Settings → Writing → Statistics (`AutocompleteStatisticsView.swift`) and
//! Usage and timing (`AutocompleteExperienceView.usage`): how much autocomplete
//! wrote, what it was shown and what was kept. These are worked out from reads
//! of the field rather than from keys, so they are estimates, and the footer
//! says so. Bars are drawn with plain elements.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::{
    AnyElement, App, ClipboardItem, Context, FontWeight, IntoElement, ParentElement as _,
    SharedString, Styled as _, Window, div, px,
};
use lokalbot_core::cotyping_stats::{
    LiveMeasure, SURFACES, UsageBucket, UsageCounts, UsageRange, UsageSummary, local_day,
};
use lokalbot_engine::{AutocompleteCommand, Command};

use super::{Section, SettingsPage};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, settings_row};

const RANGES: [UsageRange; 4] = [
    UsageRange::Week,
    UsageRange::Month,
    UsageRange::Year,
    UsageRange::AllTime,
];

/// "≈ 3 hr, 25 min", "≈ 41 min", "≈ 50 sec", "0".
pub fn time_saved(seconds: f64) -> String {
    let rounded = seconds.round() as i64;
    if rounded <= 0 {
        return "0".to_string();
    }
    if rounded < 60 {
        return lokalbot_i18n::format("≈ {0} sec", &[("0", rounded.to_string())]);
    }
    if rounded < 3_600 {
        return lokalbot_i18n::format("≈ {0} min", &[("0", (rounded / 60).to_string())]);
    }
    lokalbot_i18n::format(
        "≈ {0} hr, {1} min",
        &[
            ("0", (rounded / 3_600).to_string()),
            ("1", ((rounded % 3_600) / 60).to_string()),
        ],
    )
}

fn percent(value: Option<f64>) -> String {
    value.map_or_else(|| "—".to_string(), |value| format!("{:.0}%", value * 100.0))
}

fn decimal(value: Option<f64>) -> String {
    value.map_or_else(|| "—".to_string(), |value| format!("{value:.1}"))
}

fn words_detail(counts: &UsageCounts) -> String {
    let mut parts = Vec::new();
    if let Some(per_use) = counts.words_per_used_suggestion() {
        parts.push(lokalbot_i18n::format(
            "{0} per suggestion used",
            &[("0", decimal(Some(per_use)))],
        ));
    }
    if counts.taken_back > 0 {
        parts.push(lokalbot_i18n::format(
            "{0} taken back",
            &[("0", counts.taken_back.to_string())],
        ));
    }
    if parts.is_empty() {
        lokalbot_i18n::tr("None accepted yet").to_string()
    } else {
        parts.join(" · ")
    }
}

fn used_detail(counts: &UsageCounts) -> String {
    lokalbot_i18n::format(
        "{0} of {1} shown",
        &[
            ("0", counts.used.min(counts.shown).to_string()),
            ("1", counts.shown.to_string()),
        ],
    )
}

fn share_detail(bucket: &UsageBucket) -> String {
    let total = bucket.suggestions.characters + bucket.typed_characters;
    lokalbot_i18n::format(
        "{0} of {1} characters written",
        &[
            ("0", bucket.suggestions.characters.to_string()),
            ("1", total.to_string()),
        ],
    )
}

fn time_saved_detail(summary: &UsageSummary) -> String {
    let keystrokes = summary.total.suggestions.keystrokes_saved().to_string();
    match summary.words_per_minute() {
        Some(wpm) => lokalbot_i18n::format(
            "{0} keystrokes at your {1} words a minute",
            &[("0", keystrokes), ("1", wpm.to_string())],
        ),
        None => lokalbot_i18n::format(
            "{0} keystrokes at 40 words a minute until your speed is measured",
            &[("0", keystrokes)],
        ),
    }
}

/// "Used on 12 of 30 days · 4 typos fixed".
fn active_detail(summary: &UsageSummary) -> String {
    let args = [
        ("0", summary.active_bars().to_string()),
        ("1", summary.bars.len().to_string()),
    ];
    let mut text = if summary.monthly {
        lokalbot_i18n::format("Used in {0} of {1} months", &args)
    } else {
        lokalbot_i18n::format("Used on {0} of {1} days", &args)
    };
    if summary.total.typos_fixed > 0 {
        text.push_str(" · ");
        text.push_str(&lokalbot_i18n::format(
            "{0} typos fixed",
            &[("0", summary.total.typos_fixed.to_string())],
        ));
    }
    text
}

/// Kinds of app with any suggestion shown, most words first.
fn surface_rows(bucket: &UsageBucket) -> Vec<(String, UsageCounts)> {
    let mut rows: Vec<(String, UsageCounts)> = SURFACES
        .iter()
        .filter_map(|(key, title)| {
            let counts = bucket.surfaces.get(*key)?;
            (counts.shown > 0 || counts.words > 0)
                .then(|| (surface_title(title).to_string(), *counts))
        })
        .collect();
    rows.sort_by_key(|a| std::cmp::Reverse(a.1.words));
    rows
}

fn surface_title(title: &'static str) -> &'static str {
    match title {
        "Native apps" => lokalbot_i18n::tr("Native apps"),
        "Browsers" => lokalbot_i18n::tr("Browsers"),
        "Chat" => lokalbot_i18n::tr("Chat"),
        "Email" => lokalbot_i18n::tr("Email"),
        "Code editors" => lokalbot_i18n::tr("Code editors"),
        "Terminals" => lokalbot_i18n::tr("Terminals"),
        other => other,
    }
}

/// Models with any suggestion shown, most shown first.
fn model_rows(bucket: &UsageBucket) -> Vec<(String, UsageCounts)> {
    let mut rows: Vec<(String, UsageCounts)> = bucket
        .models
        .iter()
        .filter(|(_, counts)| counts.shown > 0)
        .map(|(id, counts)| (super::models::model_name(id).to_string(), *counts))
        .collect();
    rows.sort_by(|a, b| b.1.shown.cmp(&a.1.shown).then(a.0.cmp(&b.0)));
    rows
}

fn tile(title: &'static str, value: String, detail: String, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    v_flex()
        .flex_1()
        .min_w(px(150.))
        .gap(px(2.))
        .p(px(10.))
        .rounded(px(8.))
        .bg(lb.text.opacity(0.05))
        .child(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(title),
        )
        .child(
            div()
                .text_size(ty::COLUMN_TITLE)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(value),
        )
        .child(
            div()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(detail),
        )
}

fn tiles(summary: &UsageSummary, cx: &App) -> gpui_kit::Div {
    let counts = summary.total.suggestions;
    h_flex()
        .w_full()
        .flex_wrap()
        .items_start()
        .gap(px(8.))
        .child(tile(
            lokalbot_i18n::tr("Words accepted"),
            counts.words.to_string(),
            words_detail(&counts),
            cx,
        ))
        .child(tile(
            lokalbot_i18n::tr("Suggestions used"),
            percent(counts.acceptance_rate()),
            used_detail(&counts),
            cx,
        ))
        .child(tile(
            lokalbot_i18n::tr("Of your text"),
            percent(summary.total.share_of_text()),
            share_detail(&summary.total),
            cx,
        ))
        .child(tile(
            lokalbot_i18n::tr("Time saved"),
            time_saved(summary.time_saved_seconds()),
            time_saved_detail(summary),
            cx,
        ))
}

/// One column per day or month; empty periods keep the time axis even.
fn chart(summary: &UsageSummary, words: bool, cx: &App) -> gpui_kit::Div {
    const HEIGHT: f32 = 110.0;
    let lb = cx.lb();
    let ceiling = summary.word_ceiling() as f32;
    let bars = summary.bars.iter().map(|bar| {
        let counts = bar.bucket.suggestions;
        let fraction = if words {
            counts.words as f32 / ceiling
        } else {
            // A day with nothing shown has no rate, not a rate of zero.
            counts.acceptance_rate().unwrap_or(0.0) as f32
        };
        div()
            .flex_1()
            .min_w(px(1.))
            .h(px((fraction.clamp(0.0, 1.0) * HEIGHT).max(0.0)))
            .rounded_t(px(2.))
            .bg(lb.accent_text)
    });
    let first = summary
        .bars
        .first()
        .map(|bar| axis_label(bar.start, summary.monthly));
    let last = summary
        .bars
        .last()
        .map(|bar| axis_label(bar.start, summary.monthly));
    v_flex()
        .w_full()
        .gap(px(4.))
        .child(
            h_flex()
                .w_full()
                .h(px(HEIGHT))
                .gap(px(2.))
                .items_end()
                .border_b_1()
                .border_color(lb.separator)
                .children(bars),
        )
        .child(
            h_flex()
                .w_full()
                .justify_between()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(first.unwrap_or_default())
                .child(last.unwrap_or_default()),
        )
}

fn axis_label(date: chrono::NaiveDate, monthly: bool) -> String {
    if monthly {
        date.format("%b %Y").to_string()
    } else {
        date.format("%b %-d").to_string()
    }
}

fn breakdown(title: &'static str, rows: Vec<(String, UsageCounts)>, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    let cell = |text: String, width: f32| {
        div()
            .w(px(width))
            .flex_none()
            .flex()
            .justify_end()
            .child(text)
    };
    let header = h_flex()
        .w_full()
        .text_color(lb.text_secondary)
        .child(div().flex_1().min_w_0())
        .child(cell(lokalbot_i18n::tr("Shown").to_string(), 60.))
        .child(cell(lokalbot_i18n::tr("Used").to_string(), 60.))
        .child(cell(lokalbot_i18n::tr("Words").to_string(), 60.))
        .child(cell(lokalbot_i18n::tr("Words per use").to_string(), 100.))
        .child(cell(lokalbot_i18n::tr("Taken back").to_string(), 80.));
    v_flex()
        .w_full()
        .gap(px(4.))
        .text_size(ty::SECONDARY)
        .child(
            div()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(title),
        )
        .child(header)
        .children(rows.into_iter().map(|(name, counts)| {
            h_flex()
                .w_full()
                .text_color(lb.text)
                .child(div().flex_1().min_w_0().child(name))
                .child(cell(counts.shown.to_string(), 60.))
                .child(cell(percent(counts.acceptance_rate()), 60.))
                .child(cell(counts.words.to_string(), 60.))
                .child(cell(decimal(counts.words_per_used_suggestion()), 100.))
                .child(cell(counts.taken_back.to_string(), 80.))
        }))
}

fn timing(measure: &LiveMeasure) -> String {
    match measure.median_visible_ms() {
        None => "n/a".to_string(),
        Some(median) => format!(
            "{median} ms (p95 {})",
            measure.p95_visible_ms().unwrap_or(median)
        ),
    }
}

fn insertions(measure: &LiveMeasure) -> String {
    let mut text = lokalbot_i18n::format(
        "{0} of {1}",
        &[
            ("0", measure.insertions_confirmed.to_string()),
            ("1", measure.insertions_checked().to_string()),
        ],
    );
    if measure.insertions_unconfirmed > 0 {
        text.push_str(", ");
        text.push_str(&lokalbot_i18n::format(
            "{0} not readable",
            &[("0", measure.insertions_unconfirmed.to_string())],
        ));
    }
    text
}

impl SettingsPage {
    /// Hidden while autocomplete was never used and is off.
    pub(super) fn statistics_section(&mut self, cx: &mut Context<Self>) -> Option<Section> {
        let enabled = self.data.read(cx).settings.cotyping_enabled;
        let autocomplete = crate::autocomplete::global(cx)?;
        let usage = autocomplete.read(cx).measures.usage.clone();
        if !enabled && usage.is_empty() {
            return None;
        }
        let today = local_day(chrono::Utc::now());
        let summary = usage.summary(self.writing.range, today);
        let range_index = RANGES
            .iter()
            .position(|range| *range == self.writing.range)
            .unwrap_or(1);
        let lb = cx.lb().clone();
        let picker = settings_row::segmented(
            "autocomplete-statistics-range",
            &[
                lokalbot_i18n::tr("7 days"),
                lokalbot_i18n::tr("30 days"),
                lokalbot_i18n::tr("12 months"),
                lokalbot_i18n::tr("All time"),
            ],
            range_index,
            {
                let page = cx.entity();
                move |index, _, cx| {
                    page.update(cx, |page, cx| {
                        page.writing.range = RANGES[index.min(3)];
                        cx.notify();
                    })
                }
            },
            cx,
        );
        let mut body = v_flex().w_full().gap(px(12.)).child(h_flex().child(picker));
        if summary.total.is_empty() {
            body = body.child(settings_row::help(
                if usage.is_empty() {
                    lokalbot_i18n::tr(
                        "Statistics appear here once you use autocomplete in other apps.",
                    )
                } else {
                    lokalbot_i18n::tr("Autocomplete was not used in this period.")
                },
                cx,
            ));
        } else {
            let metric = settings_row::segmented(
                "autocomplete-statistics-metric",
                &[
                    lokalbot_i18n::tr("Words"),
                    lokalbot_i18n::tr("Suggestions used"),
                ],
                usize::from(!self.writing.chart_words),
                {
                    let page = cx.entity();
                    move |index, _, cx| {
                        page.update(cx, |page, cx| {
                            page.writing.chart_words = index == 0;
                            cx.notify();
                        })
                    }
                },
                cx,
            );
            body = body
                .child(tiles(&summary, cx))
                .child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .justify_between()
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(active_detail(&summary)),
                        )
                        .child(metric),
                )
                .child(chart(&summary, self.writing.chart_words, cx));
            let surfaces = surface_rows(&summary.total);
            if surfaces.len() > 1 {
                body = body.child(breakdown(lokalbot_i18n::tr("By kind of app"), surfaces, cx));
            }
            // A model column says something only once there is another to compare.
            let models = model_rows(&summary.total);
            if models.len() > 1 {
                body = body.child(breakdown(lokalbot_i18n::tr("By model"), models, cx));
            }
        }
        let has_usage = !usage.is_empty();
        body = body
            .child(settings_row::help(
                lokalbot_i18n::tr("Estimated on this computer from what it reads in the field while you type in other apps: suggestions shown and accepted, the characters you type yourself where autocomplete works, and the pauses between reads, by day, kind of app and model. No text, app names or window titles are kept. Time saved is the keystrokes you did not type at your measured speed, not counting time spent reading suggestions."),
                cx,
            ))
            .child(
                h_flex().child(
                    Button::new("settings-clear-autocomplete-statistics")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Clear statistics…"))
                        .disabled(!has_usage)
                        .on_click(move |_, window, cx| confirm_clear(window, cx)),
                ),
            );
        let id = "settings.autocompleteStatistics";
        Some(Section::new(lokalbot_i18n::tr("Statistics")).row(
            id,
            settings_row::content_row(id, body, self.is_focused(id), cx),
        ))
    }

    /// Counters and timings from typing in other apps, under a disclosure.
    pub(super) fn usage_timing(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let open = self.writing.timing_open;
        let toggle = Button::new("settings-autocomplete-usage-timing")
            .ghost()
            .small()
            .label(lokalbot_i18n::tr("Usage and timing"))
            .on_click(cx.listener(|this, _, _, cx| {
                this.writing.timing_open = !this.writing.timing_open;
                cx.notify();
            }));
        let mut body = v_flex().w_full().gap(px(8.)).child(h_flex().child(toggle));
        if !open {
            return body.into_any_element();
        }
        let Some(autocomplete) = crate::autocomplete::global(cx) else {
            return body.into_any_element();
        };
        let stats = autocomplete.read(cx).measures.stats.clone();
        let settings = self.data.read(cx).settings.clone();
        body = body.child(
            h_flex()
                .gap(px(8.))
                .child(ui::stat_chip(
                    ui::Ico::Sparkles,
                    stats.generations.to_string(),
                    lokalbot_i18n::tr("suggested"),
                    cx,
                ))
                .child(ui::stat_chip(
                    ui::Ico::Check,
                    stats.accepts.to_string(),
                    lokalbot_i18n::tr("accepted"),
                    cx,
                )),
        );
        let rows: Vec<(&'static str, LiveMeasure)> = stats
            .live_rows()
            .into_iter()
            .map(|(title, measure)| (title, measure.clone()))
            .collect();
        if !rows.is_empty() {
            let cell = |text: String, width: f32| div().w(px(width)).flex_none().child(text);
            body = body.child(
                v_flex()
                    .w_full()
                    .gap(px(4.))
                    .text_size(ty::SECONDARY)
                    .child(
                        h_flex()
                            .w_full()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(cell(lokalbot_i18n::tr("Where").to_string(), 100.))
                            .child(cell(lokalbot_i18n::tr("Shown").to_string(), 56.))
                            .child(cell(
                                lokalbot_i18n::tr("Keystroke to visible").to_string(),
                                140.,
                            ))
                            .child(cell(lokalbot_i18n::tr("Accepted").to_string(), 70.))
                            .child(cell(
                                lokalbot_i18n::tr("Arrived in the field").to_string(),
                                140.,
                            ))
                            .child(cell(lokalbot_i18n::tr("Taken back").to_string(), 70.)),
                    )
                    .children(rows.iter().map(|(title, measure)| {
                        h_flex()
                            .w_full()
                            .text_color(lb.text)
                            .child(cell(surface_title(title).to_string(), 100.))
                            .child(cell(measure.shown.to_string(), 56.))
                            .child(cell(timing(measure), 140.))
                            .child(cell(measure.accepts.to_string(), 70.))
                            .child(cell(insertions(measure), 140.))
                            .child(cell(measure.accepts_corrected.to_string(), 70.))
                    })),
            );
        }
        let report = stats.report(&super::writing_server::model_display_name(&settings));
        let empty = stats == Default::default();
        body.child(
            h_flex()
                .gap(px(8.))
                .child(
                    Button::new("settings-autocomplete-copy-measurements")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Copy measurements"))
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(report.clone()));
                        }),
                )
                .child(
                    Button::new("settings-autocomplete-reset-measurements")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Reset"))
                        .disabled(empty)
                        .on_click(move |_, _, cx| {
                            crate::bridge::send(
                                Command::Autocomplete(AutocompleteCommand::ResetMeasures),
                                cx,
                            );
                        }),
                ),
        )
        .child(settings_row::help(
            lokalbot_i18n::tr("Estimated from reads of the field while you type in other apps: the wait from a keystroke to a visible suggestion, whether accepted text arrived in the field, and whether you deleted it straight away. Counts and timings only, kept on this computer; no text, app names or window titles are stored."),
            cx,
        ))
        .into_any_element()
    }
}

fn confirm_clear(window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        alert
            .title(SharedString::from(lokalbot_i18n::tr(
                "Clear autocomplete statistics?",
            )))
            .description(SharedString::from(lokalbot_i18n::tr(
                "Deletes the daily and monthly counts. Usage and timing measurements are kept.",
            )))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Clear Statistics"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                crate::bridge::send(Command::Autocomplete(AutocompleteCommand::ClearUsage), cx);
                true
            })
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_saved_reads_in_the_largest_units() {
        assert_eq!(time_saved(0.2), "0");
        assert_eq!(time_saved(50.0), "≈ 50 sec");
        assert_eq!(time_saved(41.0 * 60.0 + 5.0), "≈ 41 min");
        assert_eq!(time_saved(3.0 * 3_600.0 + 25.0 * 60.0), "≈ 3 hr, 25 min");
    }

    #[test]
    fn surfaces_sort_by_words_and_leave_out_the_unused() {
        let mut bucket = UsageBucket::default();
        bucket.surfaces.insert(
            "browser".into(),
            UsageCounts {
                shown: 1,
                words: 2,
                ..Default::default()
            },
        );
        bucket.surfaces.insert(
            "chat".into(),
            UsageCounts {
                shown: 1,
                words: 9,
                ..Default::default()
            },
        );
        bucket
            .surfaces
            .insert("email".into(), UsageCounts::default());
        let rows = surface_rows(&bucket);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, "Chat");
    }
}
