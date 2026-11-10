//! What Personal Context adds to a conversation (`RememberReceiptCard`,
//! `PersonalContextDisclosure`): the receipt after "Remember …", with Undo, and
//! the list of what an answer was given.

use std::collections::{HashMap, HashSet};

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::RememberReceipt;
use lokalbot_core::personal::{Claim, ClaimEdit, ClaimKind, EditError};
use uuid::Uuid;

use super::AskPage;
use crate::i18n::h_flex;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// What the page knows about saved claims.
#[derive(Default)]
pub(super) struct RememberState {
    pub(super) claims: HashMap<Uuid, Claim>,
    /// The answers whose "Used N things" list is open.
    open: HashSet<Uuid>,
}

impl AskPage {
    /// Runs one edit off the main thread. One that could not be saved says
    /// so, as in Settings → Personal Context: Undo must not look done.
    fn edit_claim(
        &mut self,
        change: impl FnOnce(&lokalbot_core::Library) -> Result<(), EditError> + Send + 'static,
        cx: &mut Context<Self>,
    ) {
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let result = cx.background_spawn(async move { change(&library) }).await;
            data.update(cx, |data, cx| {
                if let Err(err) = result {
                    data.show_error(err.message(), cx);
                }
                data.mark_library_changed(cx)
            });
        })
        .detach();
    }

    fn manage_button(&self, id: Uuid) -> AnyElement {
        let data = self.data.clone();
        Button::new(SharedString::from(format!("remember-manage-{id}")))
            .ghost()
            .small()
            .label(lokalbot_i18n::tr("Manage…"))
            .on_click(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.open_settings(SettingsCategory::PersonalContext, cx)
                })
            })
            .into_any_element()
    }

    pub(super) fn render_remember_receipt(
        &mut self,
        message_id: Uuid,
        receipt: &RememberReceipt,
        text: &str,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Div {
        let lb = cx.lb().clone();
        let claim = receipt
            .claim_id
            .and_then(|id| self.remember.claims.get(&id).cloned());
        let (icon, title, color) = match (&receipt.claim_id, &claim) {
            (None, _) => (
                Ico::CircleAlert,
                lokalbot_i18n::tr("Not remembered"),
                lb.attention_text,
            ),
            (Some(_), None) => (
                Ico::Minus,
                lokalbot_i18n::tr("Remembered, then forgotten"),
                lb.accent_text,
            ),
            (Some(_), Some(_)) => (
                Ico::CircleCheck,
                lokalbot_i18n::tr("Remembered"),
                lb.accent_text,
            ),
        };
        let shown = claim
            .as_ref()
            .map(|c| c.text.clone())
            .unwrap_or_else(|| text.to_string());
        let mut card = v_flex()
            .gap(px(8.))
            .p(px(12.))
            .w_full()
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.group_fill)
            .child(
                h_flex()
                    .gap(px(7.))
                    .items_center()
                    .child(ui::icon(icon, px(14.), color))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(title),
                    ),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(if claim.is_some() {
                        lb.text
                    } else {
                        lb.text_secondary
                    })
                    .child(ui::text::paragraph(SharedString::from(shown))),
            );
        if let Some(claim) = claim {
            let id = claim.id;
            let page = cx.entity();
            let undo_page = page.clone();
            card = card.child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        Button::new(SharedString::from(format!("remember-kind-{message_id}")))
                            .ghost()
                            .small()
                            .label(claim.kind.display_name())
                            .dropdown_caret(true)
                            .dropdown_menu(move |mut menu, _, _| {
                                for kind in ClaimKind::ALL {
                                    let page = page.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(kind.display_name()).on_click(
                                            move |_, _, cx| {
                                                page.update(cx, |page, cx| {
                                                    page.edit_claim(
                                                        move |library| {
                                                            library
                                                                .personal()
                                                                .update(
                                                                    id,
                                                                    ClaimEdit {
                                                                        kind: Some(kind),
                                                                        ..Default::default()
                                                                    },
                                                                )
                                                                .map(|_| ())
                                                        },
                                                        cx,
                                                    )
                                                })
                                            },
                                        ),
                                    );
                                }
                                menu
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("remember-undo-{message_id}")))
                            .ghost()
                            .small()
                            .label(lokalbot_i18n::tr("Undo"))
                            .on_click(move |_, _, cx| {
                                undo_page.update(cx, |page, cx| {
                                    page.edit_claim(
                                        move |library| {
                                            library.personal().forget(&HashSet::from([id]))
                                        },
                                        cx,
                                    )
                                })
                            }),
                    )
                    .child(self.manage_button(message_id)),
            );
        } else if receipt.claim_id.is_none() {
            card = card.child(self.manage_button(message_id));
        }
        v_flex().w_full().child(card)
    }

    /// "Used 2 things you told LokalBot".
    pub(super) fn render_used_claims(
        &mut self,
        message_id: Uuid,
        claim_ids: &[Uuid],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let open = self.remember.open.contains(&message_id);
        let title = if claim_ids.len() == 1 {
            lokalbot_i18n::tr("Used 1 thing you told LokalBot").to_string()
        } else {
            lokalbot_i18n::format(
                "Used {0} things you told LokalBot",
                &[("0", claim_ids.len().to_string())],
            )
        };
        let header = h_flex()
            .id(SharedString::from(format!("remember-used-{message_id}")))
            .gap(px(6.))
            .items_center()
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            .hover(|s| s.text_color(lb.text))
            .child(ui::icon(
                if open {
                    Ico::ChevronDown
                } else {
                    Ico::ChevronRight
                },
                px(12.),
                lb.text_secondary,
            ))
            .child(ui::icon(Ico::UserRoundCheck, px(13.), lb.text_secondary))
            .child(title)
            .on_click(cx.listener(move |this, _, _, cx| {
                if !this.remember.open.remove(&message_id) {
                    this.remember.open.insert(message_id);
                }
                cx.notify();
            }));
        let mut column = v_flex().gap(px(6.)).child(header);
        if open {
            let mut list = v_flex().gap(px(4.)).pl(px(18.));
            for id in claim_ids {
                list = list.child(match self.remember.claims.get(id) {
                    Some(claim) => div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text)
                        .child(ui::text::paragraph(SharedString::from(claim.text.clone()))),
                    None => div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::tr("Forgotten since this answer")),
                });
            }
            let data = self.data.clone();
            list = list.child(
                Button::new(SharedString::from(format!(
                    "remember-used-manage-{message_id}"
                )))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Manage what LokalBot remembers…"))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.open_settings(SettingsCategory::PersonalContext, cx)
                    })
                }),
            );
            column = column.child(list);
        }
        column.into_any_element()
    }
}
