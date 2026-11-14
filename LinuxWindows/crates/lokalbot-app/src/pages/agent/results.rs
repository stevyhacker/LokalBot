//! Results (`AgentResultsPanel.swift`): beside the conversation, the files
//! the task changed, its steps, the sources it was given, and a preview of
//! whichever one is chosen. Opening a preview never runs a tool.

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

use lokalbot_agent::presentation::ChangedFile;
use lokalbot_agent::tasks::{Attachment, ResultPreview};
use lokalbot_agent::{SessionState, ToolStatus, TranscriptItem};

use super::AgentPage;
use super::conversation::mono_font;
use super::words::{self, StepContext};
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
        let snapshot = self.snapshot(cx);
        let sources: Vec<Attachment> = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .map(|tab| tab.session.source_attachments.clone())
            .unwrap_or_default();
        let steps: Vec<TranscriptItem> = snapshot
            .as_ref()
            .map(|s| {
                s.items
                    .iter()
                    .filter(|i| matches!(i, TranscriptItem::Tool { .. }))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let files: Vec<ChangedFile> = snapshot
            .as_ref()
            .map(|s| s.changed_files(&steps))
            .unwrap_or_default();
        let working = snapshot
            .as_ref()
            .is_some_and(|s| s.state == SessionState::Running);
        let results: Vec<ResultPreview> = steps.iter().filter_map(ResultPreview::tool).collect();
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
        let meeting_title = self.meeting_title(cx);
        let (workspace, workspace_name) = snapshot
            .as_ref()
            .map(|s| (s.workspace.clone(), s.workspace_name.clone()))
            .unwrap_or_default();
        let context = StepContext {
            workspace: &workspace,
            workspace_name: &workspace_name,
            meeting_title: &meeting_title,
        };

        let row = |id: SharedString, chosen: bool| {
            h_flex()
                .id(id)
                .w_full()
                .gap(px(8.))
                .items_center()
                .px(px(8.))
                .py(px(5.))
                .rounded(px(6.))
                .cursor_pointer()
                .text_size(ty::SECONDARY)
                .when(chosen, |this| this.bg(lb.accent_wash))
                .when(!chosen, |this| this.hover(|s| s.bg(lb.hover)))
        };
        let mut list = v_flex().gap(px(4.));
        if !files.is_empty() {
            list = list.child(heading(lokalbot_i18n::tr("Changed files"), cx));
            for file in &files {
                let step = steps.iter().find(|s| s.id() == file.step_id);
                let preview = step.and_then(ResultPreview::tool);
                list = list.child(
                    row(
                        SharedString::from(format!("agent-result-file-{}", file.step_id)),
                        selected_id.as_deref() == Some(file.step_id.as_str()),
                    )
                    .child(ui::icon(Ico::File, px(14.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(lb.text)
                            .child(file.target.name.clone()),
                    )
                    .when_some(words::change_label(file.change), |this, change| {
                        this.child(
                            div()
                                .flex_none()
                                .text_color(lb.text_secondary)
                                .child(change),
                        )
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.preview = preview.clone();
                        this.preview_error = None;
                        cx.notify();
                    })),
                );
            }
        }
        if !steps.is_empty() {
            list = list.child(
                div()
                    .when(!files.is_empty(), |this| this.pt(px(8.)))
                    .child(heading(lokalbot_i18n::tr("Steps"), cx)),
            );
            for step in &steps {
                let TranscriptItem::Tool {
                    id,
                    name,
                    args_json,
                    status,
                    ..
                } = step
                else {
                    continue;
                };
                let label = words::step_label(name, args_json, &context);
                let preview = ResultPreview::tool(step);
                let (icon, tint): (Ico, Hsla) = match status {
                    ToolStatus::Failed => (Ico::CircleAlert, lb.attention_text),
                    ToolStatus::Running => (Ico::Ellipsis, lb.text_secondary),
                    ToolStatus::Succeeded => (Ico::Check, lb.text_secondary),
                };
                list = list.child(
                    row(
                        SharedString::from(format!("agent-result-step-{id}")),
                        selected_id.as_deref() == Some(id.as_str()),
                    )
                    .child(ui::icon(icon, px(14.), tint))
                    .child(
                        div()
                            .flex_none()
                            .max_w(gpui_kit::relative(0.6))
                            .truncate()
                            .text_color(lb.text)
                            .child(label.text(*status, working)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(lb.text_secondary)
                            .child(label.detail.clone().unwrap_or_default()),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.preview = preview.clone();
                        this.preview_error = None;
                        cx.notify();
                    })),
                );
            }
        }
        if !sources.is_empty() {
            list = list.child(
                div()
                    .when(!steps.is_empty(), |this| this.pt(px(8.)))
                    .child(heading(lokalbot_i18n::tr("Sources used"), cx)),
            );
            for source in &sources {
                let source_click = source.clone();
                list = list.child(
                    h_flex()
                        .id(SharedString::from(format!("agent-source-{}", source.id)))
                        .gap(px(6.))
                        .px(px(8.))
                        .py(px(4.))
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

        let header = h_flex()
            .px(px(16.))
            .pt(px(14.))
            .pb(px(10.))
            .items_center()
            .child(
                div()
                    .flex_1()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Results"))),
            )
            .child(
                super::small_icon_button("agent-results-close", Ico::X, lokalbot_i18n::tr("Close"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.results_visible = false;
                        cx.notify();
                    })),
            );

        // A step's preview is headed by its plain label; other previews keep their own title.
        let body: AnyElement = match selected {
            Some(preview) => {
                let step = steps.iter().find(|s| s.id() == preview.id);
                let file = files.iter().find(|f| f.step_id == preview.id);
                let label = step.and_then(|s| match s {
                    TranscriptItem::Tool {
                        name, args_json, ..
                    } => Some(words::step_label(name, args_json, &context)),
                    _ => None,
                });
                let title = file
                    .map(|f| f.target.name.clone())
                    .or_else(|| label.as_ref().map(|l| l.done.clone()))
                    .unwrap_or_else(|| preview.title.clone());
                let detail = file
                    .map(words::changed_file_detail)
                    .or_else(|| label.as_ref().and_then(|l| l.detail.clone()))
                    .unwrap_or_else(|| preview.detail.clone());
                self.render_preview(preview, title, detail, cx)
                    .into_any_element()
            }
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
        let has_list = !files.is_empty() || !steps.is_empty() || !sources.is_empty();

        v_flex()
            .w(px(PANEL_WIDTH))
            .flex_none()
            .h_full()
            .border_l_1()
            .border_color(lb.separator)
            .bg(lb.window)
            .child(header)
            .when(has_list, |this| {
                this.child(
                    div()
                        .id("agent-results-list")
                        .max_h(px(240.))
                        .overflow_y_scroll()
                        .px(px(8.))
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

    fn render_preview(
        &mut self,
        preview: ResultPreview,
        title: String,
        detail: String,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let copy_key = format!("result-{}", preview.id);
        let copied = self.copied.as_deref() == Some(copy_key.as_str());
        let copy_text = preview.text.clone();
        let export_text = preview.text.clone();
        let mut column = v_flex().gap(px(14.));
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
                    .items_start()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(
                                div()
                                    .line_clamp(2)
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .line_clamp(3)
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(detail),
                            ),
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

fn heading(text: &'static str, cx: &Context<AgentPage>) -> Div {
    div()
        .px(px(8.))
        .pt(px(2.))
        .pb(px(2.))
        .text_size(ty::SECONDARY)
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
