//! The setup card (`AgentView.installCard`): what Agent Mode is, what setup
//! downloads, and the explicit "Set Up Agent Mode" action. Nothing is
//! downloaded until the user asks.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::progress::Progress;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement, ParentElement as _, Styled as _, div, px,
};

use lokalbot_agent::InstallPhase;
use lokalbot_agent::shell::ShellChoice;

use super::AgentPage;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

impl AgentPage {
    pub(super) fn render_setup(&mut self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let (phase, manifest, shell) = match self.model(cx) {
            Some(model) => (
                model.phase.clone(),
                model.installer().manifest().clone(),
                model.shell.clone(),
            ),
            None => (
                InstallPhase::Checking,
                lokalbot_agent::RuntimeManifest::current(),
                ShellChoice::Default,
            ),
        };
        let remote = crate::pages::ask::composer_inference(cx).remote;
        let inference = if remote {
            lokalbot_i18n::tr(
                "Prompts and approved context are sent to your configured remote Think model.",
            )
        } else {
            lokalbot_i18n::tr("Model inference runs on this PC.")
        };
        let description = lokalbot_i18n::format(
            "A local coding and file agent powered by your selected Think model. Setup downloads about {0} and uses about {1} after installation. {inference} Session history stays local; commands you approve run with your account’s permissions on this PC and may access files or the network.",
            &[
                ("0", manifest.download_label().to_string()),
                ("1", manifest.installed_label().to_string()),
                ("inference", inference.to_string()),
            ],
        );

        let action: AnyElement = match &phase {
            InstallPhase::Checking => {
                status_line(lokalbot_i18n::tr("Verifying Agent runtime…"), cx)
            }
            InstallPhase::Idle => Button::new("agent-install")
                .primary()
                .icon(Icon::new(Ico::Download))
                .label(lokalbot_i18n::tr("Set Up Agent Mode"))
                .font_weight(FontWeight::SEMIBOLD)
                .on_click(cx.listener(|this, _, _, cx| this.install(false, cx)))
                .into_any_element(),
            InstallPhase::Downloading { name, progress } => v_flex()
                .w(px(320.))
                .gap(px(8.))
                .items_center()
                .child(
                    Progress::new("agent-install-progress")
                        .value(progress.map(|p| p * 100.).unwrap_or(0.))
                        .loading(progress.is_none()),
                )
                .child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "Downloading {name}…",
                            &[("name", name.to_string())],
                        ))),
                )
                .into_any_element(),
            InstallPhase::Installing { name } => status_line(
                &lokalbot_i18n::format("Installing {name}…", &[("name", name.to_string())]),
                cx,
            ),
            InstallPhase::Failed(message) => v_flex()
                .gap(px(10.))
                .items_center()
                .child(
                    div()
                        .max_w(px(460.))
                        .text_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(message.clone()),
                )
                .child(
                    Button::new("agent-install-retry")
                        .outline()
                        .label(lokalbot_i18n::tr("Repair Agent Mode"))
                        .on_click(cx.listener(|this, _, _, cx| this.install(true, cx))),
                )
                .into_any_element(),
            InstallPhase::Installed => div().into_any_element(),
        };

        let shell_note = cfg!(windows).then(|| {
            h_flex()
                .max_w(px(460.))
                .gap(px(6.))
                .items_start()
                .child(ui::icon(Ico::Terminal, px(13.), lb.text_secondary))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(shell.description()),
                )
        });
        let settings_data = self.data.clone();
        div().size_full().flex().items_center().justify_center().child(
            v_flex()
                .items_center()
                .gap(px(12.))
                .p(px(28.))
                .child(ui::icon_tile(Ico::WandSparkles, lb.accent_text, px(56.)))
                .child(
                    div()
                        .text_size(ty::PAGE_TITLE)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Agent Mode"))),
                )
                .child(
                    div()
                        .max_w(px(460.))
                        .text_center()
                        .text_size(ty::BODY)
                        .line_height(px(21.))
                        .text_color(lb.supporting)
                        .child(description),
                )
                .when_some(shell_note, |this, note| this.child(note))
                .child(div().pt(px(4.)).child(action))
                .child(
                    div().pt(px(18.)).text_size(ty::SECONDARY).child(ui::link(
                        "agent-external-cli",
                        lokalbot_i18n::tr("Using your own coding agent? Set up lokalbot-cli and MCP in Settings → Advanced."),
                        move |_, cx| {
                            settings_data.update(cx, |data, cx| {
                                data.open_settings(SettingsCategory::Advanced, cx)
                            })
                        },
                        cx,
                    )),
                ),
        )
    }

    pub(super) fn install(&mut self, force: bool, cx: &mut Context<Self>) {
        if let Some(model) = &self.model {
            model.update(cx, |model, cx| model.install(force, cx));
        }
    }
}

fn status_line(text: &str, cx: &mut Context<AgentPage>) -> AnyElement {
    let lb = cx.lb().clone();
    h_flex()
        .gap(px(8.))
        .items_center()
        .child(Spinner::new().xsmall().color(lb.text_secondary))
        .child(
            div()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(text.to_string()),
        )
        .into_any_element()
}
