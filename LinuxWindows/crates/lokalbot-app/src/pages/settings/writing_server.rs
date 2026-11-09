//! Settings → Writing → Where autocomplete runs (`AutocompleteServerSetup`):
//! on this computer, on Think's server with the same or another model, or on
//! any OpenAI-compatible server, hosted or on the user's own network. It edits
//! a draft that Use model applies. Typing goes to a server only after its
//! origin is approved for autocomplete; Think's approval does not cover it.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    SharedString, Styled as _, Subscription, Window, div, px,
};
use lokalbot_ai::autocomplete::server::{self, Failure, Problem, Route, ServerProblem};
use lokalbot_ai::think::Dialect;
use lokalbot_core::Settings;
use lokalbot_core::access::{is_loopback_url, is_private_network_url, origin_of};
use lokalbot_core::settings::{CotypingBackend, CotypingServerRequestStyle, OpenRouterDataPolicy};

use super::{Section, SettingsPage};
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

pub fn backend_label(backend: CotypingBackend) -> &'static str {
    match backend {
        CotypingBackend::OnDevice => lokalbot_i18n::tr("On this computer"),
        CotypingBackend::ThinkServer => lokalbot_i18n::tr("Think's server"),
        CotypingBackend::Server => lokalbot_i18n::tr("Another server"),
    }
}

fn style_label(style: CotypingServerRequestStyle) -> &'static str {
    match style {
        CotypingServerRequestStyle::Automatic => lokalbot_i18n::tr("Automatic"),
        CotypingServerRequestStyle::TextCompletion => lokalbot_i18n::tr("Text completion"),
        CotypingServerRequestStyle::Chat => lokalbot_i18n::tr("Chat"),
    }
}

/// Name of the model autocomplete uses, for Settings
/// (`cotypingModelDisplayName`).
pub fn model_display_name(settings: &Settings) -> SharedString {
    match server::route(settings, None) {
        Route::OnDevice => super::models::model_name(&settings.cotyping_built_in_model_id).into(),
        Route::Server(endpoint) => {
            let host = lokalbot_core::access::host_of(&endpoint.base_url)
                .unwrap_or_else(|| endpoint.origin.clone());
            format!("{} · {host}", endpoint.model).into()
        }
        Route::Unavailable(_) => backend_label(settings.cotyping_backend).into(),
    }
}

/// What to change before the selected server can be used, worded for Settings.
pub fn problem_text(problem: &Problem) -> String {
    match problem {
        Problem::ThinkHasNoServer => lokalbot_i18n::tr("Think doesn't use a server. Choose another server for autocomplete, or run it on this computer, under Where autocomplete runs.").to_string(),
        Problem::MissingUrl => lokalbot_i18n::tr("Add a server URL for autocomplete under Where autocomplete runs.").to_string(),
        Problem::BadUrl => lokalbot_i18n::tr("The autocomplete server URL must start with http:// or https://.").to_string(),
        Problem::Unencrypted { origin } => lokalbot_i18n::format(
            "Autocomplete won't send typing to {0} unencrypted. Use HTTPS, or a server on this computer or your own network.",
            &[("0", origin.clone())],
        ),
        Problem::NeedsApproval { origin } => lokalbot_i18n::format(
            "Approve {0} for autocomplete under Where autocomplete runs before anything you type is sent there.",
            &[("0", origin.clone())],
        ),
        Problem::MissingOllamaModel => lokalbot_i18n::tr("Choose a model for Think's Ollama server, or name one for autocomplete, under Where autocomplete runs.").to_string(),
        Problem::MissingThinkModel => lokalbot_i18n::tr("Set a model for Think's server, or name one for autocomplete, under Where autocomplete runs.").to_string(),
        Problem::MissingModel => lokalbot_i18n::tr("Name the model autocomplete should use on this server under Where autocomplete runs.").to_string(),
    }
}

/// Why the selected server's last request brought no suggestion.
pub fn failure_text(problem: &ServerProblem) -> String {
    match &problem.failure {
        Failure::Status(code) => lokalbot_i18n::format(
            "The autocomplete server answered with HTTP {0}.",
            &[("0", code.to_string())],
        ),
        Failure::Unreachable => {
            lokalbot_i18n::tr("The autocomplete server could not be reached.").to_string()
        }
        Failure::BadReply => {
            lokalbot_i18n::tr("The autocomplete server's reply could not be read.").to_string()
        }
        Failure::Reasoned => lokalbot_i18n::format(
            "{0} reasoned until its reply ran out and wrote no suggestion. Choose a model that can answer without reasoning.",
            &[("0", problem.model.clone())],
        ),
        Failure::EmptyReply => lokalbot_i18n::format(
            "{0} answered with no text.",
            &[("0", problem.model.clone())],
        ),
    }
}

/// Where autocomplete runs, as being edited. Applied with Use model, so Cancel
/// changes nothing.
pub struct ServerDraft {
    pub backend: CotypingBackend,
    pub request_style: CotypingServerRequestStyle,
    /// Typing approval for the draft server's origin.
    pub approved: bool,
    url: Entity<InputState>,
    model: Entity<InputState>,
    think_model: Entity<InputState>,
    key: Entity<InputState>,
    /// `None` until the credential store has answered.
    key_saved: Option<bool>,
}

/// The settings a draft would make. The key is not part of them.
fn applied(
    settings: &Settings,
    backend: CotypingBackend,
    url: &str,
    model: &str,
    think_model: &str,
    style: CotypingServerRequestStyle,
    approved: bool,
) -> Settings {
    let mut target = settings.clone();
    target.cotyping_backend = backend;
    match backend {
        CotypingBackend::OnDevice => {}
        CotypingBackend::ThinkServer => {
            target.cotyping_think_server_model = think_model.trim().to_string();
            target.cotyping_server_request_style = style;
        }
        CotypingBackend::Server => {
            target.cotyping_server_base_url = url.trim().to_string();
            target.cotyping_server_model = model.trim().to_string();
            target.cotyping_server_request_style = style;
        }
    }
    if let Some(origin) = approval_origin(&target) {
        target
            .approved_remote_autocomplete_origins
            .retain(|known| !known.eq_ignore_ascii_case(&origin));
        if approved {
            target.approved_remote_autocomplete_origins.push(origin);
        }
    }
    target
}

/// The origin an approval belongs to. `None` on this computer, where nothing
/// leaves it and nothing needs approving.
fn approval_origin(settings: &Settings) -> Option<String> {
    let url = server::configured_url(settings)?;
    if is_loopback_url(&url) {
        return None;
    }
    origin_of(&url)
}

fn saved_approval(settings: &Settings) -> bool {
    approval_origin(settings).is_some_and(|origin| {
        settings
            .approved_remote_autocomplete_origins
            .iter()
            .any(|known| known.eq_ignore_ascii_case(&origin))
    })
}

impl ServerDraft {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let input = |value: &str,
                     hint: &'static str,
                     window: &mut Window,
                     cx: &mut Context<SettingsPage>| {
            let value = value.to_string();
            cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder(hint, window, cx))
                    .default_value(value)
            })
        };
        let url = input(
            &settings.cotyping_server_base_url,
            "http://my-pc.example.ts.net:8080/v1",
            window,
            cx,
        );
        let model = input(&settings.cotyping_server_model, "Model ID", window, cx);
        let think_model = input(
            &settings.cotyping_think_server_model,
            "Model ID",
            window,
            cx,
        );
        let key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .placeholder(crate::i18n::placeholder("Optional", window, cx))
        });
        Self {
            backend: settings.cotyping_backend,
            request_style: settings.cotyping_server_request_style,
            approved: saved_approval(settings),
            url,
            model,
            think_model,
            key,
            key_saved: None,
        }
    }

    pub fn subscribe(
        draft: &ServerDraft,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        [&draft.url, &draft.model, &draft.think_model, &draft.key]
            .into_iter()
            .map(|input| {
                cx.subscribe_in(input, window, |this, _, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        // An approval belongs to one origin: a newly
                        // entered server shows its own saved choice.
                        let settings = this.data.read(cx).settings.clone();
                        this.writing.server.reload_approval(&settings, cx);
                        cx.notify();
                    }
                })
            })
            .collect()
    }

    fn preview(&self, settings: &Settings, cx: &gpui_kit::App) -> Settings {
        applied(
            settings,
            self.backend,
            self.url.read(cx).value().as_ref(),
            self.model.read(cx).value().as_ref(),
            self.think_model.read(cx).value().as_ref(),
            self.request_style,
            self.approved,
        )
    }

    /// Shows the saved choice for the draft's origin rather than carrying the
    /// checkbox over from another one.
    fn reload_approval(&mut self, settings: &Settings, cx: &gpui_kit::App) {
        let target = applied(
            settings,
            self.backend,
            self.url.read(cx).value().as_ref(),
            self.model.read(cx).value().as_ref(),
            self.think_model.read(cx).value().as_ref(),
            self.request_style,
            false,
        );
        let origin = approval_origin(&target);
        self.approved = origin.is_some_and(|origin| {
            settings
                .approved_remote_autocomplete_origins
                .iter()
                .any(|known| known.eq_ignore_ascii_case(&origin))
        });
    }

    fn is_edited(&self, settings: &Settings, cx: &gpui_kit::App) -> bool {
        self.preview(settings, cx) != *settings
            || !self.key.read(cx).value().as_ref().trim().is_empty()
    }

    fn reset(&mut self, settings: &Settings, window: &mut Window, cx: &mut gpui_kit::App) {
        self.backend = settings.cotyping_backend;
        self.request_style = settings.cotyping_server_request_style;
        self.approved = saved_approval(settings);
        let set = |input: &Entity<InputState>,
                   value: &str,
                   window: &mut Window,
                   cx: &mut gpui_kit::App| {
            let value = value.to_string();
            input.update(cx, |input, cx| input.set_value(value, window, cx));
        };
        set(&self.url, &settings.cotyping_server_base_url, window, cx);
        set(&self.model, &settings.cotyping_server_model, window, cx);
        set(
            &self.think_model,
            &settings.cotyping_think_server_model,
            window,
            cx,
        );
        set(&self.key, "", window, cx);
    }
}

impl SettingsPage {
    /// Reads whether "Another server" has a key saved, off the main thread.
    fn load_key_state(&mut self, cx: &mut Context<Self>) {
        if self.writing.server.key_saved.is_some() {
            return;
        }
        self.writing.server.key_saved = Some(false);
        cx.spawn(async move |this, cx| {
            let saved = cx
                .background_spawn(async {
                    lokalbot_engine::secrets::autocomplete_server_api_key().is_some()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.writing.server.key_saved = Some(saved);
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn server_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let lb = cx.lb().clone();
        let backend = self.writing.server.backend;
        let page = cx.entity();
        let backends = [
            CotypingBackend::OnDevice,
            CotypingBackend::ThinkServer,
            CotypingBackend::Server,
        ];
        let picker = settings_row::picker(
            "settings-cotyping-backend-picker",
            backend_label(backend),
            backends
                .iter()
                .map(|option| {
                    (
                        SharedString::from(backend_label(*option)),
                        *option == backend,
                    )
                })
                .collect(),
            move |index, _, cx| {
                page.update(cx, |page, cx| {
                    page.writing.server.backend = backends[index.min(2)];
                    let settings = page.data.read(cx).settings.clone();
                    page.writing.server.reload_approval(&settings, cx);
                    cx.notify();
                })
            },
        );
        let id = "settings.cotypingBackend";
        let mut section = Section::new(lokalbot_i18n::tr("Where autocomplete runs")).row(
            id,
            settings_row::row(
                id,
                lokalbot_i18n::tr("Where autocomplete runs"),
                None,
                picker,
                self.is_focused(id),
                cx,
            ),
        );
        if backend == CotypingBackend::OnDevice {
            return self.apply_row(section, &settings, cx);
        }
        let mut fields = v_flex().w_full().gap(px(10.));
        if backend == CotypingBackend::ThinkServer {
            let description = server::configured_url(&self.writing.server.preview(&settings, cx))
                .map(|url| {
                    let host = lokalbot_core::access::host_of(&url).unwrap_or(url);
                    format!("{} · {host}", think_backend_name(&settings))
                })
                .unwrap_or_else(|| lokalbot_i18n::tr("Think doesn't use a server").to_string());
            fields = fields
                .child(field_row(
                    lokalbot_i18n::tr("Server"),
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(description)
                        .into_any_element(),
                    None,
                    cx,
                ))
                .child(field_row(
                    lokalbot_i18n::tr("Model"),
                    Input::new(&self.writing.server.think_model)
                        .small()
                        .into_any_element(),
                    Some(lokalbot_i18n::tr(
                        "Leave empty to use Think's model, or name a smaller one for faster suggestions.",
                    )),
                    cx,
                ));
        } else {
            self.load_key_state(cx);
            let saved = self.writing.server.key_saved == Some(true);
            let mut key_row = h_flex().w_full().gap(px(8.)).items_center().child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(Input::new(&self.writing.server.key).small().mask_toggle()),
            );
            if saved {
                let forget_data = self.data.clone();
                key_row = key_row.child(
                    Button::new("settings-autocomplete-forget-key")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Forget"))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            forget_data.update(cx, |data, cx| {
                                data.request(AppEvent::SaveAutocompleteServerKey(String::new()), cx)
                            });
                            this.writing.server.key_saved = Some(false);
                            cx.notify();
                        })),
                );
            }
            fields = fields
                .child(field_row(
                    lokalbot_i18n::tr("Server URL"),
                    Input::new(&self.writing.server.url).small().into_any_element(),
                    Some(lokalbot_i18n::tr(
                        "Any OpenAI-compatible /v1 URL, such as OpenRouter, llama-server, LM Studio, or Ollama.",
                    )),
                    cx,
                ))
                .child(field_row(
                    lokalbot_i18n::tr("Model"),
                    Input::new(&self.writing.server.model).small().into_any_element(),
                    None,
                    cx,
                ))
                .child(field_row(
                    lokalbot_i18n::tr("API key"),
                    key_row.into_any_element(),
                    saved.then_some(lokalbot_i18n::tr("Saved in the system credential store.")),
                    cx,
                ));
        }
        let style = self.writing.server.request_style;
        let styles = [
            CotypingServerRequestStyle::Automatic,
            CotypingServerRequestStyle::TextCompletion,
            CotypingServerRequestStyle::Chat,
        ];
        let page = cx.entity();
        fields = fields.child(field_row(
            lokalbot_i18n::tr("Request type"),
            h_flex()
                .child(settings_row::picker(
                    "settings-cotyping-request-style-picker",
                    style_label(style),
                    styles
                        .iter()
                        .map(|option| (SharedString::from(style_label(*option)), *option == style))
                        .collect(),
                    move |index, _, cx| {
                        page.update(cx, |page, cx| {
                            page.writing.server.request_style = styles[index.min(2)];
                            cx.notify();
                        })
                    },
                ))
                .into_any_element(),
            Some(lokalbot_i18n::tr(
                "Automatic picks text completion or chat for the server.",
            )),
            cx,
        ));
        let target = self.writing.server.preview(&settings, cx);
        let draft_url = server::configured_url(&target);
        let access = self.access_block(&target, draft_url.as_deref(), cx);
        let id = "settings.cotypingServerSetup";
        section = section.row(
            id,
            settings_row::content_row(
                id,
                fields.when_some(access, |this, access| this.child(access)),
                false,
                cx,
            ),
        );
        self.apply_row(section, &settings, cx)
    }

    /// The approval checkbox, with what it sends. Nothing to approve for a
    /// server on this computer.
    fn access_block(
        &self,
        target: &Settings,
        url: Option<&str>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let line = |icon: Ico, text: String, color: gpui_kit::Hsla| {
            h_flex()
                .gap(px(8.))
                .items_start()
                .child(div().pt(px(1.)).child(ui::icon(icon, px(14.), color)))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::SECONDARY)
                        .text_color(color)
                        .child(text),
                )
        };
        let Some(url) = url else {
            if self.writing.server.backend == CotypingBackend::Server
                && !self
                    .writing
                    .server
                    .url
                    .read(cx)
                    .value()
                    .as_ref()
                    .trim()
                    .is_empty()
            {
                return Some(
                    line(
                        Ico::TriangleAlert,
                        lokalbot_i18n::tr(
                            "The autocomplete server URL must start with http:// or https://.",
                        )
                        .to_string(),
                        lb.attention_text,
                    )
                    .into_any_element(),
                );
            }
            return None;
        };
        let Some(origin) =
            origin_of(url).filter(|o| o.starts_with("http://") || o.starts_with("https://"))
        else {
            return Some(
                line(
                    Ico::TriangleAlert,
                    lokalbot_i18n::tr(
                        "The autocomplete server URL must start with http:// or https://.",
                    )
                    .to_string(),
                    lb.attention_text,
                )
                .into_any_element(),
            );
        };
        if is_loopback_url(url) {
            return Some(
                line(
                    Ico::ShieldCheck,
                    lokalbot_i18n::tr("Runs on this computer. What you type stays here.")
                        .to_string(),
                    lb.text_secondary,
                )
                .into_any_element(),
            );
        }
        let https = origin.starts_with("https://");
        if !https && !is_private_network_url(url) {
            return Some(
                line(
                    Ico::Lock,
                    lokalbot_i18n::tr("Use HTTPS for a server outside your network or tailnet.")
                        .to_string(),
                    lb.attention_text,
                )
                .into_any_element(),
            );
        }
        let approved = self.writing.server.approved;
        let page = cx.entity();
        let mut block = v_flex()
            .w_full()
            .gap(px(6.))
            .p(px(12.))
            .rounded(px(8.))
            .bg(lb.text.opacity(0.05))
            .child(
                h_flex()
                    .w_full()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::format(
                                "Send typing to {0}",
                                &[("0", origin.clone())],
                            )),
                    )
                    .child(settings_row::switch(
                        "settings-autocomplete-consent",
                        approved,
                        move |on, _, cx| {
                            page.update(cx, |page, cx| {
                                page.writing.server.approved = on;
                                cx.notify();
                            })
                        },
                    )),
            )
            .child(settings_row::help(
                lokalbot_i18n::tr("What you type goes to this server as you type, with the context you turn on under Settings → Writing."),
                cx,
            ));
        if !https {
            block = block.child(line(
                Ico::LockOpen,
                lokalbot_i18n::tr("Unencrypted HTTP: use it only on your own network or tailnet.")
                    .to_string(),
                lb.attention_text,
            ));
        }
        if Dialect::inferred(url) == Dialect::OpenRouter {
            block = block.child(settings_row::help(
                if target.open_router_data_policy == OpenRouterDataPolicy::PrivateOnly {
                    lokalbot_i18n::tr("OpenRouter: private endpoints only, as chosen under Settings → Models.")
                } else {
                    lokalbot_i18n::tr("OpenRouter: follows your OpenRouter privacy settings, as chosen under Settings → Models.")
                },
                cx,
            ));
        }
        Some(block.into_any_element())
    }

    /// Use model and Cancel, while the draft differs from what is saved.
    fn apply_row(
        &mut self,
        section: Section,
        settings: &Settings,
        cx: &mut Context<Self>,
    ) -> Section {
        if !self.writing.server.is_edited(settings, cx) {
            return section;
        }
        let id = "settings.cotypingServerApply";
        section.row(
            id,
            settings_row::content_row(
                id,
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .justify_end()
                    .child(
                        Button::new("settings-autocomplete-cancel-server")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                let settings = this.data.read(cx).settings.clone();
                                this.writing.server.reset(&settings, window, cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("settings-autocomplete-use-server")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr("Use model"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                let settings = this.data.read(cx).settings.clone();
                                let target = this.writing.server.preview(&settings, cx);
                                let key = this
                                    .writing
                                    .server
                                    .key
                                    .read(cx)
                                    .value()
                                    .as_ref()
                                    .trim()
                                    .to_string();
                                if !key.is_empty() {
                                    this.data.update(cx, |data, cx| {
                                        data.request(AppEvent::SaveAutocompleteServerKey(key), cx)
                                    });
                                    this.writing.server.key_saved = Some(true);
                                    this.writing
                                        .server
                                        .key
                                        .update(cx, |input, cx| input.set_value("", window, cx));
                                }
                                this.update_settings(move |s| *s = target, cx);
                                cx.notify();
                            })),
                    ),
                false,
                cx,
            ),
        )
    }
}

fn think_backend_name(settings: &Settings) -> &'static str {
    match settings.summarizer_backend {
        lokalbot_core::settings::SummarizerBackend::Ollama => lokalbot_i18n::tr("Ollama"),
        _ => lokalbot_i18n::tr("OpenAI-compatible server"),
    }
}

/// A label on the left, a control on the right, optional help under it.
fn field_row(
    title: &'static str,
    control: AnyElement,
    help: Option<&'static str>,
    cx: &gpui_kit::App,
) -> gpui_kit::Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .gap(px(12.))
        .items_start()
        .child(
            div()
                .w(px(96.))
                .flex_none()
                .pt(px(4.))
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(title),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(4.))
                .child(control)
                .when_some(help, |this, help| this.child(settings_row::help(help, cx))),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    const STYLE: CotypingServerRequestStyle = CotypingServerRequestStyle::Automatic;

    #[test]
    fn an_approval_belongs_to_one_origin() {
        let settings = Settings::default();
        let target = applied(
            &settings,
            CotypingBackend::Server,
            " https://a.example/v1 ",
            " small ",
            "",
            STYLE,
            true,
        );
        assert_eq!(target.cotyping_server_base_url, "https://a.example/v1");
        assert_eq!(target.cotyping_server_model, "small");
        assert_eq!(
            target.approved_remote_autocomplete_origins,
            ["https://a.example"]
        );
        assert!(matches!(server::route(&target, None), Route::Server(_)));
        // Another origin starts unapproved, and the first keeps its choice.
        let other = applied(
            &target,
            CotypingBackend::Server,
            "https://b.example/v1",
            "small",
            "",
            STYLE,
            false,
        );
        assert!(!saved_approval(&other));
        assert_eq!(
            other.approved_remote_autocomplete_origins,
            ["https://a.example"]
        );
        // Turning it off takes the approval back.
        let revoked = applied(
            &target,
            CotypingBackend::Server,
            "https://a.example/v1",
            "small",
            "",
            STYLE,
            false,
        );
        assert!(revoked.approved_remote_autocomplete_origins.is_empty());
    }

    #[test]
    fn nothing_on_this_computer_needs_approving() {
        let target = applied(
            &Settings::default(),
            CotypingBackend::Server,
            "http://localhost:8080/v1",
            "small",
            "",
            STYLE,
            true,
        );
        assert!(target.approved_remote_autocomplete_origins.is_empty());
        assert!(matches!(server::route(&target, None), Route::Server(_)));
    }

    #[test]
    fn think_approval_never_counts() {
        let settings = Settings {
            approved_remote_inference_origins: vec!["https://a.example".into()],
            ..Settings::default()
        };
        let target = applied(
            &settings,
            CotypingBackend::Server,
            "https://a.example/v1",
            "small",
            "",
            STYLE,
            false,
        );
        assert!(matches!(
            server::route(&target, None),
            Route::Unavailable(Problem::NeedsApproval { .. })
        ));
    }
}
