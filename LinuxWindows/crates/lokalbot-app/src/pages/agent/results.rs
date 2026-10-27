//! Results and sources (`AgentResultsPanel.swift`): attached sources and tool
//! results of the task, and a preview of the selected one beside the
//! conversation. Opening a preview never runs a tool.

use std::path::PathBuf;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};

use lokalbot_agent::tasks::{Attachment, ResultPreview};

use super::AgentPage;
use super::conversation::mono_font;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const PANEL_WIDTH: f32 = 350.;

impl AgentPage {
    pub(super) fn render_results(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let (sources, results): (Vec<Attachment>, Vec<ResultPreview>) = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .map(|tab| {
                (
                    tab.session.source_attachments.clone(),
                    tab.session
                        .items()
                        .iter()
                        .filter_map(ResultPreview::tool)
                        .collect(),
                )
            })
            .unwrap_or_default();
        // Follow the live result (a running tool keeps updating its output).
        let selected = match &self.preview {
            Some(preview) => results
                .iter()
                .find(|r| r.id == preview.id)
                .cloned()
                .or_else(|| Some(preview.clone())),
            None => results.last().cloned(),
        };
        let selected_id = selected.as_ref().map(|s| s.id.clone());

        let mut list = v_flex().gap(px(8.));
        if !sources.is_empty() {
            list = list.child(caption(lokalbot_i18n::tr("Sources used"), cx));
            for source in &sources {
                let source_click = source.clone();
                list = list.child(
                    h_flex()
                        .id(SharedString::from(format!("agent-source-{}", source.id)))
                        .gap(px(6.))
                        .items_center()
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.accent_text)
                        .hover(|s| s.underline())
                        .child(ui::icon(Ico::FileText, px(12.), lb.accent_text))
                        .child(div().line_clamp(2).child(source.title.clone()))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.preview_source(&source_click, cx)
                        })),
                );
            }
        }
        if !results.is_empty() {
            list = list.child(caption(lokalbot_i18n::tr("Activity results"), cx));
            for result in &results {
                let chosen = selected_id.as_deref() == Some(result.id.as_str());
                let click = result.clone();
                list = list.child(
                    v_flex()
                        .id(SharedString::from(format!("agent-result-{}", result.id)))
                        .w_full()
                        .gap(px(3.))
                        .p(px(8.))
                        .rounded(px(8.))
                        .cursor_pointer()
                        .when(chosen, |this| this.bg(lb.accent_wash))
                        .when(!chosen, |this| this.hover(|s| s.bg(lb.hover)))
                        .child(
                            div()
                                .truncate()
                                .text_size(ty::SECONDARY)
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(lb.text)
                                .child(result.title.clone()),
                        )
                        .child(
                            div()
                                .line_clamp(2)
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(result.detail.clone()),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.preview = Some(click.clone());
                            this.preview_error = None;
                            cx.notify();
                        })),
                );
            }
        }

        let header = h_flex()
            .px(px(16.))
            .pt(px(16.))
            .pb(px(10.))
            .items_center()
            .child(
                div()
                    .flex_1()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Results & sources",
                    ))),
            )
            .child(
                super::small_icon_button(
                    "agent-results-close",
                    Ico::X,
                    lokalbot_i18n::tr("Hide results"),
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.results_visible = false;
                    cx.notify();
                })),
            );

        let body: AnyElement = match selected {
            Some(preview) => self.render_preview(preview, cx).into_any_element(),
            None => ui::empty_state(
                Ico::FileSearch,
                lokalbot_i18n::tr("Your results will appear here"),
                lokalbot_i18n::tr(
                    "Open a response, activity, or attached source to inspect it beside your task.",
                ),
                cx,
            )
            .into_any_element(),
        };

        v_flex()
            .w(px(PANEL_WIDTH))
            .flex_none()
            .h_full()
            .border_l_1()
            .border_color(lb.separator)
            .bg(lb.window)
            .child(header)
            .when(!sources.is_empty() || !results.is_empty(), |this| {
                this.child(
                    div()
                        .id("agent-results-list")
                        .max_h(px(220.))
                        .overflow_y_scroll()
                        .px(px(16.))
                        .pb(px(12.))
                        .child(list),
                )
                .child(ui::divider(cx))
            })
            .when_some(self.preview_error.clone(), |this, error| {
                this.child(
                    div()
                        .p(px(16.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(error),
                )
            })
            .child(div().flex_1().min_h_0().child(body))
    }

    fn render_preview(&mut self, preview: ResultPreview, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let copy_key = format!("result-{}", preview.id);
        let copied = self.copied.as_deref() == Some(copy_key.as_str());
        let copy_text = preview.text.clone();
        let export_text = preview.text.clone();
        let mut column = v_flex().gap(px(14.)).child(
            div()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(preview.detail.clone()),
        );
        if let (Some(original), Some(proposed)) = (&preview.original, &preview.proposed) {
            column = column
                .child(change(
                    lokalbot_i18n::tr("Before"),
                    original,
                    lb.recording,
                    cx,
                ))
                .child(change(lokalbot_i18n::tr("After"), proposed, lb.success, cx));
        }
        column = column
            .child(ui::markdown_view::markdown(
                SharedString::from(format!("agent-preview-{}", preview.id)),
                preview.text.clone(),
            ))
            .child(
                div()
                    .text_size(ty::CAPTION)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Preview of recorded output or selected source. Opening a preview does not run a tool."))),
            );
        v_flex()
            .size_full()
            .child(
                h_flex()
                    .px(px(16.))
                    .py(px(12.))
                    .gap(px(4.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .line_clamp(2)
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(preview.title.clone()),
                    )
                    .child(
                        Button::new("agent-result-copy")
                            .ghost()
                            .xsmall()
                            .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                            .tooltip(lokalbot_i18n::tr("Copy result"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.copy(copy_key.clone(), copy_text.clone(), cx)
                            })),
                    )
                    .child(
                        Button::new("agent-result-export")
                            .ghost()
                            .xsmall()
                            .icon(Icon::new(Ico::Download))
                            .tooltip(lokalbot_i18n::tr("Export result"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.export(export_text.clone(), cx)
                            })),
                    ),
            )
            .child(
                div()
                    .id("agent-preview")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px(px(16.))
                    .pb(px(16.))
                    .child(column),
            )
    }

    /// Saves the previewed text where the user chooses (`fileExporter`).
    fn export(&mut self, text: String, cx: &mut Context<Self>) {
        let directory = directories::UserDirs::new()
            .and_then(|dirs| dirs.document_dir().map(|d| d.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("."));
        let receiver = cx.prompt_for_new_path(&directory, Some("agent-result.txt"));
        cx.spawn(async move |this, cx| {
            let picked = receiver.await;
            let result = match picked {
                Ok(Ok(Some(path))) => std::fs::write(&path, text).map_err(|e| e.to_string()),
                Ok(Ok(None)) | Err(_) => Ok(()),
                Ok(Err(err)) => Err(lokalbot_i18n::format(
                    "No save dialog is available: {err}",
                    &[("err", format!("{:#}", err))],
                )),
            };
            let _ = this.update(cx, |this, cx| {
                this.preview_error = result.err();
                cx.notify();
            });
        })
        .detach();
    }
}

fn caption(text: &'static str, cx: &Context<AgentPage>) -> Div {
    div()
        .pt(px(4.))
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(cx.lb().text_secondary)
        .child(text)
}

fn change(label: &'static str, text: &str, tint: Hsla, cx: &Context<AgentPage>) -> Div {
    let lb = cx.lb();
    v_flex()
        .w_full()
        .gap(px(6.))
        .p(px(10.))
        .rounded(metric::ROW_RADIUS)
        .bg(tint.opacity(0.09))
        .child(
            div()
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(label),
        )
        .child(
            div()
                .font_family(mono_font(cx))
                .text_size(ty::CAPTION)
                .text_color(lb.text)
                .child(if text.is_empty() {
                    lokalbot_i18n::tr("(empty)").to_string()
                } else {
                    text.to_string()
                }),
        )
}
