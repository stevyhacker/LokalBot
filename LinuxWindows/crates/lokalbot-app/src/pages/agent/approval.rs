//! The approval dock (`AgentApprovalDock.swift`): the exact command, file or
//! arguments a tool asked to use, with Deny, Allow for Session (file changes
//! in the working folder only) and Allow Once.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};

use lokalbot_agent::ApprovalScope;
use lokalbot_agent::transcript::ApprovalRequest;

use super::AgentPage;
use super::conversation::{Snapshot, mono_font};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// What approving does, by tool (`approvalEffect`).
fn effect(tool: &str) -> &'static str {
    match tool.to_lowercase().as_str() {
        "read" => lokalbot_i18n::tr(
            "Read the file shown below and make its contents available to this session.",
        ),
        "write" => {
            lokalbot_i18n::tr("Create or replace the file shown below with the proposed content.")
        }
        "edit" => lokalbot_i18n::tr("Apply the replacements shown below to the target file."),
        "bash" | "shell" => lokalbot_i18n::tr(
            "Run the command shown below in the working folder with this session's current access.",
        ),
        "powershell" => lokalbot_i18n::tr(
            "Run the PowerShell command shown below in the working folder with this session's current access.",
        ),
        _ => {
            lokalbot_i18n::tr("Allow the operation shown below with this session's current access.")
        }
    }
}

impl AgentPage {
    pub(super) fn render_approval_dock(
        &mut self,
        request: &ApprovalRequest,
        snapshot: &Snapshot,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let expanded = !self.collapsed_approvals.contains(&request.id);
        let waiting = snapshot.approvals.len();
        let id = request.id.clone();
        let toggle_id = request.id.clone();
        let tool = request.tool.clone();

        let mut details = v_flex().gap(px(8.));
        if let Some(path) = &request.path {
            details = details.child(text_field(lokalbot_i18n::tr("File"), path, cx));
        }
        if let Some(command) = &request.command {
            details = details.child(code_field(
                lokalbot_i18n::tr("Command"),
                command,
                lb.text_secondary,
                cx,
            ));
        }
        if let Some(content) = &request.content {
            details = details.child(code_field(
                lokalbot_i18n::tr("Content to write"),
                content,
                lb.text_secondary,
                cx,
            ));
        }
        if let Some(arguments) = &request.arguments {
            details = details.child(code_field(
                lokalbot_i18n::tr("Arguments"),
                arguments,
                lb.text_secondary,
                cx,
            ));
        }
        let several = request.edits.len() > 1;
        for (index, edit) in request.edits.iter().enumerate() {
            let mut block = v_flex().gap(px(6.));
            if several {
                block = block.child(
                    div()
                        .text_size(ty::CAPTION)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "Edit {0}",
                            &[("0", format!("{}", index + 1))],
                        ))),
                );
            }
            details = details.child(
                block
                    .child(code_field(
                        lokalbot_i18n::tr("Remove"),
                        &edit.old_text,
                        lb.recording,
                        cx,
                    ))
                    .child(code_field(
                        lokalbot_i18n::tr("Replace with"),
                        &edit.new_text,
                        lb.success,
                        cx,
                    )),
            );
        }
        if let Some(workspace) = &request.workspace {
            details = details.child(text_field(
                lokalbot_i18n::tr("Working folder"),
                workspace,
                cx,
            ));
        }
        if !request.has_structured_details()
            && let Some(summary) = request.summary.as_deref().filter(|s| !s.is_empty())
        {
            details = details.child(code_field(
                lokalbot_i18n::tr("Request details"),
                summary,
                lb.text_secondary,
                cx,
            ));
        }
        if request.is_truncated {
            details = details.child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::CircleEllipsis, px(13.), lb.text_secondary))
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Preview shortened because the requested change is very large.",
                            ))),
                    ),
            );
        }

        let can_approve = request.can_approve();
        let deny_id = id.clone();
        let session_id = id.clone();
        let once_id = id.clone();
        let buttons = h_flex()
            .gap(px(8.))
            .justify_end()
            .flex_wrap()
            .child(
                Button::new("agent-approve-deny")
                    .outline()
                    .label(lokalbot_i18n::tr("Deny"))
                    .tooltip(lokalbot_i18n::tr("Deny (Esc)"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.respond(&deny_id, false, ApprovalScope::Once, cx)
                    })),
            )
            .when(snapshot.can_allow_first, |this| {
                this.child(
                    Button::new("agent-approve-session")
                        .outline()
                        .label(lokalbot_i18n::format(
                            "Allow {tool} for Session",
                            &[("tool", tool.to_string())],
                        ))
                        .tooltip(lokalbot_i18n::format(
                            "Automatically allow future {tool} requests until this session closes",
                            &[("tool", tool.to_string())],
                        ))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.respond(&session_id, true, ApprovalScope::Session, cx)
                        })),
                )
            })
            .child(
                Button::new("agent-approve-once")
                    .primary()
                    .label(lokalbot_i18n::tr("Allow Once"))
                    .font_weight(FontWeight::SEMIBOLD)
                    .disabled(!can_approve)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.respond(&once_id, true, ApprovalScope::Once, cx)
                    })),
            );

        v_flex()
            .w_full()
            .max_w(metric::READING_MAX_WIDTH)
            .gap(px(4.))
            .when(waiting > 1, |this| {
                this.child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "{waiting} approvals waiting",
                            &[("waiting", format!("{}", waiting))],
                        ))),
                )
            })
            .child(
                ui::status_surface(lb.attention, cx)
                    .w_full()
                    .p(px(12.))
                    .child(
                        v_flex()
                            .gap(px(10.))
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .items_center()
                                    .child(ui::icon(Ico::Hand, px(15.), lb.attention_text))
                                    .child(
                                        div()
                                            .text_size(ty::SECTION)
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(lb.attention_text)
                                            .child(crate::ui::text::paragraph(
                                                lokalbot_i18n::format(
                                                    "Approval required: {0}",
                                                    &[("0", request.tool.to_string())],
                                                ),
                                            )),
                                    ),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text)
                                    .child(effect(&request.tool)),
                            )
                            .when_some(request.path.clone(), |this, path| {
                                this.child(mono_line(&path, cx))
                            })
                            .when_some(request.command.clone(), |this, command| {
                                this.child(mono_line(&command, cx))
                            })
                            .child(
                                h_flex()
                                    .id(SharedString::from(format!(
                                        "agent-approval-details-{}",
                                        request.id
                                    )))
                                    .gap(px(4.))
                                    .items_center()
                                    .cursor_pointer()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(ui::icon(
                                        if expanded {
                                            Ico::ChevronDown
                                        } else {
                                            Ico::ChevronRight
                                        },
                                        px(11.),
                                        lb.text_secondary,
                                    ))
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Review Details",
                                    )))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if !this.collapsed_approvals.remove(&toggle_id) {
                                            this.collapsed_approvals.insert(toggle_id.clone());
                                        }
                                        cx.notify();
                                    })),
                            )
                            .when(expanded, |this| {
                                this.child(
                                    div()
                                        .id(SharedString::from(format!(
                                            "agent-approval-scroll-{}",
                                            request.id
                                        )))
                                        .max_h(px(180.))
                                        .overflow_y_scroll()
                                        .child(details),
                                )
                            })
                            .child(buttons),
                    ),
            )
            .into_any_element()
    }

    fn respond(&mut self, id: &str, approved: bool, scope: ApprovalScope, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.with_session(cx, |session| {
            session.respond_to_approval(&id, approved, scope)
        });
    }

    /// Escape denies the first waiting approval of the selected task.
    pub(super) fn deny_visible_approval(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(id) = self
            .snapshot(cx)
            .and_then(|s| s.approvals.first().map(|r| r.id.clone()))
        else {
            return false;
        };
        self.respond(&id, false, ApprovalScope::Once, cx);
        true
    }
}

fn mono_line(text: &str, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .w_full()
        .line_clamp(2)
        .font_family(mono_font(cx))
        .text_size(ty::SECONDARY)
        .text_color(lb.text)
        .child(text.to_string())
}

fn text_field(label: &str, value: &str, cx: &App) -> Div {
    let lb = cx.lb();
    v_flex()
        .gap(px(3.))
        .child(
            div()
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(label.to_string()),
        )
        .child(
            div()
                .font_family(mono_font(cx))
                .text_size(ty::SECONDARY)
                .text_color(lb.text)
                .child(value.to_string()),
        )
}

fn code_field(label: &str, value: &str, tint: Hsla, cx: &App) -> Div {
    let lb = cx.lb();
    let shown = if value.is_empty() {
        lokalbot_i18n::tr("(empty)").to_string()
    } else {
        value.to_string()
    };
    v_flex()
        .gap(px(4.))
        .child(
            div()
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(label.to_string()),
        )
        .child(
            div()
                .w_full()
                .p(px(7.))
                .rounded(px(6.))
                .bg(tint.opacity(0.08))
                .border_1()
                .border_color(tint.opacity(0.18))
                .font_family(mono_font(cx))
                .text_size(ty::SECONDARY)
                .text_color(lb.text)
                .child(shown),
        )
}
