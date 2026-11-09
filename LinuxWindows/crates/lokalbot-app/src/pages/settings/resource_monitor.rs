//! Resource Monitor in Settings → Advanced (`ResourceMonitorSection`): a live
//! readout of LokalBot and its helpers, updated every 2 seconds while it shows.

use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::v_flex;
use gpui_kit::{
    App, Context, FontWeight, IntoElement as _, ParentElement as _, SharedString, Styled as _, div,
    px,
};
use lokalbot_engine::{GenerationMetric, ResourceSampler, ResourceSnapshot};

use super::{Section, SettingsPage};
use crate::bridge::EngineHandle;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

const POLL: Duration = Duration::from_secs(2);

#[derive(Default)]
pub struct ResourceMonitor {
    sampler: ResourceSampler,
    snapshot: Option<ResourceSnapshot>,
    polling: bool,
}

fn percent(value: Option<f64>) -> String {
    match value.filter(|v| v.is_finite()) {
        Some(value) if value < 10.0 => format!("{value:.1}%"),
        Some(value) => format!("{value:.0}%"),
        None => "—".to_string(),
    }
}

/// 1.0 GB or 512 MB, in the binary units memory is counted in.
fn memory(bytes: Option<u64>) -> String {
    let Some(bytes) = bytes else {
        return "—".to_string();
    };
    if bytes >= 1_073_741_824 {
        format!("{:.1} GB", bytes as f64 / 1_073_741_824.0)
    } else {
        format!("{:.0} MB", bytes as f64 / 1_048_576.0)
    }
}

/// "12.3s · ~480 tok · 39 tok/s".
fn generation_summary(metric: &GenerationMetric) -> String {
    format!(
        "{:.1}s · ~{} tok · {:.0} tok/s",
        metric.seconds,
        metric.approx_tokens,
        metric.tokens_per_second()
    )
}

fn model_memory_summary(snapshot: &ResourceSnapshot) -> String {
    if snapshot.models.is_empty() {
        return "0 MB".to_string();
    }
    if snapshot
        .models
        .iter()
        .all(|model| model.memory_bytes.is_none())
    {
        return lokalbot_i18n::tr("included").to_string();
    }
    let total = memory(Some(snapshot.model_memory_bytes()));
    if snapshot
        .models
        .iter()
        .any(|model| model.memory_bytes.is_none())
    {
        format!("≈{total}")
    } else {
        total
    }
}

/// The line under Model Storage (`memorySummary`).
pub(super) fn memory_summary(cx: &App) -> String {
    let Some(engine) = cx.try_global::<EngineHandle>() else {
        return lokalbot_i18n::tr("No models loaded in memory.").to_string();
    };
    let snapshot = ResourceSampler::default().sample(&engine.0);
    if snapshot.models.is_empty() {
        return lokalbot_i18n::tr("No models loaded in memory.").to_string();
    }
    lokalbot_i18n::format(
        "{0} in memory · Models unload automatically when idle.",
        &[("0", model_memory_summary(&snapshot))],
    )
}

impl SettingsPage {
    /// Starts the readout; it stops itself once Advanced is no longer showing.
    fn start_resource_polling(&mut self, cx: &mut Context<Self>) {
        if self.resources.polling {
            return;
        }
        self.resources.polling = true;
        self.sample_resources(cx);
        cx.spawn(async move |page, cx| {
            loop {
                cx.background_executor().timer(POLL).await;
                let keep_going = page
                    .update(cx, |page, cx| {
                        let showing = {
                            let data = page.data.read(cx);
                            data.section == crate::state::Section::Settings
                                && data.settings_category == SettingsCategory::Advanced
                        };
                        if showing {
                            page.sample_resources(cx);
                        } else {
                            page.resources.polling = false;
                        }
                        showing
                    })
                    .unwrap_or(false);
                if !keep_going {
                    return;
                }
            }
        })
        .detach();
    }

    fn sample_resources(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = cx.try_global::<EngineHandle>().map(|e| e.0.clone()) else {
            return;
        };
        self.resources.snapshot = Some(self.resources.sampler.sample(&engine));
        cx.notify();
    }

    pub(super) fn resource_monitor_section(&mut self, cx: &mut Context<Self>) -> Section {
        self.start_resource_polling(cx);
        let lb = cx.lb().clone();
        let snapshot = self.resources.snapshot.clone().unwrap_or_default();
        let tile = |title: &'static str, value: String, detail: Option<&'static str>, cx: &App| {
            v_flex()
                .flex_1()
                .min_w(px(120.))
                .gap(px(2.))
                .child(settings_row::help(title, cx))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(cx.lb().text)
                        .child(SharedString::from(value)),
                )
                .children(detail.map(|detail| settings_row::help(detail, cx)))
        };
        let mut column = v_flex().gap(px(12.)).child(
            h_flex()
                .flex_wrap()
                .items_start()
                .gap(px(12.))
                .child(tile(
                    lokalbot_i18n::tr("CPU"),
                    percent(snapshot.cpu_percent),
                    Some(lokalbot_i18n::tr("Across all cores")),
                    cx,
                ))
                .child(tile(
                    lokalbot_i18n::tr("Memory"),
                    memory(snapshot.memory_bytes),
                    None,
                    cx,
                ))
                .child(tile(
                    lokalbot_i18n::tr("Models loaded"),
                    snapshot.models.len().to_string(),
                    None,
                    cx,
                ))
                .child(tile(
                    lokalbot_i18n::tr("Model memory"),
                    model_memory_summary(&snapshot),
                    None,
                    cx,
                )),
        );
        if snapshot.models.is_empty() {
            column = column.child(settings_row::help(
                lokalbot_i18n::tr("No LokalBot model runtimes are loaded."),
                cx,
            ));
        }
        for model in &snapshot.models {
            let label = if model.in_use {
                format!("{} · {}", model.label, lokalbot_i18n::tr("in use"))
            } else {
                model.label.clone()
            };
            column =
                column.child(
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(div().text_size(ty::BODY).text_color(lb.text).child(
                            SharedString::from(lokalbot_i18n::tr(&model.role).to_string()),
                        ))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(SharedString::from(label)),
                        )
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(SharedString::from(match model.memory_bytes {
                                    Some(bytes) => memory(Some(bytes)),
                                    None => lokalbot_i18n::tr("Included in total").to_string(),
                                })),
                        ),
                );
        }
        column = column.child(settings_row::help(
            lokalbot_i18n::tr("Updates every 2 seconds and counts LokalBot and its helpers. External Ollama models aren't counted."),
            cx,
        ));
        // `SettingsView.systemSection`: the five newest, or that there are none.
        let generation_row = |title: SharedString, value: String, cx: &App| {
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::BODY)
                        .text_color(cx.lb().text)
                        .child(title),
                )
                .child(settings_row::help(value, cx))
        };
        if snapshot.generations.is_empty() {
            column = column.child(generation_row(
                lokalbot_i18n::tr("Recent generations").into(),
                lokalbot_i18n::tr("None yet").to_string(),
                cx,
            ));
        }
        for metric in snapshot.generations.iter().take(5) {
            column = column.child(generation_row(
                metric.label.clone().into(),
                generation_summary(metric),
                cx,
            ));
        }
        Section::new(lokalbot_i18n::tr("Resource Monitor")).row(
            "settings.resourceMonitor",
            settings_row::content_row(
                "settings.resourceMonitor",
                column,
                self.is_focused("settings.resourceMonitor"),
                cx,
            )
            .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_engine::LoadedModel;

    #[test]
    fn readings_format_like_the_mac() {
        assert_eq!(percent(None), "—");
        assert_eq!(percent(Some(f64::NAN)), "—");
        assert_eq!(percent(Some(4.25)), "4.2%");
        assert_eq!(percent(Some(42.6)), "43%");
        assert_eq!(memory(None), "—");
        assert_eq!(memory(Some(524_288_000)), "500 MB");
        assert_eq!(memory(Some(1_610_612_736)), "1.5 GB");
    }

    #[test]
    fn a_generation_reads_like_the_mac() {
        let metric = GenerationMetric {
            label: "Summary · Qwen3.5 4B".into(),
            seconds: 12.34,
            approx_tokens: 480,
        };
        assert_eq!(generation_summary(&metric), "12.3s · ~480 tok · 39 tok/s");
    }

    #[test]
    fn model_memory_marks_an_estimate() {
        let model = |memory_bytes| LoadedModel {
            role: "Think".into(),
            label: "m".into(),
            memory_bytes,
            in_use: false,
        };
        let mut snapshot = ResourceSnapshot::default();
        assert_eq!(model_memory_summary(&snapshot), "0 MB");
        snapshot.models = vec![model(None)];
        assert_eq!(model_memory_summary(&snapshot), "included");
        snapshot.models = vec![model(Some(1_048_576 * 200))];
        assert_eq!(model_memory_summary(&snapshot), "200 MB");
        snapshot.models.push(model(None));
        assert_eq!(model_memory_summary(&snapshot), "≈200 MB");
    }
}
