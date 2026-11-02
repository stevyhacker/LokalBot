//! Check model setup (`ModelChecksSheet`), and what a failed connection check
//! says (`GenerationTestFailurePresentation`).

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, IntoElement as _, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::access::origin_of;
use lokalbot_core::remote_transcription::audio_destination;
use lokalbot_core::settings::{OpenRouterDataPolicy, SummarizerBackend};
use lokalbot_engine::{Command, ModelCheckResult, ModelRole};

use super::model_options::subpage_header;
use super::models::autocomplete_needs;
use super::{Section, SettingsPage};
use crate::state::ModelStatus;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

pub(super) fn role_title(role: ModelRole) -> &'static str {
    match role {
        ModelRole::Transcribe => lokalbot_i18n::tr("Transcribe"),
        ModelRole::Think => lokalbot_i18n::tr("Think"),
        ModelRole::Autocomplete => lokalbot_i18n::tr("Autocomplete"),
    }
}

fn role_icon(role: ModelRole) -> Ico {
    match role {
        ModelRole::Transcribe => Ico::AudioLines,
        ModelRole::Think => Ico::Brain,
        ModelRole::Autocomplete => Ico::TextCursorInput,
    }
}

fn role_is_ready(role: ModelRole, settings: &Settings, status: &ModelStatus) -> bool {
    match role {
        ModelRole::Transcribe => status.transcription_ready,
        ModelRole::Think => {
            status.think_ready || settings.summarizer_backend != SummarizerBackend::BuiltIn
        }
        ModelRole::Autocomplete => autocomplete_needs(settings)
            .iter()
            .all(|id| status.installed.contains(id)),
    }
}

/// "Check passed · 15:41", or "Check failed: …".
pub(super) fn result_label(result: &ModelCheckResult) -> String {
    match &result.failure {
        Some(failure) => lokalbot_i18n::format("Check failed: {0}", &[("0", failure.clone())]),
        None => lokalbot_i18n::format(
            "Check passed · {0}",
            &[("0", result.checked_at.format("%H:%M").to_string())],
        ),
    }
}

/// What the checks send where. Text only ever names sample content.
fn disclosure(settings: &Settings) -> String {
    let think_remote = !settings.think_is_local();
    match (audio_destination(settings), think_remote) {
        (Some(host), false) => lokalbot_i18n::format(
            "The Transcribe check sends a built-in spoken sample to {0}. Other checks run on this PC. No meeting, screen, or clipboard content is used.",
            &[("0", host)],
        ),
        (Some(host), true) => lokalbot_i18n::format(
            "Think sends a short sample prompt to your approved server, and the Transcribe check sends a built-in spoken sample to {0}. Autocomplete is checked on this PC.",
            &[("0", host)],
        ),
        (None, false) => lokalbot_i18n::tr(
            "Sample audio and text are processed on this PC. No meeting, screen, or clipboard content is used.",
        )
        .to_string(),
        (None, true) => lokalbot_i18n::tr(
            "Think sends a short sample prompt to your approved server. Transcription and autocomplete are checked on this PC.",
        )
        .to_string(),
    }
}

impl SettingsPage {
    pub(super) fn model_checks_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let (settings, status, checks) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.clone(),
                data.model_checks.clone(),
            )
        };
        let header = subpage_header(
            cx.entity(),
            lokalbot_i18n::tr("Check model setup"),
            lokalbot_i18n::tr("Check each available model independently using sample content."),
            cx,
        );
        let available: Vec<ModelRole> = ModelRole::ALL
            .into_iter()
            .filter(|role| role_is_ready(*role, &settings, &status))
            .collect();

        let mut section = Section::new(None).row(
            "settings.modelChecks",
            settings_row::content_row(
                "settings.modelChecks",
                v_flex()
                    .gap(px(6.))
                    .child(settings_row::help(disclosure(&settings), cx))
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Checks confirm that a model responds. They do not measure transcription accuracy or answer quality."),
                        cx,
                    )),
                self.is_focused("settings.modelChecks"),
                cx,
            ),
        );
        for role in ModelRole::ALL {
            let ready = role_is_ready(role, &settings, &status);
            let result = checks.result(role);
            let detail: Vec<(SharedString, gpui_kit::Hsla)> = if checks.testing == Some(role) {
                vec![(lokalbot_i18n::tr("Checking…").into(), lb.text_secondary)]
            } else if let Some(result) = result {
                let mut lines = vec![(
                    SharedString::from(result_label(result)),
                    if result.failure.is_none() {
                        lb.text_secondary
                    } else {
                        lb.attention_text
                    },
                )];
                if result.failure.is_none() {
                    lines.push((
                        lokalbot_i18n::format(
                            "Sample check completed in {0} seconds",
                            &[("0", format!("{:.1}", result.elapsed_seconds))],
                        )
                        .into(),
                        lb.text_secondary,
                    ));
                }
                lines
            } else if ready {
                vec![(
                    lokalbot_i18n::tr("Not checked yet").into(),
                    lb.text_secondary,
                )]
            } else {
                vec![(
                    lokalbot_i18n::tr("Download required").into(),
                    lb.text_secondary,
                )]
            };
            let id: &'static str = match role {
                ModelRole::Transcribe => "settings-check-transcribe",
                ModelRole::Think => "settings-check-think",
                ModelRole::Autocomplete => "settings-check-autocomplete",
            };
            section = section.row(
                id,
                settings_row::content_row(
                    id,
                    h_flex()
                        .gap(px(12.))
                        .items_start()
                        .child(ui::icon(role_icon(role), px(19.), lb.text_secondary))
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(3.))
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.text)
                                        .child(role_title(role)),
                                )
                                .children(detail.into_iter().map(|(text, color)| {
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(color)
                                        .child(crate::ui::text::paragraph(text))
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("{id}-run")))
                                .outline()
                                .small()
                                .label(if result.is_some_and(|r| r.failure.is_some()) {
                                    lokalbot_i18n::tr("Retry")
                                } else {
                                    lokalbot_i18n::tr("Check")
                                })
                                .disabled(checks.running || !ready)
                                .on_click(move |_, _, cx| {
                                    crate::bridge::send(Command::CheckModels(vec![role]), cx)
                                }),
                        ),
                    false,
                    cx,
                ),
            );
        }
        let action = if checks.running {
            Button::new("settings-checks-cancel")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Cancel checks"))
                .on_click(move |_, _, cx| crate::bridge::send(Command::CancelModelChecks, cx))
        } else {
            Button::new("settings-checks-available")
                .primary()
                .small()
                .label(lokalbot_i18n::tr("Check available models"))
                .disabled(available.is_empty())
                .on_click(move |_, _, cx| {
                    crate::bridge::send(Command::CheckModels(available.clone()), cx)
                })
        };
        section = section.row(
            "settings-checks-actions",
            settings_row::content_row("settings-checks-actions", h_flex().child(action), false, cx),
        );
        vec![
            Section::new(None).row(
                "settings.modelsHeader",
                settings_row::content_row("settings.modelsHeader", header, false, cx),
            ),
            section,
        ]
    }

    /// "Check connection", its status and what a failure means, below the
    /// connection form. Checks use the saved values, so unsaved edits disable it.
    pub(super) fn connection_check_row(
        &mut self,
        backend: SummarizerBackend,
        has_changes: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (settings, check) = {
            let data = self.data.read(cx);
            (data.settings.clone(), data.connection_check.clone())
        };
        let mine = check.backend == Some(backend);
        let running = mine && check.running;
        let mut column = v_flex()
            .gap(px(8.))
            .child(
                h_flex().child(
                    Button::new("settings-check-connection")
                        .outline()
                        .small()
                        .label(if running {
                            lokalbot_i18n::tr("Checking…")
                        } else {
                            lokalbot_i18n::tr("Check connection")
                        })
                        .disabled(running || has_changes)
                        .on_click(move |_, _, cx| {
                            crate::bridge::send(Command::CheckConnection(backend), cx)
                        }),
                ),
            )
            .child(settings_row::help(
                if has_changes {
                    lokalbot_i18n::tr("Save changes before checking this connection.")
                } else {
                    lokalbot_i18n::tr("Connection checks send a short sample prompt to this server. No meeting or screen content is used.")
                },
                cx,
            ));
        if mine && !has_changes {
            if let Some(reply) = &check.reply {
                column = column.child(settings_row::help(
                    lokalbot_i18n::format("Connection check passed · {0}", &[("0", reply.clone())]),
                    cx,
                ));
            }
            if let Some(error) = &check.error {
                let (base_url, model) = if backend == SummarizerBackend::OpenAICompatible {
                    (
                        Some(settings.openai_base_url.as_str()),
                        Some(settings.openai_model.as_str()),
                    )
                } else {
                    (None, None)
                };
                let failure = GenerationFailure::new(
                    error,
                    base_url,
                    model,
                    settings.open_router_data_policy,
                );
                column = column.child(failure_details(&failure, cx));
            }
        }
        column.into_any_element()
    }
}

fn failure_details(failure: &GenerationFailure, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb().clone();
    v_flex()
        .gap(px(6.))
        .p(px(12.))
        .rounded(px(8.))
        .bg(lb.status_fill(lb.attention))
        .border_1()
        .border_color(lb.status_stroke(lb.attention))
        .child(
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(failure.title.clone())),
                ),
        )
        .child(settings_row::help(failure.explanation.clone(), cx))
        .child(settings_row::help(failure.recovery.clone(), cx))
        .when_some(failure.privacy_note.clone(), |this, note| {
            this.child(settings_row::help(note, cx))
        })
        .when_some(failure.action, |this, (title, url)| {
            this.child(h_flex().child(settings_row::link_button(
                "settings-connection-failure-action",
                lokalbot_i18n::tr(title),
                move |_, cx| cx.open_url(url),
                cx,
            )))
        })
        .child(
            div()
                .text_size(ty::CAPTION)
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(
                    failure.technical_details.clone(),
                )),
        )
}

/// What a failed check tells the user (`GenerationTestFailurePresentation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GenerationFailure {
    pub title: String,
    pub explanation: String,
    pub recovery: String,
    pub privacy_note: Option<String>,
    pub action: Option<(&'static str, &'static str)>,
    pub technical_details: String,
}

impl GenerationFailure {
    pub fn new(
        error: &str,
        base_url: Option<&str>,
        model: Option<&str>,
        policy: OpenRouterDataPolicy,
    ) -> Self {
        let details = error.to_lowercase();
        let host = base_url
            .and_then(origin_of)
            .and_then(|origin| origin.split_once("://").map(|(_, host)| host.to_string()));
        let is_open_router = host
            .as_deref()
            .is_some_and(|host| host == "openrouter.ai" || host.ends_with(".openrouter.ai"));
        let is_data_policy = details.contains("data policy")
            || details.contains("paid model training")
            || details.contains("openrouter.ai/settings/privacy");
        let technical_details = error.to_string();
        if !(is_open_router && is_data_policy) {
            return Self {
                title: lokalbot_i18n::tr("Generation test failed").to_string(),
                explanation: lokalbot_i18n::tr("LokalBot couldn't complete the test request.")
                    .to_string(),
                recovery: lokalbot_i18n::tr(
                    "Check the server URL, model name, API key, and server availability, then try again.",
                )
                .to_string(),
                privacy_note: None,
                action: None,
                technical_details,
            };
        }
        let selected = model
            .map(str::trim)
            .filter(|model| !model.is_empty())
            .map_or_else(
                || lokalbot_i18n::tr("the selected model").to_string(),
                str::to_string,
            );
        match policy {
            OpenRouterDataPolicy::PrivateOnly => Self {
                title: lokalbot_i18n::tr("No private endpoint for this model").to_string(),
                explanation: lokalbot_i18n::format(
                    "LokalBot restricts OpenRouter to providers that do not collect inference data, but no available endpoint for {0} matches that requirement.",
                    &[("0", selected)],
                ),
                recovery: lokalbot_i18n::tr(
                    "Keep “Private endpoints only” and choose a compatible model, or change Provider data use to follow your OpenRouter privacy settings.",
                )
                .to_string(),
                privacy_note: Some(
                    lokalbot_i18n::tr("Private endpoints only remains recommended for meeting content.")
                        .to_string(),
                ),
                action: None,
                technical_details,
            },
            OpenRouterDataPolicy::AccountPolicy => Self {
                title: lokalbot_i18n::tr("OpenRouter still blocks this model").to_string(),
                explanation: lokalbot_i18n::format(
                    "LokalBot is following your OpenRouter policy, but OpenRouter couldn't find an allowed endpoint for {0}.",
                    &[("0", selected)],
                ),
                recovery: lokalbot_i18n::tr(
                    "Review the privacy settings and any guardrail assigned to this account, API key, or workspace, or choose another model.",
                )
                .to_string(),
                privacy_note: Some(
                    lokalbot_i18n::tr("LokalBot cannot read which OpenRouter policy applies to this key. Providers allowed by that policy may retain or train on approved meeting transcripts, screen text, and Agent context.")
                        .to_string(),
                ),
                action: Some((
                    "Open OpenRouter Privacy Settings",
                    "https://openrouter.ai/settings/privacy",
                )),
                technical_details,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPEN_ROUTER: &str = "https://openrouter.ai/api/v1";
    const POLICY_ERROR: &str =
        "LLM server returned HTTP 404: No endpoints found matching your data policy";

    #[test]
    fn a_generic_failure_keeps_the_details() {
        let failure = GenerationFailure::new(
            "connection refused",
            Some(OPEN_ROUTER),
            Some("m"),
            OpenRouterDataPolicy::PrivateOnly,
        );
        assert_eq!(failure.title, "Generation test failed");
        assert_eq!(failure.technical_details, "connection refused");
        assert_eq!(failure.action, None);
    }

    #[test]
    fn a_data_policy_failure_explains_the_routing() {
        let private = GenerationFailure::new(
            POLICY_ERROR,
            Some(OPEN_ROUTER),
            Some(" openai/gpt "),
            OpenRouterDataPolicy::PrivateOnly,
        );
        assert_eq!(private.title, "No private endpoint for this model");
        assert!(private.explanation.contains("openai/gpt"));
        assert!(private.privacy_note.is_some());
        assert_eq!(private.action, None);

        let account = GenerationFailure::new(
            POLICY_ERROR,
            Some(OPEN_ROUTER),
            Some(""),
            OpenRouterDataPolicy::AccountPolicy,
        );
        assert_eq!(account.title, "OpenRouter still blocks this model");
        assert!(account.explanation.contains("the selected model"));
        assert_eq!(
            account.action.map(|(_, url)| url),
            Some("https://openrouter.ai/settings/privacy")
        );
    }

    #[test]
    fn only_openrouter_gets_the_data_policy_advice() {
        let failure = GenerationFailure::new(
            POLICY_ERROR,
            Some("https://openrouter.ai.evil.example/v1"),
            Some("m"),
            OpenRouterDataPolicy::PrivateOnly,
        );
        assert_eq!(failure.title, "Generation test failed");
    }

    #[test]
    fn the_disclosure_names_where_samples_go() {
        let local = Settings::default();
        assert!(disclosure(&local).contains("on this PC"));
        let remote = Settings {
            transcription_model: lokalbot_core::remote_transcription::MODEL_ID.into(),
            remote_transcription_base_url: "https://audio.example/v1".into(),
            approved_remote_transcription_origins: vec!["https://audio.example".into()],
            ..Default::default()
        };
        assert!(disclosure(&remote).contains("audio.example"));
        // A server on this computer keeps the sample here.
        let loopback = Settings {
            transcription_model: lokalbot_core::remote_transcription::MODEL_ID.into(),
            remote_transcription_base_url: "http://127.0.0.1:9000/v1".into(),
            ..Default::default()
        };
        assert!(!disclosure(&loopback).contains("127.0.0.1"));
    }

    #[test]
    fn the_label_says_pass_or_why_not() {
        let result = |failure: Option<&str>| ModelCheckResult {
            role: ModelRole::Think,
            checked_at: chrono::Local::now(),
            elapsed_seconds: 1.0,
            failure: failure.map(str::to_string),
            identity: Vec::new(),
        };
        assert!(result_label(&result(None)).starts_with("Check passed · "));
        assert_eq!(result_label(&result(Some("boom"))), "Check failed: boom");
    }
}
