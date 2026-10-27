//! Think on a ChatGPT or Claude plan (`SubscriptionPlanSetupView.swift`):
//! the account, the model and the plan's own consent, shown under Settings →
//! Models → Connections. Signing in, approval and the model are separate
//! steps: a sign-in alone never lets context leave this PC.
//!
//! Also the OpenRouter provider data policy and the Anthropic API note shown
//! with the OpenAI-compatible connection (`ModelConnectionsView.swift`).

use std::path::PathBuf;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Context, Div, Entity, FontWeight, ParentElement as _, SharedString, Styled as _, Window,
    div, px,
};
use lokalbot_ai::plans::chatgpt::{self, PlanModel, PlanStatus};
use lokalbot_ai::plans::claude::{self, AuthStatus};
use lokalbot_core::settings::{OpenRouterDataPolicy, SubscriptionPlan};

use super::SettingsPage;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// Claude Code's aliases, which follow the newest model of each family.
const CLAUDE_CHOICES: [(&str, &str); 5] = [
    ("", "Claude Code default"),
    ("fable", "Fable"),
    ("opus", "Opus"),
    ("sonnet", "Sonnet"),
    ("haiku", "Haiku"),
];

/// What the plan forms know about the accounts. Filled in the background.
#[derive(Default)]
pub struct PlansState {
    chatgpt_loading: bool,
    chatgpt_status: Option<Result<PlanStatus, String>>,
    chatgpt_models: Option<Result<Vec<PlanModel>, String>>,
    signing_in: bool,
    chatgpt_error: Option<String>,
    revocation_unconfirmed: bool,
    show_notice: bool,
    claude_checking: bool,
    claude_checked: bool,
    claude_executable: Option<PathBuf>,
    claude_version: Option<String>,
    claude_auth: Option<AuthStatus>,
    claude_error: Option<String>,
}

fn error_text(err: &anyhow::Error) -> String {
    format!("{err:#}")
}

impl SettingsPage {
    // ------------------------------------------------------------ ChatGPT

    fn load_chatgpt(&mut self, refresh_models: bool, cx: &mut Context<Self>) {
        let plans = &mut self.models.plans;
        if plans.chatgpt_loading {
            return;
        }
        plans.chatgpt_loading = true;
        cx.spawn(async move |this, cx| {
            let (status, models) = smol::unblock(move || {
                let account = chatgpt::shared();
                let status = account.status();
                let models = match &status {
                    Ok(status) if status.allows_plan_usage() => {
                        Some(account.models(refresh_models).map_err(|e| error_text(&e)))
                    }
                    _ => None,
                };
                (status.map_err(|e| error_text(&e)), models)
            })
            .await;
            let _ = this.update(cx, |this, cx| {
                let plans = &mut this.models.plans;
                plans.chatgpt_loading = false;
                plans.chatgpt_status = Some(status);
                plans.chatgpt_models = models;
                this.choose_first_chatgpt_model(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// A signed-in account with no model chosen gets its first model.
    fn choose_first_chatgpt_model(&mut self, cx: &mut Context<Self>) {
        let first = match &self.models.plans.chatgpt_models {
            Some(Ok(models)) => models.first().map(|m| m.slug.clone()),
            _ => None,
        };
        if let Some(first) = first
            && self
                .data
                .read(cx)
                .settings
                .chatgpt_plan_model
                .trim()
                .is_empty()
        {
            self.update_settings(|s| s.chatgpt_plan_model = first, cx);
        }
    }

    fn sign_in(&mut self, new_registration: bool, cx: &mut Context<Self>) {
        let plans = &mut self.models.plans;
        plans.chatgpt_error = None;
        plans.revocation_unconfirmed = false;
        plans.signing_in = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = smol::unblock(move || {
                let account = chatgpt::shared();
                if new_registration {
                    account.forget_registration();
                }
                account.sign_in(new_registration, &|url| lokalbot_platform::open_url(url))
            })
            .await;
            let _ = this.update(cx, |this, cx| {
                let acknowledged = this.data.read(cx).settings.chatgpt_plan_notice_acknowledged;
                let plans = &mut this.models.plans;
                plans.signing_in = false;
                match result {
                    Ok(status) => {
                        plans.show_notice = status.allows_plan_usage() && !acknowledged;
                    }
                    Err(err) => {
                        if !matches!(
                            lokalbot_ai::plans::plan_error(&err),
                            Some(lokalbot_ai::plans::PlanError::SignInCancelled)
                        ) {
                            plans.chatgpt_error = Some(error_text(&err));
                        }
                    }
                }
                this.load_chatgpt(true, cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn cancel_sign_in(&mut self, cx: &mut Context<Self>) {
        chatgpt::shared().cancel_sign_in();
        cx.notify();
    }

    fn sign_out(&mut self, cx: &mut Context<Self>) {
        let plans = &mut self.models.plans;
        plans.chatgpt_error = None;
        plans.signing_in = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let confirmed = smol::unblock(|| chatgpt::shared().sign_out()).await;
            let _ = this.update(cx, |this, cx| {
                let plans = &mut this.models.plans;
                plans.signing_in = false;
                plans.revocation_unconfirmed = !confirmed;
                plans.chatgpt_models = None;
                this.load_chatgpt(false, cx);
                cx.notify();
            });
        })
        .detach();
    }

    // ------------------------------------------------------------- Claude

    fn check_claude(&mut self, refresh: bool, cx: &mut Context<Self>) {
        let plans = &mut self.models.plans;
        if plans.claude_checking {
            return;
        }
        plans.claude_checking = true;
        plans.claude_error = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let (executable, version, auth) = smol::unblock(move || {
                let Some(executable) = claude::locate(refresh) else {
                    return (None, None, None);
                };
                let version = claude::version(&executable);
                let auth = claude::auth_status(&executable).map_err(|e| error_text(&e));
                (Some(executable), version, Some(auth))
            })
            .await;
            let _ = this.update(cx, |this, cx| {
                let plans = &mut this.models.plans;
                plans.claude_checking = false;
                plans.claude_checked = true;
                plans.claude_executable = executable;
                plans.claude_version = version;
                match auth {
                    Some(Ok(auth)) => plans.claude_auth = Some(auth),
                    Some(Err(err)) => {
                        plans.claude_auth = None;
                        plans.claude_error = Some(err);
                    }
                    None => plans.claude_auth = None,
                }
                cx.notify();
            });
        })
        .detach();
    }

    // -------------------------------------------------------------- forms

    /// The account, model and consent rows for one plan.
    pub(super) fn plan_form(&mut self, plan: SubscriptionPlan, cx: &mut Context<Self>) -> Div {
        match plan {
            SubscriptionPlan::ChatGpt => {
                if self.models.plans.chatgpt_status.is_none() {
                    self.load_chatgpt(false, cx);
                }
            }
            SubscriptionPlan::Claude => {
                if !self.models.plans.claude_checked {
                    self.check_claude(false, cx);
                }
            }
        }
        let account = match plan {
            SubscriptionPlan::ChatGpt => self.chatgpt_account(cx),
            SubscriptionPlan::Claude => self.claude_account(cx),
        };
        v_flex()
            .w_full()
            .gap(px(14.))
            .child(account)
            .child(plan_consent(self.data.clone(), plan, cx))
    }

    fn chatgpt_account(&mut self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let plans = &self.models.plans;
        let signing_in = plans.signing_in;
        let mut body = v_flex().gap(px(10.));
        match &plans.chatgpt_status {
            None => {
                body = body.child(settings_row::help(lokalbot_i18n::tr("Loading models…"), cx));
            }
            Some(Err(err)) => {
                body = body.child(warning(err.clone(), cx));
            }
            Some(Ok(PlanStatus::SignedOut { previous_email })) => {
                let sign_in = page.clone();
                let cancel = page.clone();
                let other = page.clone();
                body = body
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Use your ChatGPT plan for Think instead of an API key."),
                        cx,
                    ))
                    .child(
                        h_flex()
                            .gap(px(12.))
                            .items_center()
                            .child(
                                Button::new("settings-chatgpt-sign-in")
                                    .primary()
                                    .small()
                                    .label(if signing_in {
                                        lokalbot_i18n::tr("Waiting for your browser…")
                                    } else {
                                        lokalbot_i18n::tr("Continue with ChatGPT")
                                    })
                                    .disabled(signing_in)
                                    .on_click(move |_, _, cx| {
                                        sign_in.update(cx, |page, cx| page.sign_in(false, cx))
                                    }),
                            )
                            .when(signing_in, |this| {
                                this.child(
                                    Button::new("settings-chatgpt-cancel")
                                        .outline()
                                        .small()
                                        .label(lokalbot_i18n::tr("Cancel"))
                                        .on_click(move |_, _, cx| {
                                            cancel.update(cx, |page, cx| page.cancel_sign_in(cx))
                                        }),
                                )
                            })
                            .when(!signing_in && previous_email.is_some(), |this| {
                                this.child(settings_row::link_button(
                                    "settings-chatgpt-other-account",
                                    lokalbot_i18n::tr("Use a different account"),
                                    move |_, cx| {
                                        other.update(cx, |page, cx| page.sign_in(true, cx))
                                    },
                                    cx,
                                ))
                            }),
                    );
                if signing_in {
                    body = body.child(settings_row::help(
                        lokalbot_i18n::tr("Finish signing in in your browser, then return here."),
                        cx,
                    ));
                } else if let Some(email) = previous_email {
                    body = body.child(settings_row::help(
                        lokalbot_i18n::format(
                            "Last signed in as {email}.",
                            &[("email", email.clone())],
                        ),
                        cx,
                    ));
                }
            }
            Some(Ok(PlanStatus::SignedIn { email, plan_usage })) => {
                let sign_out = page.clone();
                let account = email
                    .clone()
                    .unwrap_or_else(|| lokalbot_i18n::tr("Signed in").to_string());
                body = body.child(labelled(
                    lokalbot_i18n::tr("Account"),
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(ui::icon(Ico::CircleCheck, px(14.), lb.success_text))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(account),
                        )
                        .child(settings_row::link_button(
                            "settings-chatgpt-sign-out",
                            lokalbot_i18n::tr("Sign out"),
                            move |_, cx| sign_out.update(cx, |page, cx| page.sign_out(cx)),
                            cx,
                        )),
                    cx,
                ));
                if *plan_usage {
                    body = body
                        .child(labelled(
                            lokalbot_i18n::tr("Model"),
                            self.chatgpt_model_picker(cx),
                            cx,
                        ))
                        .child(labelled(
                            lokalbot_i18n::tr("Usage"),
                            h_flex()
                                .gap(px(6.))
                                .items_center()
                                .child(
                                    div()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text)
                                        .child(lokalbot_i18n::tr("Using ChatGPT plan")),
                                )
                                .child(div().text_color(lb.text_secondary).child("·"))
                                .child(manage_usage(
                                    "settings-chatgpt-usage",
                                    SubscriptionPlan::ChatGpt,
                                    cx,
                                )),
                            cx,
                        ));
                } else {
                    let allow = page.clone();
                    body = body.child(labelled(
                        lokalbot_i18n::tr("Usage"),
                        v_flex()
                            .gap(px(8.))
                            .child(warning(
                                lokalbot_i18n::tr(
                                    "This sign-in doesn't allow requests on your plan.",
                                ),
                                cx,
                            ))
                            .child(
                                h_flex().child(
                                    Button::new("settings-chatgpt-allow-usage")
                                        .outline()
                                        .small()
                                        .label(if signing_in {
                                            lokalbot_i18n::tr("Waiting for your browser…")
                                        } else {
                                            lokalbot_i18n::tr("Allow plan usage…")
                                        })
                                        .disabled(signing_in)
                                        .on_click(move |_, _, cx| {
                                            allow.update(cx, |page, cx| page.sign_in(false, cx))
                                        }),
                                ),
                            ),
                        cx,
                    ));
                }
            }
        }
        let plans = &self.models.plans;
        if let Some(error) = &plans.chatgpt_error {
            body = body.child(warning(error.clone(), cx));
        }
        if plans.revocation_unconfirmed {
            body = body.child(settings_row::help(
                lokalbot_i18n::tr("Signed out here, but OpenAI didn't confirm it. You can also disconnect LokalBot in ChatGPT settings."),
                cx,
            ));
        }
        if plans.show_notice {
            let data = self.data.clone();
            let dismiss = page.clone();
            body = body.child(
                v_flex()
                    .gap(px(8.))
                    .p(px(12.))
                    .rounded(px(8.))
                    .bg(lb.chip_fill)
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr("You're using your ChatGPT plan")),
                    )
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Eligible requests from LokalBot now use your ChatGPT plan. Manage usage and app access in ChatGPT settings. LokalBot has no charges of its own."),
                        cx,
                    ))
                    .child(
                        h_flex()
                            .gap(px(12.))
                            .items_center()
                            .child(
                                Button::new("settings-chatgpt-notice")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Got it"))
                                    .on_click(move |_, _, cx| {
                                        data.update(cx, |data, cx| {
                                            data.update_settings(
                                                |s| s.chatgpt_plan_notice_acknowledged = true,
                                                cx,
                                            )
                                        });
                                        dismiss.update(cx, |page, cx| {
                                            page.models.plans.show_notice = false;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .child(manage_usage("settings-chatgpt-notice-usage", SubscriptionPlan::ChatGpt, cx)),
                    ),
            );
        }
        body
    }

    fn chatgpt_model_picker(&mut self, cx: &mut Context<Self>) -> Div {
        let selection = self.data.read(cx).settings.chatgpt_plan_model.clone();
        let page = cx.entity();
        let plans = &self.models.plans;
        let mut models: Vec<(String, String)> = match &plans.chatgpt_models {
            Some(Ok(models)) => models
                .iter()
                .map(|m| (m.slug.clone(), m.display_name.clone()))
                .collect(),
            _ => Vec::new(),
        };
        // A saved model the list no longer offers stays visible instead of
        // silently changing.
        if !selection.is_empty() && !models.iter().any(|(slug, _)| *slug == selection) {
            models.push((selection.clone(), selection.clone()));
        }
        let current: SharedString = models
            .iter()
            .find(|(slug, _)| *slug == selection)
            .map(|(_, name)| SharedString::from(name.clone()))
            .unwrap_or_else(|| {
                if plans.chatgpt_loading {
                    lokalbot_i18n::tr("Loading models…").into()
                } else {
                    lokalbot_i18n::tr("Choose a model").into()
                }
            });
        let data = self.data.clone();
        let slugs: Vec<String> = models.iter().map(|(slug, _)| slug.clone()).collect();
        let mut row = h_flex()
            .gap(px(8.))
            .items_center()
            .child(settings_row::picker(
                "settings-chatgpt-model",
                current,
                models
                    .iter()
                    .map(|(slug, name)| (SharedString::from(name.clone()), *slug == selection))
                    .collect(),
                move |index, _, cx| {
                    if let Some(slug) = slugs.get(index).cloned() {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.chatgpt_plan_model = slug, cx)
                        });
                    }
                },
            ));
        let problem = match &plans.chatgpt_models {
            Some(Err(_)) => Some(lokalbot_i18n::tr("Couldn't load your plan's models.")),
            Some(Ok(models)) if models.is_empty() => {
                Some(lokalbot_i18n::tr("Your plan offered no models."))
            }
            _ => None,
        };
        if let Some(problem) = problem {
            row = row
                .child(settings_row::help(problem, cx))
                .child(settings_row::link_button(
                    "settings-chatgpt-models-retry",
                    lokalbot_i18n::tr("Try again"),
                    move |_, cx| page.update(cx, |page, cx| page.load_chatgpt(true, cx)),
                    cx,
                ));
        }
        row
    }

    fn claude_account(&mut self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let plans = &self.models.plans;
        let check_again = |id: &'static str, page: Entity<SettingsPage>| {
            Button::new(id)
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Check again"))
                .on_click(move |_, _, cx| page.update(cx, |page, cx| page.check_claude(true, cx)))
        };
        let status: Div = if plans.claude_checking || !plans.claude_checked {
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(settings_row::help(
                    lokalbot_i18n::tr("Looking for Claude Code…"),
                    cx,
                ))
        } else if plans.claude_executable.is_none() {
            v_flex()
                .gap(px(8.))
                .child(warning(
                    lokalbot_i18n::tr("Claude Code isn't installed on this PC."),
                    cx,
                ))
                .child(
                    h_flex()
                        .gap(px(12.))
                        .items_center()
                        .child(settings_row::link_button(
                            "settings-claude-install",
                            lokalbot_i18n::tr("How to install Claude Code"),
                            |_, _| {
                                let _ = lokalbot_platform::open_url(claude::SETUP_URL);
                            },
                            cx,
                        ))
                        .child(check_again("settings-claude-check", page.clone())),
                )
        } else if let Some(auth) = plans.claude_auth.as_ref().filter(|a| a.logged_in) {
            let mut parts: Vec<String> = Vec::new();
            if let Some(email) = &auth.email {
                parts.push(email.clone());
            }
            if let Some(plan) = auth.plan_name() {
                parts.push(lokalbot_i18n::format("{plan} plan", &[("plan", plan)]));
            }
            let signed_in = if parts.is_empty() {
                lokalbot_i18n::tr("Signed in").to_string()
            } else {
                parts.join(" · ")
            };
            let mut column = v_flex().gap(px(6.)).child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::CircleCheck, px(14.), lb.success_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(signed_in),
                    )
                    .child(manage_usage(
                        "settings-claude-usage",
                        SubscriptionPlan::Claude,
                        cx,
                    )),
            );
            let detail: Vec<String> = [
                plans
                    .claude_executable
                    .as_ref()
                    .map(|p| p.display().to_string()),
                plans.claude_version.clone(),
            ]
            .into_iter()
            .flatten()
            .collect();
            if !detail.is_empty() {
                column = column.child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .truncate()
                        .child(detail.join(" · ")),
                );
            }
            if !auth.uses_subscription() {
                column = column.child(warning(
                    lokalbot_i18n::format(
                        "Claude Code signs in with {method} rather than a Claude plan, so requests are billed that way.",
                        &[(
                            "method",
                            auth.auth_method.clone().unwrap_or_else(|| "?".into()),
                        )],
                    ),
                    cx,
                ));
            }
            column
        } else {
            v_flex()
                .gap(px(8.))
                .child(warning(lokalbot_i18n::tr("Claude Code isn't signed in."), cx))
                .child(settings_row::help(
                    lokalbot_i18n::tr("Run claude in a terminal and sign in with your Claude account. Then check again."),
                    cx,
                ))
                .child(h_flex().child(check_again("settings-claude-recheck", page.clone())))
        };
        let mut body = v_flex()
            .gap(px(10.))
            .child(settings_row::help(
                lokalbot_i18n::tr("Runs your own Claude Code with its tools turned off. You sign in to Claude Code yourself; LokalBot never sees your Claude sign-in."),
                cx,
            ))
            .child(labelled(lokalbot_i18n::tr("Account"), status, cx));
        if plans.claude_auth.as_ref().is_some_and(|a| a.logged_in) {
            body = body.child(labelled(
                lokalbot_i18n::tr("Model"),
                self.claude_model_picker(cx),
                cx,
            ));
        }
        if let Some(error) = &self.models.plans.claude_error {
            body = body.child(warning(error.clone(), cx));
        }
        body
    }

    fn claude_model_picker(&self, cx: &mut Context<Self>) -> Div {
        let selection = self
            .data
            .read(cx)
            .settings
            .claude_plan_model
            .trim()
            .to_string();
        let mut choices: Vec<(String, String)> = CLAUDE_CHOICES
            .iter()
            .map(|(slug, name)| {
                let name = if slug.is_empty() {
                    lokalbot_i18n::tr(name).to_string()
                } else {
                    name.to_string()
                };
                (slug.to_string(), name)
            })
            .collect();
        if !choices.iter().any(|(slug, _)| *slug == selection) {
            choices.push((selection.clone(), selection.clone()));
        }
        let current = choices
            .iter()
            .find(|(slug, _)| *slug == selection)
            .map(|(_, name)| name.clone())
            .unwrap_or_default();
        let data = self.data.clone();
        let slugs: Vec<String> = choices.iter().map(|(slug, _)| slug.clone()).collect();
        h_flex().child(settings_row::picker(
            "settings-claude-model",
            current,
            choices
                .iter()
                .map(|(slug, name)| (SharedString::from(name.clone()), *slug == selection))
                .collect(),
            move |index, _, cx| {
                if let Some(slug) = slugs.get(index).cloned() {
                    data.update(cx, |data, cx| {
                        data.update_settings(|s| s.claude_plan_model = slug, cx)
                    });
                }
            },
        ))
    }
}

/// "Allow sending context to OpenAI with my ChatGPT plan" and what it means.
fn plan_consent(data: Entity<AppData>, plan: SubscriptionPlan, cx: &App) -> Div {
    let lb = cx.lb();
    let approved = plan.is_approved(&data.read(cx).settings);
    let provider = plan.provider_name().to_string();
    let title = lokalbot_i18n::tr(plan.title()).to_string();
    v_flex()
        .gap(px(8.))
        .p(px(12.))
        .rounded(px(8.))
        .bg(lb.status_fill(lb.attention))
        .border_1()
        .border_color(lb.status_stroke(lb.attention))
        .child(
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(ui::icon(Ico::Network, px(14.), lb.attention_text))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "Allow sending context to {provider} with my {plan}",
                            &[("provider", provider.clone()), ("plan", title)],
                        ))),
                )
                .child(settings_row::switch(
                    SharedString::from(format!("settings-plan-consent-{}", plan.consent_key())),
                    approved,
                    move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| plan.set_approved(s, on), cx)
                        })
                    },
                )),
        )
        .child(settings_row::help(
            lokalbot_i18n::format(
                "Think may send meeting transcripts, Ask questions with their sources, and dictation requests to {provider} when you use those features. Scheduled daily summaries also run there without a prompt each time. {provider}'s terms for your account apply, and requests count toward your plan's usage limits.",
                &[("provider", provider)],
            ),
            cx,
        ))
}

fn labelled(title: &'static str, content: impl gpui_kit::IntoElement, cx: &App) -> Div {
    h_flex()
        .gap(px(16.))
        .items_start()
        .child(
            div()
                .w(px(80.))
                .flex_none()
                .text_size(ty::BODY)
                .text_color(cx.lb().text_secondary)
                .child(title),
        )
        .child(div().flex_1().min_w_0().child(content))
}

fn warning(text: impl Into<SharedString>, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(6.))
        .items_start()
        .child(ui::icon(Ico::TriangleAlert, px(13.), lb.attention_text))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .text_color(lb.attention_text)
                .child(crate::ui::text::paragraph(text)),
        )
}

fn manage_usage(id: &'static str, plan: SubscriptionPlan, cx: &App) -> gpui_kit::Stateful<Div> {
    settings_row::link_button(
        id,
        lokalbot_i18n::tr("Manage usage"),
        move |_, _| {
            let _ = lokalbot_platform::open_url(plan.manage_usage_url());
        },
        cx,
    )
}

/// OpenRouter's provider data policy, shown with an OpenRouter server URL.
pub(super) fn openrouter_policy(data: Entity<AppData>, cx: &App) -> Div {
    let policy = data.read(cx).settings.open_router_data_policy;
    let detail = match policy {
        OpenRouterDataPolicy::PrivateOnly => lokalbot_i18n::tr(
            "Every request is restricted to providers that do not collect inference data.",
        ),
        OpenRouterDataPolicy::AccountPolicy => lokalbot_i18n::tr(
            "Provider eligibility follows your OpenRouter account, API-key, workspace, and guardrail settings.",
        ),
    };
    v_flex()
        .gap(px(6.))
        .child(
            h_flex()
                .gap(px(10.))
                .items_center()
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(cx.lb().text)
                        .child(lokalbot_i18n::tr("Provider data use")),
                )
                .child(settings_row::picker(
                    "settings-openrouter-policy",
                    lokalbot_i18n::tr(policy.label()),
                    OpenRouterDataPolicy::ALL
                        .iter()
                        .map(|p| {
                            (
                                SharedString::from(lokalbot_i18n::tr(p.label())),
                                *p == policy,
                            )
                        })
                        .collect(),
                    move |index, window, cx| {
                        let chosen = OpenRouterDataPolicy::ALL[index];
                        let current = data.read(cx).settings.open_router_data_policy;
                        if chosen == OpenRouterDataPolicy::AccountPolicy && current != chosen {
                            confirm_account_policy(data.clone(), window, cx);
                        } else {
                            data.update(cx, |data, cx| {
                                data.update_settings(|s| s.open_router_data_policy = chosen, cx)
                            });
                        }
                    },
                )),
        )
        .child(settings_row::help(detail, cx))
}

fn confirm_account_policy(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        alert
            .title(lokalbot_i18n::tr("Follow your OpenRouter privacy policy?"))
            .description(lokalbot_i18n::tr("Approved meeting transcripts, screen text, and Agent context may be sent to providers that retain requests or use them for training. LokalBot cannot verify the OpenRouter policy attached to this account, API key, workspace, or guardrail."))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Follow OpenRouter Policy"))
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.update_settings(
                        |s| s.open_router_data_policy = OpenRouterDataPolicy::AccountPolicy,
                        cx,
                    )
                });
                true
            })
    });
}

/// What Think does with an Anthropic API URL.
pub(super) fn anthropic_note(cx: &App) -> Div {
    v_flex()
        .gap(px(4.))
        .child(
            div()
                .text_size(ty::BODY)
                .text_color(cx.lb().text)
                .child(lokalbot_i18n::tr("Anthropic API")),
        )
        .child(settings_row::help(
            lokalbot_i18n::tr("Think uses Anthropic's Messages API with prompt caching: Anthropic keeps the system prompt and shared context for about five minutes so repeated requests cost less. Agent Mode uses Anthropic's OpenAI-compatible endpoint."),
            cx,
        ))
}
