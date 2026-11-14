//! What Personal Context adds to a conversation (`RememberReceiptCard`,
//! `PersonalContextDisclosure`): the receipt after "Remember …", with Undo, and
//! the list of what an answer was given.

use std::collections::{HashMap, HashSet};

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, IntoElement, ParentElement as _,
    SharedString, Styled as _, div, px,
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

    /// The sources list's last row (`PersonalContextRow`): what the person told
    /// LokalBot about themselves that went into this answer.
    pub(super) fn render_used_claims(
        &mut self,
        message_id: Uuid,
        claim_ids: &[Uuid],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let told: Vec<String> = claim_ids
            .iter()
            .map(|id| match self.remember.claims.get(id) {
                Some(claim) => format!("“{}”", claim.text),
                None => lokalbot_i18n::tr("Forgotten since this answer").to_string(),
            })
            .collect();
        let data = self.data.clone();
        h_flex()
            .w_full()
            .min_h(px(36.))
            .gap(px(10.))
            .items_center()
            .pl(px(8.))
            .pr(px(12.))
            .py(px(7.))
            .child(super::matches::source_tile(
                Ico::UserRoundCheck,
                px(32.),
                px(22.),
                &lb,
            ))
            .child(
                div()
                    .flex_none()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::tr("You told LokalBot")),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(told.join(" · ")),
            )
            .child(div().flex_none().text_size(ty::SECONDARY).child(ui::link(
                SharedString::from(format!("remember-used-manage-{message_id}")),
                lokalbot_i18n::tr("Manage"),
                move |_, cx| {
                    data.update(cx, |data, cx| {
                        data.open_settings(SettingsCategory::PersonalContext, cx)
                    })
                },
                cx,
            )))
            .into_any_element()
    }
}
