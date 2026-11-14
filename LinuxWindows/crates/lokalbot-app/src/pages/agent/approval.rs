//! The approval card above the composer (`AgentApprovalDock.swift`): a
//! question that names its file or command, what will happen and where, the
//! first lines to review, then Deny apart from the answers that allow. A
//! command gets Deny and Allow once only, and so does a file inside
//! LokalBot's own data.

use std::path::Path;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};

use lokalbot_agent::ApprovalScope;
use lokalbot_agent::endpoint::Destination;
use lokalbot_agent::presentation::Place;
use lokalbot_agent::transcript::{ApprovalRequest, is_shell_tool};

use super::AgentPage;
use super::conversation::{Snapshot, mono_font};
use super::words::{self, ApprovalCard, ApprovalPlace, COLLAPSED_PREVIEW_LINES};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

impl AgentPage {
    /// The card's words for this request, from the selected task.
    fn approval_card(&self, request: &ApprovalRequest, cx: &gpui_kit::App) -> Option<ApprovalCard> {
        let tab = self.model(cx)?.tasks.as_ref()?.selected()?;
        let session = &tab.session;
        let file = session.approval_file(request);
        let place = match &file {
            None => ApprovalPlace::None,
            Some(file) if file.is_protected => ApprovalPlace::LokalbotData,
            Some(file) if file.target.place == Place::WorkingFolder => ApprovalPlace::WorkingFolder,
            Some(_) => ApprovalPlace::Outside,
        };
        let remote = match session.presented_model().destination {
            Destination::Remote(host) => Some(host),
            _ => None,
        };
        // A command runs in the folder its request came from.
        let folder = if is_shell_tool(&request.tool) {
            request
                .workspace
                .as_deref()
                .map(|w| session.workspace_display_name_for(Path::new(w)))
        } else {
            None
        };
        Some(ApprovalCard::new(
            request,
            place,
            file.is_some_and(|f| f.exists),
            &folder.unwrap_or_else(|| session.workspace_display_name()),
            remote.as_deref(),
            session.can_allow_for_session(request),
        ))
    }

    pub(super) fn render_approval_dock(
        &mut self,
        request: &ApprovalRequest,
        snapshot: &Snapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(card) = self.approval_card(request, cx) else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let waiting = snapshot.approvals.len();
        let showing_all = self.approval_previews.contains(&request.id);
        // Room for the whole preview once it is opened, without taking the
        // conversation above it in a small window.
        let preview_max = px((f32::from(window.viewport_size().height) - 520.).clamp(60., 260.));

        let mut column = v_flex()
            .flex_1()
            .min_w_0()
            .gap(px(8.))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(card.title.clone())),
                    )
                    .when(waiting > 1, |this| {
                        this.child(
                            div()
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.attention_text)
                                .child(crate::pages::ask::model::directional(
                                    &crate::pages::ask::model::mac(
                                        "1 of %lld",
                                        &[&lokalbot_i18n::number(waiting)],
                                    ),
                                )),
                        )
                    }),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(card.effect.clone())),
            );
        if let Some(caution) = card.caution.clone() {
            column = column.child(
                h_flex()
                    .gap(px(6.))
                    .items_start()
                    .child(div().pt(px(1.)).child(ui::icon(
                        Ico::TriangleAlert,
                        px(13.),
                        lb.attention_text,
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .font_family(mono_font(cx))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(caution),
                    ),
            );
        }
        if let Some(destination) = card.destination.clone() {
            column = column.child(
                h_flex()
                    .gap(px(6.))
                    .items_start()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(div().pt(px(1.)).child(ui::icon(
                        Ico::Network,
                        px(13.),
                        lb.attention_text,
                    )))
                    .child(div().flex_1().min_w_0().child(destination)),
            );
        }
        if !card.preview.is_empty() {
            let lines = card.preview_lines();
            let long = lines > COLLAPSED_PREVIEW_LINES;
            let shown = if showing_all || !long {
                card.preview.clone()
            } else {
                card.preview
                    .split('\n')
                    .take(COLLAPSED_PREVIEW_LINES)
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            let toggle_id = request.id.clone();
            column = column.child(
                v_flex()
                    .w_full()
                    .gap(px(6.))
                    .p(px(10.))
                    .rounded(px(8.))
                    .bg(lb.panel.opacity(0.75))
                    .border_1()
                    .border_color(lb.group_stroke)
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "agent-approval-preview-{}",
                                request.id
                            )))
                            .w_full()
                            .max_h(if showing_all { preview_max } else { px(96.) })
                            .overflow_y_scroll()
                            .font_family(mono_font(cx))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(shown),
                    )
                    .when(long, |this| {
                        this.child(div().text_size(ty::SECONDARY).child(ui::link(
                            SharedString::from(format!("agent-approval-show-{}", request.id)),
                            if showing_all {
                                lokalbot_i18n::tr("Show less").to_string()
                            } else {
                                words::show_all(lines)
                            },
                            {
                                let page = cx.entity();
                                move |_, cx| {
                                    let id = toggle_id.clone();
                                    page.update(cx, |page, cx| {
                                        if !page.approval_previews.remove(&id) {
                                            page.approval_previews.insert(id);
                                        }
                                        cx.notify();
                                    })
                                }
                            },
                            cx,
                        )))
                    }),
            );
        }
        if request.is_truncated {
            column = column.child(note(
                Ico::CircleEllipsis,
                lokalbot_i18n::tr("Preview shortened because the requested change is very large."),
                lb.text_secondary,
            ));
        }
        let can_approve = request.can_approve();
        if !can_approve {
            column = column.child(note(
                Ico::TriangleAlert,
                lokalbot_i18n::tr("This request can’t be shown in full, so it can only be denied."),
                lb.attention_text,
            ));
        }

        let (deny_id, task_id, once_id) =
            (request.id.clone(), request.id.clone(), request.id.clone());
        let buttons = h_flex()
            .w_full()
            .gap(px(8.))
            .items_center()
            .flex_wrap()
            .pt(px(2.))
            .child(
                Button::new("agent-approve-deny")
                    .outline()
                    .label(lokalbot_i18n::tr("Deny"))
                    .tooltip(lokalbot_i18n::tr("Deny (Esc)"))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.respond(&deny_id, false, ApprovalScope::Once, cx)
                    })),
            )
            .child(div().flex_1().min_w(px(12.)))
            .when_some(card.task_answer, |this, answer| {
                this.child(
                    Button::new("agent-approve-session")
                        .outline()
                        .label(answer)
                        .tooltip(lokalbot_i18n::tr("Further changes of this kind inside the working folder run without asking, until this task’s agent stops or the access level changes."))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.respond(&task_id, true, ApprovalScope::Session, cx)
                        })),
                )
            })
            .child(
                Button::new("agent-approve-once")
                    .primary()
                    .label(lokalbot_i18n::tr("Allow once"))
                    .font_weight(FontWeight::SEMIBOLD)
                    .disabled(!can_approve)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.respond(&once_id, true, ApprovalScope::Once, cx)
                    })),
            );

        ui::status_surface(lb.attention, cx)
            .w_full()
            .p(px(14.))
            .child(
                h_flex()
                    .w_full()
                    .gap(px(12.))
                    .items_start()
                    .child(
                        div()
                            .flex_none()
                            .size(px(28.))
                            .rounded_full()
                            .bg(lb.attention.opacity(0.18))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(ui::icon(
                                if card.is_command {
                                    Ico::Terminal
                                } else {
                                    Ico::Hand
                                },
                                px(15.),
                                lb.attention_text,
                            )),
                    )
                    .child(column.child(buttons)),
            )
            .into_any_element()
    }

    fn respond(&mut self, id: &str, approved: bool, scope: ApprovalScope, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.approval_previews.remove(&id);
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

fn note(icon: Ico, text: &'static str, tint: gpui_kit::Hsla) -> impl IntoElement {
    h_flex()
        .gap(px(6.))
        .items_start()
        .text_size(ty::SECONDARY)
        .text_color(tint)
        .child(div().pt(px(1.)).child(ui::icon(icon, px(13.), tint)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .child(crate::ui::text::paragraph(text)),
        )
}
